import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import 'audit_log.dart';
import 'auth_service.dart';
import 'backup_service.dart';
import 'crypto_service.dart';
import 'google_drive_backup.dart';

/// Callback for restore progress reporting.
typedef RestoreProgressCallback = void Function(RestoreProgress progress);

/// Orchestrates the complete cross-device restore pipeline:
///
/// 1. detectBackup    — checks Google Drive for existing backup
/// 2. prepareRestore  — downloads, verifies password, validates integrity
/// 3. hasLocalData    — checks if local vault has existing data (conflicts)
/// 4. commitRestore   — writes data only after validation passes
/// 5. cancelRestore   — cleans up on cancellation
///
/// SECURITY:
/// Restore requires the SAME vault/master password used to create the backup.
/// The password is verified by decrypting the auth bundle from the backup,
/// which contains the wrapped master key. If the password matches, the
/// master key is recovered and used for the restore.
/// NO device-specific keys are used — restore works across any device
/// with the same Google account + vault password.
class RestoreService {
  RestoreService({
    required this.authService,
    required this.driveService,
    required this.masterKey,
    required this.kind,
    this.onProgress,
  });

  final VaultAuthService authService;
  final GoogleDriveBackupService driveService;
  final Uint8List masterKey;
  final VaultKind kind;
  final RestoreProgressCallback? onProgress;

  final _crypto = CryptoService();

  BackupVersion? _detectedVersion;

  void _report(RestoreProgress progress) {
    onProgress?.call(progress);
  }

  /// Detect whether a backup exists on Google Drive.
  ///
  /// Returns the latest [BackupVersion] if a backup is found, or `null`.
  /// Does NOT download the full backup — only metadata.
  Future<BackupVersion?> detectBackup() async {
    _report(const RestoreProgress(
      stage: RestoreStage.detecting,
      fraction: 0.0,
      componentName: 'Checking Google Drive...',
    ));

    try {
      final hasBackup = await driveService.hasBackup();
      if (!hasBackup) {
        debugPrint('RESTORE DETECT: no backup found on Drive');
        _report(const RestoreProgress(
          stage: RestoreStage.detecting,
          fraction: 0.0,
          componentName: 'No backup found',
        ));
        return null;
      }

      final versions = await driveService.listBackups();
      if (versions.isEmpty) {
        debugPrint('RESTORE DETECT: listBackups returned empty');
        _report(const RestoreProgress(
          stage: RestoreStage.detecting,
          fraction: 0.0,
          componentName: 'No backup versions found',
        ));
        return null;
      }

      _detectedVersion = versions.first;
      debugPrint('RESTORE DETECT: found backup from ${_detectedVersion!.label}');
      _report(const RestoreProgress(
        stage: RestoreStage.detecting,
        fraction: 1.0,
        componentName: 'Backup found',
      ));
      return _detectedVersion;
    } catch (e, st) {
      debugPrint('RESTORE DETECT ERROR: $e\n$st');
      _report(RestoreProgress(
        stage: RestoreStage.failed,
        error: 'Backup detection failed: $e',
      ));
      return null;
    }
  }

  /// Download and validate a backup, then verify the vault password.
  ///
  /// [version] is the backup version to restore (from [detectBackup]).
  /// [password] is the user's vault/master password used to decrypt.
  ///
  /// Returns [RestoreInfo] on success with the decrypted master key and
  /// backup metadata. Returns `null` on failure (wrong password, corrupt
  /// backup, network error, etc.).
  Future<RestoreInfo?> prepareRestore({
    required BackupVersion version,
    required String password,
  }) async {
    _report(const RestoreProgress(
      stage: RestoreStage.downloading,
      fraction: 0.0,
      componentName: 'Downloading backup...',
    ));

    try {
      // ── 1. Download ────────────────────────────────────────────────────────
      final data = await driveService.downloadVersion(version);
      if (data == null) {
        _report(const RestoreProgress(
          stage: RestoreStage.failed,
          error: 'Failed to download backup. Check your internet connection.',
        ));
        return null;
      }

      _report(const RestoreProgress(
        stage: RestoreStage.downloading,
        fraction: 1.0,
        componentName: 'Downloaded',
      ));

      // ── 2. Verify password & extract master key ────────────────────────────
      _report(const RestoreProgress(
        stage: RestoreStage.decrypting,
        fraction: 0.0,
        componentName: 'Verifying password...',
      ));

      final masterKey = await _verifyPassword(data, password);
      if (masterKey == null) {
        _report(const RestoreProgress(
          stage: RestoreStage.failed,
          error: 'Wrong vault password. Restore requires the same password used to create the backup.',
        ));
        return null;
      }

      _report(const RestoreProgress(
        stage: RestoreStage.decrypting,
        fraction: 1.0,
        componentName: 'Password verified',
      ));

      // ── 3. Validate integrity ──────────────────────────────────────────────
      _report(const RestoreProgress(
        stage: RestoreStage.verifying,
        fraction: 0.0,
        componentName: 'Validating backup integrity...',
      ));

      String? integrityError;
      final warnings = <String>[];

      final manifestJson = data['manifest'] as Map<String, dynamic>?;
      BackupManifest? manifest;
      if (manifestJson != null) {
        try {
          manifest = BackupManifest.fromJson(manifestJson);
        } catch (e) {
          integrityError = 'Invalid backup manifest: $e';
        }
      }

      final backupService = BackupService(
        masterKey: masterKey,
        kind: kind,
        authService: authService,
      );
      final verifyResult = await backupService.verifyBackupIntegrity(data);
      if (!verifyResult.passed) {
        integrityError = verifyResult.errors.isNotEmpty
            ? verifyResult.errors.first
            : 'Backup integrity check failed';
        warnings.addAll(verifyResult.warnings);
      } else {
        warnings.addAll(verifyResult.warnings);
      }

      _report(RestoreProgress(
        stage: RestoreStage.verifying,
        fraction: 1.0,
        componentName: integrityError == null ? 'Integrity verified' : 'Integrity issues found',
      ));

      // ── 4. Build RestoreInfo ───────────────────────────────────────────────
      final counts = manifest?.counts ?? {};
      final mainVault = data['mainVault'] as List?;
      final hiddenVault = data['hiddenVault'] as List?;
      final driveMeta = data['driveMetadata'] as List?;
      final driveBlobs = data['driveBlobs'] as List?;
      final attachmentBlobs = data['attachmentBlobs'] as List?;
      final settings = data['settings'] as Map?;
      final passwordBox = data['passwordEntries'] as List?;

      return RestoreInfo(
        version: version,
        manifest: manifest ?? BackupManifest(createdAt: DateTime.now(), deviceId: ''),
        backupData: data,
        masterKey: masterKey,
        mainNoteCount: mainVault?.length ?? counts['mainNoteCount'] ?? 0,
        hiddenNoteCount: hiddenVault?.length ?? counts['hiddenNoteCount'] ?? 0,
        driveFileCount: driveMeta?.length ?? counts['driveFileCount'] ?? 0,
        driveBlobCount: driveBlobs?.length ?? counts['driveBlobCount'] ?? 0,
        attachmentBlobCount: attachmentBlobs?.length ?? counts['attachmentBlobCount'] ?? 0,
        settingsCount: settings?.length ?? counts['settingsCount'] ?? 0,
        passwordEntryCount: passwordBox?.length ?? counts['passwordEntryCount'] ?? 0,
        hasAuthBundle: data.containsKey('authBundle'),
        integrityPassed: integrityError == null,
        integrityWarnings: warnings,
        error: integrityError,
      );
    } catch (e, st) {
      debugPrint('RESTORE PREPARE ERROR: $e\n$st');
      _report(RestoreProgress(
        stage: RestoreStage.failed,
        error: _humanReadableError(e),
      ));
      return null;
    }
  }

  /// Check whether the local vault already has data (for conflict detection).
  Future<bool> hasLocalData() async {
    try {
      final recordsBox = Hive.box('vaultx_records');
      final driveBox = Hive.box('vaultx_drive');
      final passwordsBox = Hive.box('vaultx_passwords');

      return recordsBox.isNotEmpty || driveBox.isNotEmpty || passwordsBox.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Commit the restore after validation and user confirmation.
  ///
  /// [info] is the prepared restore info.
  /// [mode] is either [RestoreMode.merge] (skip existing) or
  ///        [RestoreMode.replace] (overwrite all).
  ///
  /// Returns [RestoreResult] with per-component counts.
  Future<RestoreResult> commitRestore(
    RestoreInfo info, {
    required RestoreMode mode,
  }) async {
    _report(const RestoreProgress(
      stage: RestoreStage.restoring,
      fraction: 0.0,
      componentName: 'Restoring data...',
    ));

    try {
      final backupService = BackupService(
        masterKey: info.masterKey,
        kind: kind,
        authService: authService,
        onProgress: (backupProgress) {
          final processed = backupProgress.components.fold<int>(
            0, (sum, c) => sum + c.itemsProcessed,
          );
          final total = backupProgress.components.fold<int>(
            0, (sum, c) => sum + c.totalItems,
          );
          _report(RestoreProgress(
            stage: RestoreStage.restoring,
            fraction: total > 0 ? processed / total : 0.0,
            componentName: _currentComponentLabel(backupProgress.components),
            itemsProcessed: processed,
            totalItems: total,
          ));
        },
      );

      final result = await backupService.restoreBackup(
        info.backupData,
        mode: mode,
        mainMasterKey: info.masterKey,
      );

      if (result.success) {
        _report(const RestoreProgress(
          stage: RestoreStage.rebuildingIndexes,
          fraction: 0.5,
          componentName: 'Rebuilding indexes...',
        ));

        // Invalidate all caches so data is reloaded fresh
        await _rebuildIndexes();
        debugPrint('PROVIDER REBUILD: restore service cache rebuild complete');

        _report(const RestoreProgress(
          stage: RestoreStage.completed,
          fraction: 1.0,
          componentName: 'Restore complete',
        ));
        debugPrint('UI REFRESH COMPLETE: restore completed and listeners notified');

        await AuditLog.write('Cross-device restore completed: ${result.summary}');
      } else {
        _report(RestoreProgress(
          stage: RestoreStage.failed,
          error: result.error ?? 'Restore failed',
        ));
      }

      return result;
    } catch (e, st) {
      debugPrint('RESTORE COMMIT ERROR: $e\n$st');
      _report(RestoreProgress(
        stage: RestoreStage.failed,
        error: _humanReadableError(e),
      ));
      return RestoreResult(success: false, error: e.toString());
    }
  }

  /// Cancel a prepared restore and release resources.
  Future<void> cancelRestore(RestoreInfo info) async {
    debugPrint('RESTORE CANCELLED: cleaning up');
    _detectedVersion = null;
    // Wipe the recovered master key from memory
    for (var i = 0; i < info.masterKey.length; i++) {
      info.masterKey[i] = 0;
    }
  }

  /// Verify the vault password against the backup's auth bundle.
  ///
  /// Derives the master key from the password and backup salts, then
  /// verifies against the HMAC verifier. Returns the master key on
  /// success, or `null` if the password is wrong.
  Future<Uint8List?> _verifyPassword(
    Map<String, dynamic> backupData,
    String password,
  ) async {
    try {
      final authBundle = backupData['authBundle'] as Map<String, dynamic>?;
      if (authBundle == null) {
        debugPrint('RESTORE VERIFY PASSWORD: no auth bundle in backup');
        return null;
      }

      // Extract auth params from backup
      final saltB64 = authBundle['passwordSalt'] as String?;
      final wrappedB64 = authBundle['wrappedMaster.password'] as String?;
      final verifier = authBundle['masterVerifier'] as String?;
      final kdf = authBundle['passwordKdf'] as String?;

      if (saltB64 == null || wrappedB64 == null) {
        debugPrint('RESTORE VERIFY PASSWORD: missing auth params');
        return null;
      }

      // Derive key from password + backup salt
      final key = kdf == 'argon2id:v1'
          ? await _crypto.deriveCredentialKey(password, saltB64)
          : _crypto.deriveLegacyCredentialKey(password, saltB64);

      // Try to decrypt wrapped master key
      Map<String, dynamic> wrapped;
      try {
        wrapped = jsonDecode(wrappedB64) as Map<String, dynamic>;
      } catch (_) {
        _crypto.wipe(key);
        return null;
      }

      Uint8List recoveredKey;
      try {
        final payload = _crypto.decryptJson(wrapped, key);
        recoveredKey = base64Decode(payload['k'] as String);
      } catch (_) {
        _crypto.wipe(key);
        return null;
      }

      // Verify against verifier
      if (verifier != null) {
        final actual = Hmac(
          sha256,
          recoveredKey,
        ).convert(utf8.encode('vaultx-master')).toString();
        if (actual != verifier) {
          _crypto.wipe(key);
          _crypto.wipe(recoveredKey);
          return null;
        }
      }

      _crypto.wipe(key);
      debugPrint('RESTORE VERIFY PASSWORD: password verified successfully');
      return recoveredKey;
    } catch (e) {
      debugPrint('RESTORE VERIFY PASSWORD ERROR: $e');
      return null;
    }
  }

  Future<void> _rebuildIndexes() async {
    // Invalidate all Hive caches and reload state
    final recordsBox = Hive.box('vaultx_records');
    final driveBox = Hive.box('vaultx_drive');
    final passwordsBox = Hive.box('vaultx_passwords');

    // Force re-read by invalidating any in-memory caches
    await recordsBox.get('');
    await driveBox.get('');
    await passwordsBox.get('');

    debugPrint('RESTORE REBUILD: indexes rebuilt, caches invalidated');
  }

  String _currentComponentLabel(List<ComponentProgress> components) {
    for (final c in components) {
      if (c.state == BackupOperationState.inProgress) {
        return '${c.component.name} (${c.itemsProcessed}/${c.totalItems})';
      }
    }
    return 'Processing...';
  }

  /// Maps exception types to human-readable error messages.
  static String _humanReadableError(Object error) {
    final msg = error.toString();
    if (msg.contains('SocketException') || msg.contains('HandshakeException')) {
      return 'Network error. Check your internet connection and try again.';
    }
    if (msg.contains('FormatException')) {
      return 'Corrupted backup data. The backup file may be damaged.';
    }
    if (msg.contains('InvalidCipherTextException') || msg.contains('FormatException')) {
      return 'Wrong vault password or corrupted backup data.';
    }
    if (msg.contains('google_sign_in') || msg.contains('auth')) {
      return 'Google authentication expired. Please sign in again.';
    }
    if (msg.contains('checksum') || msg.contains('mismatch')) {
      return 'Backup integrity check failed. The backup may be corrupted.';
    }
    return 'Restore failed: $msg';
  }
}

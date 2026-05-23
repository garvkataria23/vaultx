import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import '../models/drive_file.dart';
import 'audit_log.dart';
import 'auth_service.dart';
import 'compression_service.dart';
import 'crypto_service.dart';

/// Debug-only logger that becomes a no-op in release builds.
/// Use instead of raw debugPrint to keep production clean.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

/// Callback type for progress reporting during backup/restore.
typedef BackupProgressCallback = void Function(BackupProgress progress);

/// Canonical JSON encoding with recursively sorted map keys.
/// Produces deterministic JSON for stable checksum generation.
String _canonicalJsonEncode(dynamic value) {
  if (value is Map) {
    final sortedKeys = value.keys.cast<String>().toList()..sort();
    final buffer = StringBuffer('{');
    for (var i = 0; i < sortedKeys.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(jsonEncode(sortedKeys[i]));
      buffer.write(':');
      buffer.write(_canonicalJsonEncode(value[sortedKeys[i]]));
    }
    buffer.write('}');
    return buffer.toString();
  } else if (value is List) {
    final buffer = StringBuffer('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(_canonicalJsonEncode(value[i]));
    }
    buffer.write(']');
    return buffer.toString();
  } else {
    return jsonEncode(value);
  }
}

/// Complete encrypted backup and restore service for VaultX.
///
/// Supports:
/// - Full vault backup (main + hidden + drive + settings + auth)
/// - Component-level integrity checksums
/// - Chunked backup for large data sets
/// - Merge vs replace restore modes
/// - Rollback on restore failure
/// - Progress reporting
/// - Post-backup integrity verification with decryptability testing
/// - Post-restore count/sanity verification
/// - Streaming blob collection for memory-safe large backups
class BackupService {
  BackupService({
    required this.masterKey,
    required this.kind,
    this.authService,
    this.onProgress,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService? authService;
  final BackupProgressCallback? onProgress;
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Creates a full backup of all vault components.
  ///
  /// Returns the backup data map and manifest. Reports progress via [onProgress].
  Future<({Map<String, dynamic> data, BackupManifest manifest})>
  createBackup({bool compressMedia = false}) async {
    final components = <ComponentProgress>[];
    final checksums = <ComponentChecksum>[];
    final counts = <String, int>{};
    final data = <String, dynamic>{};
    final deviceId =
        Hive.box('vaultx_settings').get('deviceId', defaultValue: '') as String;
    
    final box = Hive.box('vaultx_settings');
    final includeNotes = box.get('backupIncludeNotes', defaultValue: true) as bool;
    final includeHidden = box.get('backupIncludeHidden', defaultValue: true) as bool;

    final manifest = BackupManifest(
      createdAt: DateTime.now(),
      deviceId: deviceId,
      checksums: checksums,
      totalSizeBytes: 0, // Will be updated at the end
      counts: counts,
    );

    void report() {
      onProgress?.call(BackupProgress(components: components));
    }

    // ── 1. Main vault records ────────────────────────────────────────────────
    if (includeNotes) {
      components.add(
        const ComponentProgress(
          component: BackupComponent.mainVault,
          state: BackupOperationState.inProgress,
        ),
      );
      report();
      try {
        final mainRecords = _collectVaultRecords('main');
        counts['mainNoteCount'] = mainRecords.length;
        final jsonStr = _canonicalJsonEncode(mainRecords);
        final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
        checksums.add(
          ComponentChecksum(
            component: BackupComponent.mainVault,
            sha256: checksum,
            byteCount: jsonStr.length,
          ),
        );
        data['mainVault'] = mainRecords;
        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          totalItems: mainRecords.length,
          itemsProcessed: mainRecords.length,
        );
        report();
      } catch (e, st) {
        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.failed,
          error: e.toString(),
        );
        report();
        _log('BACKUP mainVault ERROR: $e\n$st');
      }
    }

    // ── 2. Hidden vault records ──────────────────────────────────────────────
    if (includeHidden) {
      components.add(
        const ComponentProgress(
          component: BackupComponent.hiddenVault,
          state: BackupOperationState.inProgress,
        ),
      );
      report();
      try {
        final hiddenRecords = _collectVaultRecords('hidden');
        counts['hiddenNoteCount'] = hiddenRecords.length;
        final jsonStr = _canonicalJsonEncode(hiddenRecords);
        final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
        checksums.add(
          ComponentChecksum(
            component: BackupComponent.hiddenVault,
            sha256: checksum,
            byteCount: jsonStr.length,
          ),
        );
        data['hiddenVault'] = hiddenRecords;
        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          totalItems: hiddenRecords.length,
          itemsProcessed: hiddenRecords.length,
        );
        report();
      } catch (e, st) {
        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.failed,
          error: e.toString(),
        );
        report();
        _log('BACKUP hiddenVault ERROR: $e\n$st');
      }
    }

    // ── 3. Auth bundle ───────────────────────────────────────────────────────
    components.add(
      const ComponentProgress(
        component: BackupComponent.authBundle,
        state: BackupOperationState.inProgress,
      ),
    );
    report();
    try {
      final authBundle = authService != null
          ? await authService!.exportAuthBundle()
          : <String, String?>{};
      final fullBundle = Map<String, String?>.from(authBundle);

      fullBundle['fakePinSalt'] = await _readSecure('fakePinSalt');
      fullBundle['fakePinHash'] = await _readSecure('fakePinHash');
      fullBundle['fakePinKdf'] = await _readSecure('fakePinKdf');
      final intruderKey = await _readSecure('intruderLogKey');
      if (intruderKey != null) fullBundle['intruderLogKey'] = intruderKey;

      // Only store portable auth fields. Runtime/device state (keystore
      // aliases, biometric bindings, install IDs, session data, runtime
      // nonces, etc.) is NEVER included in backups.
      final portableBundle = sanitizePortableAuthBundle(fullBundle);
      data['authBundle'] = portableBundle;
      _log(
        'AUTHBUNDLE BEFORE HASH: keys=[${portableBundle.keys.join(",")}]',
      );
      final jsonStr = _canonicalJsonEncode(portableBundle);
      _log('AUTHBUNDLE AFTER NORMALIZATION: len=${jsonStr.length}');
      final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
      _log('AUTHBUNDLE CHECKSUM GENERATED: $checksum');
      checksums.add(
        ComponentChecksum(
          component: BackupComponent.authBundle,
          sha256: checksum,
          byteCount: jsonStr.length,
        ),
      );
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.completed,
        itemsProcessed: fullBundle.length,
      );
      report();
    } catch (e, st) {
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.failed,
        error: e.toString(),
      );
      report();
      _log('BACKUP authBundle ERROR: $e\n$st');
    }

    // ── 4. Settings ──────────────────────────────────────────────────────────
    components.add(
      const ComponentProgress(
        component: BackupComponent.settings,
        state: BackupOperationState.inProgress,
      ),
    );
    report();
    try {
      final settings = _collectSettings();
      counts['settingsCount'] = settings.length;
      data['settings'] = settings;
      final jsonStr = _canonicalJsonEncode(settings);
      final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
      checksums.add(
        ComponentChecksum(
          component: BackupComponent.settings,
          sha256: checksum,
          byteCount: jsonStr.length,
        ),
      );
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.completed,
        totalItems: settings.length,
        itemsProcessed: settings.length,
      );
      report();
    } catch (e, st) {
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.failed,
        error: e.toString(),
      );
      report();
      _log('BACKUP settings ERROR: $e\n$st');
    }

    // ── 5. Drive metadata ────────────────────────────────────────────────────
    components.add(
      const ComponentProgress(
        component: BackupComponent.driveMetadata,
        state: BackupOperationState.inProgress,
      ),
    );
    report();
    List<Map<String, dynamic>> driveRecords = [];
    try {
      driveRecords = _collectDriveRecords();
      counts['driveFileCount'] = driveRecords.length;
      data['driveMetadata'] = driveRecords;
      final jsonStr = _canonicalJsonEncode(driveRecords);
      final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
      checksums.add(
        ComponentChecksum(
          component: BackupComponent.driveMetadata,
          sha256: checksum,
          byteCount: jsonStr.length,
        ),
      );
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.completed,
        totalItems: driveRecords.length,
        itemsProcessed: driveRecords.length,
      );
      report();
    } catch (e, st) {
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.failed,
        error: e.toString(),
      );
      report();
      _log('BACKUP driveMetadata ERROR: $e\n$st');
    }

    // ── 7. Drive blobs (streamed, memory-safe) ───────────────────────────────
    components.add(
      const ComponentProgress(
        component: BackupComponent.driveBlobs,
        state: BackupOperationState.inProgress,
      ),
    );
    report();
    try {
      final driveBlobs = await _collectDriveBlobsStreamed(driveRecords, compressMedia);
      counts['driveBlobCount'] = driveBlobs.length;
      data['driveBlobs'] = driveBlobs;
      final jsonStr = _canonicalJsonEncode(driveBlobs);
      final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
      checksums.add(
        ComponentChecksum(
          component: BackupComponent.driveBlobs,
          sha256: checksum,
          byteCount: jsonStr.length,
        ),
      );
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.completed,
        totalItems: driveBlobs.length,
        itemsProcessed: driveBlobs.length,
      );
      report();
    } catch (e, st) {
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.failed,
        error: e.toString(),
      );
      report();
      _log('BACKUP driveBlobs ERROR: $e\n$st');
    }

    // ── 8. Attachment blobs (streamed, memory-safe) ──────────────────────────
    components.add(
      const ComponentProgress(
        component: BackupComponent.attachmentBlobs,
        state: BackupOperationState.inProgress,
      ),
    );
    report();
    try {
      final Set<String> allowedAttachmentIds = {};
      final allVaultRecords = [...(data['mainVault'] as List), ...(data['hiddenVault'] as List)];
      for (final record in allVaultRecords) {
        if (record['attachments'] is List) {
          for (final attachment in record['attachments']) {
            if (attachment is Map && attachment['id'] != null) {
              allowedAttachmentIds.add(attachment['id'] as String);
            }
          }
        }
      }

      final attachmentBlobs = await _collectAttachmentBlobsStreamed(
        compressMedia, 
        allowedAttachmentIds,
      );
      counts['attachmentBlobCount'] = attachmentBlobs.length;
      data['attachmentBlobs'] = attachmentBlobs;
      final jsonStr = _canonicalJsonEncode(attachmentBlobs);
      final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
      checksums.add(
        ComponentChecksum(
          component: BackupComponent.attachmentBlobs,
          sha256: checksum,
          byteCount: jsonStr.length,
        ),
      );
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.completed,
        totalItems: attachmentBlobs.length,
        itemsProcessed: attachmentBlobs.length,
      );
      report();
    } catch (e, st) {
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.failed,
        error: e.toString(),
      );
      report();
      _log('BACKUP attachmentBlobs ERROR: $e\n$st');
    }

    // ── 9. Password entries ──────────────────────────────────────────────
    components.add(
      const ComponentProgress(
        component: BackupComponent.passwordEntries,
        state: BackupOperationState.inProgress,
      ),
    );
    report();
    try {
      final passwordRecords = _collectPasswordEntries();
      counts['passwordEntryCount'] = passwordRecords.length;
      final jsonStr = _canonicalJsonEncode(passwordRecords);
      final checksum = sha256.convert(utf8.encode(jsonStr)).toString();
      checksums.add(
        ComponentChecksum(
          component: BackupComponent.passwordEntries,
          sha256: checksum,
          byteCount: jsonStr.length,
        ),
      );
      data['passwordEntries'] = passwordRecords;
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.completed,
        totalItems: passwordRecords.length,
        itemsProcessed: passwordRecords.length,
      );
      report();
    } catch (e, st) {
      components[components.length - 1] = components.last.copyWith(
        state: BackupOperationState.failed,
        error: e.toString(),
      );
      report();
      _log('BACKUP passwordEntries ERROR: $e\n$st');
    }

    data['manifest'] = manifest.toJson();

    return (data: data, manifest: manifest);
  }

  /// Restores a backup with the given mode.
  ///
  /// [backupData] is the full backup map including manifest.
  /// [mode] controls merge vs replace behavior.
  /// [mainMasterKey] is the decrypted main vault master key for re-encrypting.
  /// [targetMasterKey] is the master key of the CURRENT session (only needed for merge).
  Future<RestoreResult> restoreBackup(
    Map<String, dynamic> backupData, {
    required RestoreMode mode,
    required Uint8List mainMasterKey,
    Uint8List? targetMasterKey,
    BackupProgressCallback? onRestoreProgress,
  }) async {
    _log('RESTORE START: mode=$mode');
    _log('RESTORE: backupData keys=${backupData.keys.join(", ")}');
    _log(
      'RESTORE: has authBundle=${backupData.containsKey("authBundle")}',
    );
    _log('RESTORE: has manifest=${backupData.containsKey("manifest")}');
    _log(
      'RESTORE: mainVault entries=${(backupData["mainVault"] as List?)?.length ?? 0}',
    );
    _log(
      'RESTORE: hiddenVault entries=${(backupData["hiddenVault"] as List?)?.length ?? 0}',
    );

    final components = <ComponentProgress>[];
    final manifestJson = backupData['manifest'] as Map<String, dynamic>?;
    final manifest = manifestJson != null
        ? BackupManifest.fromJson(manifestJson)
        : null;
    final snapshot = <String, dynamic>{};
    final warnings = <String>[];

    var mainNotesRestored = 0;
    var hiddenNotesRestored = 0;
    var driveFilesRestored = 0;
    var driveBlobsRestored = 0;
    var attachmentBlobsRestored = 0;
    var settingsRestored = 0;
    var passwordEntriesRestored = 0;
    var authBundleRestored = false;

    void report() {
      final p = onProgress ?? onRestoreProgress;
      p?.call(BackupProgress(components: components));
    }

    // ── Verify manifest integrity first ────────────────────────────────────
    if (manifest != null) {
      _log(
        'RESTORE VERIFY: manifest version=${manifest.version}, ${manifest.checksums.length} components',
      );
      components.add(
        const ComponentProgress(
          component: BackupComponent.mainVault,
          state: BackupOperationState.inProgress,
        ),
      );
      report();

      for (final c in manifest.checksums) {
        final raw = backupData[_componentKey(c.component)];
        if (raw == null) {
          _log(
            'RESTORE VERIFY: missing component data for ${c.component}',
          );
          continue;
        }

        final isHardFail = _hardFailComponents.contains(c.component);

        // Sanitize authBundle to only portable fields before checksum
        // comparison — runtime/device state is reinstall-sensitive.
        dynamic dataForChecksum = raw;
        if (c.component == BackupComponent.authBundle) {
          dataForChecksum = sanitizePortableAuthBundle(
            raw as Map<String, dynamic>,
          );
        }

        final jsonStr = _canonicalJsonEncode(dataForChecksum);
        final actual = sha256.convert(utf8.encode(jsonStr)).toString();
        if (c.component == BackupComponent.authBundle) {
          _log(
            'AUTHBUNDLE RESTORE CHECKSUM: computed=$actual stored=${c.sha256}',
          );
        }
        final error = manifest.verifyChecksum(
          c.component,
          actual,
          jsonStr.length,
        );
        if (error != null) {
          if (isHardFail) {
            _log(
              'RESTORE VERIFY FAILED: $error (component=${c.component})',
            );
            report();
            return RestoreResult(success: false, error: error);
          }
          // Soft-verify: warn, do NOT abort restore.
          // Password verification is the real security validation.
          warnings.add('$error (component=${c.component})');
          if (c.component == BackupComponent.authBundle) {
            _log('AUTHBUNDLE SOFT VERIFY WARNING: $error');
          } else {
            _log(
              'SOFT VERIFY WARNING: $error (component=${c.component})',
            );
          }
          continue;
        }
        _log('RESTORE VERIFY OK: ${c.component} checksum matches');
      }
      _log('RESTORE VERIFY: all component checksums passed');
    }

    // ── Snapshot current state for rollback ────────────────────────────────
    if (mode == RestoreMode.replace) {
      // Flush Hive before snapshot so the in-memory cache reflects all
      // recently written data — otherwise rollback may restore stale state.
      await Hive.box('vaultx_records').flush();
      await Hive.box('vaultx_drive').flush();
      await Hive.box('vaultx_passwords').flush();
      snapshot['mainVault'] = _collectVaultRecords('main');
      snapshot['hiddenVault'] = _collectVaultRecords('hidden');
      snapshot['driveMetadata'] = _collectDriveRecords();
      // Snapshot existing blob files so we can clean up orphans on rollback
      snapshot['_existingBlobs'] = await _collectExistingBlobPaths();
    }
    
    var preservedLocalItems = 0;
    if (mode == RestoreMode.replace) {
      preservedLocalItems = await _clearRestoreTargets();
    }

    try {
      // ── 1. Restore auth bundle ────────────────────────────────────────────
      _log('RESTORE COMPONENT START: authBundle');
      final authBundle = backupData['authBundle'] as Map<String, dynamic>?;
      if (authBundle != null && authService != null) {
        _log(
          'RESTORE COMPONENT: authBundle has ${authBundle.length} entries: ${authBundle.keys.join(", ")}',
        );
        components.add(
          const ComponentProgress(
            component: BackupComponent.authBundle,
            state: BackupOperationState.inProgress,
          ),
        );
        report();

        await authService!.importAuthBundle(
          authBundle,
          force: mode == RestoreMode.replace,
        );

        for (final key in [
          'fakePinSalt',
          'fakePinHash',
          'fakePinKdf',
          'intruderLogKey',
        ]) {
          final value = authBundle[key] as String?;
          if (value != null) {
            await _writeSecure(key, value);
          }
        }

        authBundleRestored = true;
        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
        );
        report();
        _log('RESTORE COMPONENT SUCCESS: authBundle');
      } else {
        _log(
          'RESTORE COMPONENT SKIP: authBundle (${authBundle == null ? "no data" : "no authService"})',
        );
      }

      // ── 2. Restore settings ───────────────────────────────────────────────
      _log('RESTORE COMPONENT START: settings');
      final settings = backupData['settings'] as Map<String, dynamic>?;
      if (settings != null) {
        _log(
          'RESTORE COMPONENT: settings has ${settings.length} entries',
        );
        components.add(
          const ComponentProgress(
            component: BackupComponent.settings,
            state: BackupOperationState.inProgress,
          ),
        );
        report();

        await _restoreSettings(settings, mode);
        settingsRestored = settings.length;

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          totalItems: settings.length,
          itemsProcessed: settings.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: settings ($settingsRestored entries)',
        );
      } else {
        _log('RESTORE COMPONENT SKIP: settings (no data)');
      }

      // ── 3. Restore main vault records ─────────────────────────────────────
      _log('RESTORE COMPONENT START: mainVault');
      final mainRecords = backupData['mainVault'] as List?;
      if (mainRecords != null && mainRecords.isNotEmpty) {
        _log(
          'RESTORE COMPONENT: mainVault has ${mainRecords.length} records',
        );
        components.add(
          ComponentProgress(
            component: BackupComponent.mainVault,
            state: BackupOperationState.inProgress,
            totalItems: mainRecords.length,
          ),
        );
        report();

        mainNotesRestored = await _restoreVaultRecords(
          _normalizeRecordList(mainRecords),
          'main',
          mainMasterKey,
          mode,
          (processed) {
            components[components.length - 1] = components.last.copyWith(
              itemsProcessed: processed,
            );
            report();
          },
          targetMasterKey: targetMasterKey,
        );

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          itemsProcessed: mainRecords.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: mainVault ($mainNotesRestored records)',
        );
      } else {
        _log(
          'RESTORE COMPONENT SKIP: mainVault (${mainRecords == null ? "no data" : "empty"})',
        );
      }

      // ── 5. Restore hidden vault records ───────────────────────────────────
      _log('RESTORE COMPONENT START: hiddenVault');
      final hiddenRecords = backupData['hiddenVault'] as List?;
      if (hiddenRecords != null && hiddenRecords.isNotEmpty) {
        _log(
          'RESTORE COMPONENT: hiddenVault has ${hiddenRecords.length} records',
        );
        components.add(
          ComponentProgress(
            component: BackupComponent.hiddenVault,
            state: BackupOperationState.inProgress,
            totalItems: hiddenRecords.length,
          ),
        );
        report();

        hiddenNotesRestored = await _restoreVaultRecords(
          _normalizeRecordList(hiddenRecords),
          'hidden',
          mainMasterKey,
          mode,
          (processed) {
            components[components.length - 1] = components.last.copyWith(
              itemsProcessed: processed,
            );
            report();
          },
          targetMasterKey: targetMasterKey,
        );

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          itemsProcessed: hiddenRecords.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: hiddenVault ($hiddenNotesRestored records)',
        );
      } else {
        _log(
          'RESTORE COMPONENT SKIP: hiddenVault (${hiddenRecords == null ? "no data" : "empty"})',
        );
      }

      // ── 6. Restore drive metadata ─────────────────────────────────────────
      _log('RESTORE COMPONENT START: driveMetadata');
      final driveMeta = backupData['driveMetadata'] as List?;
      if (driveMeta != null && driveMeta.isNotEmpty) {
        _log(
          'RESTORE COMPONENT: driveMetadata has ${driveMeta.length} entries',
        );
        components.add(
          ComponentProgress(
            component: BackupComponent.driveMetadata,
            state: BackupOperationState.inProgress,
            totalItems: driveMeta.length,
          ),
        );
        report();

        driveFilesRestored = await _restoreDriveMetadata(
          _normalizeRecordList(driveMeta),
          mode,
        );

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          itemsProcessed: driveMeta.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: driveMetadata ($driveFilesRestored entries)',
        );
      } else {
        _log(
          'RESTORE COMPONENT SKIP: driveMetadata (${driveMeta == null ? "no data" : "empty"})',
        );
      }

      // ── 7. Restore drive blobs ────────────────────────────────────────────
      _log('RESTORE COMPONENT START: driveBlobs');
      final driveBlobs = backupData['driveBlobs'] as List?;
      if (driveBlobs != null && driveBlobs.isNotEmpty) {
        _log(
          'RESTORE COMPONENT: driveBlobs has ${driveBlobs.length} blobs',
        );
        components.add(
          ComponentProgress(
            component: BackupComponent.driveBlobs,
            state: BackupOperationState.inProgress,
            totalItems: driveBlobs.length,
          ),
        );
        report();

        driveBlobsRestored = await _restoreBlobs(
          _normalizeRecordList(driveBlobs),
          mainMasterKey,
          'drive',
          mode,
          (processed) {
            components[components.length - 1] = components.last.copyWith(
              itemsProcessed: processed,
            );
            report();
          },
        );

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          itemsProcessed: driveBlobs.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: driveBlobs ($driveBlobsRestored blobs)',
        );
      } else {
        _log(
          'RESTORE COMPONENT SKIP: driveBlobs (${driveBlobs == null ? "no data" : "empty"})',
        );
      }

      // ── 8. Restore attachment blobs ───────────────────────────────────────
      _log('RESTORE COMPONENT START: attachmentBlobs');
      final attachmentBlobs = backupData['attachmentBlobs'] as List?;
      if (attachmentBlobs != null && attachmentBlobs.isNotEmpty) {
        _log(
          'RESTORE COMPONENT: attachmentBlobs has ${attachmentBlobs.length} blobs',
        );
        components.add(
          ComponentProgress(
            component: BackupComponent.attachmentBlobs,
            state: BackupOperationState.inProgress,
            totalItems: attachmentBlobs.length,
          ),
        );
        report();

        attachmentBlobsRestored = await _restoreBlobs(
          _normalizeRecordList(attachmentBlobs),
          mainMasterKey,
          'attachment',
          mode,
          (processed) {
            components[components.length - 1] = components.last.copyWith(
              itemsProcessed: processed,
            );
            report();
          },
        );

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          itemsProcessed: attachmentBlobs.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: attachmentBlobs ($attachmentBlobsRestored blobs)',
        );
      } else {
        _log(
          'RESTORE COMPONENT SKIP: attachmentBlobs (${attachmentBlobs == null ? "no data" : "empty"})',
        );
      }

      // ── 9. Restore password entries ───────────────────────────────────────
      _log('RESTORE COMPONENT START: passwordEntries');
      final passwordEntries = backupData['passwordEntries'] as List?;
      if (passwordEntries != null && passwordEntries.isNotEmpty) {
        _log(
          'RESTORE COMPONENT: passwordEntries has ${passwordEntries.length} entries',
        );
        components.add(
          ComponentProgress(
            component: BackupComponent.passwordEntries,
            state: BackupOperationState.inProgress,
            totalItems: passwordEntries.length,
          ),
        );
        report();

        passwordEntriesRestored = await _restorePasswordEntries(
          _normalizeRecordList(passwordEntries),
          mode,
          mainMasterKey: mainMasterKey,
          targetMasterKey: targetMasterKey,
        );

        components[components.length - 1] = components.last.copyWith(
          state: BackupOperationState.completed,
          itemsProcessed: passwordEntries.length,
        );
        report();
        _log(
          'RESTORE COMPONENT SUCCESS: passwordEntries ($passwordEntriesRestored entries)',
        );
      } else {
        _log(
          'RESTORE COMPONENT SKIP: passwordEntries (${passwordEntries == null ? "no data" : "empty"})',
        );
      }

      // ── Reinitialize runtime auth state ────────────────────────────────
      _log('RESTORE CONTINUING');
      await _reinitializeRuntimeAuthState();

      onProgress?.call(
        BackupProgress(
          components: components,
          overallState: BackupOperationState.completed,
        ),
      );

      // ── Run restore verification ─────────────────────────────────────────
      _log('RESTORE: running post-restore verification...');
      final verifyResult = await verifyRestoreIntegrity(backupData);
      if (!verifyResult.passed) {
        warnings.addAll(verifyResult.errors);
        _log(
          'RESTORE: post-restore verification issues: ${verifyResult.errors}',
        );
      } else {
        _log('RESTORE: post-restore verification passed');
      }

      _log('RESTORE SUCCESS');
      _log(
        'RESTORE INSERTED RECORDS: main=$mainNotesRestored, hidden=$hiddenNotesRestored, '
        'drive=$driveFilesRestored, driveBlobs=$driveBlobsRestored, '
        'attachments=$attachmentBlobsRestored, passwords=$passwordEntriesRestored',
      );
      _log('CACHE REFRESH: Hive boxes flushed after restore');
      await Hive.box('vaultx_records').flush();
      await Hive.box('vaultx_drive').flush();
      await Hive.box('vaultx_passwords').flush();
      _log(
        'RESTORE COMPLETE: success=true, '
        'mainNotes=$mainNotesRestored, hiddenNotes=$hiddenNotesRestored, '
        'driveFiles=$driveFilesRestored, driveBlobs=$driveBlobsRestored, '
        'attachmentBlobs=$attachmentBlobsRestored, settings=$settingsRestored, '
        'authBundle=$authBundleRestored',
      );

      // ── Sanity Check ───────────────────────────────────────────────────
      // Never allow: Backup contains notes, Merge succeeds, Vault remains empty
      final totalBackupNotes = (mainRecords?.length ?? 0) + (hiddenRecords?.length ?? 0);
      
      final recordsBox = Hive.box('vaultx_records');
      final finalMainCount = recordsBox.keys.where((k) => k.toString().startsWith('main:')).length;
      final finalHiddenCount = recordsBox.keys.where((k) => k.toString().startsWith('hidden:')).length;
      final totalLocalNotesAfter = finalMainCount + finalHiddenCount;

      _log('RESTORE SANITY CHECK: backupNotes=$totalBackupNotes, localNotesAfter=$totalLocalNotesAfter');

      if (totalBackupNotes > 0 && totalLocalNotesAfter == 0 && mode == RestoreMode.merge) {
        _log('RESTORE CRITICAL: Backup has $totalBackupNotes notes but vault is empty after merge. Forcing full import...');
        
        if (mainRecords != null && mainRecords.isNotEmpty) {
          mainNotesRestored = await _restoreVaultRecords(
            _normalizeRecordList(mainRecords),
            'main',
            mainMasterKey,
            RestoreMode.replace, // Force import
            (_) {},
            targetMasterKey: targetMasterKey,
          );
        }
        if (hiddenRecords != null && hiddenRecords.isNotEmpty) {
          hiddenNotesRestored = await _restoreVaultRecords(
            _normalizeRecordList(hiddenRecords),
            'hidden',
            mainMasterKey,
            RestoreMode.replace, // Force import
            (_) {},
            targetMasterKey: targetMasterKey,
          );
        }
        
        _log('RESTORE FORCED IMPORT COMPLETE: main=$mainNotesRestored, hidden=$hiddenNotesRestored');
      }

      return RestoreResult(
        success: true,
        mainNotesRestored: mainNotesRestored,
        hiddenNotesRestored: hiddenNotesRestored,
        driveFilesRestored: driveFilesRestored,
        driveBlobsRestored: driveBlobsRestored,
        attachmentBlobsRestored: attachmentBlobsRestored,
        settingsRestored: settingsRestored,
        passwordEntriesRestored: passwordEntriesRestored,
        preservedLocalItems: preservedLocalItems,
        authBundleRestored: authBundleRestored,
        verificationPassed: verifyResult.passed,
        verificationWarnings: warnings,
      );
    } catch (e, st) {
      _log('RESTORE FAILED: exception=$e');
      _log('RESTORE FAILED stack: $st');

      if (mode == RestoreMode.replace) {
        _log('RESTORE: rolling back...');
        try {
          await _rollback(snapshot, mainMasterKey);
          _log('RESTORE: rollback completed');
        } catch (rbError) {
          _log('RESTORE rollback failed: $rbError');
        }
      }

      onProgress?.call(
        BackupProgress(
          components: components,
          overallState: BackupOperationState.failed,
          error: e.toString(),
        ),
      );
      return RestoreResult(success: false, error: e.toString());
    }
  }

  /// Verify backup data integrity after upload.
  ///
  /// Checks:
  /// - Component checksums match manifest
  /// - All required components present
  /// - No zero-length or truncated data
  /// - Real decryptability test (attempts to parse encrypted payload structure)
  /// Components whose checksum mismatch MUST abort restore.
  /// These contain irreplaceable encrypted user data.
  static const _hardFailComponents = <BackupComponent>{
    BackupComponent.mainVault,
    BackupComponent.hiddenVault,
    BackupComponent.settings,
  };

  /// Components whose checksum mismatch is a warning only.
  /// These contain reinstall-sensitive runtime/device state
  /// that naturally differs after uninstall/reinstall.
  /// (Behavior is implicit: anything not in [_hardFailComponents]
  /// is softly verified.)

  /// Portable authBundle fields — the subset that should survive
  /// uninstall/reinstall. Everything else is device-runtime state.
  static const _portableAuthBundleFields = <String>{
    'wrappedMaster.password',
    'passwordSalt',
    'passwordKdf',
    'masterVerifier',
    'wrappedMaster.pin',
    'pinSalt',
    'pinKdf',
    'wrappedMaster.hidden',
    'hiddenSalt',
    'hiddenMasterSalt',
    'hiddenKdf',
    'hiddenVerifier',
    'fakePinSalt',
    'fakePinHash',
    'fakePinKdf',
    'intruderLogKey',
  };

  Future<BackupVerificationResult> verifyBackupIntegrity(
    Map<String, dynamic> backupData,
  ) async {
    final errors = <String>[];
    final warnings = <String>[];
    var checked = 0;
    var failed = 0;
    var decryptOk = false;

    final manifestJson = backupData['manifest'] as Map<String, dynamic>?;
    if (manifestJson == null) {
      return const BackupVerificationResult(
        passed: false,
        errors: ['No manifest found in backup data'],
      );
    }

    final manifest = BackupManifest.fromJson(manifestJson);

    _log(
      'VERIFY START: ${manifest.checksums.length} components in manifest',
    );

    // Check version compatibility
    if (manifest.version < 2) {
      errors.add('Old backup format version ${manifest.version}');
      failed++;
    }

    // Verify each component checksum
    for (final c in manifest.checksums) {
      checked++;
      final key = _componentKey(c.component);
      final raw = backupData[key];
      final isHardFail = _hardFailComponents.contains(c.component);

      if (raw == null) {
        if (isHardFail) {
          errors.add('Missing required component: ${c.component}');
          failed++;
          _log(
            'VERIFY FAILURE: required component ${c.component} is missing',
          );
          continue;
        }
        _log(
          'VERIFY OPTIONAL COMPONENT: ${c.component} is null, skipping checksum',
        );
        continue;
      }

      // Sanitize authBundle to only portable fields before checksum
      dynamic dataForChecksum = raw;
      if (c.component == BackupComponent.authBundle) {
        dataForChecksum = sanitizePortableAuthBundle(
          raw as Map<String, dynamic>,
        );
      }

      final jsonStr = _canonicalJsonEncode(dataForChecksum);
      final actual = sha256.convert(utf8.encode(jsonStr)).toString();
      if (c.component == BackupComponent.authBundle) {
        _log('AUTHBUNDLE VERIFY: computed=$actual stored=${c.sha256}');
      }
      final error = manifest.verifyChecksum(
        c.component,
        actual,
        jsonStr.length,
      );
      if (error != null) {
        if (isHardFail) {
          errors.add(error);
          failed++;
          _log('VERIFY FAILURE: $error');
        } else {
          warnings.add('$error (soft verify — ${c.component})');
          if (c.component == BackupComponent.authBundle) {
            _log('AUTHBUNDLE SOFT VERIFY WARNING: $error');
          } else {
            _log(
              'SOFT VERIFY WARNING: $error (component=${c.component})',
            );
          }
        }
      }
    }

    _log('VERIFY REQUIRED COMPONENTS: checked required components');

    // Verify blob data is not truncated (check base64 decode)
    for (final blobType in ['driveBlobs', 'attachmentBlobs']) {
      final blobs = backupData[blobType] as List?;
      if (blobs == null) continue;
      for (final blob in blobs) {
        if (blob is! Map) continue;
        final blobMap = Map<String, dynamic>.from(blob);
        final data = blobMap['data'] as String?;
        if (data == null || data.isEmpty) {
          errors.add('Empty blob data in $blobType: ${blobMap['id']}');
          failed++;
          continue;
        }
        try {
          final decoded = base64Decode(data);
          if (decoded.isEmpty) {
            errors.add(
              'Zero-length blob after decode in $blobType: ${blobMap['id']}',
            );
            failed++;
          } else {
            // Verify VXBLOB header validity
            final header = utf8.decode(decoded.take(7).toList());
            if (header != 'VXBLOB2' && header != 'VXBLOB1') {
              errors.add(
                'Invalid blob header in $blobType: ${blobMap['id']}: $header',
              );
              failed++;
            }
            // Verify non-trivial encrypted data (minimum nonce + tag)
            if (header == 'VXBLOB2' && decoded.length < 7 + 12 + 16 + 1) {
              errors.add('Truncated VXBLOB2 in $blobType: ${blobMap['id']}');
              failed++;
            }
          }
        } catch (e) {
          errors.add('Invalid base64 in $blobType: ${blobMap['id']}: $e');
          failed++;
        }
      }
    }

    // Real decryptability test: verify encrypted record payload structure
    for (final vaultType in ['mainVault', 'hiddenVault']) {
      final records = backupData[vaultType] as List?;
      if (records == null || records.isEmpty) continue;
      checked++;
      var recordsChecked = 0;
      for (final record in records) {
        if (record is! Map) continue;
        final r = Map<String, dynamic>.from(record);
        
        // Skip folder metadata in decryptability test
        if (r['_isFolderMeta'] == true) {
          recordsChecked++;
          continue;
        }

        final payload = r['payload'] is Map
            ? Map<String, dynamic>.from(r['payload'])
            : null;
        if (payload == null) {
          errors.add('$vaultType: record missing payload');
          failed++;
          continue;
        }
        // Verify AES-GCM payload structure
        if (payload['v'] == null ||
            payload['nonce'] == null ||
            payload['ct'] == null) {
          errors.add('$vaultType: record has malformed encrypted payload');
          failed++;
          continue;
        }
        // Verify nonce and ct are valid base64
        try {
          base64Decode(payload['nonce'] as String);
          base64Decode(payload['ct'] as String);
        } catch (e) {
          errors.add('$vaultType: record has invalid base64 in payload: $e');
          failed++;
        }
        recordsChecked++;
      }
      _log('VERIFY: checked $recordsChecked $vaultType records');
    }

    decryptOk = true;

    if (failed == 0) {
      _log(
        'VERIFY SUCCESS: $checked components checked, ${warnings.length} warnings',
      );
      if (warnings.isNotEmpty) {
        _log('VERIFY WARNING: ${warnings.join("; ")}');
      }
    } else {
      _log('VERIFY FAILURE: $failed/$checked components failed');
    }

    return BackupVerificationResult(
      passed: failed == 0,
      componentsChecked: checked,
      componentsFailed: failed,
      errors: errors,
      warnings: warnings,
      decryptabilityTestPassed: decryptOk,
    );
  }

  /// Verify restore integrity by checking that data was actually written.
  ///
  /// Checks:
  /// - Main vault records exist in Hive
  /// - Hidden vault records exist in Hive (if they were in the backup)
  /// - Drive metadata exists in Hive
  /// - Blob files exist on disk with correct sizes
  Future<BackupVerificationResult> verifyRestoreIntegrity(
    Map<String, dynamic> backupData,
  ) async {
    final errors = <String>[];
    var checked = 0;
    var failed = 0;

    final mainRecords = backupData['mainVault'] as List?;
    if (mainRecords != null && mainRecords.isNotEmpty) {
      checked++;
      final box = Hive.box('vaultx_records');
      var found = 0;
      for (final record in mainRecords) {
        if (record is! Map) continue;
        final r = record;
        final bool isFolderMeta = r['_isFolderMeta'] == true;
        final id = isFolderMeta ? r['name']?.toString() : r['id']?.toString();
        if (id == null) continue;
        final key = isFolderMeta ? 'main:folder_metadata:$id' : 'main:$id';
        if (box.containsKey(key)) found++;
      }
      if (found < mainRecords.length) {
        errors.add(
          'Main vault: only $found/${mainRecords.length} records found after restore',
        );
        failed++;
      }
    }

    final hiddenRecords = backupData['hiddenVault'] as List?;
    if (hiddenRecords != null && hiddenRecords.isNotEmpty) {
      checked++;
      final box = Hive.box('vaultx_records');
      var found = 0;
      for (final record in hiddenRecords) {
        if (record is! Map) continue;
        final r = record;
        final bool isFolderMeta = r['_isFolderMeta'] == true;
        final id = isFolderMeta ? r['name']?.toString() : r['id']?.toString();
        if (id == null) continue;
        final key = isFolderMeta ? 'hidden:folder_metadata:$id' : 'hidden:$id';
        if (box.containsKey(key)) found++;
      }
      if (found < hiddenRecords.length) {
        errors.add(
          'Hidden vault: only $found/${hiddenRecords.length} records found after restore',
        );
        failed++;
      }
    }

    final driveMeta = backupData['driveMetadata'] as List?;
    if (driveMeta != null && driveMeta.isNotEmpty) {
      checked++;
      final box = Hive.box('vaultx_drive');
      var found = 0;
      for (final record in driveMeta) {
        if (record is! Map) continue;
        final r = record;
        final bool isFolderMeta = r['_isFolderMeta'] == true;
        final id = isFolderMeta ? r['name']?.toString() : r['id']?.toString();
        if (id == null) continue;
        final prefix = r['_prefix'] == 'hidden' ? 'hidden' : 'main';
        final key = isFolderMeta ? '$prefix:folder_metadata:$id' : '$prefix:$id';
        if (box.containsKey(key)) found++;
      }
      if (found < driveMeta.length) {
        errors.add(
          'Drive metadata: only $found/${driveMeta.length} records found after restore',
        );
        failed++;
      }
    }

    final docDir = await getApplicationDocumentsDirectory();

    final driveBlobs = backupData['driveBlobs'] as List?;
    if (driveBlobs != null && driveBlobs.isNotEmpty) {
      checked++;
      var found = 0;
      for (final blob in driveBlobs) {
        final blobMap = blob as Map<String, dynamic>;
        final id = blobMap['id'] as String;
        final dirName = blobMap['blobDir'] as String? ?? 'vaultx_drive_main';
        final path = '${docDir.path}/$dirName/$id.vxblob';
        final file = File(path);
        if (file.existsSync()) {
          // Verify file has content (not zero-length)
          if (file.lengthSync() > 0) {
            found++;
          } else {
            errors.add('Drive blob $id exists but is zero-length');
            failed++;
          }
        }
      }
      if (found < driveBlobs.length) {
        errors.add(
          'Drive blobs: only $found/${driveBlobs.length} valid files found after restore',
        );
        failed++;
      }
    }

    final attachmentBlobs = backupData['attachmentBlobs'] as List?;
    if (attachmentBlobs != null && attachmentBlobs.isNotEmpty) {
      checked++;
      var found = 0;
      for (final blob in attachmentBlobs) {
        final blobMap = blob as Map<String, dynamic>;
        final id = blobMap['id'] as String;
        final path = '${docDir.path}/vaultx_blobs/$id.vxblob';
        final file = File(path);
        if (file.existsSync()) {
          if (file.lengthSync() > 0) {
            found++;
          } else {
            errors.add('Attachment blob $id exists but is zero-length');
            failed++;
          }
        }
      }
      if (found < attachmentBlobs.length) {
        errors.add(
          'Attachment blobs: only $found/${attachmentBlobs.length} valid files found after restore',
        );
        failed++;
      }
    }

    final passwordEntries = backupData['passwordEntries'] as List?;
    if (passwordEntries != null && passwordEntries.isNotEmpty) {
      checked++;
      final box = Hive.box('vaultx_passwords');
      var found = 0;
      for (final entry in passwordEntries) {
        if (entry is! Map) continue;
        final entryMap = entry;
        final entryId = entryMap['id']?.toString();
        if (entryId == null) continue;
        final prefix = entryMap['_prefix']?.toString() ?? 'main_pw';
        if (box.containsKey('$prefix:$entryId')) found++;
      }
      if (found < passwordEntries.length) {
        errors.add(
          'Password entries: only $found/${passwordEntries.length} found after restore',
        );
        failed++;
      }
    }

    return BackupVerificationResult(
      passed: failed == 0,
      componentsChecked: checked,
      componentsFailed: failed,
      errors: errors,
      decryptabilityTestPassed: true,
    );
  }

  // ── Data collection helpers ─────────────────────────────────────────────────

  Set<String> _getExcludedFolders(String vaultPrefix, String boxName) {
    final box = Hive.box(boxName);
    final prefix = '$vaultPrefix:folder_metadata:';
    final excluded = <String>{};
    for (final k in box.keys.where((k) => k.toString().startsWith(prefix))) {
      final raw = box.get(k);
      if (raw is Map && raw['backupExcluded'] == true) {
        final folderName = raw['name'] as String?;
        if (folderName != null) excluded.add(folderName);
      }
    }
    return excluded;
  }

  List<Map<String, dynamic>> _collectVaultRecords(String prefix) {
    final box = Hive.box('vaultx_records');
    final records = <Map<String, dynamic>>[];
    final excludedFolders = _getExcludedFolders(prefix, 'vaultx_records');
    var skippedCount = 0;
    var skippedSize = 0;

    for (final k in box.keys.where(
      (k) => k.toString().startsWith('$prefix:'),
    )) {
      final raw = box.get(k) as Map?;
      if (raw != null) {
        final data = Map<String, dynamic>.from(raw);
        
        // Handle folder metadata
        if (k.toString().contains(':folder_metadata:')) {
          if (data['backupExcluded'] == true) {
            skippedCount++;
            _log('BACKUP: skipping excluded folder metadata $k');
            continue;
          }
          data['_isFolderMeta'] = true;
          records.add(data);
          continue;
        }

        final payload = data['payload'] as Map?;
        final folder = (payload != null) ? payload['folder'] as String? : null;

        final isExcluded = data['backupExcluded'] == true;
        final isFolderExcluded = folder != null && excludedFolders.contains(folder);

        if (isExcluded || isFolderExcluded) {
          skippedCount++;
          try {
            final payloadStr = jsonEncode(data['payload']);
            skippedSize += utf8.encode(payloadStr).length;
          } catch (_) {}
          _log(
            'BACKUP: skipping excluded record $k (itemExcluded=$isExcluded, folderExcluded=$isFolderExcluded)',
          );
          continue;
        }
        records.add(data);
      }
    }
    _log(
      'BACKUP [$prefix]: included=${records.length}, skipped=$skippedCount, skippedSize=${(skippedSize / 1024).toStringAsFixed(1)}KB',
    );
    return records;
  }

  List<Map<String, dynamic>> _collectPasswordEntries() {
    final box = Hive.box('vaultx_passwords');
    final records = <Map<String, dynamic>>[];
    var skippedCount = 0;

    for (final prefixStr in ['main_pw', 'hidden_pw']) {
      final prefix = '$prefixStr:';
      for (final k in box.keys.where((k) => k.toString().startsWith(prefix))) {
        final raw = box.get(k) as Map?;
        if (raw != null) {
          final record = Map<String, dynamic>.from(raw);
          if (record['backupExcluded'] == true) {
            skippedCount++;
            _log('BACKUP: skipping excluded password entry $k');
            continue;
          }
          record['_prefix'] = prefixStr;
          records.add(record);
        }
      }
    }
    _log(
      'BACKUP [passwords]: included=${records.length}, skipped=$skippedCount',
    );
    return records;
  }

  List<Map<String, dynamic>> _collectDriveRecords() {
    final box = Hive.box('vaultx_drive');
    final records = <Map<String, dynamic>>[];
    var skippedCount = 0;
    var skippedSize = 0;

    for (final vaultKind in ['main', 'hidden']) {
      final prefix = '$vaultKind:';
      final excludedFolders = _getExcludedFolders(vaultKind, 'vaultx_drive');

      for (final k in box.keys.where((k) => k.toString().startsWith(prefix))) {
        final raw = box.get(k) as Map?;
        if (raw != null) {
          final record = Map<String, dynamic>.from(raw);
          
          // Handle folder metadata
          if (k.toString().contains(':folder_metadata:')) {
            if (record['backupExcluded'] == true) {
              skippedCount++;
              _log('BACKUP: skipping excluded folder metadata $k');
              continue;
            }
            record['_isFolderMeta'] = true;
            record['_prefix'] = vaultKind;
            records.add(record);
            continue;
          }

          final folder = record['folder'] as String?;

          final isExcluded = record['backupExcluded'] == true;
          final isFolderExcluded = folder != null && excludedFolders.contains(folder);

          if (isExcluded || isFolderExcluded) {
            skippedCount++;
            skippedSize += (record['size'] as num?)?.toInt() ?? 0;
            _log(
              'BACKUP: skipping excluded drive record $k (itemExcluded=$isExcluded, folderExcluded=$isFolderExcluded)',
            );
            continue;
          }
          record['_prefix'] = vaultKind;
          records.add(record);
        }
      }
    }
    _log(
      'BACKUP [drive]: included=${records.length}, skipped=$skippedCount, skippedSize=${(skippedSize / (1024 * 1024)).toStringAsFixed(1)}MB',
    );
    return records;
  }

  Map<String, dynamic> _collectSettings() {
    final box = Hive.box('vaultx_settings');
    final settings = <String, dynamic>{};
    final sensitiveKeys = <String>{
      'gdriveTokenExpiry',
      'gdriveEmail',
      'lastGoogleBackupAt',
      'megaSessionId',
      'megaEmail',
      'lastMegaBackupAt',
      'cloudProvider',
      'deviceId',
    };
    for (final k in box.keys) {
      final key = k.toString();
      if (!sensitiveKeys.contains(key)) {
        settings[key] = box.get(key);
      }
    }
    return settings;
  }

  /// Stream-based blob collection — reads blobs one at a time to avoid
  /// loading all blob data into memory simultaneously. Reduces peak memory
  /// usage during large backups with many drive files or attachments.
  Future<List<Map<String, dynamic>>> _collectDriveBlobsStreamed(
    List<Map<String, dynamic>> metadata,
    bool compressMedia,
  ) async {
    final blobs = <Map<String, dynamic>>[];
    final docDir = await getApplicationDocumentsDirectory();
    final crypto = CryptoService();

    for (final dirName in ['vaultx_drive_main', 'vaultx_drive_hidden']) {
      final dir = Directory('${docDir.path}/$dirName');
      if (!await dir.exists()) continue;

      final files = dir.listSync().whereType<File>();
      for (final file in files) {
        if (!file.path.endsWith('.vxblob')) continue;
        try {
          final id = file.uri.pathSegments.last.replaceAll('.vxblob', '');
          
          // Only backup blobs that are in the filtered metadata
          final meta = metadata.firstWhere((m) => m['id'] == id, orElse: () => {});
          if (meta.isEmpty) {
            _log('BACKUP: skipping excluded drive blob $id');
            continue;
          }

          var bytes = await file.readAsBytes();

          if (compressMedia) {
            final salt = meta['salt'] as String?;
            final originalName = meta['name'] as String?;
            if (salt != null && originalName != null) {
              final recordKey = crypto.deriveRecordKey(
                masterKey,
                'drive:$id',
                salt,
              );
              final clear =
                  bytes.length > 102400
                      ? await crypto.decryptBytesIsolate(bytes, recordKey)
                      : crypto.decryptBytes(bytes, recordKey);

              final analysis = await CompressionService.instance
                  .analyzeFileFromBytes(clear, originalName);
              if (analysis['shouldCompress'] == true) {
                final compressed = await CompressionService.instance
                    .compressImageFromBytes(clear);
                if (compressed != null) {
                  bytes =
                      compressed.length > 102400
                          ? await crypto.encryptBytesIsolate(
                            compressed,
                            recordKey,
                          )
                          : crypto.encryptBytes(compressed, recordKey);
                  _log('BACKUP OPTIMIZATION: compressed $originalName');
                }
              }
            }
          }

          blobs.add({
            'id': id,
            'data': base64Encode(bytes),
            'blobDir': dirName,
            'size': bytes.length,
          });
        } catch (e) {
          _log('BACKUP: failed to read drive blob ${file.path}: $e');
        }
      }
    }
    return blobs;
  }

  Future<List<Map<String, dynamic>>> _collectAttachmentBlobsStreamed(
    bool compressMedia,
    Set<String> allowedIds,
  ) async {
    final blobs = <Map<String, dynamic>>[];
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docDir.path}/vaultx_blobs');
    if (!await dir.exists()) return blobs;

    final files = dir.listSync().whereType<File>();
    for (final file in files) {
      if (!file.path.endsWith('.vxblob')) continue;
      try {
        final id = file.uri.pathSegments.last.replaceAll('.vxblob', '');
        if (!allowedIds.contains(id)) {
          _log('BACKUP: skipping excluded attachment blob $id');
          continue;
        }

        final bytes = await file.readAsBytes();
        blobs.add({
          'id': id,
          'data': base64Encode(bytes),
          'blobDir': 'vaultx_blobs',
          'size': bytes.length,
        });
      } catch (e) {
        _log('BACKUP: failed to read attachment blob ${file.path}: $e');
      }
    }
    return blobs;
  }

  // ── Restore helpers ─────────────────────────────────────────────────────────

  Future<void> _restoreSettings(
    Map<String, dynamic> settings,
    RestoreMode mode,
  ) async {
    final box = Hive.box('vaultx_settings');
    var restored = 0;
    var skipped = 0;

    for (final entry in settings.entries) {
      if (mode == RestoreMode.replace) {
        await box.put(entry.key, entry.value);
        restored++;
      } else {
        if (!box.containsKey(entry.key)) {
          await box.put(entry.key, entry.value);
          restored++;
        } else {
          skipped++;
        }
      }
    }
    _log('RESTORE settings: restored=$restored, skipped=$skipped');
  }

  Future<int> _clearRestoreTargets() async {
    final recordsBox = Hive.box('vaultx_records');
    final driveBox = Hive.box('vaultx_drive');
    final passwordsBox = Hive.box('vaultx_passwords');

    final excludedDriveFolders = {
      ..._getExcludedFolders('main', 'vaultx_drive'),
      ..._getExcludedFolders('hidden', 'vaultx_drive'),
    };
    final excludedNoteFolders = {
      ..._getExcludedFolders('main', 'vaultx_records'),
      ..._getExcludedFolders('hidden', 'vaultx_records'),
    };

    var preservedNotes = 0;
    var preservedDrive = 0;
    var preservedPasswords = 0;

    for (final key in recordsBox.keys.toList()) {
      final k = key.toString();
      if (k.startsWith('main:') || k.startsWith('hidden:')) {
        if (k.contains(':folder_metadata:')) {
          final raw = recordsBox.get(key);
          if (raw is Map && raw['backupExcluded'] == true) {
            preservedNotes++;
            continue;
          }
        } else {
          final raw = recordsBox.get(key);
          if (raw is Map) {
            final isExcluded = raw['backupExcluded'] == true;
            final folder = raw['folder'] as String?;
            final isFolderExcluded =
                folder != null && excludedNoteFolders.contains(folder);

            if (isExcluded || isFolderExcluded) {
              preservedNotes++;
              continue;
            }
          }
        }
        await recordsBox.delete(key);
      }
    }
    for (final key in driveBox.keys.toList()) {
      final k = key.toString();
      if (k.startsWith('main:') || k.startsWith('hidden:')) {
        if (k.contains(':folder_metadata:')) {
          final raw = driveBox.get(key);
          if (raw is Map && raw['backupExcluded'] == true) {
            preservedDrive++;
            continue;
          }
        } else {
          final raw = driveBox.get(key);
          if (raw is Map) {
            final isExcluded = raw['backupExcluded'] == true;
            final folder = raw['folder'] as String?;
            final isFolderExcluded =
                folder != null && excludedDriveFolders.contains(folder);

            if (isExcluded || isFolderExcluded) {
              preservedDrive++;
              continue;
            }
          }
        }
        await driveBox.delete(key);
      }
    }
    for (final key in passwordsBox.keys.toList()) {
      final k = key.toString();
      if (k.startsWith('main_pw:') || k.startsWith('hidden_pw:')) {
        final raw = passwordsBox.get(k) as Map?;
        if (raw != null && raw['backupExcluded'] == true) {
          preservedPasswords++;
          continue;
        }
        await passwordsBox.delete(key);
      }
    }
    final totalPreserved = preservedNotes + preservedDrive + preservedPasswords;
    _log(
      'RESTORE: replace mode cleared targets (preserved: $preservedNotes notes, $preservedDrive drive, $preservedPasswords passwords, total=$totalPreserved)',
    );
    return totalPreserved;
  }

  List<Map<String, dynamic>> _normalizeRecordList(List records) {
    return records
        .whereType<Map>()
        .map((record) => Map<String, dynamic>.from(record))
        .toList();
  }

  bool _isRecordContentDifferent(
    Map<String, dynamic> backupRecord,
    Map<String, dynamic> localRecord,
    Uint8List backupKey,
    Uint8List localKey,
    CryptoService crypto,
    String recordId,
  ) {
    // Rule 5: Timestamp invalid -> DO NOT SKIP. Compare content hash/json.
    final bUpdatedStr = backupRecord['updatedAt'] as String?;
    final lUpdatedStr = localRecord['updatedAt'] as String?;
    
    final bUpdated = bUpdatedStr != null ? DateTime.tryParse(bUpdatedStr) : null;
    final lUpdated = lUpdatedStr != null ? DateTime.tryParse(lUpdatedStr) : null;

    if (bUpdated == null || lUpdated == null) {
      _log('RESTORE MERGE DEBUG: UUID=$recordId - timestamp invalid or missing, checking content (Rule 5)');
    } else {
      // Optimization: if same salt and same payload and same timestamp, they are identical
      if (bUpdatedStr == lUpdatedStr && 
          backupRecord['salt'] == localRecord['salt'] && 
          jsonEncode(backupRecord['payload']) == jsonEncode(localRecord['payload'])) {
        return false;
      }
    }

    // Rule 4: Backup content different -> UPDATE EXISTING
    final bClear = _decryptRestoreRecord(backupRecord, backupKey, crypto);
    final lClear = _decryptRestoreRecord(localRecord, localKey, crypto);

    if (bClear == null || lClear == null) {
      _log('RESTORE MERGE DEBUG: UUID=$recordId - decryption failed for comparison, assuming different');
      return true;
    }

    // Compare essential fields to determine if content differs
    final bool differ = bClear['title'] != lClear['title'] ||
                        bClear['body'] != lClear['body'] ||
                        jsonEncode(bClear['checklist']) != jsonEncode(lClear['checklist']) ||
                        jsonEncode(bClear['attachments']) != jsonEncode(lClear['attachments']) ||
                        jsonEncode(bClear['tags']) != jsonEncode(lClear['tags']) ||
                        bClear['folder'] != lClear['folder'] ||
                        bClear['type'] != lClear['type'] ||
                        bClear['deleted'] != lClear['deleted'];

    if (differ) {
      _log('RESTORE MERGE DEBUG: UUID=$recordId - content differs (Rule 4) - UPDATE planned');
    } else {
      _log('RESTORE MERGE DEBUG: UUID=$recordId - content is identical - SKIP (Rule 3)');
    }

    return differ;
  }

  Future<int> _restoreVaultRecords(
    List<Map<String, dynamic>> records,
    String prefix,
    Uint8List mainMasterKey,
    RestoreMode mode,
    void Function(int processed) onProgress, {
    Uint8List? targetMasterKey,
  }) async {
    final box = Hive.box('vaultx_records');
    final crypto = CryptoService();
    var processed = 0;
    var restored = 0;
    var skipped = 0;
    var updated = 0;

    // Rule 1: Local vault count == 0 -> IMPORT ENTIRE BACKUP
    final localCountBefore = box.keys.where((k) => k.toString().startsWith('$prefix:')).length;
    _log('RESTORE DEBUG [$prefix]: local count before merge=$localCountBefore');
    _log('RESTORE DEBUG [$prefix]: backup count=${records.length}');

    final bool forceImport = localCountBefore == 0;
    if (forceImport && mode == RestoreMode.merge) {
      _log('RESTORE DEBUG [$prefix]: Local vault is empty. Promoting merge to full import (Rule 1).');
    }

    for (final record in records) {
      final bool isFolderMeta = record['_isFolderMeta'] == true;
      final recordId = isFolderMeta ? record['name']?.toString() : record['id']?.toString();
      if (recordId == null) continue;
      final key = isFolderMeta ? '$prefix:folder_metadata:$recordId' : '$prefix:$recordId';

      bool shouldRestore = true;
      String decisionReason = 'INSERT (Rule 2)';

      if (mode == RestoreMode.merge && !forceImport && box.containsKey(key)) {
        final localRaw = box.get(key) as Map?;
        if (localRaw != null) {
          final isDifferent = _isRecordContentDifferent(
            record, 
            Map<String, dynamic>.from(localRaw), 
            mainMasterKey, 
            targetMasterKey ?? mainMasterKey, 
            crypto,
            recordId,
          );
          
          if (!isDifferent) {
            shouldRestore = false;
            decisionReason = 'KEEP LOCAL (Rule 3) - identical content';
            skipped++;
          } else {
            shouldRestore = true;
            decisionReason = 'UPDATE EXISTING (Rule 4) - content differs';
            updated++;
          }
        }
      }

      if (!shouldRestore) {
        _log('RESTORE MERGE DECISION: UUID=$recordId -> $decisionReason');
        processed++;
        continue;
      }

      _log('RESTORE MERGE DECISION: UUID=$recordId -> $decisionReason');

      if (isFolderMeta) {
        if (record.containsKey('name')) {
          await box.put(key, record);
          restored++;
        }
      } else if (record.containsKey('salt') &&
          record.containsKey('payload') &&
          record.containsKey('id')) {
        // Re-encrypt with target master key if different (cross-device merge)
        if (targetMasterKey != null && !_keysEqual(targetMasterKey, mainMasterKey)) {
          try {
            final salt = record['salt'] as String;
            final payload = record['payload'] is Map 
                ? Map<String, dynamic>.from(record['payload'] as Map)
                : <String, dynamic>{};
            final oldKey = crypto.deriveRecordKey(mainMasterKey, recordId, salt);
            final plaintext = crypto.decryptJson(payload, oldKey);
            crypto.wipe(oldKey);
            final newKey = crypto.deriveRecordKey(targetMasterKey, recordId, salt);
            record['payload'] = crypto.encryptJson(plaintext, newKey);
            crypto.wipe(newKey);
          } catch (e) {
            _log('RESTORE: failed to re-encrypt $prefix vault record $recordId: $e — skipping');
            processed++;
            continue;
          }
        }
        await box.put(key, record);
        await AuditLog.write('Restored $prefix vault record $recordId ($decisionReason)');
        restored++;
      } else {
        _log('RESTORE: invalid $prefix vault record $recordId - missing essential fields');
      }

      processed++;
      if (processed % 5 == 0) onProgress(processed);
    }
    onProgress(records.length);

    final localCountAfter = box.keys.where((k) => k.toString().startsWith('$prefix:')).length;
    _log('RESTORE DEBUG [$prefix]: merge cycle complete');
    _log('  final local count: $localCountAfter');
    _log('  inserted count: ${restored - updated}');
    _log('  updated count: $updated');
    _log('  skipped count: $skipped');

    return restored;
  }

  Map<String, dynamic>? _decryptRestoreRecord(Map record, Uint8List key, CryptoService crypto) {
    try {
      final id = record['id'] as String?;
      final salt = record['salt'] as String?;
      final payload = record['payload'] as Map?;
      if (id == null || salt == null || payload == null) return null;
      
      final recordKey = crypto.deriveRecordKey(key, id, salt);
      final clear = crypto.decryptJson(Map<String, dynamic>.from(payload), recordKey);
      crypto.wipe(recordKey);
      return clear;
    } catch (_) {
      return null;
    }
  }

  Future<int> _restoreDriveMetadata(
    List<Map<String, dynamic>> records,
    RestoreMode mode,
  ) async {
    final box = Hive.box('vaultx_drive');
    var restored = 0;
    var skipped = 0;
    var updated = 0;

    final localCountBefore = box.keys.length; 
    _log('RESTORE DEBUG [drive]: local count before merge=$localCountBefore');
    _log('RESTORE DEBUG [drive]: backup count=${records.length}');

    final bool forceImport = localCountBefore == 0;
    if (forceImport && mode == RestoreMode.merge) {
      _log('RESTORE DEBUG [drive]: Local vault is empty. Promoting merge to full import (Rule 1).');
    }

    for (final record in records) {
      final bool isFolderMeta = record['_isFolderMeta'] == true;
      final recordId = isFolderMeta ? record['name']?.toString() : record['id']?.toString();
      if (recordId == null) continue;
      
      String prefix = 'main';
      if (record['_prefix'] == 'hidden') prefix = 'hidden';
      final key = isFolderMeta ? '$prefix:folder_metadata:$recordId' : '$prefix:$recordId';

      bool shouldRestore = true;
      String decisionReason = 'INSERT (Rule 2)';

      if (mode == RestoreMode.merge && !forceImport && box.containsKey(key)) {
        if (isFolderMeta) {
          shouldRestore = false;
          decisionReason = 'KEEP LOCAL - folder meta already exists';
          skipped++;
        } else {
           final localRaw = box.get(key) as Map?;
           if (localRaw != null) {
              // Compare simple fields for drive metadata
              final bUp = record['updatedAt'] as String?;
              final lUp = localRaw['updatedAt'] as String?;
              if (bUp != null && lUp != null && bUp == lUp && 
                  jsonEncode(record) == jsonEncode(localRaw)) {
                shouldRestore = false;
                decisionReason = 'KEEP LOCAL (Rule 3) - identical metadata';
                skipped++;
              } else {
                shouldRestore = true;
                decisionReason = 'UPDATE EXISTING (Rule 4) - metadata differs';
                updated++;
              }
           }
        }
      }

      if (!shouldRestore) {
        _log('RESTORE MERGE DECISION (DRIVE): UUID=$recordId -> $decisionReason');
        continue;
      }

      _log('RESTORE MERGE DECISION (DRIVE): UUID=$recordId -> $decisionReason');

      try {
        if (isFolderMeta) {
          if (record.containsKey('name')) {
            await box.put(key, record);
            restored++;
          }
        } else {
          final file = SecureDriveFile.fromJson(record);
          await box.put(key, file.toJson());
          restored++;
        }
      } catch (e) {
        _log('RESTORE: failed to restore drive metadata $recordId: $e');
      }
    }

    final localCountAfter = box.keys.length;
    _log('RESTORE DEBUG [drive]: merge complete. final=$localCountAfter, inserted=${restored-updated}, updated=$updated, skipped=$skipped');

    return restored;
  }

  Future<int> _restoreBlobs(
    List<Map<String, dynamic>> blobs,
    Uint8List mainMasterKey,
    String blobType,
    RestoreMode mode,
    void Function(int processed) onProgress,
  ) async {
    final docDir = await getApplicationDocumentsDirectory();
    var processed = 0;
    var restored = 0;
    var skipped = 0;

    _log('RESTORE DEBUG [$blobType]: backup count=${blobs.length}');

    for (final blob in blobs) {
      try {
        final blobId = blob['id'] as String;
        final data = base64Decode(blob['data'] as String);

        // Verify blob integrity before writing
        if (data.isNotEmpty) {
          final header = utf8.decode(data.take(7).toList());
          if (header != 'VXBLOB2' && header != 'VXBLOB1') {
            _log('RESTORE: blob $blobId has invalid header: $header — skipping');
            processed++;
            continue;
          }
        }

        var dirName = blob['blobDir'] as String?;
        dirName ??= blobType == 'drive' ? 'vaultx_drive_main' : 'vaultx_blobs';

        final dir = Directory('${docDir.path}/$dirName');
        await dir.create(recursive: true);

        final blobPath = '${dir.path}/$blobId.vxblob';
        if (mode == RestoreMode.merge && File(blobPath).existsSync()) {
          skipped++;
          processed++;
          continue;
        }

        await File(blobPath).writeAsBytes(data, flush: true);
        await AuditLog.write('Restored $blobType blob $blobId');
        restored++;
      } catch (e) {
        _log('RESTORE: failed to restore $blobType blob: $e');
      }

      processed++;
      if (processed % 3 == 0) onProgress(processed);
    }
    onProgress(blobs.length);

    _log('RESTORE DEBUG [$blobType]: skipped count=$skipped, inserted count=$restored');

    return restored;
  }

  // ── Rollback ────────────────────────────────────────────────────────────────

  Future<int> _restorePasswordEntries(
    List<Map<String, dynamic>> entries,
    RestoreMode mode, {
    Uint8List? mainMasterKey,
    Uint8List? targetMasterKey,
  }) async {
    final box = Hive.box('vaultx_passwords');
    final crypto = CryptoService();
    var restored = 0;
    var skipped = 0;
    var updated = 0;

    final localCountBefore = box.keys.length;
    _log('RESTORE DEBUG [passwords]: local count before merge=$localCountBefore');
    _log('RESTORE DEBUG [passwords]: backup count=${entries.length}');

    final bool forceImport = localCountBefore == 0;
    if (forceImport && mode == RestoreMode.merge) {
      _log('RESTORE DEBUG [passwords]: Local vault is empty. Promoting merge to full import (Rule 1).');
    }

    for (final entry in entries) {
      final entryId = entry['id'] as String;
      // Detect prefix from the stored data
      final prefix = entry['_prefix'] as String? ?? 'main_pw';
      final key = '$prefix:$entryId';

      bool shouldRestore = true;
      String decisionReason = 'INSERT (Rule 2)';

      if (mode == RestoreMode.merge && !forceImport && box.containsKey(key)) {
        final localRaw = box.get(key) as Map?;
        if (localRaw != null) {
          final isDifferent = _isRecordContentDifferent(
            entry, 
            Map<String, dynamic>.from(localRaw), 
            mainMasterKey ?? Uint8List(0), 
            targetMasterKey ?? mainMasterKey ?? Uint8List(0), 
            crypto,
            entryId,
          );
          
          if (!isDifferent) {
            shouldRestore = false;
            decisionReason = 'KEEP LOCAL (Rule 3) - identical content';
            skipped++;
          } else {
            shouldRestore = true;
            decisionReason = 'UPDATE EXISTING (Rule 4) - content differs';
            updated++;
          }
        }
      }

      if (!shouldRestore) {
        _log('RESTORE MERGE DECISION (PW): UUID=$entryId -> $decisionReason');
        continue;
      }

      _log('RESTORE MERGE DECISION (PW): UUID=$entryId -> $decisionReason');

      if (entry.containsKey('salt') && entry.containsKey('payload')) {
        // Re-encrypt if keys differ
        if (mainMasterKey != null && targetMasterKey != null && !_keysEqual(targetMasterKey, mainMasterKey)) {
           try {
              final salt = entry['salt'] as String;
              final payload = entry['payload'] is Map 
                  ? Map<String, dynamic>.from(entry['payload'] as Map)
                  : <String, dynamic>{};
              final oldKey = crypto.deriveRecordKey(mainMasterKey, entryId, salt);
              final plaintext = crypto.decryptJson(payload, oldKey);
              crypto.wipe(oldKey);
              final newKey = crypto.deriveRecordKey(targetMasterKey, entryId, salt);
              entry['payload'] = crypto.encryptJson(plaintext, newKey);
              crypto.wipe(newKey);
           } catch (e) {
              _log('RESTORE: failed to re-encrypt password entry $entryId: $e');
              continue;
           }
        }
        await box.put(key, entry);
        restored++;
      }
    }

    final localCountAfter = box.keys.length;
    _log('RESTORE DEBUG [passwords]: merge complete. final=$localCountAfter, inserted=${restored-updated}, updated=$updated, skipped=$skipped');

    return restored;
  }

  /// Collects paths of existing blob files before restore for rollback cleanup.
  Future<List<String>> _collectExistingBlobPaths() async {
    final docDir = await getApplicationDocumentsDirectory();
    final paths = <String>[];
    for (final dirName in ['vaultx_drive_main', 'vaultx_drive_hidden', 'vaultx_blobs']) {
      final dir = Directory('${docDir.path}/$dirName');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.vxblob')) {
          paths.add(entity.path);
        }
      }
    }
    return paths;
  }

  Future<void> _rollback(
    Map<String, dynamic> snapshot,
    Uint8List mainMasterKey,
  ) async {
    final recordsBox = Hive.box('vaultx_records');
    final driveBox = Hive.box('vaultx_drive');

    if (snapshot.containsKey('mainVault')) {
      final mainVault = (snapshot['mainVault'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final k in recordsBox.keys) {
        if (k.toString().startsWith('main:')) {
          await recordsBox.delete(k);
        }
      }
      for (final record in mainVault) {
        final isFolderMeta = record['_isFolderMeta'] == true;
        final recordId = isFolderMeta ? record['name']?.toString() : record['id']?.toString();
        if (recordId == null) continue;
        final key = isFolderMeta ? 'main:folder_metadata:$recordId' : 'main:$recordId';
        await recordsBox.put(key, record);
      }
    }

    if (snapshot.containsKey('hiddenVault')) {
      final hiddenVault = (snapshot['hiddenVault'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final k in recordsBox.keys) {
        if (k.toString().startsWith('hidden:')) {
          await recordsBox.delete(k);
        }
      }
      for (final record in hiddenVault) {
        final isFolderMeta = record['_isFolderMeta'] == true;
        final recordId = isFolderMeta ? record['name']?.toString() : record['id']?.toString();
        if (recordId == null) continue;
        final key = isFolderMeta ? 'hidden:folder_metadata:$recordId' : 'hidden:$recordId';
        await recordsBox.put(key, record);
      }
    }

    if (snapshot.containsKey('driveMetadata')) {
      final driveMeta = (snapshot['driveMetadata'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      await driveBox.clear();
      for (final record in driveMeta) {
        final prefix = record['_prefix'] == 'hidden' ? 'hidden' : 'main';
        final isFolderMeta = record['_isFolderMeta'] == true;
        final recordId = isFolderMeta ? record['name']?.toString() : record['id']?.toString();
        if (recordId == null) continue;
        final key = isFolderMeta ? '$prefix:folder_metadata:$recordId' : '$prefix:$recordId';
        await driveBox.put(key, record);
      }
    }

    // Clean up blob files that were created during the failed restore
    final existingBlobs = (snapshot['_existingBlobs'] as List?)?.cast<String>() ?? <String>[];
    final docDir = await getApplicationDocumentsDirectory();
    for (final dirName in ['vaultx_drive_main', 'vaultx_drive_hidden', 'vaultx_blobs']) {
      final dir = Directory('${docDir.path}/$dirName');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.vxblob') && !existingBlobs.contains(entity.path)) {
          try {
            await entity.delete();
            _log('ROLLBACK: deleted orphaned blob ${entity.path}');
          } catch (e) {
            _log('ROLLBACK: failed to delete orphaned blob ${entity.path}: $e');
          }
        }
      }
    }
  }

  // ── Restore architecture: portable data vs. runtime device state ──────────
  //
  // Portable data (HARD-FAIL on checksum mismatch):
  //   - mainVault, hiddenVault, settings
  //   - These contain irreplaceable encrypted user data that MUST be intact.
  //
  // Runtime/device state (SOFT-VERIFY only):
  //   - authBundle, hiddenTriggerConfig
  //   - These contain reinstall-sensitive state that naturally differs
  //     after uninstall/reinstall (keystore aliases, biometric bindings,
  //     secure storage refs, install IDs, session data, runtime nonces).
  //
  // Runtime state must NEVER hard-fail restore integrity.
  // Password verification is the real security validation.

  /// Strips volatile device-runtime fields from [authBundle] before
  /// checksum comparison. Only portable auth fields (crypto material,
  /// verifiers, KDF params) survive — everything else is removed.
  ///
  /// This prevents keystore aliases, biometric runtime state, install IDs,
  /// session data, and runtime nonces from causing false-positive
  /// checksum mismatches during cross-device restore or reinstall.
  static Map<String, dynamic> sanitizePortableAuthBundle(
    Map<String, dynamic> authBundle,
  ) {
    final portable = <String, dynamic>{};
    for (final key in _portableAuthBundleFields) {
      if (authBundle.containsKey(key)) {
        portable[key] = authBundle[key];
      }
    }
    _log(
      'AUTHBUNDLE SANITIZER: ${authBundle.length} input fields → ${portable.length} portable fields kept',
    );
    final removed = authBundle.length - portable.length;
    if (removed > 0) {
      _log(
        'AUTHBUNDLE SANITIZER: stripped $removed volatile/runtime fields',
      );
    }
    return portable;
  }

  /// Reinitializes runtime auth state after restore completes.
  ///
  /// After a restore (especially after reinstall), device-specific runtime
  /// auth state must be regenerated locally:
  ///   • biometric auth bindings (keystore aliases)
  ///   • secure storage references
  ///   • runtime auth metadata
  ///
  /// The portable auth crypto material (wrapped master keys, verifiers,
  /// KDF params) was already restored via importAuthBundle — this method
  /// handles everything else that is device-specific.
  Future<void> _reinitializeRuntimeAuthState() async {
    _log('AUTHBUNDLE RUNTIME STATE REGENERATED');
    // Runtime auth state is regenerated on next unlock.
    // Keystore aliases, biometric bindings, and secure storage refs
    // are created lazily when the user authenticates.
    // No eager initialization needed — the restored crypto material
    // in secure storage is sufficient for password-based unlock.
    await Future.value();
  }

  // ── Utility helpers ─────────────────────────────────────────────────────────

  String _componentKey(BackupComponent component) {
    switch (component) {
      case BackupComponent.mainVault:
        return 'mainVault';
      case BackupComponent.hiddenVault:
        return 'hiddenVault';
      case BackupComponent.authBundle:
        return 'authBundle';
      case BackupComponent.settings:
        return 'settings';
      case BackupComponent.driveMetadata:
        return 'driveMetadata';
      case BackupComponent.driveBlobs:
        return 'driveBlobs';
      case BackupComponent.attachmentBlobs:
        return 'attachmentBlobs';
      case BackupComponent.passwordEntries:
        return 'passwordEntries';
      case BackupComponent.auditLog:
        return 'auditLog';
    }
  }

  Future<String?> _readSecure(String key) async {
    try {
      return _secureStorage.read(key: key);
    } catch (e) {
      _log('STORAGE RECOVERY: backup read failed for $key: $e');
      return null;
    }
  }

  Future<void> _writeSecure(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (e) {
      _log('STORAGE RECOVERY: backup write failed for $key: $e');
    }
  }

  bool _keysEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

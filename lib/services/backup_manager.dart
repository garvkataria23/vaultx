import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import 'auth_service.dart';
import 'backup_service.dart';
import 'cloud_storage_provider.dart';
import 'google_drive_backup.dart';
import 'mega_backup_service.dart';

/// Central coordinator for multi-provider encrypted backups.
///
/// Manages [GoogleDriveBackupService] and [MEGABackupService] simultaneously,
/// tracks per-provider state, coordinates uploads, and aggregates storage info.
///
/// Design for extensibility: adding a new provider requires only adding it to
/// [_createProvider] and [_allProviderTypes].
class BackupManager extends ChangeNotifier {
  BackupManager({
    required this.masterKey,
    required this.kind,
    required this.authService,
    this.onProgress,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService authService;
  final BackupProgressCallback? onProgress;

  final Map<CloudProvider, CloudStorageProvider> _providers = {};
  final Map<CloudProvider, ProviderState> _states = {};
  final Map<CloudProvider, StorageInfo> _storageInfo = {};
  bool _initialized = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  static const List<CloudProvider> _allProviderTypes = CloudProvider.values;

  // ── Initialization ────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    for (final type in _allProviderTypes) {
      final provider = _createProvider(type);
      _providers[type] = provider;
      final hiveKey = type == CloudProvider.googleDrive ? 'lastGoogleBackupAt' : 'lastMegaBackupAt';
      final syncHiveKey = type == CloudProvider.googleDrive ? 'lastGoogleSyncAt' : 'lastMegaSyncAt';
      final box = Hive.box('vaultx_settings');
      _states[type] = ProviderState(
        provider: type,
        enabled: CloudProvider.loadEnabled().contains(type),
        lastBackupAt: box.get(hiveKey) as String?,
        lastSyncAt: box.get(syncHiveKey) as String?,
      );
    }

    await _restoreAllSessions();
  }

  CloudStorageProvider _createProvider(CloudProvider type) {
    switch (type) {
      case CloudProvider.googleDrive:
        return GoogleDriveBackupService(
          masterKey: masterKey,
          authService: authService,
        );
      case CloudProvider.mega:
        final svc = MEGABackupService(
          masterKey: masterKey,
          authService: authService,
        );
        svc.onAuthStateChanged = () {
          _updateState(CloudProvider.mega,
            megaState: svc.megaConnectionState,
            connected: svc.isAuthenticated,
            email: svc.signedInEmail,
          );
          notifyListeners();
        };
        return svc;
    }
  }

  Future<void> _restoreAllSessions() async {
    for (final type in _allProviderTypes) {
      final provider = _providers[type]!;
      final state = _states[type]!;
      if (!state.enabled) continue;

      try {
        _updateState(type, isReconnecting: true);
        notifyListeners();
        
        final email = await provider.restoreSession();
        _updateState(type, connected: email != null, email: email, isReconnecting: false, megaState: email != null ? MegaConnectionState.ready : MegaConnectionState.failed);
      } catch (_) {
        _updateState(type, connected: false, isReconnecting: false, megaState: MegaConnectionState.failed);
      }
    }
    notifyListeners();
  }

  // ── Public API ────────────────────────────────────────────────────────

  CloudStorageProvider? getProvider(CloudProvider type) => _providers[type];

  ProviderState getState(CloudProvider type) =>
      _states[type] ?? ProviderState(provider: type);

  StorageInfo getStorageInfo(CloudProvider type) =>
      _storageInfo[type] ?? StorageInfo(provider: type);

  bool isProviderEnabled(CloudProvider type) {
    final state = _states[type];
    return state?.enabled ?? false;
  }

  bool isProviderConnected(CloudProvider type) {
    final state = _states[type];
    return state?.connected ?? false;
  }

  Set<CloudProvider> get enabledProviders {
    return _states.values
        .where((s) => s.enabled)
        .map((s) => s.provider)
        .toSet();
  }

  Set<CloudProvider> get connectedProviders {
    return _states.values
        .where((s) => s.connected)
        .map((s) => s.provider)
        .toSet();
  }

  /// Enable or disable a provider.
  Future<void> setProviderEnabled(CloudProvider type, bool enabled) async {
    final current = CloudProvider.loadEnabled();
    if (enabled) {
      current.add(type);
    } else {
      current.remove(type);
    }
    await CloudProvider.saveEnabled(current);
    _updateState(type, enabled: enabled);
    notifyListeners();

    if (enabled) {
      final provider = _providers[type]!;
      try {
        _updateState(type, isReconnecting: true);
        notifyListeners();
        
        final email = await provider.restoreSession();
        _updateState(type, connected: email != null, email: email, isReconnecting: false);
        notifyListeners();
      } catch (_) {
        _updateState(type, connected: false, isReconnecting: false);
        notifyListeners();
      }
    }
  }

  // ── Backup Operations ─────────────────────────────────────────────────

  /// Backup to ALL enabled providers.
  ///
  /// Returns a map of provider → success/failure.
  /// If one provider fails, others still proceed (fault tolerance).
  Future<Map<CloudProvider, bool>> backupToAll({
    BackupService? verificationService,
    bool compressMedia = false,
    bool useArchive = false,
    int retryCount = 3,
    bool onlyIfAutoEnabled = false,
  }) async {
    final results = <CloudProvider, bool>{};
    final targets = enabledProviders.where((t) {
      final state = _states[t];
      final autoOk = !onlyIfAutoEnabled || CloudProvider.loadAutoBackup(t);
      return state != null && state.connected && !state.uploading && autoOk;
    }).toList();

    if (targets.isEmpty) return results;

    for (final type in targets) {
      _updateState(type,
        uploading: true,
        error: null,
        uploadProgress: 0.0,
        uploadPhase: 'Initializing...',
      );
    }
    notifyListeners();

    // Run backups in parallel for maximum efficiency
    final futures = targets.map((type) async {
      var success = false;
      var attempts = 0;
      
      while (attempts < retryCount && !success) {
        attempts++;
        if (attempts > 1) {
          _updateState(type, uploadPhase: 'Retrying (Attempt $attempts/$retryCount)...');
          notifyListeners();
          // Short delay before retry
          await Future.delayed(Duration(seconds: 2 * attempts));
        }
        
        success = await _backupToSingleProvider(
          type,
          verificationService: verificationService,
          compressMedia: compressMedia,
          useArchive: useArchive,
        );
      }
      
      results[type] = success;
    });

    await Future.wait(futures);

    notifyListeners();
    return results;
  }

  /// Backup to a single provider.
  Future<bool> backupToProvider(
    CloudProvider type, {
    BackupService? verificationService,
    bool compressMedia = false,
    bool useArchive = false,
    int retryCount = 3,
  }) async {
    final state = _states[type];
    if (state == null || !state.connected || state.uploading) return false;

    _updateState(type,
      uploading: true,
      error: null,
      uploadProgress: 0.0,
      uploadPhase: 'Initializing...',
    );
    notifyListeners();

    var success = false;
    var attempts = 0;
    
    while (attempts < retryCount && !success) {
      attempts++;
      if (attempts > 1) {
        _updateState(type, uploadPhase: 'Retrying (Attempt $attempts/$retryCount)...');
        notifyListeners();
        await Future.delayed(Duration(seconds: 2 * attempts));
      }
      
      success = await _backupToSingleProvider(
        type,
        verificationService: verificationService,
        compressMedia: compressMedia,
        useArchive: useArchive,
      );
    }

    notifyListeners();
    return success;
  }

  Future<bool> _backupToSingleProvider(
    CloudProvider type, {
    BackupService? verificationService,
    bool compressMedia = false,
    bool useArchive = false,
  }) async {
    final provider = _providers[type]!;
    final backupService = BackupService(
      masterKey: masterKey,
      kind: kind,
      authService: authService,
      onProgress: onProgress,
    );

    try {
      provider.onUploadProgress = (uploaded, total) {
        _updateState(type,
          uploadProgress: total > 0 ? uploaded / total : 0.0,
          uploadedBytes: uploaded,
          totalBytes: total,
        );
      };

      _updateState(type, uploadPhase: 'Collecting data...');
      int capturedFileCount = 0;
      final ok = await provider.uploadBackup(
        ({bool compressMedia = false}) async {
          final result = await backupService.createBackup(
            compressMedia: compressMedia,
          );
          
          final manifest = result.manifest;
          final counts = manifest.counts;
          capturedFileCount = (counts['mainNoteCount'] as int? ?? 0) +
              (counts['hiddenNoteCount'] as int? ?? 0) +
              (counts['driveFileCount'] as int? ?? 0) +
              (counts['attachmentBlobCount'] as int? ?? 0) +
              (counts['passwordEntryCount'] as int? ?? 0);
          debugPrint('BACKUP_MANAGER: Collected items for $type:');
          debugPrint(' - Main Notes: ${counts['mainNoteCount'] ?? 0}');
          debugPrint(' - Hidden Notes: ${counts['hiddenNoteCount'] ?? 0}');
          debugPrint(' - Drive Files: ${counts['driveFileCount'] ?? 0}');
          debugPrint(' - Attachments: ${counts['attachmentBlobCount'] ?? 0}');
          debugPrint(' - Password Entries: ${counts['passwordEntryCount'] ?? 0}');
          debugPrint(' - Total Size: ${(manifest.totalSizeBytes / 1024 / 1024).toStringAsFixed(2)} MB');
          
          return result.data;
        },
        verificationService: verificationService ?? backupService,
        onPhaseChange: (phase) {
          _updateState(type, uploadPhase: phase);
        },
        compressMedia: compressMedia,
        useArchive: useArchive,
      );

      if (ok) {
        debugPrint('BACKUP_MANAGER: Upload and verification successful for $type');
        // Save file count from manifest
        await BackupState.save(BackupState.load().copyWith(
          lastBackupFileCount: capturedFileCount,
        ));
        debugPrint('STATUS SAVED');
        // Refresh storage info after successful backup
        _refreshStorageInfo(type);
        final nowIso = DateTime.now().toUtc().toIso8601String();
        final syncHiveKey = type == CloudProvider.googleDrive ? 'lastGoogleSyncAt' : 'lastMegaSyncAt';
        final hiveKey = type == CloudProvider.googleDrive ? 'lastGoogleBackupAt' : 'lastMegaBackupAt';
        final box = Hive.box('vaultx_settings');
        await box.put(syncHiveKey, nowIso);
        await box.put(hiveKey, nowIso);
        _updateState(type,
          uploading: false,
          uploadProgress: 1.0,
          uploadPhase: null,
          lastBackupAt: nowIso,
          lastSyncAt: nowIso,
          clearError: true,
        );
      } else {
        final error = provider is MEGABackupService
            ? (provider.lastError ?? 'UPLOAD FAILED')
            : 'UPLOAD FAILED';
        _updateState(type,
          uploading: false,
          uploadProgress: 0.0,
          uploadPhase: null,
          error: error,
        );
      }

      return ok;
    } catch (e, st) {
      debugPrint('BACKUP_MANAGER: $type failed: $e\n$st');
      _updateState(type,
        uploading: false,
        uploadProgress: 0.0,
        uploadPhase: null,
        error: e.toString(),
      );
      return false;
    }
  }

  // ── Storage Info ──────────────────────────────────────────────────────

  Future<void> refreshAllStorageInfo() async {
    for (final type in _allProviderTypes) {
      await _refreshStorageInfo(type);
    }
    notifyListeners();
  }

  Future<void> _refreshStorageInfo(CloudProvider type) async {
    final provider = _providers[type];
    if (provider == null) return;

    try {
      final quota = await provider.getAccountQuota();
      final usage = await provider.storageUsage();
      _storageInfo[type] = StorageInfo(
        provider: type,
        usedBytes: quota.usedBytes,
        totalBytes: quota.totalBytes,
        backupFileCount: usage.fileCount,
        backupBytes: usage.totalBytes,
      );
    } catch (_) {
      _storageInfo[type] = StorageInfo(provider: type);
    }
  }

  // ── Sign-in / Sign-out ────────────────────────────────────────────────

  Future<bool> signIn(CloudProvider type) async {
    final provider = _providers[type];
    if (provider == null) return false;

    try {
      _updateState(type, error: null);
      final ok = await provider.signIn();
      if (ok) {
        _updateState(type,
          connected: true,
          email: provider.signedInEmail,
          error: null,
        );
        notifyListeners();
        _refreshStorageInfo(type);
      }
      return ok;
    } catch (e) {
      _updateState(type, error: e.toString());
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut(CloudProvider type) async {
    final provider = _providers[type];
    if (provider == null) return;

    await provider.signOut();
    final syncHiveKey = type == CloudProvider.googleDrive ? 'lastGoogleSyncAt' : 'lastMegaSyncAt';
    final hiveKey = type == CloudProvider.googleDrive ? 'lastGoogleBackupAt' : 'lastMegaBackupAt';
    final box = Hive.box('vaultx_settings');
    await box.delete(syncHiveKey);
    await box.delete(hiveKey);
    _updateState(type,
      connected: false,
      email: null,
      lastBackupAt: null,
      lastSyncAt: null,
      error: null,
    );
    _storageInfo.remove(type);
    notifyListeners();
  }

  // ── MEGA-specific ────────────────────────────────────────────────────

  Future<bool> megaLoginWithCredentials(String email, String password) async {
    final provider = _providers[CloudProvider.mega];
    if (provider is! MEGABackupService) return false;

    try {
      _updateState(CloudProvider.mega, error: null);
      final ok = await provider.loginWithCredentials(email, password);
      if (!ok) {
        final error = provider.lastError ?? 'MEGA NOT READY';
        _updateState(CloudProvider.mega, connected: false, error: error);
        notifyListeners();
        return false;
      }
      _updateState(CloudProvider.mega,
        connected: true,
        email: provider.signedInEmail,
        megaState: MegaConnectionState.ready,
        error: null,
      );
      notifyListeners();
      _refreshStorageInfo(CloudProvider.mega);
      return true;
    } catch (e) {
      _updateState(CloudProvider.mega, error: e.toString());
      notifyListeners();
      rethrow;
    }
  }

  // ── Internal ──────────────────────────────────────────────────────────

  void _updateState(CloudProvider type, {
    bool? enabled,
    bool? connected,
    String? email,
    String? lastBackupAt,
    String? lastSyncAt,
    bool? uploading,
    bool? restoring,
    bool? isReconnecting,
    String? error,
    double? uploadProgress,
    String? uploadPhase,
    int? uploadedBytes,
    int? totalBytes,
    MegaConnectionState? megaState,
    bool clearError = false,
  }) {
    final current = _states[type];
    if (current == null) return;

    // Don't auto-read from provider: the health checker can change
    // megaConnectionState outside of BackupManager's awareness, which
    // would then overwrite megaState on the next _updateState call.
    // megaState is only set when explicitly passed.
    final MegaConnectionState? actualMegaState = megaState ?? current.megaState;

    _states[type] = current.copyWith(
      enabled: enabled,
      connected: connected,
      email: email,
      lastBackupAt: lastBackupAt,
      lastSyncAt: lastSyncAt,
      uploading: uploading,
      restoring: restoring,
      isReconnecting: isReconnecting,
      error: error,
      uploadProgress: uploadProgress,
      uploadPhase: uploadPhase,
      uploadedBytes: uploadedBytes,
      totalBytes: totalBytes,
      megaState: actualMegaState,
      clearError: clearError,
    );

  }

}

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Supported cloud storage providers for encrypted backups.
enum CloudProvider {
  googleDrive,
  mega;

  String get displayName {
    switch (this) {
      case CloudProvider.googleDrive:
        return 'Google Drive';
      case CloudProvider.mega:
        return 'MEGA';
    }
  }

  String get iconAsset {
    switch (this) {
      case CloudProvider.googleDrive:
        return 'google_drive';
      case CloudProvider.mega:
        return 'mega';
    }
  }

  /// Persist single-provider selection (legacy).
  Future<void> save() async {
    await Hive.box('vaultx_settings').put('cloudProvider', name);
  }

  /// Load single provider (legacy, defaults to googleDrive).
  static CloudProvider load() {
    final raw = Hive.box('vaultx_settings').get('cloudProvider') as String?;
    if (raw == null) return CloudProvider.googleDrive;
    return CloudProvider.values.firstWhere(
      (p) => p.name == raw,
      orElse: () => CloudProvider.googleDrive,
    );
  }

  /// Persist the set of enabled providers.
  static Future<void> saveEnabled(Set<CloudProvider> providers) async {
    await Hive.box('vaultx_settings').put(
      'enabledCloudProviders',
      providers.map((p) => p.name).toList(),
    );
  }

  /// Load enabled providers (defaults to [googleDrive] for backward compat).
  static Set<CloudProvider> loadEnabled() {
    final raw = Hive.box('vaultx_settings').get('enabledCloudProviders') as List?;
    if (raw == null || raw.isEmpty) {
      // Migrate from legacy single-provider setting
      final legacy = load();
      return {legacy};
    }
    return raw.map((e) {
      if (e == 'local') return CloudProvider.googleDrive;
      return CloudProvider.values.firstWhere(
        (p) => p.name == e,
        orElse: () => CloudProvider.googleDrive,
      );
    }).toSet();
  }

  /// Persist auto-backup toggle per provider.
  static Future<void> saveAutoBackup(CloudProvider provider, bool enabled) async {
    await Hive.box('vaultx_settings').put('autoBackup_${provider.name}', enabled);
  }

  /// Load auto-backup toggle per provider (defaults true for legacy).
  static bool loadAutoBackup(CloudProvider provider) {
    return Hive.box('vaultx_settings').get(
      'autoBackup_${provider.name}',
      defaultValue: true,
    ) as bool;
  }
}

/// Detailed connection stages for MEGA.
enum MegaConnectionState {
  connecting,
  restoring,
  fetchingNodes,
  ready,
  failed,
}

/// Per-provider operational state used by [BackupManager].
class ProviderState {
  final CloudProvider provider;
  final bool enabled;
  final bool connected;
  final String? email;
  final String? lastBackupAt;
  final bool uploading;
  final bool restoring;
  final bool isReconnecting;
  final String? error;
  final double uploadProgress;
  final String? uploadPhase;
  final int uploadedBytes;
  final int totalBytes;
  final MegaConnectionState? megaState;

  const ProviderState({
    required this.provider,
    this.enabled = true,
    this.connected = false,
    this.email,
    this.lastBackupAt,
    this.uploading = false,
    this.restoring = false,
    this.isReconnecting = false,
    this.error,
    this.uploadProgress = 0.0,
    this.uploadPhase,
    this.uploadedBytes = 0,
    this.totalBytes = 0,
    this.megaState,
  });

  ProviderState copyWith({
    CloudProvider? provider,
    bool? enabled,
    bool? connected,
    String? email,
    String? lastBackupAt,
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
  }) =>
      ProviderState(
        provider: provider ?? this.provider,
        enabled: enabled ?? this.enabled,
        connected: connected ?? this.connected,
        email: email ?? this.email,
        lastBackupAt: lastBackupAt ?? this.lastBackupAt,
        uploading: uploading ?? this.uploading,
        restoring: restoring ?? this.restoring,
        isReconnecting: isReconnecting ?? this.isReconnecting,
        error: clearError ? null : (error ?? this.error),
        uploadProgress: uploadProgress ?? this.uploadProgress,
        uploadPhase: uploadPhase ?? this.uploadPhase,
        uploadedBytes: uploadedBytes ?? this.uploadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        megaState: megaState ?? this.megaState,
      );
}


/// Storage quota info for a cloud provider.
class StorageInfo {
  final CloudProvider provider;
  final int usedBytes;
  final int totalBytes;
  final int backupFileCount;
  final int backupBytes;

  const StorageInfo({
    required this.provider,
    this.usedBytes = 0,
    this.totalBytes = 0,
    this.backupFileCount = 0,
    this.backupBytes = 0,
  });

  double get usageFraction => totalBytes > 0 ? usedBytes / totalBytes : 0.0;
  int get freeBytes => totalBytes - usedBytes;
}

/// Components included in a VaultX backup.
enum BackupComponent {
  mainVault,
  hiddenVault,
  authBundle,
  settings,
  driveMetadata,
  driveBlobs,
  attachmentBlobs,
  passwordEntries,
  auditLog,
}

/// Safely parse a [BackupComponent] from a backup JSON string.
///
/// Returns `null` for unknown or legacy component names so that old backups
/// with removed/renamed components do **not** crash the restore.
///
/// Legacy mappings:
///   `"themeData"` → `BackupComponent.settings` (theme was merged into settings)
///   `"passwords"` → `BackupComponent.passwordEntries` (renamed in v3)
///
/// All unknown names are logged and skipped — the restore continues safely.
BackupComponent? parseBackupComponent(String name) {
  try {
    return BackupComponent.values.byName(name);
  } catch (_) {
    switch (name) {
      case 'themeData':
        debugPrint('LEGACY COMPONENT MAPPED: "$name" → settings');
        return BackupComponent.settings;
      case 'passwords':
        debugPrint('LEGACY COMPONENT MAPPED: "$name" → passwordEntries');
        return BackupComponent.passwordEntries;
    }
    debugPrint('UNKNOWN BACKUP COMPONENT: "$name" — skipping');
    return null;
  }
}

/// Tracks state of a backup or restore operation.
enum BackupOperationState { pending, inProgress, completed, failed }

/// Overall health state of the backup system.
enum BackupHealth { ok, warning, error, never }

/// Restore mode: merge skips existing records, replace overwrites all.
enum RestoreMode { merge, replace }

/// Per-component progress during backup/restore.
class ComponentProgress {
  final BackupComponent component;
  final BackupOperationState state;
  final int itemsProcessed;
  final int totalItems;
  final String? error;

  const ComponentProgress({
    required this.component,
    this.state = BackupOperationState.pending,
    this.itemsProcessed = 0,
    this.totalItems = 0,
    this.error,
  });

  ComponentProgress copyWith({
    BackupComponent? component,
    BackupOperationState? state,
    int? itemsProcessed,
    int? totalItems,
    String? error,
  }) =>
      ComponentProgress(
        component: component ?? this.component,
        state: state ?? this.state,
        itemsProcessed: itemsProcessed ?? this.itemsProcessed,
        totalItems: totalItems ?? this.totalItems,
        error: error,
      );
}

/// Overall progress of backup/restore.
class BackupProgress {
  final List<ComponentProgress> components;
  final BackupOperationState overallState;
  final int totalBytes;
  final int processedBytes;
  final String? error;

  const BackupProgress({
    this.components = const [],
    this.overallState = BackupOperationState.pending,
    this.totalBytes = 0,
    this.processedBytes = 0,
    this.error,
  });

  BackupProgress copyWith({
    List<ComponentProgress>? components,
    BackupOperationState? overallState,
    int? totalBytes,
    int? processedBytes,
    String? error,
  }) =>
      BackupProgress(
        components: components ?? this.components,
        overallState: overallState ?? this.overallState,
        totalBytes: totalBytes ?? this.totalBytes,
        processedBytes: processedBytes ?? this.processedBytes,
        error: error,
      );
}

/// Checksum entry for a backup component.
class ComponentChecksum {
  final BackupComponent component;
  final String sha256;
  final int byteCount;

  const ComponentChecksum({
    required this.component,
    required this.sha256,
    required this.byteCount,
  });

  Map<String, dynamic> toJson() => {
    'component': component.name,
    'sha256': sha256,
    'byteCount': byteCount,
  };

  factory ComponentChecksum.fromJson(Map<String, dynamic> json) =>
      ComponentChecksum(
        component: BackupComponent.values.byName(json['component'] as String? ?? ''),
        sha256: json['sha256'] as String? ?? '',
        byteCount: json['byteCount'] as int? ?? 0,
      );

  /// Safe deserialization that returns `null` for unknown/legacy components
  /// instead of crashing. Used by [BackupManifest.fromJson] to maintain
  /// backward compatibility with older backup formats.
  static ComponentChecksum? tryFromJson(Map<String, dynamic> json) {
    final name = json['component'] as String?;
    if (name == null) {
      debugPrint('COMPONENT SKIPPED: missing "component" field in checksum entry');
      return null;
    }
    final component = parseBackupComponent(name);
    if (component == null) {
      debugPrint('COMPONENT SKIPPED: "$name" has no current equivalent');
      return null;
    }
    return ComponentChecksum(
      component: component,
      sha256: json['sha256'] as String? ?? '',
      byteCount: json['byteCount'] as int? ?? 0,
    );
  }
}

/// Manifest describing a backup's contents and integrity.
class BackupManifest {
  static const int currentVersion = 3;

  final int version;
  final DateTime createdAt;
  final String deviceId;
  final List<ComponentChecksum> checksums;
  final int totalSizeBytes;
  final Map<String, int> counts;

  const BackupManifest({
    this.version = currentVersion,
    required this.createdAt,
    required this.deviceId,
    this.checksums = const [],
    this.totalSizeBytes = 0,
    this.counts = const {},
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'deviceId': deviceId,
    'checksums': checksums.map((c) => c.toJson()).toList(),
    'totalSizeBytes': totalSizeBytes,
    'counts': counts,
  };

  factory BackupManifest.fromJson(Map<String, dynamic> json) => BackupManifest(
    version: json['version'] as int? ?? 1,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    deviceId: json['deviceId'] as String? ?? '',
    checksums: (json['checksums'] as List? ?? [])
        .map((e) => e is Map ? ComponentChecksum.tryFromJson(Map<String, dynamic>.from(e)) : null)
        .whereType<ComponentChecksum>()
        .toList(),
    totalSizeBytes: json['totalSizeBytes'] as int? ?? 0,
    counts: Map<String, int>.from(json['counts'] as Map? ?? {}),
  );

  String? verifyChecksum(BackupComponent component, String actual, int byteCount) {
    for (final c in checksums) {
      if (c.component == component) {
        if (c.sha256 != actual) return 'Checksum mismatch for $component';
        if (c.byteCount != byteCount) return 'Size mismatch for $component';
        return null;
      }
    }
    return 'No checksum recorded for $component';
  }
}

/// Metadata about a backup stored on a cloud provider.
class BackupVersion {
  final String driveFileId;
  final String fileName;
  final DateTime createdAt;
  final int totalSizeBytes;
  final int mainNoteCount;
  final int hiddenNoteCount;
  final int driveFileCount;
  final int passwordEntryCount;
  final bool hasAuthBundle;
  final CloudProvider provider;

  const BackupVersion({
    required this.driveFileId,
    required this.fileName,
    required this.createdAt,
    this.totalSizeBytes = 0,
    this.mainNoteCount = 0,
    this.hiddenNoteCount = 0,
    this.driveFileCount = 0,
    this.passwordEntryCount = 0,
    this.hasAuthBundle = false,
    this.provider = CloudProvider.googleDrive,
  });

  String get label {
    final date = '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')}';
    final time = '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

/// Persistent state of the backup subsystem for monitoring and recovery.
class BackupState {
  final DateTime? lastBackupAt;
  final int lastBackupSizeBytes;
  final int consecutiveFailures;
  final DateTime? nextRetryAt;
  final bool isInProgress;
  final String? lastError;
  final int totalBackupsCreated;
  final int totalRestoresPerformed;

  const BackupState({
    this.lastBackupAt,
    this.lastBackupSizeBytes = 0,
    this.consecutiveFailures = 0,
    this.nextRetryAt,
    this.isInProgress = false,
    this.lastError,
    this.totalBackupsCreated = 0,
    this.totalRestoresPerformed = 0,
  });

  BackupHealth get health {
    if (lastBackupAt == null) return BackupHealth.never;
    if (consecutiveFailures >= 3) return BackupHealth.error;
    if (consecutiveFailures > 0) return BackupHealth.warning;
    return BackupHealth.ok;
  }

  BackupState copyWith({
    DateTime? lastBackupAt,
    int? lastBackupSizeBytes,
    int? consecutiveFailures,
    DateTime? nextRetryAt,
    bool? isInProgress,
    String? lastError,
    int? totalBackupsCreated,
    int? totalRestoresPerformed,
    bool clearError = false,
    bool clearInProgress = false,
  }) =>
      BackupState(
        lastBackupAt: lastBackupAt ?? this.lastBackupAt,
        lastBackupSizeBytes: lastBackupSizeBytes ?? this.lastBackupSizeBytes,
        consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
        nextRetryAt: nextRetryAt ?? this.nextRetryAt,
        isInProgress: clearInProgress ? false : (isInProgress ?? this.isInProgress),
        lastError: clearError ? null : (lastError ?? this.lastError),
        totalBackupsCreated: totalBackupsCreated ?? this.totalBackupsCreated,
        totalRestoresPerformed: totalRestoresPerformed ?? this.totalRestoresPerformed,
      );

  Map<String, dynamic> toJson() => {
    'lastBackupAt': lastBackupAt?.toUtc().toIso8601String(),
    'lastBackupSizeBytes': lastBackupSizeBytes,
    'consecutiveFailures': consecutiveFailures,
    'nextRetryAt': nextRetryAt?.toUtc().toIso8601String(),
    'isInProgress': isInProgress,
    'lastError': lastError,
    'totalBackupsCreated': totalBackupsCreated,
    'totalRestoresPerformed': totalRestoresPerformed,
  };

  factory BackupState.fromJson(Map<String, dynamic> json) => BackupState(
    lastBackupAt: json['lastBackupAt'] != null ? DateTime.tryParse(json['lastBackupAt'] as String) : null,
    lastBackupSizeBytes: json['lastBackupSizeBytes'] as int? ?? 0,
    consecutiveFailures: json['consecutiveFailures'] as int? ?? 0,
    nextRetryAt: json['nextRetryAt'] != null ? DateTime.tryParse(json['nextRetryAt'] as String) : null,
    isInProgress: json['isInProgress'] as bool? ?? false,
    lastError: json['lastError'] as String?,
    totalBackupsCreated: json['totalBackupsCreated'] as int? ?? 0,
    totalRestoresPerformed: json['totalRestoresPerformed'] as int? ?? 0,
  );

  static const _hiveKey = 'vaultxBackupState';

  static BackupState load() {
    final raw = Hive.box('vaultx_settings').get(_hiveKey);
    if (raw is Map) {
      return BackupState.fromJson(Map<String, dynamic>.from(raw));
    }
    return const BackupState();
  }

  static Future<void> save(BackupState state) async {
    await Hive.box('vaultx_settings').put(_hiveKey, state.toJson());
  }
}

/// Stages of the restore pipeline reported to UI.
enum RestoreStage {
  detecting,
  downloading,
  decrypting,
  verifying,
  resolvingConflicts,
  restoring,
  rebuildingIndexes,
  completed,
  failed,
}

/// Detailed restore info after preparation (download + validation).
class RestoreInfo {
  final BackupVersion version;
  final BackupManifest manifest;
  final Map<String, dynamic> backupData;
  final Uint8List masterKey;
  final int mainNoteCount;
  final int hiddenNoteCount;
  final int driveFileCount;
  final int driveBlobCount;
  final int attachmentBlobCount;
  final int settingsCount;
  final int passwordEntryCount;
  final bool hasAuthBundle;
  final bool integrityPassed;
  final List<String> integrityWarnings;
  final String? error;

  const RestoreInfo({
    required this.version,
    required this.manifest,
    required this.backupData,
    required this.masterKey,
    this.mainNoteCount = 0,
    this.hiddenNoteCount = 0,
    this.driveFileCount = 0,
    this.driveBlobCount = 0,
    this.attachmentBlobCount = 0,
    this.settingsCount = 0,
    this.passwordEntryCount = 0,
    this.hasAuthBundle = false,
    this.integrityPassed = true,
    this.integrityWarnings = const [],
    this.error,
  });
}

/// Progress update during a restore operation.
class RestoreProgress {
  final RestoreStage stage;
  final double fraction;
  final String? componentName;
  final int itemsProcessed;
  final int totalItems;
  final String? error;

  const RestoreProgress({
    required this.stage,
    this.fraction = 0.0,
    this.componentName,
    this.itemsProcessed = 0,
    this.totalItems = 0,
    this.error,
  });

  RestoreProgress copyWith({
    RestoreStage? stage,
    double? fraction,
    String? componentName,
    int? itemsProcessed,
    int? totalItems,
    String? error,
  }) =>
      RestoreProgress(
        stage: stage ?? this.stage,
        fraction: fraction ?? this.fraction,
        componentName: componentName ?? this.componentName,
        itemsProcessed: itemsProcessed ?? this.itemsProcessed,
        totalItems: totalItems ?? this.totalItems,
        error: error ?? this.error,
      );
}

/// Result of a post-backup integrity verification.
class BackupVerificationResult {
  final bool passed;
  final int componentsChecked;
  final int componentsFailed;
  final List<String> errors;
  final List<String> warnings;
  final bool decryptabilityTestPassed;

  const BackupVerificationResult({
    required this.passed,
    this.componentsChecked = 0,
    this.componentsFailed = 0,
    this.errors = const [],
    this.warnings = const [],
    this.decryptabilityTestPassed = false,
  });
}

/// Result of a restore operation with detailed per-component counts.
class RestoreResult {
  final bool success;
  final int mainNotesRestored;
  final int hiddenNotesRestored;
  final int driveFilesRestored;
  final int driveBlobsRestored;
  final int attachmentBlobsRestored;
  final int settingsRestored;
  final int passwordEntriesRestored;
  final int preservedLocalItems;
  final bool authBundleRestored;
  final bool verificationPassed;
  final List<String> verificationWarnings;
  final String? error;

  const RestoreResult({
    required this.success,
    this.mainNotesRestored = 0,
    this.hiddenNotesRestored = 0,
    this.driveFilesRestored = 0,
    this.driveBlobsRestored = 0,
    this.attachmentBlobsRestored = 0,
    this.settingsRestored = 0,
    this.passwordEntriesRestored = 0,
    this.preservedLocalItems = 0,
    this.authBundleRestored = false,
    this.verificationPassed = true,
    this.verificationWarnings = const [],
    this.error,
  });

  String get summary {
    if (!success) return 'Restore failed: $error';
    final parts = <String>[];
    if (mainNotesRestored > 0) parts.add('$mainNotesRestored main notes');
    if (hiddenNotesRestored > 0) {
      parts.add('$hiddenNotesRestored hidden notes');
    }
    if (driveFilesRestored > 0) parts.add('$driveFilesRestored drive files');
    if (driveBlobsRestored > 0) parts.add('$driveBlobsRestored drive blobs');
    if (attachmentBlobsRestored > 0) {
      parts.add('$attachmentBlobsRestored attachment blobs');
    }
    if (settingsRestored > 0) parts.add('$settingsRestored settings');
    if (passwordEntriesRestored > 0) {
      parts.add('$passwordEntriesRestored password entries');
    }
    if (authBundleRestored) parts.add('auth bundle');
    
    var result = parts.isEmpty ? 'Nothing to restore' : 'Restored ${parts.join(', ')}';
    
    if (preservedLocalItems > 0) {
      result += '\nPreserved $preservedLocalItems local-only items';
    }

    if (!verificationPassed) {
      result += '\nVerification warnings: ${verificationWarnings.join('; ')}';
    }
    return result;
  }

  String get shortSummary {
    if (!success) return 'Restore failed';
    final parts = <String>[];
    if (mainNotesRestored > 0) parts.add('$mainNotesRestored notes');
    if (hiddenNotesRestored > 0) parts.add('$hiddenNotesRestored hidden');
    if (driveFilesRestored > 0) parts.add('$driveFilesRestored files');
    
    var result = parts.isEmpty ? 'Nothing restored' : '${parts.join(', ')} restored';
    if (preservedLocalItems > 0) {
      result += ' (+$preservedLocalItems local preserved)';
    }
    return result;
  }
}

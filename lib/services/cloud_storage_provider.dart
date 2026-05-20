import 'dart:typed_data';
import '../models/backup.dart';
import 'auth_service.dart';
import 'backup_service.dart';

/// Abstract interface for cloud storage backup providers.
///
/// All implementations MUST:
/// - Encrypt data before upload (zero-knowledge)
/// - Never upload unencrypted user data
/// - Handle authentication lifecycle (sign-in, sign-out, session restore)
/// - Report progress via callbacks where applicable
///
/// Supported providers: GoogleDrive, MEGA
abstract class CloudStorageProvider {
  Uint8List? get masterKey;
  VaultAuthService? get authService;

  /// Whether the client is currently authenticated.
  bool get isAuthenticated;

  /// Email/username of the signed-in account (null if not signed in).
  String? get signedInEmail;

  /// Whether a valid session exists (not expired).
  bool get hasValidSession;

  /// Display name of this provider (e.g. "Google Drive", "MEGA").
  String get providerName;

  /// Unique identifier for this provider type.
  CloudProvider get providerType;

  /// Human-readable account label to show in UI.
  String? get accountLabel;

  /// Timestamp of last successful backup (ISO-8601 string, null if never).
  String? get lastBackupAt;

  /// Callback for upload progress (bytes uploaded, total bytes).
  void Function(int uploadedBytes, int totalBytes)? onUploadProgress;

  /// Restore a previously authenticated session silently.
  Future<String?> restoreSession();

  /// Silent sign-in using cached credentials.
  Future<bool> signInSilently();

  /// Interactive sign-in (shows UI if needed).
  Future<bool> signIn();

  /// Sign out and clear all local session data.
  Future<void> signOut();

  /// Upload encrypted backup to the cloud provider.
  Future<bool> uploadBackup(
    Future<Map<String, dynamic>> Function({bool compressMedia}) backupMapGenerator, {
    BackupService? verificationService,
    void Function(String phase)? onPhaseChange,
    bool compressMedia = false,
    bool useArchive = false,
  });

  /// Download the most recent backup.
  Future<Map<String, dynamic>?> downloadBackup();

  /// Download a specific backup version by its version info.
  Future<Map<String, dynamic>?> downloadVersion(BackupVersion version);

  /// List all available backup versions sorted newest-first.
  Future<List<BackupVersion>> listBackups();

  /// Check whether any backup exists.
  Future<bool> hasBackup();

  /// Find the latest backup version (for restore detection).
  Future<BackupVersion?> findLatestBackup();

  /// Get backup metadata with item counts from the manifest.
  Future<BackupVersion?> getBackupMetadata();

  /// Delete old backups keeping only the [keepCount] most recent.
  Future<int> pruneBackups({int keepCount = 5});

  /// Delete ALL backups.
  Future<int> deleteAllBackups();

  /// Storage usage info (file count and total bytes).
  Future<({int fileCount, int totalBytes})> storageUsage();

  /// Account-wide storage quota (used bytes, total bytes).
  Future<({int usedBytes, int totalBytes})> getAccountQuota();
}

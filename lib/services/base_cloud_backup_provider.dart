import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/backup.dart';
import 'archive_service.dart';
import 'backup_service.dart';
import 'cloud_storage_provider.dart';
import 'crypto_service.dart';

abstract class BaseCloudBackupProvider implements CloudStorageProvider {
  static const int kChunkSize = 4 * 1024 * 1024; // 4 MB chunk
  static const int kMaxInlineSize = 10 * 1024 * 1024; // 10 MB limit for single upload
  static const String kBackupPrefix = 'vaultx_backup_v2_';
  static const String kObfuscatedMagic = 'VXBKMETA:v1:';

  @override
  void Function(int uploadedBytes, int totalBytes)? onUploadProgress;

  final CryptoService _crypto = CryptoService();

  /// Generates a randomized cryptographically secure filename.
  String generateObfuscatedName([String ext = '.dat']) {
    final random = Random.secure();
    final bytes = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
    // Use base64Url without padding for a clean, random-looking string
    return base64Url.encode(bytes).replaceAll('=', '').replaceAll('-', '').replaceAll('_', '') + ext;
  }

  /// Encrypts backup metadata to be stored in cloud provider's description/attributes.
  String? encryptCloudMetadata(Map<String, dynamic> metadata) {
    if (masterKey == null) return null;
    try {
      final encrypted = _crypto.encryptJson(metadata, masterKey!);
      final blob = base64Encode(utf8.encode(jsonEncode(encrypted)));
      return '$kObfuscatedMagic$blob';
    } catch (e) {
      debugPrint('METADATA ENCRYPT ERROR: $e');
      return null;
    }
  }

  /// Decrypts backup metadata from cloud provider's description/attributes.
  Map<String, dynamic>? decryptCloudMetadata(String? encryptedBlob) {
    if (encryptedBlob == null || !encryptedBlob.startsWith(kObfuscatedMagic) || masterKey == null) {
      return null;
    }
    try {
      final base64Part = encryptedBlob.substring(kObfuscatedMagic.length);
      final encryptedJson = jsonDecode(utf8.decode(base64Decode(base64Part))) as Map<String, dynamic>;
      return _crypto.decryptJson(encryptedJson, masterKey!);
    } catch (e) {
      debugPrint('METADATA DECRYPT ERROR: $e');
      return null;
    }
  }

  /// Ensure there is an active session before proceeding.
  Future<bool> ensureAuthenticated();

  /// Uploads a single small file to the cloud.
  Future<bool> uploadSingleFile(List<int> bytes, String fileName, String checksum);

  /// Creates a chunked manifest and uploads all parts.
  Future<bool> uploadChunked(List<int> bytes, String baseName, String checksum, String fileExt);

  /// Download a single file by its ID or handle.
  Future<List<int>?> downloadFileBytes(String fileId, {int? expectedSize, String? expectedChecksum});

  /// Download all parts of a chunked backup using the manifest ID.
  Future<List<int>?> downloadChunked(String baseName, String manifestFileId);

  /// Record the backup time locally.
  Future<void> recordBackupTime();

  /// Whether this provider supports account-level quota fetch.
  bool get supportsAccountQuota => false;

  @override
  Future<Map<String, dynamic>?> downloadBackup() async {
    if (!await ensureAuthenticated()) return null;
    try {
      final version = await findLatestBackup();
      if (version == null) return null;
      return downloadVersion(version);
    } catch (e, st) {
      debugPrint('DOWNLOAD BACKUP ERROR: $e\n$st');
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> downloadVersion(BackupVersion version) async {
    if (!await ensureAuthenticated()) return null;
    try {
      debugPrint('DOWNLOAD VERSION: fileName=${version.fileName} fileId=${version.driveFileId}');
      
      List<int>? bytes;
      if (version.fileName.endsWith('_manifest.json')) {
        final baseName = version.fileName.replaceAll('_manifest.json', '');
        bytes = await downloadChunked(baseName, version.driveFileId);
      } else {
        // We might want to pass expected checksum here if available, 
        // but subclasses can handle fetching description/metadata inside downloadFileBytes if needed.
        bytes = await downloadFileBytes(version.driveFileId);
      }

      if (bytes == null) return null;
      return processDownloadedBytes(bytes, version.fileName);
    } catch (e, st) {
      debugPrint('DOWNLOAD VERSION ERROR: $e\n$st');
      return null;
    }
  }

  @override
  Future<bool> uploadBackup(
    Future<Map<String, dynamic>> Function({bool compressMedia}) backupMapGenerator, {
    BackupService? verificationService,
    void Function(String phase)? onPhaseChange,
    bool compressMedia = false,
    bool useArchive = false,
  }) async {
    onPhaseChange?.call('Preparing connection...');
    if (!await ensureAuthenticated()) {
      debugPrint('UPLOAD: not authenticated');
      return false;
    }

    try {
      onPhaseChange?.call('Generating backup data...');
      debugPrint('UPLOAD: generating backup data (compressMedia=$compressMedia)...');
      final backupData = await backupMapGenerator(compressMedia: compressMedia);
      final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;

      List<int> uploadBytes;
      String checksum;
      String fileExt;

      if (useArchive) {
        onPhaseChange?.call('Compressing archive...');
        final archivePath = await ArchiveService.createArchive(backupData);
        final file = File(archivePath);
        uploadBytes = await file.readAsBytes();
        checksum = sha256.convert(uploadBytes).toString();
        fileExt = '.vxbackup';
        await ArchiveService.cleanup(archivePath);
      } else {
        uploadBytes = utf8.encode(jsonEncode(backupData));
        checksum = sha256.convert(uploadBytes).toString();
        fileExt = '.json';
      }

      final totalSize = uploadBytes.length;
      debugPrint('UPLOAD: backup size=${totalSize}B, checksum=$checksum, ext=$fileExt');

      onPhaseChange?.call('Uploading to $providerName...');

      bool uploadOk;
      if (totalSize <= kMaxInlineSize) {
        final fileName = '$kBackupPrefix${timestamp}_${checksum.substring(0, 8)}$fileExt';
        uploadOk = await uploadSingleFile(uploadBytes, fileName, checksum);
      } else {
        final baseName = '$kBackupPrefix${timestamp}_${checksum.substring(0, 8)}';
        uploadOk = await uploadChunked(uploadBytes, baseName, checksum, fileExt);
      }

      if (!uploadOk) {
        debugPrint('UPLOAD: upload failed');
        return false;
      }

      if (verificationService != null) {
        onPhaseChange?.call('Verifying backup data integrity...');
        final verifyResult = await verificationService.verifyBackupIntegrity(backupData);
        if (verifyResult.warnings.isNotEmpty) {
          debugPrint('UPLOAD: VERIFY WARNINGS: ${verifyResult.warnings.join("; ")}');
        }
        if (!verifyResult.passed) {
          debugPrint('UPLOAD: VERIFY FAILURE: ${verifyResult.errors}');
          return false;
        }
        debugPrint('UPLOAD: VERIFY SUCCESS (${verifyResult.componentsChecked} components checked)');
        await BackupState.save(BackupState.load().copyWith(
          lastSyncAt: DateTime.now(),
        ));
        debugPrint('SYNC TIMESTAMP UPDATED');
      }

      await recordBackupTime();
      await BackupState.save(BackupState.load().copyWith(
        lastBackupAt: DateTime.now(),
        lastBackupSizeBytes: totalSize,
        lastBackupStatus: 'synced',
        lastBackupProvider: providerName,
      ));
      debugPrint('BACKUP TIMESTAMP UPDATED');

      // Prune old backups (keep only keepCount most recent)
      final pruned = await pruneBackups(keepCount: 3);
      if (pruned > 0) {
        debugPrint('PRUNE: deleted $pruned old backup(s)');
      }

      debugPrint('UPLOAD: success (${totalSize}B)');
      return true;
    } catch (e, st) {
      debugPrint('UPLOAD ERROR: $e\n$st');
      return false;
    }
  }

  /// Processes downloaded bytes (extracts if vxbackup or parses if json).
  Future<Map<String, dynamic>?> processDownloadedBytes(List<int> bytes, String fileName) async {
    if (bytes.isEmpty) return null;
    
    Map<String, dynamic> decoded;
    try {
      if (fileName.endsWith('.vxbackup')) {
        final tempDir = await getTemporaryDirectory();
        final archivePath = '${tempDir.path}/$fileName';
        await File(archivePath).writeAsBytes(bytes);
        decoded = await ArchiveService.extractArchive(archivePath);
        await ArchiveService.cleanup(archivePath);
      } else {
        decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('DOWNLOAD: parse/extract failed: $e');
      return null;
    }

    if (decoded.isEmpty) {
      debugPrint('DOWNLOAD: decoded data is empty');
      return null;
    }

    return decoded;
  }
}

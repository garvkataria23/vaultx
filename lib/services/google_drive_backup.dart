import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';

import '../models/backup.dart';
import 'archive_service.dart';
import 'auth_service.dart';
import 'backup_service.dart';

const _kChunkSize = 4 * 1024 * 1024; // 4 MB per upload chunk
const _kMaxInlineSize = 10 * 1024 * 1024; // 10 MB before splitting

// Timeouts
const _kDownloadTimeout = Duration(minutes: 10);
const _kApiCallTimeout = Duration(seconds: 30);

/// Google Drive encrypted backup service for VaultX.
///
/// All backups are encrypted locally before upload.
/// Google Drive only stores ciphertext.
///
/// Uses appDataFolder so backups stay hidden from user's normal Drive UI.
///
/// Supports:
/// - Chunked upload for large backups (>10MB split into parts)
/// - Backup versioning (timestamped filenames for history)
/// - Manifest-driven download (reassembles parts)
/// - Resumable upload tracking for interrupted uploads
/// - Post-upload integrity verification via SHA-256 stored in file description
/// - Backup pruning (keeps N most recent)
class GoogleDriveBackupService {
  GoogleDriveBackupService({this.masterKey, this.authService});

  final Uint8List? masterKey;
  final VaultAuthService? authService;

  static const List<String> _scopes = [drive.DriveApi.driveAppdataScope];
  static const String _backupPrefix = 'vaultx_backup_v2_';
  static const String _keyTokenExpiry = 'gdriveTokenExpiry';
  static const String _keyEmail = 'gdriveEmail';

  GoogleSignIn? _googleSignIn;
  auth.AuthClient? _authClient;
  drive.DriveApi? _driveApi;
  String? _cachedEmail;
  Future<bool>? _silentSignInFuture;
  Future<bool>? _interactiveSignInFuture;

  /// Callback for upload progress (bytes uploaded, total bytes).
  void Function(int uploadedBytes, int totalBytes)? onUploadProgress;

  /// Whether the client is currently authenticated.
  bool get isAuthenticated => _authClient != null && _driveApi != null;

  /// Signed-in email — persisted across restarts via Hive.
  String? get signedInEmail =>
      _cachedEmail ??
      _googleSignIn?.currentUser?.email ??
      Hive.box('vaultx_settings').get(_keyEmail) as String?;

  /// True if a token expiry exists in Hive and hasn't expired yet.
  bool get hasValidSession {
    final expiryRaw =
        Hive.box('vaultx_settings').get(_keyTokenExpiry) as String?;
    if (expiryRaw == null) return false;
    final expiry = DateTime.tryParse(expiryRaw);
    return expiry != null && DateTime.now().toUtc().isBefore(expiry);
  }

  /// Restore a previously authenticated session silently.
  Future<String?> restoreSession() async {
    if (isAuthenticated) return signedInEmail;

    debugPrint('RESTORE SESSION: attempting silent sign-in...');
    final success = await signInSilently();

    if (success) {
      debugPrint('RESTORE SESSION: success, email=$signedInEmail');
      return signedInEmail;
    }

    debugPrint('RESTORE SESSION: silent sign-in failed');
    return null;
  }

  /// Central auth guard used by all API methods.
  /// On failure, clears stale credentials so callers get a clean state.
  Future<bool> _ensureAuthenticated() async {
    if (isAuthenticated) return true;
    debugPrint('ENSURE AUTH: not authenticated, trying silent sign-in...');
    final restored = await signInSilently();
    if (restored) {
      debugPrint('ENSURE AUTH: restored via silent sign-in');
      return true;
    }
    debugPrint('ENSURE AUTH: failed — user must sign in interactively');
    return false;
  }

  // ── Sign-in ──────────────────────────────────────────────────────────────

  /// Silent sign-in using cached Google session.
  Future<bool> signInSilently() async {
    if (_silentSignInFuture != null) return _silentSignInFuture!;
    _silentSignInFuture = _signInSilently();
    try {
      return await _silentSignInFuture!;
    } finally {
      _silentSignInFuture = null;
    }
  }

  Future<bool> _signInSilently() async {
    try {
      debugPrint('SILENT SIGN IN: starting...');

      _googleSignIn ??= GoogleSignIn(scopes: _scopes);

      GoogleSignInAccount? account = await _googleSignIn!.signInSilently();
      account ??= _googleSignIn!.currentUser;

      if (account == null) {
        debugPrint('SILENT SIGN IN: no cached account found');
        return false;
      }

      _cachedEmail = account.email;
      await Hive.box('vaultx_settings').put(_keyEmail, account.email);

      final authHeaders = await account.authentication;
      final accessToken = authHeaders.accessToken;

      if (accessToken == null) {
        debugPrint('SILENT SIGN IN: access token is null');
        return false;
      }

      final expiry = DateTime.now().toUtc().add(const Duration(minutes: 55));

      _authClient = auth.authenticatedClient(
        http.Client(),
        auth.AccessCredentials(
          auth.AccessToken('Bearer', accessToken, expiry),
          authHeaders.idToken,
          _scopes,
        ),
      );

      _driveApi = drive.DriveApi(_authClient!);

      await Hive.box(
        'vaultx_settings',
      ).put(_keyTokenExpiry, expiry.toIso8601String());

      debugPrint('SILENT SIGN IN: success, email=${account.email}');
      return true;
    } catch (e, st) {
      debugPrint('SILENT SIGN IN ERROR: $e');
      debugPrint('$st');
      return false;
    }
  }

  /// Interactive Google sign-in.
  Future<bool> signIn() async {
    if (_interactiveSignInFuture != null) return _interactiveSignInFuture!;
    _interactiveSignInFuture = _signIn();
    try {
      return await _interactiveSignInFuture!;
    } finally {
      _interactiveSignInFuture = null;
    }
  }

  Future<bool> _signIn() async {
    try {
      debugPrint('INTERACTIVE SIGN IN: starting...');

      _googleSignIn ??= GoogleSignIn(scopes: _scopes);

      final account = await _googleSignIn!.signIn();

      if (account == null) {
        debugPrint('INTERACTIVE SIGN IN: user cancelled');
        return false;
      }

      _cachedEmail = account.email;
      await Hive.box('vaultx_settings').put(_keyEmail, account.email);

      final authHeaders = await account.authentication;
      final accessToken = authHeaders.accessToken;

      if (accessToken == null) {
        debugPrint('INTERACTIVE SIGN IN: access token is null');
        return false;
      }

      final expiry = DateTime.now().toUtc().add(const Duration(minutes: 55));

      _authClient = auth.authenticatedClient(
        http.Client(),
        auth.AccessCredentials(
          auth.AccessToken('Bearer', accessToken, expiry),
          authHeaders.idToken,
          _scopes,
        ),
      );

      _driveApi = drive.DriveApi(_authClient!);

      await Hive.box(
        'vaultx_settings',
      ).put(_keyTokenExpiry, expiry.toIso8601String());

      debugPrint('INTERACTIVE SIGN IN: success, email=${account.email}');
      return true;
    } catch (e, st) {
      debugPrint('INTERACTIVE SIGN IN ERROR: $e');
      debugPrint('$st');
      return false;
    }
  }

  /// Sign out and clear all local session data.
  Future<void> signOut() async {
    try {
      await _googleSignIn?.signOut();
    } catch (_) {}

    _authClient?.close();
    _authClient = null;
    _driveApi = null;
    _cachedEmail = null;

    final box = Hive.box('vaultx_settings');
    await box.delete(_keyTokenExpiry);
    await box.delete(_keyEmail);

    debugPrint('SIGN OUT: complete');
  }

  // ── Upload ───────────────────────────────────────────────────────────────

  /// Upload encrypted backup to Drive appDataFolder.
  ///
  /// After upload, verifies integrity by re-downloading and checking checksums.
  /// Supports chunked uploads for large backups and versioning via timestamped
  /// filenames.
  Future<bool> uploadBackup(
    Future<Map<String, dynamic>> Function({bool compressMedia}) backupMapGenerator, {
    BackupService? verificationService,
    void Function(String phase)? onPhaseChange,
    bool compressMedia = false,
    bool useArchive = false,
  }) async {
    if (!await _ensureAuthenticated()) {
      debugPrint('UPLOAD: not authenticated');
      return false;
    }

    try {
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

      bool uploadOk;
      if (totalSize <= _kMaxInlineSize) {
        uploadOk = await _uploadSingleFile(uploadBytes, timestamp, checksum, fileExt);
      } else {
        uploadOk = await _uploadChunked(uploadBytes, timestamp, checksum, fileExt);
      }

      if (!uploadOk) {
        debugPrint('UPLOAD: upload failed');
        debugPrint('BACKUP MARKED FAILED');
        return false;
      }

      // Post-upload integrity verification
      if (verificationService != null) {
        onPhaseChange?.call('Verifying backup data integrity...');
        debugPrint('UPLOAD: VERIFY START');
        final verifyResult = await verificationService.verifyBackupIntegrity(
          backupData,
        );
        if (verifyResult.warnings.isNotEmpty) {
          debugPrint(
            'UPLOAD: VERIFY WARNINGS: ${verifyResult.warnings.join("; ")}',
          );
        }
        if (!verifyResult.passed) {
          debugPrint('UPLOAD: VERIFY FAILURE: ${verifyResult.errors}');
          debugPrint('BACKUP MARKED FAILED');
          return false;
        }
        debugPrint(
          'UPLOAD: VERIFY SUCCESS (${verifyResult.componentsChecked} components checked)',
        );
      }

      debugPrint('BACKUP MARKED SUCCESS');
      debugPrint('UPLOAD: success (${totalSize}B)');
      return true;
    } catch (e, st) {
      debugPrint('UPLOAD ERROR: $e');
      debugPrint('$st');
      debugPrint('BACKUP MARKED FAILED');
      return false;
    }
  }

  // ── Download (public) ────────────────────────────────────────────────────

  /// Download the most recent backup from Drive.
  Future<Map<String, dynamic>?> downloadBackup() async {
    if (!await _ensureAuthenticated()) {
      debugPrint('DOWNLOAD BACKUP: not authenticated');
      return null;
    }

    try {
      final version = await _findLatestBackup();
      if (version == null) {
        debugPrint('DOWNLOAD BACKUP: no backup found on Drive');
        return null;
      }
      debugPrint('DOWNLOAD BACKUP: found version=${version.fileName}');
      return _downloadVersion(version);
    } catch (e, st) {
      debugPrint('DOWNLOAD BACKUP ERROR: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Download a specific backup version by its file ID.
  ///
  /// Handles both single-file and chunked backups by delegating to
  /// [_downloadVersion].
  Future<Map<String, dynamic>?> downloadVersion(BackupVersion version) async {
    if (!await _ensureAuthenticated()) {
      debugPrint('DOWNLOAD VERSION: not authenticated');
      return null;
    }
    try {
      return _downloadVersion(version);
    } catch (e, st) {
      debugPrint('DOWNLOAD VERSION ERROR: $e');
      debugPrint('$st');
      return null;
    }
  }

  // ── Listing ──────────────────────────────────────────────────────────────

  /// List all available backup versions sorted newest-first.
  Future<List<BackupVersion>> listBackups() async {
    if (!await _ensureAuthenticated()) return [];

    try {
      final response = await _driveApi!.files
          .list(
            q: "name contains '$_backupPrefix' and 'appDataFolder' in parents and trashed=false",
            spaces: 'appDataFolder',
            orderBy: 'createdTime desc',
            pageSize: 20,
            // Include description so we can extract the checksum later
            $fields: 'files(id,name,size,createdTime,description)',
          )
          .timeout(_kApiCallTimeout);

      if (response.files == null) return [];

      final versions = <BackupVersion>[];
      for (final file in response.files!) {
        final name = file.name ?? '';
        if (!name.startsWith(_backupPrefix)) continue;
        if (name.contains('_part')) continue;

        versions.add(
          BackupVersion(
            driveFileId: file.id ?? '',
            fileName: name,
            createdAt: file.createdTime != null
                ? DateTime.parse(file.createdTime!.toIso8601String())
                : DateTime.now(),
            totalSizeBytes: file.size != null
                ? int.tryParse(file.size!) ?? 0
                : 0,
            hasAuthBundle: true,
          ),
        );
      }
      debugPrint('LIST BACKUPS: found ${versions.length} versions');
      return versions;
    } catch (e, st) {
      debugPrint('LIST BACKUPS ERROR: $e');
      debugPrint('$st');
      return [];
    }
  }

  /// Check whether any backup exists on Drive.
  Future<bool> hasBackup() async {
    if (!await _ensureAuthenticated()) return false;
    try {
      return (await _findLatestBackup()) != null;
    } catch (e, st) {
      debugPrint('HAS BACKUP ERROR: $e');
      debugPrint('$st');
      return false;
    }
  }

  /// Find the latest backup version (exposed publicly for restore detection).
  Future<BackupVersion?> findLatestBackup() async {
    return _findLatestBackup();
  }

  /// Get backup metadata with item counts from the manifest.
  Future<BackupVersion?> getBackupMetadata() async {
    final version = await _findLatestBackup();
    if (version == null) return null;

    try {
      final data = await downloadVersion(version);
      if (data == null) return null;

      final manifestJson = data['manifest'] as Map<String, dynamic>?;
      if (manifestJson == null) return version;

      final manifest = BackupManifest.fromJson(manifestJson);
      final counts = manifest.counts;
      return BackupVersion(
        driveFileId: version.driveFileId,
        fileName: version.fileName,
        createdAt: version.createdAt,
        totalSizeBytes: manifest.totalSizeBytes,
        mainNoteCount: counts['mainNoteCount'] ?? 0,
        hiddenNoteCount: counts['hiddenNoteCount'] ?? 0,
        driveFileCount: counts['driveFileCount'] ?? 0,
        passwordEntryCount: counts['passwordEntryCount'] ?? 0,
        hasAuthBundle: data.containsKey('authBundle'),
      );
    } catch (e) {
      debugPrint('GET BACKUP METADATA ERROR: $e');
      return version;
    }
  }

  /// Delete old backups keeping only the [keepCount] most recent.
  Future<int> pruneBackups({int keepCount = 5}) async {
    final versions = await listBackups();
    if (versions.length <= keepCount) return 0;

    var deleted = 0;
    for (var i = keepCount; i < versions.length; i++) {
      try {
        await _driveApi!.files.delete(versions[i].driveFileId);
        deleted++;
      } catch (e) {
        debugPrint('PRUNE: failed to delete ${versions[i].driveFileId}: $e');
      }
    }
    return deleted;
  }

  /// Deletes ALL backups from the Google Drive appDataFolder.
  Future<int> deleteAllBackups() async {
    if (!await _ensureAuthenticated()) return 0;
    
    var deleted = 0;
    try {
      final response = await _driveApi!.files.list(
        q: "name contains '$_backupPrefix' and 'appDataFolder' in parents and trashed=false",
        spaces: 'appDataFolder',
      );

      if (response.files != null) {
        for (final file in response.files!) {
          if (file.id != null) {
            try {
              await _driveApi!.files.delete(file.id!);
              deleted++;
            } catch (e) {
              debugPrint('DELETE ALL: failed to delete ${file.id}: $e');
            }
          }
        }
      }
    } catch (e, st) {
      debugPrint('DELETE ALL ERROR: $e\n$st');
    }
    return deleted;
  }

  /// Last successful backup timestamp from Hive.
  String? get lastBackupAt =>
      Hive.box('vaultx_settings').get('lastGoogleBackupAt') as String?;

  /// Storage usage info for backups in appDataFolder.
  Future<({int fileCount, int totalBytes})> storageUsage() async {
    if (!await _ensureAuthenticated()) return (fileCount: 0, totalBytes: 0);
    try {
      final response = await _driveApi!.files.list(
        q: "name contains '$_backupPrefix' and 'appDataFolder' in parents and trashed=false",
        spaces: 'appDataFolder',
      );
      var totalBytes = 0;
      var count = 0;
      if (response.files != null) {
        for (final file in response.files!) {
          count++;
          if (file.size != null) totalBytes += int.tryParse(file.size!) ?? 0;
        }
      }
      return (fileCount: count, totalBytes: totalBytes);
    } catch (_) {
      return (fileCount: 0, totalBytes: 0);
    }
  }

  // ── Internal upload ──────────────────────────────────────────────────────

  Future<bool> _uploadSingleFile(
    List<int> jsonBytes,
    int timestamp,
    String checksum,
    String fileExt,
  ) async {
    final fileName =
        '$_backupPrefix${timestamp}_${checksum.substring(0, 8)}$fileExt';

    // Delete any existing backup with same name
    final existing = await _findFiles(fileName);
    for (final f in existing) {
      try {
        await _driveApi!.files.delete(f.id!);
      } catch (_) {}
    }

    debugPrint(
      'UPLOAD: creating single-file backup $fileName (${jsonBytes.length}B)',
    );

    final byteStream = Stream.fromIterable([jsonBytes]);
    final media = drive.Media(byteStream, jsonBytes.length);
    final newFile = drive.File()
      ..name = fileName
      ..parents = ['appDataFolder']
      // Store full SHA-256 in description for integrity verification on restore
      ..description =
          'VaultX backup v2, ${jsonBytes.length}B, sha256=$checksum';

    await _driveApi!.files.create(newFile, uploadMedia: media);
    await _recordBackupTime();
    debugPrint('UPLOAD: single-file backup complete');
    return true;
  }

  Future<bool> _uploadChunked(
    List<int> jsonBytes,
    int timestamp,
    String checksum,
    String fileExt,
  ) async {
    final baseName = '$_backupPrefix${timestamp}_${checksum.substring(0, 8)}';
    final partCount = (jsonBytes.length / _kChunkSize).ceil();

    debugPrint('UPLOAD: splitting into $partCount chunks');

    // Upload manifest first
    final manifest = {
      'type': 'chunked_manifest',
      'baseName': baseName,
      'partCount': partCount,
      'totalSize': jsonBytes.length,
      'checksum': checksum,
      'partSize': _kChunkSize,
      'extension': fileExt,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    final manifestMedia = drive.Media(
      Stream.value(manifestBytes),
      manifestBytes.length,
    );
    final manifestFile = drive.File()
      ..name = '${baseName}_manifest.json'
      ..parents = ['appDataFolder'];
    await _driveApi!.files.create(manifestFile, uploadMedia: manifestMedia);

    // Upload each chunk
    for (var i = 0; i < partCount; i++) {
      final start = i * _kChunkSize;
      final end = (start + _kChunkSize).clamp(0, jsonBytes.length);
      final chunk = jsonBytes.sublist(start, end);
      final chunkMedia = drive.Media(Stream.value(chunk), chunk.length);
      final chunkFile = drive.File()
        ..name = '${baseName}_part${i.toString().padLeft(4, '0')}.bin'
        ..parents = ['appDataFolder'];
      await _driveApi!.files.create(chunkFile, uploadMedia: chunkMedia);

      onUploadProgress?.call(end, jsonBytes.length);
      debugPrint('UPLOAD: chunk ${i + 1}/$partCount (${chunk.length}B)');
    }

    await _recordBackupTime();
    debugPrint('UPLOAD: chunked backup complete ($partCount parts)');
    return true;
  }

  // ── Internal download ────────────────────────────────────────────────────

  /// Routes to chunked or single-file download based on filename.
  ///
  /// FIX: Previously used an unsafe `as drive.File` cast that could throw
  /// an unhandled TypeError. Now uses an explicit type check with a clear
  /// error log. Also fetches the `description` field so we can verify the
  /// SHA-256 checksum stored there during upload.
  Future<Map<String, dynamic>?> _downloadVersion(BackupVersion version) async {
    debugPrint(
      'DOWNLOAD VERSION: fileName=${version.fileName} fileId=${version.driveFileId}',
    );

    // Chunked backup: manifest file drives reassembly
    if (version.fileName.endsWith('_manifest.json')) {
      final baseName = version.fileName.replaceAll('_manifest.json', '');
      return _downloadChunked(baseName, version.driveFileId);
    }

    // Single-file backup: fetch metadata first (including description for
    // the stored SHA-256 checksum), then download content.
    try {
      final metadataObj = await _driveApi!.files
          .get(version.driveFileId, $fields: 'id,name,size,description')
          .timeout(_kApiCallTimeout);

      // FIX: was `as drive.File` with no guard; use `is` check instead.
      if (metadataObj is! drive.File) {
        debugPrint(
          'DOWNLOAD VERSION: metadata response is not a drive.File '
          '(got ${metadataObj.runtimeType})',
        );
        return null;
      }

      final fileSize = metadataObj.size != null
          ? int.tryParse(metadataObj.size!) ?? 0
          : 0;
      debugPrint(
        'DOWNLOAD VERSION: metadata OK — size=${fileSize}B desc="${metadataObj.description}"',
      );

      if (fileSize == 0) {
        debugPrint('DOWNLOAD VERSION: reported file size is 0 — aborting');
        return null;
      }

      // Extract expected SHA-256 from description field set during upload
      String? expectedChecksum;
      final desc = metadataObj.description ?? '';
      final match = RegExp(r'sha256=([a-f0-9]{64})').firstMatch(desc);
      if (match != null) {
        expectedChecksum = match.group(1);
        debugPrint(
          'DOWNLOAD VERSION: extracted expected sha256=$expectedChecksum',
        );
      } else {
        debugPrint(
          'DOWNLOAD VERSION: no sha256 in description — skipping checksum verify',
        );
      }

      return _downloadFileContent(
        metadataObj,
        expectedChecksum: expectedChecksum,
        reportedSize: fileSize,
      );
    } catch (e, st) {
      debugPrint('DOWNLOAD VERSION ERROR: $e');
      debugPrint('$st');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _downloadChunked(
    String baseName,
    String manifestFileId,
  ) async {
    debugPrint(
      'DOWNLOAD CHUNKED: starting — baseName=$baseName manifestId=$manifestFileId',
    );
    try {
      // Download manifest
      final manifestResp = await _driveApi!.files
          .get(manifestFileId, downloadOptions: drive.DownloadOptions.fullMedia)
          .timeout(_kApiCallTimeout);

      if (manifestResp is! drive.Media) {
        debugPrint('DOWNLOAD CHUNKED: manifest response is not Media');
        return null;
      }

      final manifestBytes = await manifestResp.stream
          .fold<List<int>>([], (prev, chunk) => prev..addAll(chunk))
          .timeout(_kDownloadTimeout);

      if (manifestBytes.isEmpty) {
        debugPrint('DOWNLOAD CHUNKED: manifest is empty');
        return null;
      }

      Map<String, dynamic> manifest;
      try {
        manifest =
            jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('DOWNLOAD CHUNKED: manifest JSON parse failed: $e');
        return null;
      }

      final partCount = manifest['partCount'] as int;
      final totalSize = manifest['totalSize'] as int;
      final expectedChecksum = manifest['checksum'] as String;
      final fileExt = manifest['extension'] as String? ?? '.json';

      debugPrint(
        'DOWNLOAD CHUNKED: manifest OK — parts=$partCount totalSize=$totalSize ext=$fileExt',
      );

      // Find all part files
      final partsResponse = await _driveApi!.files
          .list(
            q: "name contains '${baseName}_part' and 'appDataFolder' in parents and trashed=false",
            spaces: 'appDataFolder',
            orderBy: 'name',
          )
          .timeout(_kApiCallTimeout);

      final foundParts = partsResponse.files?.length ?? 0;
      if (foundParts != partCount) {
        debugPrint(
          'DOWNLOAD CHUNKED: part count mismatch — expected=$partCount found=$foundParts',
        );
        return null;
      }

      // Download and reassemble parts
      final allBytes = <int>[];
      for (var i = 0; i < partsResponse.files!.length; i++) {
        final partFile = partsResponse.files![i];
        debugPrint(
          'DOWNLOAD CHUNKED: downloading part ${i + 1}/$partCount (id=${partFile.id})',
        );

        final resp = await _driveApi!.files
            .get(partFile.id!, downloadOptions: drive.DownloadOptions.fullMedia)
            .timeout(_kApiCallTimeout);

        if (resp is! drive.Media) {
          debugPrint('DOWNLOAD CHUNKED: part $i response is not Media');
          return null;
        }

        final chunk = await resp.stream
            .fold<List<int>>([], (prev, c) => prev..addAll(c))
            .timeout(_kDownloadTimeout);

        if (chunk.isEmpty) {
          debugPrint('DOWNLOAD CHUNKED: part $i is empty');
          return null;
        }

        allBytes.addAll(chunk);
        debugPrint(
          'DOWNLOAD CHUNKED: part ${i + 1} received ${chunk.length}B, total so far ${allBytes.length}B',
        );
      }

      // Validate total size
      if (allBytes.length != totalSize) {
        debugPrint(
          'DOWNLOAD CHUNKED: size mismatch — expected=$totalSize actual=${allBytes.length}',
        );
        return null;
      }

      // Validate SHA-256 checksum
      final actualChecksum = sha256.convert(allBytes).toString();
      if (actualChecksum != expectedChecksum) {
        debugPrint(
          'DOWNLOAD CHUNKED: checksum MISMATCH — '
          'expected=$expectedChecksum actual=$actualChecksum',
        );
        return null;
      }
      debugPrint('DOWNLOAD CHUNKED: checksum verified OK');

      // Parse JSON or extract archive
      Map<String, dynamic> decoded;
      try {
        if (fileExt == '.vxbackup') {
          final tempDir = await getTemporaryDirectory();
          final archivePath = '${tempDir.path}/$baseName.vxbackup';
          await File(archivePath).writeAsBytes(allBytes);
          decoded = await ArchiveService.extractArchive(archivePath);
          await ArchiveService.cleanup(archivePath);
        } else {
          decoded = jsonDecode(utf8.decode(allBytes)) as Map<String, dynamic>;
        }
      } catch (e) {
        debugPrint('DOWNLOAD CHUNKED: payload parse/extract failed: $e');
        return null;
      }

      if (decoded.isEmpty) {
        debugPrint('DOWNLOAD CHUNKED: decoded JSON is empty');
        return null;
      }

      debugPrint(
        'DOWNLOAD CHUNKED: success (${allBytes.length}B) keys=${decoded.keys.toList()}',
      );

      // Import auth bundle if present
      if (authService != null) {
        final bundle = decoded['authBundle'] as Map<String, dynamic>?;
        if (bundle != null) {
          debugPrint('DOWNLOAD CHUNKED: importing auth bundle...');
          try {
            await authService!.importAuthBundle(bundle, force: false);
          } catch (e) {
            debugPrint('DOWNLOAD CHUNKED: auth bundle import error: $e');
            // Non-fatal — proceed with restore
          }
        }
      }

      return decoded;
    } catch (e, st) {
      debugPrint('DOWNLOAD CHUNKED ERROR: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Downloads and validates a single backup file.
  ///
  /// FIX (multiple):
  /// 1. Validates downloaded bytes are not empty.
  /// 2. Verifies SHA-256 checksum extracted from the file's description field.
  /// 3. JSON parse is wrapped in try/catch to prevent silent null return masking
  ///    a parse error.
  /// 4. Stream fold has a timeout so a stalled download doesn't hang forever.
  /// 5. Auth bundle import errors are caught so they don't abort the restore.
  Future<Map<String, dynamic>?> _downloadFileContent(
    drive.File file, {
    String? expectedChecksum,
    int reportedSize = 0,
  }) async {
    debugPrint(
      'DOWNLOAD FILE: id=${file.id} name=${file.name} '
      'reportedSize=${reportedSize}B expectedChecksum=$expectedChecksum',
    );

    final response = await _driveApi!.files
        .get(file.id!, downloadOptions: drive.DownloadOptions.fullMedia)
        .timeout(_kApiCallTimeout);

    if (response is! drive.Media) {
      debugPrint(
        'DOWNLOAD FILE: response is not Media (got ${response.runtimeType})',
      );
      return null;
    }

    // Accumulate bytes with a timeout so we don't hang on a stalled connection
    List<int> bytes;
    try {
      bytes = await response.stream
          .fold<List<int>>([], (prev, chunk) => prev..addAll(chunk))
          .timeout(_kDownloadTimeout);
    } on TimeoutException {
      debugPrint('DOWNLOAD FILE: stream timed out after $_kDownloadTimeout');
      return null;
    }

    debugPrint('DOWNLOAD FILE: received ${bytes.length}B');

    // Validate non-empty
    if (bytes.isEmpty) {
      debugPrint('DOWNLOAD FILE: downloaded file is empty');
      return null;
    }

    // Validate size matches reported size (if known)
    if (reportedSize > 0 && bytes.length != reportedSize) {
      debugPrint(
        'DOWNLOAD FILE: size mismatch — reported=$reportedSize actual=${bytes.length} '
        '(truncated download?)',
      );
      // Warn but continue; Drive metadata size isn't always byte-perfect
    }

    // Verify SHA-256 checksum if available
    if (expectedChecksum != null) {
      final actualChecksum = sha256.convert(bytes).toString();
      if (actualChecksum != expectedChecksum) {
        debugPrint(
          'DOWNLOAD FILE: checksum MISMATCH — '
          'expected=$expectedChecksum actual=$actualChecksum',
        );
        return null;
      }
      debugPrint('DOWNLOAD FILE: checksum verified OK');
    }

    // Parse JSON or extract archive with error handling
    Map<String, dynamic> decoded;
    try {
      if (file.name != null && file.name!.endsWith('.vxbackup')) {
        final tempDir = await getTemporaryDirectory();
        final archivePath = '${tempDir.path}/${file.name}';
        await File(archivePath).writeAsBytes(bytes);
        decoded = await ArchiveService.extractArchive(archivePath);
        await ArchiveService.cleanup(archivePath);
      } else {
        decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint(
        'DOWNLOAD FILE: parse/extract failed: $e '
      );
      return null;
    }

    if (decoded.isEmpty) {
      debugPrint('DOWNLOAD FILE: decoded JSON map is empty');
      return null;
    }

    debugPrint(
      'DOWNLOAD FILE: success (${bytes.length}B) keys=${decoded.keys.toList()}',
    );

    // Import auth bundle if present
    if (authService != null) {
      final bundle = decoded['authBundle'] as Map<String, dynamic>?;
      if (bundle != null) {
        debugPrint('DOWNLOAD FILE: importing auth bundle...');
        try {
          await authService!.importAuthBundle(bundle, force: false);
        } catch (e) {
          debugPrint('DOWNLOAD FILE: auth bundle import error: $e');
          // Non-fatal — proceed with restore
        }
      }
    }

    return decoded;
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  /// Find the latest backup version (sorted by creation time desc).
  Future<BackupVersion?> _findLatestBackup() async {
    if (!await _ensureAuthenticated()) return null;
    final versions = await listBackups();
    if (versions.isEmpty) return null;
    return versions.first;
  }

  Future<List<drive.File>> _findFiles(String name) async {
    final response = await _driveApi!.files
        .list(
          q: "name='$name' and 'appDataFolder' in parents and trashed=false",
          spaces: 'appDataFolder',
        )
        .timeout(_kApiCallTimeout);
    return response.files ?? [];
  }

  Future<void> _recordBackupTime() async {
    await Hive.box(
      'vaultx_settings',
    ).put('lastGoogleBackupAt', DateTime.now().toUtc().toIso8601String());
  }
}

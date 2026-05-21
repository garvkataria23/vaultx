import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../models/backup.dart';
import 'auth_service.dart';
import 'base_cloud_backup_provider.dart';

const _kDownloadTimeout = Duration(minutes: 10);
const _kApiCallTimeout = Duration(seconds: 30);

/// An HTTP client that automatically attaches Google Sign-In authentication headers.
/// This ensures tokens are refreshed by the google_sign_in plugin as needed.
class AuthenticatedGoogleClient extends http.BaseClient {
  final GoogleSignInAccount _account;
  final http.Client _inner = http.Client();

  AuthenticatedGoogleClient(this._account);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      debugPrint('GD_AUTH: Requesting authentication headers for ${request.url}');
      final headers = await _account.authentication;
      final accessToken = headers.accessToken;

      if (accessToken == null) {
        debugPrint('GD_AUTH_ERROR: Access token is null for ${_account.email}');
        throw Exception('GD_AUTH: Failed to obtain access token from Google Sign-In');
      }

      request.headers['Authorization'] = 'Bearer $accessToken';
      request.headers['X-Goog-AuthUser'] = '0'; // Standard header for Google APIs
      
      return _inner.send(request);
    } catch (e, st) {
      debugPrint('GD_AUTH_ERROR: Failed to attach auth headers: $e');
      debugPrint('$st');
      rethrow;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

class GoogleDriveBackupService extends BaseCloudBackupProvider {
  GoogleDriveBackupService({this.masterKey, this.authService});

  @override
  final Uint8List? masterKey;
  @override
  final VaultAuthService? authService;

  static const List<String> _scopes = [
    'email',
    drive.DriveApi.driveAppdataScope,
  ];
  static const String _keyTokenExpiry = 'gdriveTokenExpiry';
  static const String _keyEmail = 'gdriveEmail';

  GoogleSignIn? _googleSignIn;
  AuthenticatedGoogleClient? _authClient;
  drive.DriveApi? _driveApi;
  String? _cachedEmail;
  Future<bool>? _silentSignInFuture;
  Future<bool>? _interactiveSignInFuture;

  @override
  bool get isAuthenticated => _authClient != null && _driveApi != null;

  @override
  String? get signedInEmail {
    if (_cachedEmail != null) return _cachedEmail;
    
    final currentUserEmail = _googleSignIn?.currentUser?.email;
    if (currentUserEmail != null && currentUserEmail.isNotEmpty) {
      return currentUserEmail;
    }

    final storedEmail = Hive.box('vaultx_settings').get(_keyEmail) as String?;
    if (storedEmail != null && storedEmail.isNotEmpty) {
      return storedEmail;
    }

    return null;
  }

  @override
  String get providerName => 'Google Drive';

  @override
  CloudProvider get providerType => CloudProvider.googleDrive;

  @override
  String? get accountLabel => signedInEmail ?? 'Google Account';

  @override
  bool get hasValidSession {
    // If we have an active client, session is valid.
    if (isAuthenticated) return true;
    
    // Otherwise check stored email. If we have it, we can try silent sign-in.
    final email = Hive.box('vaultx_settings').get(_keyEmail) as String?;
    return email != null && email.isNotEmpty;
  }

  @override
  Future<String?> restoreSession() async {
    if (isAuthenticated) {
      debugPrint('RESTORE SESSION: already authenticated as $signedInEmail');
      return signedInEmail;
    }

    debugPrint('RESTORE SESSION: checking if email is stored...');
    final email = Hive.box('vaultx_settings').get(_keyEmail) as String?;
    if (email == null || email.isEmpty) {
      debugPrint('RESTORE SESSION: no stored email, skipping silent sign-in');
      return null;
    }

    debugPrint('RESTORE SESSION: attempting silent sign-in for $email...');
    try {
      final success = await signInSilently();
      if (success) {
        debugPrint('RESTORE SESSION: success, email=$signedInEmail');
        return signedInEmail;
      }
    } catch (e) {
      debugPrint('RESTORE SESSION: silent sign-in failed: $e');
    }

    debugPrint('RESTORE SESSION: silent sign-in failed');
    return null;
  }

  @override
  Future<bool> ensureAuthenticated() async {
    if (isAuthenticated) return true;
    debugPrint('ENSURE AUTH: not authenticated, trying silent sign-in...');
    try {
      final restored = await signInSilently();
      if (restored) {
        debugPrint('ENSURE AUTH: restored via silent sign-in');
        return true;
      }
    } catch (e) {
      debugPrint('ENSURE AUTH: silent sign-in exception: $e');
    }
    debugPrint('ENSURE AUTH: failed — user must sign in interactively');
    return false;
  }

  @override
  Future<bool> signInSilently() async {
    if (_silentSignInFuture != null) {
      debugPrint('GD_AUTH: silent sign-in already in progress, awaiting...');
      return _silentSignInFuture!;
    }
    _silentSignInFuture = _signInSilently();
    try {
      return await _silentSignInFuture!;
    } finally {
      _silentSignInFuture = null;
    }
  }

  Future<bool> _signInSilently() async {
    try {
      debugPrint('GD_AUTH: Starting silent sign-in attempt...');

      _googleSignIn ??= GoogleSignIn(
        scopes: _scopes,
      );

      GoogleSignInAccount? account = await _googleSignIn!.signInSilently();
      
      if (account == null) {
        debugPrint('GD_AUTH: signInSilently() returned null, checking currentUser...');
        account = _googleSignIn!.currentUser;
      }

      if (account == null) {
        debugPrint('GD_AUTH: No account available after silent attempt');
        return false;
      }

      final email = account.email;
      if (email.isEmpty) {
        debugPrint('GD_AUTH_ERROR: Account found but email is empty');
        return false;
      }

      debugPrint('GD_AUTH: Silent sign-in successful for $email');
      
      _cachedEmail = email;
      await Hive.box('vaultx_settings').put(_keyEmail, email);

      _authClient = AuthenticatedGoogleClient(account);
      _driveApi = drive.DriveApi(_authClient!);
      debugPrint('GD_AUTH: DriveApi initialized for $email');

      final expiry = DateTime.now().toUtc().add(const Duration(minutes: 55));
      await Hive.box(
        'vaultx_settings',
      ).put(_keyTokenExpiry, expiry.toIso8601String());

      return true;
    } catch (e, st) {
      debugPrint('GD_AUTH_ERROR: Silent sign-in failed with exception: $e');
      debugPrint('GD_AUTH_ERROR: Stack trace:\n$st');
      return false;
    }
  }

  @override
  Future<bool> signIn() async {
    if (_interactiveSignInFuture != null) {
      debugPrint('GD_AUTH: interactive sign-in already in progress, awaiting...');
      return _interactiveSignInFuture!;
    }
    _interactiveSignInFuture = _signIn();
    try {
      return await _interactiveSignInFuture!;
    } finally {
      _interactiveSignInFuture = null;
    }
  }

  Future<bool> _signIn() async {
    try {
      debugPrint('GD_AUTH: Starting interactive sign-in...');

      _googleSignIn ??= GoogleSignIn(
        scopes: _scopes,
      );

      // Disconnect first to clear stale state without full sign-out
      try {
        await _googleSignIn!.disconnect();
      } catch (_) {}

      final account = await _googleSignIn!.signIn();

      if (account == null) {
        debugPrint('GD_AUTH: Interactive sign-in returned null (cancelled)');
        return false;
      }

      final email = account.email;
      if (email.isEmpty) {
        throw Exception('Account found but email is empty. Check Google account settings.');
      }

      debugPrint('GD_AUTH: Interactive sign-in successful for $email');
      
      _cachedEmail = email;
      await Hive.box('vaultx_settings').put(_keyEmail, email);

      _authClient = AuthenticatedGoogleClient(account);
      _driveApi = drive.DriveApi(_authClient!);
      debugPrint('GD_AUTH: DriveApi initialized for $email');

      final expiry = DateTime.now().toUtc().add(const Duration(minutes: 55));
      await Hive.box(
        'vaultx_settings',
      ).put(_keyTokenExpiry, expiry.toIso8601String());

      return true;
    } catch (e, st) {
      debugPrint('GD_AUTH_ERROR: Interactive sign-in failed: $e');
      String userMessage = 'Google Sign-In failed.';
      
      if (e is PlatformException) {
        debugPrint('GD_AUTH_ERROR: PlatformException code=${e.code}, message=${e.message}');
        if (e.code == '10' || e.code == 'DEVELOPER_ERROR') {
          userMessage = 'Configuration error (Developer Error 10). Check SHA-1 fingerprint and google-services.json.';
        } else if (e.code == 'network_error') {
          userMessage = 'Network error during Google Sign-In. Check your internet and try again.';
        } else if (e.code == 'sign_in_cancelled') {
          return false;
        } else if (e.code == 'sign_in_failed') {
          userMessage = 'Sign-in failed. Ensure Google Play Services are up to date.';
        } else {
          userMessage = 'Google Sign-In error: ${e.message ?? e.code}';
        }
      } else {
        userMessage = 'Google Sign-In error: $e';
      }
      
      debugPrint('GD_AUTH_ERROR: Stack trace:\n$st');
      throw userMessage; // Throwing the message so the UI can catch it
    }
  }


  @override
  Future<void> signOut() async {
    debugPrint('GD_AUTH: Signing out from ${signedInEmail ?? "unknown account"}...');
    try {
      await _googleSignIn?.signOut();
      debugPrint('GD_AUTH: GoogleSignIn.signOut() completed');
    } catch (e) {
      debugPrint('GD_AUTH_ERROR: GoogleSignIn.signOut() failed: $e');
    }

    _authClient?.close();
    _authClient = null;
    _driveApi = null;
    _cachedEmail = null;

    final box = Hive.box('vaultx_settings');
    await box.delete(_keyTokenExpiry);
    await box.delete(_keyEmail);

    debugPrint('GD_AUTH: Local session cleared');
  }

  // ── BaseCloudBackupProvider Implementations ────────────────────────────

  @override
  Future<bool> uploadSingleFile(List<int> bytes, String fileName, String checksum) async {
    // We use the original fileName as part of the encrypted metadata
    // but the actual cloud filename will be obfuscated.
    final cloudName = generateObfuscatedName(fileName.endsWith('.vxbackup') ? '.vxbin' : '.dat');
    final metadata = {
      'originalName': fileName,
      'checksum': checksum,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      'type': 'single',
    };
    final encryptedDesc = encryptCloudMetadata(metadata);

    // Delete any existing backup with same name (legacy support)
    final existing = await _findFiles(fileName);
    for (final f in existing) {
      try {
        await _driveApi!.files.delete(f.id!);
      } catch (_) {}
    }

    final byteStream = Stream.fromIterable([bytes]);
    final media = drive.Media(byteStream, bytes.length);
    final newFile = drive.File()
      ..name = cloudName
      ..parents = ['appDataFolder']
      ..description = encryptedDesc ?? 'VaultX encrypted data';

    try {
      await _driveApi!.files.create(newFile, uploadMedia: media);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('storageQuotaExceeded') || msg.contains('quota') || msg.contains('storage')) {
        debugPrint('GD_UPLOAD_ERROR: Storage quota exceeded');
        throw Exception('Google Drive storage quota exceeded. Free up space or upgrade your storage plan.');
      }
      rethrow;
    }
    return true;
  }

  @override
  Future<bool> uploadChunked(List<int> bytes, String baseName, String checksum, String fileExt) async {
    final partCount = (bytes.length / BaseCloudBackupProvider.kChunkSize).ceil();
    final cloudBaseName = generateObfuscatedName('');

    final manifest = {
      'type': 'chunked_manifest',
      'baseName': baseName,
      'cloudBaseName': cloudBaseName, // MUST be included for cross-device restore
      'partCount': partCount,
      'totalSize': bytes.length,
      'checksum': checksum,
      'partSize': BaseCloudBackupProvider.kChunkSize,
      'extension': fileExt,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    final manifestMedia = drive.Media(Stream.value(manifestBytes), manifestBytes.length);
    
    final cloudManifestName = '${cloudBaseName}_m.dat';
    final metadata = {
      'originalName': '${baseName}_manifest.json',
      'checksum': checksum,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      'type': 'manifest',
      'cloudBaseName': cloudBaseName,
    };
    final encryptedDesc = encryptCloudMetadata(metadata);

    final manifestFile = drive.File()
      ..name = cloudManifestName
      ..parents = ['appDataFolder']
      ..description = encryptedDesc ?? 'VaultX index';
    await _driveApi!.files.create(manifestFile, uploadMedia: manifestMedia);

    for (var i = 0; i < partCount; i++) {
      final start = i * BaseCloudBackupProvider.kChunkSize;
      final end = (start + BaseCloudBackupProvider.kChunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(start, end);
      final chunkMedia = drive.Media(Stream.value(chunk), chunk.length);
      
      // Use 4-digit padding to ensure correct alphabetical sorting (p0000, p0001, etc.)
      final cloudPartName = '${cloudBaseName}_p${i.toString().padLeft(4, '0')}.bin';
      final partMetadata = {
        'type': 'part',
        'index': i,
        'cloudBaseName': cloudBaseName,
      };
      
      final chunkFile = drive.File()
        ..name = cloudPartName
        ..parents = ['appDataFolder']
        ..description = encryptCloudMetadata(partMetadata) ?? 'VaultX part';
      try {
        await _driveApi!.files.create(chunkFile, uploadMedia: chunkMedia);
      } catch (e) {
        final msg = e.toString();
        if (msg.contains('storageQuotaExceeded') || msg.contains('quota') || msg.contains('storage')) {
          throw Exception('Google Drive storage quota exceeded. Free up space or upgrade your storage plan.');
        }
        rethrow;
      }

      onUploadProgress?.call(end, bytes.length);
    }
    return true;
  }

  @override
  Future<List<int>?> downloadFileBytes(String fileId, {int? expectedSize, String? expectedChecksum}) async {
    try {
      debugPrint('GD_DRIVE: Downloading file $fileId...');
      final response = await _driveApi!.files
          .get(fileId, downloadOptions: drive.DownloadOptions.fullMedia)
          .timeout(_kApiCallTimeout);

      if (response is! drive.Media) {
        debugPrint('GD_DRIVE: Download failed - response is not Media');
        return null;
      }

      final builder = BytesBuilder(copy: false);

      await for (final chunk in response.stream.timeout(_kDownloadTimeout)) {
        builder.add(chunk);
        // Optionally update progress if we have a callback
        // onDownloadProgress?.call(builder.length, expectedSize ?? -1);
      }

      final result = builder.takeBytes();
      debugPrint('GD_DRIVE: Download complete - ${result.length} bytes');
      return result;
    } catch (e, st) {
      debugPrint('GD_DRIVE_ERROR: Download failed for $fileId: $e');
      debugPrint('GD_DRIVE_ERROR: Stack trace:\n$st');
      return null;
    }
  }

  @override
  Future<List<int>?> downloadChunked(String baseName, String manifestFileId) async {
    final manifestBytes = await downloadFileBytes(manifestFileId);
    if (manifestBytes == null || manifestBytes.isEmpty) return null;

    Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final partCount = manifest['partCount'] as int;
    final totalSize = manifest['totalSize'] as int;
    final expectedChecksum = manifest['checksum'] as String;

    // We need to find the cloudBaseName to download parts.
    // 1. Try manifest JSON (included in newer backups for cross-device support)
    // 2. Try manifest file description (requires masterKey)
    // 3. Fallback to original baseName (legacy)
    String? cloudBaseName = manifest['cloudBaseName'] as String?;
    
    if (cloudBaseName == null) {
      try {
        final manifestMeta = await _driveApi!.files.get(manifestFileId, $fields: 'name,description') as drive.File;
        final decrypted = decryptCloudMetadata(manifestMeta.description);
        if (decrypted != null && decrypted['cloudBaseName'] != null) {
          cloudBaseName = decrypted['cloudBaseName'] as String;
        }
      } catch (_) {}
    }

    final partPrefix = cloudBaseName != null ? '${cloudBaseName}_p' : '${baseName}_part';
    debugPrint('GD_RESTORE: Downloading chunked backup, partPrefix=$partPrefix, parts=$partCount');

    final allParts = <drive.File>[];
    String? nextPageToken;
    const int maxPartPages = 10;
    var partPages = 0;

    do {
      final partsResponse = await _driveApi!.files
          .list(
            q: "name contains '$partPrefix' and 'appDataFolder' in parents and trashed=false",
            spaces: 'appDataFolder',
            orderBy: 'name',
            pageToken: nextPageToken,
          )
          .timeout(_kApiCallTimeout);

      if (partsResponse.files == null) break;
      allParts.addAll(partsResponse.files!);
      nextPageToken = partsResponse.nextPageToken;
      partPages++;
    } while (nextPageToken != null && nextPageToken.isNotEmpty && partPages < maxPartPages);

    if (allParts.length < partCount) {
      debugPrint('GD_RESTORE: Found only ${allParts.length}/$partCount parts');
      return null;
    }

    // Filtering exactly by prefix just in case "contains" was too broad
    final filteredParts = allParts.where((f) => f.name != null && f.name!.startsWith(partPrefix)).toList();
    if (filteredParts.length < partCount) return null;

    final allBytes = <int>[];
    for (var i = 0; i < filteredParts.length; i++) {
      final partFile = filteredParts[i];
      debugPrint('GD_RESTORE: Downloading part ${i+1}/$partCount (${partFile.name})...');
      final chunk = await downloadFileBytes(partFile.id!);
      if (chunk == null || chunk.isEmpty) return null;
      allBytes.addAll(chunk);
    }

    if (allBytes.length != totalSize) return null;
    if (sha256.convert(allBytes).toString() != expectedChecksum) return null;

    return allBytes;
  }

  @override
  Future<void> recordBackupTime() async {
    await Hive.box('vaultx_settings').put(
      'lastGoogleBackupAt',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  // ── Listing ──────────────────────────────────────────────────────────────

  @override
  Future<List<BackupVersion>> listBackups() async {
    if (!await ensureAuthenticated()) return [];

    try {
      final versions = <BackupVersion>[];
      String? nextPageToken;
      const int maxPages = 10;
      var pages = 0;

      do {
        final response = await _driveApi!.files
            .list(
              spaces: 'appDataFolder',
              orderBy: 'createdTime desc',
              pageSize: 100,
              pageToken: nextPageToken,
              $fields: 'files(id,name,size,createdTime,description),nextPageToken',
            )
            .timeout(_kApiCallTimeout);

        if (response.files == null) break;

        for (final file in response.files!) {
        final name = file.name ?? '';
        final description = file.description;
        
        // 1. Try decrypting metadata (New Obfuscated Format)
        final isObfuscated = description?.startsWith(BaseCloudBackupProvider.kObfuscatedMagic) ?? false;
        
        if (isObfuscated) {
          final meta = decryptCloudMetadata(description);
          if (meta != null) {
            // Decryption succeeded - we have the original name
            final type = meta['type'] as String?;
            if (type == 'single' || type == 'manifest') {
              versions.add(
                BackupVersion(
                  driveFileId: file.id ?? '',
                  fileName: meta['originalName'] as String? ?? name,
                  createdAt: file.createdTime != null
                      ? DateTime.parse(file.createdTime!.toIso8601String())
                      : DateTime.now(),
                  totalSizeBytes: file.size != null ? int.tryParse(file.size!) ?? 0 : 0,
                  hasAuthBundle: true,
                ),
              );
            }
          } else {
            // Decryption failed (probably missing masterKey) but it IS a VaultX file
            // We add it to the list so detection succeeds.
            versions.add(
              BackupVersion(
                driveFileId: file.id ?? '',
                fileName: name, // Show obfuscated name or "Encrypted Backup"
                createdAt: file.createdTime != null
                    ? DateTime.parse(file.createdTime!.toIso8601String())
                    : DateTime.now(),
                totalSizeBytes: file.size != null ? int.tryParse(file.size!) ?? 0 : 0,
                hasAuthBundle: true,
              ),
            );
          }
          continue;
        }

        // 2. Legacy Support (Readable Format)
        if (name.startsWith(BaseCloudBackupProvider.kBackupPrefix)) {
          if (name.contains('_part')) continue;
          versions.add(
            BackupVersion(
              driveFileId: file.id ?? '',
              fileName: name,
              createdAt: file.createdTime != null
                  ? DateTime.parse(file.createdTime!.toIso8601String())
                  : DateTime.now(),
              totalSizeBytes: file.size != null ? int.tryParse(file.size!) ?? 0 : 0,
              hasAuthBundle: true,
            ),
          );
        }
      }
        nextPageToken = response.nextPageToken;
        pages++;
      } while (nextPageToken != null && nextPageToken.isNotEmpty && pages < maxPages);

      return versions;
    } catch (e, st) {
      debugPrint('LIST BACKUPS ERROR: $e\n$st');
      return [];
    }
  }

  @override
  Future<bool> hasBackup() async {
    if (!await ensureAuthenticated()) return false;
    return (await findLatestBackup()) != null;
  }

  @override
  Future<BackupVersion?> findLatestBackup() async {
    if (!await ensureAuthenticated()) return null;
    final versions = await listBackups();
    if (versions.isEmpty) return null;
    return versions.first;
  }

  @override
  Future<BackupVersion?> getBackupMetadata() async {
    final version = await findLatestBackup();
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
      return version;
    }
  }

  @override
  Future<int> pruneBackups({int keepCount = 3}) async {
    debugPrint('BACKUP CLEANUP START (GOOGLE DRIVE)');
    final versions = await listBackups();
    debugPrint('FOUND ${versions.length} BACKUPS');

    if (versions.length <= keepCount) {
      debugPrint('FINAL BACKUP COUNT: ${versions.length}');
      return 0;
    }

    var deleted = 0;
    for (var i = keepCount; i < versions.length; i++) {
      try {
        final version = versions[i];
        debugPrint('DELETE OLD BACKUP: ${version.fileName}');
        
        // Before deleting the manifest, we MUST check if it has obfuscated parts
        if (version.fileName.endsWith('_manifest.json') || version.fileName.endsWith('_m.dat')) {
           final baseName = version.fileName
               .replaceAll('_manifest.json', '')
               .replaceAll('_m.dat', '');
           await _deleteParts(baseName, version.driveFileId);
        }
        
        await _driveApi!.files.delete(version.driveFileId);
        debugPrint('DELETE SUCCESS: ${version.fileName}');
        deleted++;
      } catch (e) {
        debugPrint('PRUNE ERROR: failed to delete ${versions[i].driveFileId}: $e');
      }
    }

    final finalCount = versions.length - deleted;
    debugPrint('FINAL BACKUP COUNT: $finalCount');
    return deleted;
  }
  
  Future<void> _deleteParts(String baseName, String manifestFileId) async {
      String partPrefix;
      
      // Attempt to resolve cloud prefix from manifest metadata
      try {
        final manifestMeta = await _driveApi!.files.get(manifestFileId, $fields: 'description') as drive.File;
        final decrypted = decryptCloudMetadata(manifestMeta.description);
        if (decrypted != null && decrypted['cloudBaseName'] != null) {
          partPrefix = '${decrypted['cloudBaseName']}_p';
        } else {
          partPrefix = '${baseName}_part';
        }
      } catch (_) {
        partPrefix = '${baseName}_part';
      }

      final response = await _driveApi!.files.list(
        q: "name contains '$partPrefix' and 'appDataFolder' in parents and trashed=false",
        spaces: 'appDataFolder',
      );
      if (response.files != null) {
         for (final file in response.files!) {
            if (file.id != null && file.name != null && file.name!.startsWith(partPrefix)) {
               try {
                 await _driveApi!.files.delete(file.id!);
               } catch (_) {}
            }
         }
      }
  }

  @override
  Future<int> deleteAllBackups() async {
    if (!await ensureAuthenticated()) return 0;
    
    var deleted = 0;
    try {
      // List all files in AppData folder to catch obfuscated files too
      final response = await _driveApi!.files.list(
        spaces: 'appDataFolder',
        $fields: 'files(id,name)',
      );

      if (response.files != null) {
        for (final file in response.files!) {
          if (file.id != null) {
            try {
              await _driveApi!.files.delete(file.id!);
              deleted++;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return deleted;
  }

  @override
  String? get lastBackupAt =>
      Hive.box('vaultx_settings').get('lastGoogleBackupAt') as String?;

  @override
  Future<({int fileCount, int totalBytes})> storageUsage() async {
    if (!await ensureAuthenticated()) return (fileCount: 0, totalBytes: 0);
    try {
      // List all files in AppData since names are now obfuscated
      final response = await _driveApi!.files.list(
        spaces: 'appDataFolder',
        $fields: 'files(id,size)',
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

  @override
  Future<({int usedBytes, int totalBytes})> getAccountQuota() async {
    if (!await ensureAuthenticated()) return (usedBytes: 0, totalBytes: 0);
    try {
      final about = await _driveApi!.about
          .get($fields: 'storageQuota')
          .timeout(_kApiCallTimeout);
      final used = (about.storageQuota?.usage ?? 0) as int;
      final total = (about.storageQuota?.limit ?? 0) as int;
      return (usedBytes: used, totalBytes: total);
    } catch (_) {
      return (usedBytes: 0, totalBytes: 0);
    }
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
}

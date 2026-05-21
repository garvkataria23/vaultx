import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/backup.dart';
import 'auth_service.dart';
import 'base_cloud_backup_provider.dart';
import 'mega_sdk_service.dart';

class MEGABackupService extends BaseCloudBackupProvider {
  MEGABackupService({this.masterKey, this.authService});

  @override
  final Uint8List? masterKey;
  @override
  final VaultAuthService? authService;

  final MegaSdkService _sdk = MegaSdkService.instance;
  String? _cachedEmail;
  String? lastError;
  bool _isReconnecting = false;
  Timer? _healthCheckTimer;

  MegaConnectionState? megaConnectionState;

  /// Called when auth state changes outside the normal login flow
  /// (e.g., health checker restores a dropped connection).
  VoidCallback? onAuthStateChanged;

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _keySessionId = 'megaSdkSession';
  static const String _keyEmail = 'megaSdkEmail';

  @override
  bool get isAuthenticated => _cachedEmail != null;

  @override
  String? get signedInEmail => _cachedEmail;

  @override
  bool get hasValidSession => _cachedEmail != null;

  @override
  String get providerName => 'MEGA';

  @override
  CloudProvider get providerType => CloudProvider.mega;

  @override
  String? get accountLabel => signedInEmail;

  @override
  String? get lastBackupAt =>
      Hive.box('vaultx_settings').get('lastMegaBackupAt') as String?;

  // ── Initialization & Health Check ───────────────────────────────────────

  void startHealthChecker() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      final email = await _secureStorage.read(key: _keyEmail);
      if (email == null) {
        _healthCheckTimer?.cancel();
        return;
      }

      final loggedIn = await _sdk.isLoggedIn();
      final ready = await _sdk.isReady();
      
      if (!loggedIn || !ready) {
        debugPrint('MEGA HEALTH CHECK: Connection lost, attempting silent reconnect...');
        await ensureAuthenticated();
      } else {
        debugPrint('MEGA HEALTH CHECK: Connection healthy');
      }
    });
  }

  // ── Authentication ──────────────────────────────────────────────────────

  @override
  Future<String?> restoreSession() async {
    debugPrint('MEGA INIT START');
    if (_cachedEmail != null) {
      startHealthChecker();
      return _cachedEmail;
    }
    final success = await signInSilently();
    if (success) startHealthChecker();
    return success ? _cachedEmail : null;
  }

  @override
  Future<bool> ensureAuthenticated() async {
    if (_isReconnecting) {
       // Wait for in-progress reconnection if it's already active
       var timeout = 0;
       while (_isReconnecting && timeout < 30) {
         await Future.delayed(const Duration(seconds: 1));
         timeout++;
       }
       return _cachedEmail != null && await _sdk.isReady();
    }

    _isReconnecting = true;
    megaConnectionState = MegaConnectionState.connecting;
    try {
      // 1. Check if we already have an active and ready session
      if (_cachedEmail != null) {
        if (await _sdk.isReady()) {
          megaConnectionState = MegaConnectionState.ready;
          return true;
        }
        // Email cached but not fully ready — native side may be restoring;
        // try silent sign-in which will queue behind any in-progress restore.
        final ok = await signInSilently();
        if (ok) {
          startHealthChecker();
          return true;
        }
      }

      // 2. Try silent sign-in (restore session from native)
      // The Kotlin side handles fastLogin + fetchNodes + retries internally
      final success = await signInSilently();
      if (success) {
        startHealthChecker();
        return true;
      }
      
      megaConnectionState = MegaConnectionState.failed;
      return false;
    } finally {
      _isReconnecting = false;
      onAuthStateChanged?.call();
    }
  }

  @override
  Future<bool> signInSilently() async {
    final email = await _secureStorage.read(key: _keyEmail);
    if (email == null) return false;

    // Use a guard to prevent multiple concurrent restoration attempts
    if (megaConnectionState == MegaConnectionState.restoring) {
       var timeout = 0;
       while (megaConnectionState == MegaConnectionState.restoring && timeout < 60) {
          await Future.delayed(const Duration(seconds: 1));
          timeout++;
       }
       return _cachedEmail != null;
    }

    megaConnectionState = MegaConnectionState.restoring;
    debugPrint('SESSION RESTORE START for $email');

    try {
      // The Kotlin side handles fastLogin + fetchNodes + 3 retry attempts.
      // Timeout prevents hanging if native side encounters an unrecoverable error.
      final result = await _sdk.restoreSession().timeout(
        const Duration(seconds: 60),
        onTimeout: () => {'success': false, 'error': 'Restore timed out after 60s'},
      );

      if (result['success'] == true) {
        // Essential: double-check ready state before declaring success
        if (await _sdk.isReady()) {
          _cachedEmail = email;
          lastError = null;
          debugPrint('MEGA SESSION RESTORED AND READY');
          megaConnectionState = MegaConnectionState.ready;
          return true;
        } else {
          debugPrint('MEGA SESSION RESTORED BUT NOT READY');
          // Fall through to failure
        }
      }

      lastError = (result['error'] as String?)?.isNotEmpty == true
          ? result['error'] as String
          : 'RESTORE FAILED';
      debugPrint('MEGA SESSION RESTORE FAILED: $lastError');
      megaConnectionState = MegaConnectionState.failed;
      return false;
    } on TimeoutException {
      lastError = 'Restore timed out after 60s';
      debugPrint('MEGA SESSION RESTORE TIMED OUT');
      megaConnectionState = MegaConnectionState.failed;
      return false;
    } catch (e) {
      debugPrint('MEGA SESSION RESTORE EXCEPTION: $e');
      megaConnectionState = MegaConnectionState.failed;
      return false;
    }
  }


  @override
  Future<bool> signIn() async {
    throw UnsupportedError(
      'MEGA requires credentials. Use loginWithCredentials instead.',
    );
  }

  Future<bool> loginWithCredentials(String email, String password) async {
    lastError = null;
    megaConnectionState = MegaConnectionState.connecting;
    final result = await _sdk.login(email, password);
    debugPrint('MEGA SDK LOGIN: success=${result['success']}');
    if (result['success'] == true) {
      _cachedEmail = email;
      await _saveSession(null, email);
      debugPrint('MEGA SESSION SAVED for $email');
      
      // After login, we also need to fetch nodes
      megaConnectionState = MegaConnectionState.fetchingNodes;
      debugPrint('FETCH NODES START');
      await _sdk.fetchNodes();
      megaConnectionState = MegaConnectionState.ready;
      debugPrint('MEGA READY TRUE');
      
      startHealthChecker();
      return true;
    }
    megaConnectionState = MegaConnectionState.failed;
    lastError = (result['error'] as String?)?.isNotEmpty == true
        ? result['error'] as String
        : 'MEGA NOT READY';
    return false;
  }


  @override
  Future<void> signOut() async {
    _healthCheckTimer?.cancel();
    await _sdk.logout();
    _cachedEmail = null;
    megaConnectionState = null;
    await _clearSession();
    debugPrint('MEGA LOGOUT completed');
  }


  Future<void> _saveSession(String? session, String email) async {
    if (session != null && session.isNotEmpty) {
      await _secureStorage.write(key: _keySessionId, value: session);
    }
    await _secureStorage.write(key: _keyEmail, value: email);
  }

  Future<void> _clearSession() async {
    await _secureStorage.delete(key: _keySessionId);
    await _secureStorage.delete(key: _keyEmail);
  }

  // ── Folder management ───────────────────────────────────────────────────

  Future<bool> _ensureBackupFolderExists() async {
    final result = await _sdk.ensureBackupFolder();
    return result['success'] == true;
  }

  Future<List<Map<String, dynamic>>> _listBackupNodes() async {
    await _ensureBackupFolderExists();
    final result = await _sdk.listBackupFiles();
    if (result['success'] == true && result['files'] != null) {
      return List<Map<String, dynamic>>.from(result['files'] as List);
    }
    return [];
  }

  // ── Upload ──────────────────────────────────────────────────────────────

  @override
  Future<bool> uploadSingleFile(
    List<int> bytes,
    String fileName,
    String checksum,
  ) async {
    lastError = null;
    await _deleteExistingFiles(fileName);

    final uploadName = _cloudFileName(fileName);
    
    // Listen for progress updates for this specific file
    final subscription = _sdk.progressStream.listen((event) {
      if (event.fileName == uploadName) {
        onUploadProgress?.call(event.uploaded, event.total);
      }
    });

    try {
      final mapResult = await _sdk.uploadFile(bytes: bytes, fileName: uploadName);
      if (mapResult['success'] == true) return true;
      lastError = (mapResult['error'] as String?)?.isNotEmpty == true
          ? mapResult['error'] as String
          : 'UPLOAD FAILED';
      debugPrint('MEGA SDK UPLOAD ERROR: $lastError');
      return false;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<bool> uploadChunked(
    List<int> bytes,
    String baseName,
    String checksum,
    String fileExt,
  ) async {
    lastError = null;
    final cloudBaseName = generateObfuscatedName('');
    final partCount =
        (bytes.length / BaseCloudBackupProvider.kChunkSize).ceil();

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
    final cloudManifestName = '${cloudBaseName}_m.dat';
    
    final manifestUpload = await _sdk.uploadFile(
      bytes: manifestBytes,
      fileName: cloudManifestName,
    );
    
    if (manifestUpload['success'] != true) {
      lastError = (manifestUpload['error'] as String?)?.isNotEmpty == true
          ? manifestUpload['error'] as String
          : 'UPLOAD FAILED';
      debugPrint('MEGA SDK MANIFEST UPLOAD ERROR: $lastError');
      return false;
    }

    var totalUploaded = 0;

    for (var i = 0; i < partCount; i++) {
      final start = i * BaseCloudBackupProvider.kChunkSize;
      final end =
          (start + BaseCloudBackupProvider.kChunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(start, end);
      final cloudPartName =
          '${cloudBaseName}_p${i.toString().padLeft(4, '0')}.bin';

      // Local tracker for this chunk's progress
      var lastChunkUploaded = 0;
      final subscription = _sdk.progressStream.listen((event) {
        if (event.fileName == cloudPartName) {
          final delta = event.uploaded - lastChunkUploaded;
          if (delta > 0) {
            totalUploaded += delta;
            lastChunkUploaded = event.uploaded;
            onUploadProgress?.call(totalUploaded, bytes.length);
          }
        }
      });

      try {
        final partUpload = await _sdk.uploadFile(
          bytes: chunk,
          fileName: cloudPartName,
        );
        if (partUpload['success'] != true) {
          lastError = (partUpload['error'] as String?)?.isNotEmpty == true
              ? partUpload['error'] as String
              : 'UPLOAD FAILED';
          debugPrint('MEGA SDK PART UPLOAD ERROR: $lastError');
          return false;
        }
      } finally {
        await subscription.cancel();
      }
    }
    return true;
  }

  String _cloudFileName(String original) {
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final hash = sha256
        .convert(utf8.encode(original))
        .toString()
        .substring(0, 8);
    final ext = original.endsWith('.vxbackup') ? '.vxbin' : '.dat';
    return '${_namePrefix()}${timestamp}_$hash$ext';
  }

  String _namePrefix() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List.generate(8, (_) => random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _deleteExistingFiles(String fileName) async {
    final nodes = await _listBackupNodes();
    for (final node in nodes) {
      final name = node['name'] as String? ?? '';
      if (name == fileName) {
        await _sdk.deleteNode(node['handle'] as String);
      }
    }
  }

  // ── Download ────────────────────────────────────────────────────────────

  @override
  Future<List<int>?> downloadFileBytes(
    String fileId, {
    int? expectedSize,
    String? expectedChecksum,
  }) async {
    final result = await _sdk.downloadFile(fileId);
    if (result['success'] == true && result['bytes'] != null) {
      final bytes = result['bytes'] as List<int>;
      if (expectedSize != null && bytes.length != expectedSize) return null;
      if (expectedChecksum != null &&
          sha256.convert(bytes).toString() != expectedChecksum) {
        return null;
      }
      return bytes;
    }
    return null;
  }

  @override
  Future<List<int>?> downloadChunked(
    String baseName,
    String manifestFileId,
  ) async {
    final manifestResult = await _sdk.downloadFile(manifestFileId);
    if (manifestResult['success'] != true) {
      debugPrint('MEGA_RESTORE: Manifest download failed for $manifestFileId');
      return null;
    }

    final manifestBytes = manifestResult['bytes'] as List<int>;
    if (manifestBytes.isEmpty) return null;

    Map<String, dynamic> manifest;
    try {
      manifest =
          jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('MEGA_RESTORE: Manifest parse failed: $e');
      return null;
    }

    final partCount = manifest['partCount'] as int;
    final totalSize = manifest['totalSize'] as int;
    final expectedChecksum = manifest['checksum'] as String;
    
    // Cloud base name is essential for finding parts when names are obfuscated
    final cloudBaseName = manifest['cloudBaseName'] as String? ?? baseName;
    debugPrint('MEGA_RESTORE: Found manifest, baseName=$baseName, cloudBaseName=$cloudBaseName, parts=$partCount');

    final nodes = await _listBackupNodes();
    final partPrefix = '${cloudBaseName}_p';
    final parts = nodes
        .where((n) => (n['name'] as String).startsWith(partPrefix))
        .toList()
      ..sort((a, b) =>
          (a['name'] as String).compareTo(b['name'] as String));

    if (parts.length < partCount) {
       debugPrint('MEGA_RESTORE: Missing parts! Found ${parts.length} of $partCount');
       return null;
    }

    final allBytes = <int>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      debugPrint('MEGA_RESTORE: Downloading part ${i+1}/$partCount (${part['name']})...');
      final chunkResult = await _sdk.downloadFile(part['handle'] as String);
      if (chunkResult['success'] != true || chunkResult['bytes'] == null) {
        debugPrint('MEGA_RESTORE: Part download failed for ${part['name']}');
        return null;
      }
      allBytes.addAll(chunkResult['bytes'] as List<int>);
    }

    if (allBytes.length != totalSize) {
      debugPrint('MEGA_RESTORE: Size mismatch: expected $totalSize, got ${allBytes.length}');
      return null;
    }
    final actualChecksum = sha256.convert(allBytes).toString();
    if (actualChecksum != expectedChecksum) {
      debugPrint('MEGA_RESTORE: Checksum mismatch');
      return null;
    }

    debugPrint('MEGA_RESTORE: Chunked restore successful');
    return allBytes;
  }

  // ── Listing ─────────────────────────────────────────────────────────────

  @override
  Future<List<BackupVersion>> listBackups() async {
    if (!await ensureAuthenticated()) return [];

    try {
      final nodes = await _listBackupNodes();
      final versions = <BackupVersion>[];

      for (final node in nodes) {
        final name = node['name'] as String? ?? '';
        final handle = node['handle'] as String? ?? '';
        final size = node['size'] as int? ?? 0;
        final ts = node['modificationTime'] as int? ?? 0;

        final createdAt = ts > 0
            ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
            : DateTime.now();

        versions.add(BackupVersion(
          driveFileId: handle,
          fileName: name,
          createdAt: createdAt,
          totalSizeBytes: size,
          hasAuthBundle: true,
          provider: CloudProvider.mega,
        ));
      }

      versions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return versions;
    } catch (e, st) {
      debugPrint('MEGA SDK LIST: $e\n$st');
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
    return versions.isNotEmpty ? versions.first : null;
  }

  @override
  Future<BackupVersion?> getBackupMetadata() async {
    final version = await findLatestBackup();
    if (version == null) return null;

    try {
      final data = await downloadVersion(version);
      if (data == null) return version;

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
        provider: CloudProvider.mega,
      );
    } catch (e, st) {
      debugPrint('MEGA SDK METADATA: $e\n$st');
      return version;
    }
  }

  // ── Prune / Delete ──────────────────────────────────────────────────────

  @override
  Future<int> pruneBackups({int keepCount = 3}) async {
    final versions = await listBackups();
    if (versions.length <= keepCount) return 0;

    var deleted = 0;
    for (var i = keepCount; i < versions.length; i++) {
      try {
        await _sdk.deleteNode(versions[i].driveFileId);
        deleted++;
      } catch (e) {
        debugPrint('MEGA SDK PRUNE: ${versions[i].driveFileId}: $e');
      }
    }
    return deleted;
  }

  @override
  Future<int> deleteAllBackups() async {
    if (!await ensureAuthenticated()) return 0;

    var deleted = 0;
    try {
      final nodes = await _listBackupNodes();
      for (final node in nodes) {
        final handle = node['handle'] as String?;
        if (handle == null) continue;
        await _sdk.deleteNode(handle);
        deleted++;
      }
    } catch (e, st) {
      debugPrint('MEGA SDK DELETE ALL: $e\n$st');
    }
    return deleted;
  }

  // ── Storage / Quota ─────────────────────────────────────────────────────

  @override
  Future<({int fileCount, int totalBytes})> storageUsage() async {
    if (!await ensureAuthenticated()) return (fileCount: 0, totalBytes: 0);

    try {
      final nodes = await _listBackupNodes();
      var totalBytes = 0;
      for (final node in nodes) {
        totalBytes += node['size'] as int? ?? 0;
      }
      return (fileCount: nodes.length, totalBytes: totalBytes);
    } catch (e) {
      debugPrint('MEGA SDK STORAGE USAGE: $e');
      return (fileCount: 0, totalBytes: 0);
    }
  }

  @override
  Future<({int usedBytes, int totalBytes})> getAccountQuota() async {
    if (!await ensureAuthenticated()) return (usedBytes: 0, totalBytes: 0);

    try {
      final result = await _sdk.getAccountQuota();
      if (result['success'] == true) {
        return (
          usedBytes: result['usedBytes'] as int? ?? 0,
          totalBytes: result['totalBytes'] as int? ?? 0,
        );
      }
    } catch (e) {
      debugPrint('MEGA SDK QUOTA: $e');
    }
    return (usedBytes: 0, totalBytes: 0);
  }

  @override
  Future<void> recordBackupTime() async {
    await Hive.box('vaultx_settings').put(
      'lastMegaBackupAt',
      DateTime.now().toUtc().toIso8601String(),
    );
  }
}

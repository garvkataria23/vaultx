import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/auth.dart';
import '../models/drive_file.dart';
import 'backup_change_tracker.dart';
import 'compression_service.dart';
import 'crypto_service.dart';
import 'vault_repository.dart';

enum DriveImageCompression { original, high, medium, low }
enum DriveVideoCompression { original, p720, p480, reduceBitrate }
enum DriveFileCompression { original, zip }

class DriveCompressionOptions {
  const DriveCompressionOptions({
    this.image = DriveImageCompression.original,
    this.video = DriveVideoCompression.original,
    this.file = DriveFileCompression.original,
    this.preserveOriginalLocally = true,
  });

  final DriveImageCompression image;
  final DriveVideoCompression video;
  final DriveFileCompression file;
  final bool preserveOriginalLocally;
}

class DriveService {
  DriveService(Uint8List masterKey, this.kind)
    : masterKey = Uint8List.fromList(masterKey),
      _crypto = CryptoService(),
      _uuid = const Uuid();

  final Uint8List masterKey;
  final VaultKind kind;
  final CryptoService _crypto;
  final Uuid _uuid;

  Box get _box => Hive.box('vaultx_drive');
  String get _prefix => kind == VaultKind.hidden ? 'hidden' : 'main';

  List<SecureDriveFile> _cache = [];
  bool _loaded = false;

  String get _driveBlobDir =>
      _prefix == 'hidden' ? 'vaultx_drive_hidden' : 'vaultx_drive_main';

  Future<List<SecureDriveFile>> loadFiles() async {
    if (_loaded) return List<SecureDriveFile>.from(_cache);
    _cache = [];
    final keys = _box.keys.where((k) => k.toString().startsWith('$_prefix:'));
    for (final key in keys) {
      final raw = _box.get(key);
      if (raw is! Map) continue;
      try {
        final data = Map<String, dynamic>.from(raw);
        _cache.add(SecureDriveFile.fromJson(data));
      } catch (e) {
        debugPrint('DRIVE: skipping corrupted entry $key: $e');     
      }
    }
    _cache.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    _loaded = true;
    return List<SecureDriveFile>.from(_cache);
  }
  /// Loads metadata for logical folders in Secure Drive.
  Future<List<SecureDriveFolder>> loadFolderMetadata() async {
    final folders = <SecureDriveFolder>[];
    final prefix = '$_prefix:folder_metadata:';
    for (final k in _box.keys.where((k) => k.toString().startsWith(prefix))) {
      final raw = _box.get(k);
      if (raw is Map) {
        folders.add(SecureDriveFolder.fromJson(Map<String, dynamic>.from(raw)));
      }
    }
    return folders;
  }

  /// Saves metadata for a logical folder in Secure Drive.
  Future<void> saveFolderMetadata(SecureDriveFolder folder) async {
    final key = '$_prefix:folder_metadata:${folder.name}';
    await _box.put(key, folder.toJson());
  }

  Future<void> _persist(SecureDriveFile file) async {
    await _box.put('$_prefix:${file.id}', file.toJson());
  }

  Future<void> _remove(String id) async {
    await _box.delete('$_prefix:$id');
  }

  Future<SecureDriveFile?> replaceFileWithCompressed({
    required SecureDriveFile originalFile,
    required CompressionResult compression,
    String? kind,
    String? mimeType,
    void Function(double progress, String label)? onProgress,
  }) async {
    try {
      final file = File(compression.path);
      if (!await file.exists()) return null;

      onProgress?.call(0.2, 'Reading optimized file');
      final bytes = await file.readAsBytes();

      onProgress?.call(0.5, 'Encrypting new version');
      // We keep the same ID but derive a new record key with a new salt for security
      final salt = base64Encode(_crypto.randomBytes(16));
      final recordKey = _crypto.deriveRecordKey(masterKey, 'drive:${originalFile.id}', salt);

      final encrypted = bytes.length > 102400
          ? await _crypto.encryptBytesIsolate(bytes, recordKey)
          : _crypto.encryptBytes(bytes, recordKey);

      // Save to same path or new one? 
      // To be safe, we write to a new blob path first, then delete the old one.
      final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/$_driveBlobDir',
      );
      final newBlobPath = '${dir.path}/${originalFile.id}_${DateTime.now().millisecondsSinceEpoch}.vxblob';
      await File(newBlobPath).writeAsBytes(encrypted, flush: true);

      // Delete old blob
      try {
        final oldBlob = File(originalFile.encryptedPath);
        if (await oldBlob.exists()) await oldBlob.delete();
      } catch (e) {
        debugPrint('DRIVE: failed to delete old blob: $e');
      }

      onProgress?.call(0.9, 'Updating vault');

      final updatedFile = originalFile.copyWith(
        name: compression.newName ?? originalFile.name,
        kind: kind,
        mimeType: mimeType,
        size: bytes.length,
        originalSize: compression.originalSize,
        encryptedPath: newBlobPath,
        salt: salt,
        updatedAt: DateTime.now(),
      );

      await _persist(updatedFile);
      
      // Update cache
      final idx = _cache.indexWhere((f) => f.id == originalFile.id);
      if (idx >= 0) _cache[idx] = updatedFile;

      BackupChangeTracker.instance.notifyDriveChanged(
        estimatedBytes: bytes.length - originalFile.size,
      );

      // Cleanup temp compression file
      if (compression.path.contains('compressed_') || compression.path.contains('video_compress') || compression.path.contains('vaultx_temp')) {
        try { await File(compression.path).delete(); } catch(_) {}
      }

      onProgress?.call(1, 'Complete');
      return updatedFile;
    } catch (e, st) {
      debugPrint('DRIVE REPLACE ERROR: $e\n$st');
      return null;
    }
  }

  Future<SecureDriveFile?> importCompressedFile({
    required CompressionResult compression,
    required String originalName,
    String? folder,
    List<String> tags = const [],
    void Function(double progress, String label)? onProgress,
  }) async {
    try {
      final file = File(compression.path);
      if (!await file.exists()) return null;

      final mimeType = _detectMimeType(originalName);
      final kind = SecureDriveFile.detectKind(originalName, mimeType);

      onProgress?.call(0.1, 'Reading optimized file');
      final bytes = await file.readAsBytes();

      onProgress?.call(0.4, 'Encrypting for vault');
      final id = _uuid.v4();
      final salt = base64Encode(_crypto.randomBytes(16));
      final recordKey = _crypto.deriveRecordKey(masterKey, 'drive:$id', salt);

      final encrypted = bytes.length > 102400
          ? await _crypto.encryptBytesIsolate(bytes, recordKey)
          : _crypto.encryptBytes(bytes, recordKey);

      final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/$_driveBlobDir',
      );
      await dir.create(recursive: true);
      final blobPath = '${dir.path}/$id.vxblob';
      await File(blobPath).writeAsBytes(encrypted, flush: true);

      onProgress?.call(0.9, 'Finalizing');

      final box = Hive.box('vaultx_settings');
      final backupDefault =
          box.get('backupNewDriveFilesByDefault', defaultValue: true) as bool;

      final driveFile = SecureDriveFile(
        id: id,
        name: originalName,
        kind: kind,
        mimeType: mimeType,
        size: bytes.length,
        originalSize: compression.originalSize,
        encryptedPath: blobPath,
        salt: salt,
        folder: folder ?? SecureDriveFile.detectFolder(kind),
        tags: tags,
        backupExcluded: !backupDefault,
      );

      _cache.removeWhere((f) => f.id == id);
      _cache.insert(0, driveFile);
      await _persist(driveFile);

      BackupChangeTracker.instance.notifyDriveChanged(
        estimatedBytes: bytes.length,
      );

      // Cleanup temp compression file if it's not the original
      if (compression.path != originalName) {
         if (compression.path.contains('compressed_') || compression.path.contains('video_compress')) {
            try { await File(compression.path).delete(); } catch(_) {}
         }
      }

      onProgress?.call(1, 'Complete');
      return driveFile;
    } catch (e, st) {
      debugPrint('DRIVE IMPORT ERROR: $e\n$st');
      return null;
    }
  }

  Future<SecureDriveFile?> importFile({
    required String filePath,
    String? folder,
    List<String> tags = const [],
    DriveCompressionOptions compression = const DriveCompressionOptions(),
    void Function(double progress, String label)? onProgress,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final name = file.path.split(Platform.pathSeparator).last;
      final mimeType = _detectMimeType(name);
      final kind = SecureDriveFile.detectKind(name, mimeType);
      onProgress?.call(0.05, 'Reading file');
      List<int> bytes = await file.readAsBytes();
      final originalSize = bytes.length;
      onProgress?.call(0.25, 'Preparing upload');
      bytes = await _compressForDrive(
        bytes: bytes,
        name: name,
        kind: kind,
        mimeType: mimeType,
        options: compression,
      );
      debugPrint(
        'DRIVE COMPRESSION: $name original=$originalSize upload=${bytes.length} kind=$kind',
      );
      onProgress?.call(0.5, 'Encrypting');
      final id = _uuid.v4();
      final salt = base64Encode(_crypto.randomBytes(16));
      final recordKey = _crypto.deriveRecordKey(masterKey, 'drive:$id', salt);
      final encrypted = bytes.length > 102400
          ? await _crypto.encryptBytesIsolate(bytes, recordKey)
          : _crypto.encryptBytes(bytes, recordKey);

      final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/$_driveBlobDir',
      );
      await dir.create(recursive: true);
      final blobPath = '${dir.path}/$id.vxblob';
      await File(blobPath).writeAsBytes(encrypted, flush: true);
      onProgress?.call(0.85, 'Saving metadata');

      final box = Hive.box('vaultx_settings');
      final backupDefault =
          box.get('backupNewDriveFilesByDefault', defaultValue: true) as bool;

      final driveFile = SecureDriveFile(
        id: id,
        name: name,
        kind: kind,
        mimeType: mimeType,
        size: bytes.length,
        originalSize: originalSize,
        encryptedPath: blobPath,
        salt: salt,
        folder: folder ?? SecureDriveFile.detectFolder(kind),
        tags: tags,
        backupExcluded: !backupDefault,
      );
      _cache.removeWhere((f) => f.id == id);
      _cache.insert(0, driveFile);
      await _persist(driveFile);
      BackupChangeTracker.instance.notifyDriveChanged(
        estimatedBytes: bytes.length,
      );
      onProgress?.call(1, 'Complete');
      return driveFile;
    } catch (e, st) {
      debugPrint('DRIVE IMPORT ERROR: $e\n$st');
      return null;
    }
  }

  Future<int> estimateUploadSize(
    String filePath,
    DriveCompressionOptions options,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) return 0;
    final bytes = await file.readAsBytes();
    final name = file.path.split(Platform.pathSeparator).last;
    final mimeType = _detectMimeType(name);
    final kind = SecureDriveFile.detectKind(name, mimeType);
    final compressed = await _compressForDrive(
      bytes: bytes,
      name: name,
      kind: kind,
      mimeType: mimeType,
      options: options,
    );
    return compressed.length;
  }

  Future<List<int>> _compressForDrive({
    required List<int> bytes,
    required String name,
    required String kind,
    required String mimeType,
    required DriveCompressionOptions options,
  }) async {
    if (kind == 'image' && options.image != DriveImageCompression.original) {
      final quality = switch (options.image) {
        DriveImageCompression.high => 88,
        DriveImageCompression.medium => 72,
        DriveImageCompression.low => 52,
        DriveImageCompression.original => 100,
      };
      final maxEdge = switch (options.image) {
        DriveImageCompression.high => 2400,
        DriveImageCompression.medium => 1600,
        DriveImageCompression.low => 1024,
        DriveImageCompression.original => 0,
      };
      return compute(_compressImageBytes, {
        'bytes': Uint8List.fromList(bytes),
        'quality': quality,
        'maxEdge': maxEdge,
      });
    }

    if (kind == 'video' && options.video != DriveVideoCompression.original) {
      debugPrint(
        'DRIVE COMPRESSION: video transcoding requested for $name, keeping original bytes because no platform transcoder is configured',
      );
    }
    if (kind != 'image' &&
        kind != 'video' &&
        options.file == DriveFileCompression.zip) {
      debugPrint(
        'DRIVE COMPRESSION: ZIP requested for $name, keeping original bytes to preserve restore/open compatibility',
      );
    }
    return bytes;
  }

  Future<SecureDriveFile?> importFromPicker({
    String? folder,
    List<String> tags = const [],
  }) async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.first.path;
    if (path == null) return null;
    return importFile(filePath: path, folder: folder, tags: tags);
  }

  Future<String?> decryptToTemp(SecureDriveFile file) async {
    try {
      final encrypted = await File(file.encryptedPath).readAsBytes();
      final recordKey = _crypto.deriveRecordKey(
        masterKey,
        'drive:${file.id}',
        file.salt,
      );
      final clear = encrypted.length > 102400
          ? await _crypto.decryptBytesIsolate(encrypted, recordKey)
          : _crypto.decryptBytes(encrypted, recordKey);
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/vaultx_drive',
      );
      await dir.create(recursive: true);
      final safeName = file.name.replaceAll(RegExp(r'[\\/:*?"<>| ]'), '_');
      final out = File('${dir.path}/$safeName');
      await out.writeAsBytes(clear, flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> decryptToBytes(SecureDriveFile file) async {
    return decryptToTemp(file);
  }

  Future<bool> deleteFile(SecureDriveFile file) async {
    try {
      await EncryptedBlobService.secureDeletePath(file.encryptedPath);
      await _remove(file.id);
      _cache.removeWhere((f) => f.id == file.id);
      BackupChangeTracker.instance.notifyDriveChanged(
        estimatedBytes: file.size,
      );
      return true;
    } catch (_) {
      try {
        await _remove(file.id);
        _cache.removeWhere((f) => f.id == file.id);
      } catch (_) {}
      return false;
    }
  }

  Future<void> updateFile(SecureDriveFile file) async {
    file.updatedAt = DateTime.now();
    await _persist(file);
    final idx = _cache.indexWhere((f) => f.id == file.id);
    if (idx >= 0) _cache[idx] = file;
    BackupChangeTracker.instance.notifyDriveChanged();
  }

  Future<void> renameFile(String id, String newName) async {
    final file = _cache.where((f) => f.id == id).firstOrNull;
    if (file == null) return;
    file.name = newName;
    await updateFile(file);
  }

  Future<void> moveFile(String id, String newFolder) async {
    final file = _cache.where((f) => f.id == id).firstOrNull;
    if (file == null) return;
    file.folder = newFolder;
    await updateFile(file);
  }

  Future<void> toggleFavorite(String id) async {
    final file = _cache.where((f) => f.id == id).firstOrNull;
    if (file == null) return;
    file.favorite = !file.favorite;
    await updateFile(file);
  }

  List<String> getFolders() {
    final folders = _cache.map((f) => f.folder).toSet();
    final sorted = folders.where((f) => f.isNotEmpty).toList()..sort();
    return sorted;
  }

  List<SecureDriveFile> search(String query) {
    final q = query.toLowerCase();
    return _cache.where((f) {
      return f.name.toLowerCase().contains(q) ||
          f.folder.toLowerCase().contains(q) ||
          f.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  List<SecureDriveFile> filterByFolder(String folder) {
    return _cache.where((f) => f.folder == folder).toList();
  }

  List<SecureDriveFile> filterByKind(String kind) {
    return _cache.where((f) => f.kind == kind).toList();
  }

  int get fileCount => _cache.length;

  void invalidateCache() {
    _loaded = false;
    _cache = [];
  }

  static Future<void> cleanupTempExports() async {
    try {
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/vaultx_drive',
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  String _detectMimeType(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'ogg':
        return 'audio/ogg';
      case 'aac':
        return 'audio/aac';
      case 'wma':
        return 'audio/x-ms-wma';
      case 'm4a':
        return 'audio/mp4';
      case 'opus':
        return 'audio/opus';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'mkv':
        return 'video/x-matroska';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
      case 'docx':
        return 'application/msword';
      case 'xls':
      case 'xlsx':
        return 'application/vnd.ms-excel';
      case 'ppt':
      case 'pptx':
        return 'application/vnd.ms-powerpoint';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }
}

List<int> _compressImageBytes(Map<String, Object> args) {
  final bytes = args['bytes']! as Uint8List;
  final quality = args['quality']! as int;
  final maxEdge = args['maxEdge']! as int;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  var output = decoded;
  final edge = math.max(decoded.width, decoded.height);
  if (edge > maxEdge && maxEdge > 0) {
    output = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? maxEdge : null,
      height: decoded.height > decoded.width ? maxEdge : null,
      interpolation: img.Interpolation.average,
    );
  }
  return img.encodeJpg(output, quality: quality);
}

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class TempFileManager {
  static final TempFileManager instance = TempFileManager._();
  TempFileManager._();

  static const String _tempDirName = 'vaultx_temp';
  final _uuid = const Uuid();

  Future<Directory> get _tempDir async {
    final baseDir = await getTemporaryDirectory();
    final dir = Directory(p.join(baseDir.path, _tempDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Creates a safe path for a temporary file with the given extension.
  Future<String> createTempPath(String originalPath) async {
    final dir = await _tempDir;
    final ext = p.extension(originalPath);
    final fileName = 'temp_${_uuid.v4()}$ext';
    return p.join(dir.path, fileName);
  }

  /// Creates a safe path for a compressed file.
  Future<String> createCompressedPath(String originalPath) async {
    final dir = await _tempDir;
    final ext = p.extension(originalPath);
    final fileName = 'compressed_${_uuid.v4()}$ext';
    return p.join(dir.path, fileName);
  }

  /// Creates a safe path for a compressed file with a specific extension.
  Future<String> createCompressedPathWithExt(String originalPath, String targetExt) async {
    final dir = await _tempDir;
    final fileName = 'compressed_${_uuid.v4()}$targetExt';
    return p.join(dir.path, fileName);
  }

  /// Cleans up a specific temporary file.
  Future<void> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }

  /// Cleans up all files in the temporary directory.
  Future<void> clearAll() async {
    try {
      final dir = await _tempDir;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }

  /// Validates that a file was successfully created and is not empty.
  Future<bool> validateFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final size = await file.length();
      return size > 0;
    } catch (_) {
      return false;
    }
  }
}

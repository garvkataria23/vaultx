import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ArchiveService {
  /// Compresses the backup data map into a .vxbackup archive.
  /// Returns the path to the temporary archive file.
  static Future<String> createArchive(Map<String, dynamic> backupData) async {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final archivePath = '${tempDir.path}/backup_$timestamp.vxbackup';

    final encoder = ZipFileEncoder();
    encoder.create(archivePath);

    // 1. Add manifest
    if (backupData.containsKey('manifest')) {
      final manifestBytes = utf8.encode(jsonEncode(backupData['manifest']));
      encoder.addArchiveFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    }

    // 2. Add data components
    for (final entry in backupData.entries) {
      if (entry.key == 'manifest') continue;
      
      final dataBytes = utf8.encode(jsonEncode(entry.value));
      encoder.addArchiveFile(ArchiveFile('data/${entry.key}.json', dataBytes.length, dataBytes));
    }

    encoder.close();
    return archivePath;
  }

  /// Extracts a .vxbackup archive into a backup data map.
  static Future<Map<String, dynamic>> extractArchive(String archivePath) async {
    final bytes = await File(archivePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final data = <String, dynamic>{};
    Map<String, dynamic>? manifestMap;

    for (final file in archive) {
      if (file.isFile) {
        final content = file.content as List<int>;
        final jsonStr = utf8.decode(content);
        final decoded = jsonDecode(jsonStr);

        if (file.name == 'manifest.json') {
          manifestMap = decoded;
          data['manifest'] = manifestMap;
        } else if (file.name.startsWith('data/') && file.name.endsWith('.json')) {
          final key = file.name.substring(5, file.name.length - 5);
          data[key] = decoded;
        }
      }
    }

    return data;
  }
  
  static Future<void> cleanup(String archivePath) async {
    try {
      final file = File(archivePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Archive cleanup failed: $e');
    }
  }
}

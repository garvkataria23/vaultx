import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/drive_file.dart';
import 'package:path/path.dart' as p;

class OptimizationSuggestion {
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onAction;
  final String actionLabel;
  final double potentialSavings; // 0.0 to 1.0

  OptimizationSuggestion({
    required this.title,
    required this.description,
    required this.icon,
    required this.onAction,
    this.actionLabel = 'Optimize',
    this.potentialSavings = 0.5,
  });
}

class DriveStorageStats {
  final int totalFiles;
  final int totalSize;
  final int totalOriginalSize;
  final Map<String, int> typeSizes;
  final List<SecureDriveFile> largeFiles;
  final List<SecureDriveFile> compressibleFiles;
  final List<SecureDriveFile> allFiles;
  final List<List<SecureDriveFile>> duplicates;

  DriveStorageStats({
    this.totalFiles = 0,
    this.totalSize = 0,
    this.totalOriginalSize = 0,
    this.typeSizes = const {},
    this.largeFiles = const [],
    this.compressibleFiles = const [],
    this.allFiles = const [],
    this.duplicates = const [],
  });

  double get savingsRatio {
    if (totalOriginalSize <= 0) return 0.0;
    final savings = totalOriginalSize - totalSize;
    if (savings <= 0) return 0.0;
    return savings / totalOriginalSize;
  }
}

class StorageInsightsService {
  static final StorageInsightsService instance = StorageInsightsService._();
  StorageInsightsService._();

  Future<DriveStorageStats> analyzeDrive({Set<String> unlockedFolders = const {}}) async {
    final box = Hive.box('vaultx_drive');
    int totalFiles = 0;
    int totalSize = 0;
    int totalOriginalSize = 0;
    final typeSizes = <String, int>{};
    final largeFiles = <SecureDriveFile>[];
    final compressibleFiles = <SecureDriveFile>[];
    final allFiles = <SecureDriveFile>[];
    
    final fileMap = <String, List<SecureDriveFile>>{}; // name_size -> list

    // First pass: find all locked folders
    final lockedFolders = <String>{};
    for (final key in box.keys) {
      final k = key.toString();
      if (k.contains(':folder_metadata:')) {
        final raw = box.get(key);
        if (raw is Map) {
          final folder = SecureDriveFolder.fromJson(Map<String, dynamic>.from(raw));
          // 'Passwords' is locked by default in the app logic, but let's strictly rely on isLocked flag.
          // Wait, 'Passwords' folder might not be in metadata if it was never modified!
          // Actually, let's also hardcode 'Passwords' as locked just like DriveScreen does.
          if (folder.isLocked) {
            lockedFolders.add(folder.name);
          }
        }
      }
    }
    lockedFolders.add('Passwords');

    for (final key in box.keys) {
      final k = key.toString();
      if (k.contains(':folder_metadata:')) continue;
      
      final raw = box.get(key);
      if (raw is Map) {
        final file = SecureDriveFile.fromJson(Map<String, dynamic>.from(raw));
        
        // Skip files in locked folders unless they are unlocked in the current session
        if (lockedFolders.contains(file.folder) && !unlockedFolders.contains(file.folder)) {
          continue;
        }

        allFiles.add(file);
        totalFiles++;
        totalSize += file.size;
        totalOriginalSize += (file.originalSize ?? 0) > 0 ? (file.originalSize ?? 0) : file.size;

        typeSizes[file.kind] = (typeSizes[file.kind] ?? 0) + file.size;

        if (file.size > 10 * 1024 * 1024) { // > 10MB
          largeFiles.add(file);
        }

        final ext = p.extension(file.name).toLowerCase();
        bool isCompressible = ['.mp4', '.mov', '.jpg', '.jpeg', '.png', '.webp', '.pdf'].contains(ext);
        if (isCompressible) {
          compressibleFiles.add(file);
        }

        // Duplicate heuristic: same name and size
        final dupKey = '${file.name}_${file.size}';
        fileMap.putIfAbsent(dupKey, () => []).add(file);
      }
    }

    final duplicates = fileMap.values.where((list) => list.length > 1).toList();
    largeFiles.sort((a, b) => b.size.compareTo(a.size));

    return DriveStorageStats(
      totalFiles: totalFiles,
      totalSize: totalSize,
      totalOriginalSize: totalOriginalSize,
      typeSizes: typeSizes,
      largeFiles: largeFiles,
      compressibleFiles: compressibleFiles,
      allFiles: allFiles,
      duplicates: duplicates,
    );
  }

  String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

import 'package:hive_flutter/hive_flutter.dart';
import '../models/backup.dart';
import 'backup_service.dart';

/// Insights about backup storage usage and potential optimizations.
class StorageInsights {
  final int totalLocalItems;
  final int totalExcludedItems;
  final int totalCloudItems;
  final int totalCloudSizeBytes;
  final int potentialSavingsBytes;
  final Map<String, int> categorySavings;
  final List<String> largeFilesSuggestions;

  StorageInsights({
    this.totalLocalItems = 0,
    this.totalExcludedItems = 0,
    this.totalCloudItems = 0,
    this.totalCloudSizeBytes = 0,
    this.potentialSavingsBytes = 0,
    this.categorySavings = const {},
    this.largeFilesSuggestions = const [],
  });

  double get optimizationRatio => totalCloudSizeBytes > 0 
      ? (potentialSavingsBytes / totalCloudSizeBytes) 
      : 0.0;
}

/// Service to analyze and optimize backup storage.
class BackupOptimizer {
  final BackupService backupService;

  BackupOptimizer(this.backupService);

  /// Calculates storage insights by analyzing local Hive boxes and current backup state.
  Future<StorageInsights> calculateInsights() async {
    final recordsBox = Hive.box('vaultx_records');
    final driveBox = Hive.box('vaultx_drive');
    final passwordsBox = Hive.box('vaultx_passwords');
    final backupState = BackupState.load();

    int totalLocal = 0;
    int totalExcluded = 0;
    int potentialSavings = 0;
    final categorySavings = <String, int>{'notes': 0, 'files': 0, 'passwords': 0};
    final largeFiles = <String>[];

    final excludedNoteFolders = {
      ..._getExcludedFolders('main', 'vaultx_records'),
      ..._getExcludedFolders('hidden', 'vaultx_records'),
    };
    final excludedDriveFolders = {
      ..._getExcludedFolders('main', 'vaultx_drive'),
      ..._getExcludedFolders('hidden', 'vaultx_drive'),
    };

    // 1. Analyze Notes
    for (final key in recordsBox.keys) {
      final k = key.toString();
      if (k.startsWith('main:') || k.startsWith('hidden:')) {
        if (k.contains(':folder_metadata:')) continue;
        totalLocal++;
        final raw = recordsBox.get(key);
        if (raw is Map) {
          final isExcluded = raw['backupExcluded'] == true;
          final folder = raw['folder'] as String?;
          final isFolderExcluded = folder != null && excludedNoteFolders.contains(folder);

          if (isExcluded || isFolderExcluded) {
            totalExcluded++;
            final size = _estimateJsonSize(raw);
            potentialSavings += size;
            categorySavings['notes'] = (categorySavings['notes'] ?? 0) + size;
          }
        }
      }
    }

    // 2. Analyze Drive Files
    for (final key in driveBox.keys) {
      final k = key.toString();
      if (k.startsWith('main:') || k.startsWith('hidden:')) {
        if (k.contains(':folder_metadata:')) continue;
        totalLocal++;
        final raw = driveBox.get(key);
        if (raw is Map) {
          final size = (raw['size'] as num?)?.toInt() ?? 0;
          final isExcluded = raw['backupExcluded'] == true;
          final folder = raw['folder'] as String?;
          final isFolderExcluded = folder != null && excludedDriveFolders.contains(folder);

          if (isExcluded || isFolderExcluded) {
            totalExcluded++;
            potentialSavings += size;
            categorySavings['files'] = (categorySavings['files'] ?? 0) + size;
          } else if (size > 50 * 1024 * 1024) { // Suggest optimization for files > 50MB
            largeFiles.add('${raw['name']} (${(size / (1024 * 1024)).toStringAsFixed(1)} MB)');
          }
        }
      }
    }

    // 3. Analyze Passwords
    for (final key in passwordsBox.keys) {
      final k = key.toString();
      if (k.startsWith('main_pw:') || k.startsWith('hidden_pw:')) {
        totalLocal++;
        final raw = passwordsBox.get(k);
        if (raw is Map && raw['backupExcluded'] == true) {
          totalExcluded++;
          final size = _estimateJsonSize(raw);
          potentialSavings += size;
          categorySavings['passwords'] = (categorySavings['passwords'] ?? 0) + size;
        }
      }
    }

    return StorageInsights(
      totalLocalItems: totalLocal,
      totalExcludedItems: totalExcluded,
      totalCloudItems: backupState.totalBackupsCreated > 0 ? totalLocal - totalExcluded : 0,
      totalCloudSizeBytes: backupState.lastBackupSizeBytes,
      potentialSavingsBytes: potentialSavings,
      categorySavings: categorySavings,
      largeFilesSuggestions: largeFiles,
    );
  }

  Set<String> _getExcludedFolders(String prefix, String boxName) {
    final box = Hive.box(boxName);
    final excluded = <String>{};
    for (final key in box.keys) {
      final k = key.toString();
      if (k.startsWith('$prefix:') && k.contains(':folder_metadata:')) {
        final raw = box.get(key);
        if (raw is Map && raw['backupExcluded'] == true) {
          final folderName = k.split(':').last;
          excluded.add(folderName);
        }
      }
    }
    return excluded;
  }

  int _estimateJsonSize(dynamic data) {
    try {
      // Very rough estimate of JSON size in bytes
      return data.toString().length;
    } catch (_) {
      return 0;
    }
  }

  /// Returns a summary of optimization results.
  String getOptimizationSummary(StorageInsights insights) {
    if (insights.potentialSavingsBytes == 0) {
      return 'Your backup is already optimized.';
    }
    final savedMB = (insights.potentialSavingsBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$savedMB MB can be removed from future cloud backups by excluding items marked Local Only.';
  }
}

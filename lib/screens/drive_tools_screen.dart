import 'dart:io';
import 'package:flutter/material.dart';
import '../models/drive_file.dart';
import '../services/services.dart';
import '../services/compression_service.dart';
import '../widgets/smart_compression_sheet.dart';
import '../widgets/smart_optimizer_sheet.dart';
import '../widgets/document_conversion_sheet.dart';

class DriveToolsScreen extends StatefulWidget {
  final DriveService drive;
  final Set<String> unlockedFolders;
  const DriveToolsScreen({super.key, required this.drive, this.unlockedFolders = const {}});

  @override
  State<DriveToolsScreen> createState() => _DriveToolsScreenState();
}

class _DriveToolsScreenState extends State<DriveToolsScreen> {
  bool _loading = true;
  DriveStorageStats? _stats;
  final _insightsSvc = StorageInsightsService.instance;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    final stats = await _insightsSvc.analyzeDrive(unlockedFolders: widget.unlockedFolders);
    if (mounted) {
      setState(() {
        _stats = stats;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart File Tools'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStats,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadStats,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildStorageOverview(cs),
                  const SizedBox(height: 24),
                  _buildToolsGrid(cs),
                  const SizedBox(height: 24),
                  _buildSmartSuggestions(cs),
                  const SizedBox(height: 24),
                  _buildLargeFiles(cs),
                ],
              ),
            ),
    );
  }

  Widget _buildStorageOverview(ColorScheme cs) {
    final stats = _stats!;
    final savings = stats.totalOriginalSize - stats.totalSize;
    final savingsPercent = stats.totalOriginalSize > 0 
        ? (savings / stats.totalOriginalSize * 100).toInt() 
        : 0;

    return Card(
      elevation: 0,
      color: cs.primaryContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: cs.primary.withValues(alpha: 0.1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Drive Health',
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _insightsSvc.formatSize(stats.totalSize),
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1,
                        ),
                      ),
                      Text(
                        'Total secure storage used',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 70,
                  height: 70,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$savingsPercent%',
                      style: TextStyle(
                        color: cs.onPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (savings > 0) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.bolt, color: Colors.amber, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'You saved ${_insightsSvc.formatSize(savings)} with smart optimization',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolsGrid(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'File Tools',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: [
            _toolCard(Icons.compress, 'Optimize', 'Reduce file size', cs, _showOptimizerPicker),
            _toolCard(Icons.transform, 'Convert', 'Change format', cs, _showConverterPicker),
          ],
        ),
      ],
    );
  }

  Widget _toolCard(IconData icon, String title, String subtitle, ColorScheme cs, VoidCallback onTap) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: cs.primary),
              const SizedBox(height: 8),
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              Text(
                subtitle,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSmartSuggestions(ColorScheme cs) {
    final stats = _stats!;
    final suggestions = <Widget>[];

    if (stats.compressibleFiles.isNotEmpty) {
      suggestions.add(_suggestionCard(
        'Media Optimization',
        '${stats.compressibleFiles.length} media files can be compressed to save space.',
        Icons.auto_fix_high,
        Colors.blue,
        cs,
        _showOptimizerPicker,
      ));
    }

    if (stats.duplicates.isNotEmpty) {
      suggestions.add(_suggestionCard(
        'Duplicate Detection',
        'Found ${stats.duplicates.length} sets of duplicate files.',
        Icons.copy,
        Colors.orange,
        cs,
        _showDuplicates,
      ));
    }

    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Smart Suggestions',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 12),
        ...suggestions,
      ],
    );
  }

  Widget _suggestionCard(String title, String desc, IconData icon, Color color, ColorScheme cs, VoidCallback onTap) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(desc, style: const TextStyle(fontSize: 13)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  Widget _buildLargeFiles(ColorScheme cs) {
    final stats = _stats!;
    if (stats.largeFiles.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Largest Files',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 12),
        ...stats.largeFiles.take(5).map((f) => Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: ListTile(
            leading: Icon(_kindIcon(f.kind), color: cs.primary),
            title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: Text(f.folder, style: const TextStyle(fontSize: 12)),
            trailing: Text(
              _insightsSvc.formatSize(f.size),
              style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary, fontSize: 13),
            ),
            onTap: () => _showFileTools(f),
          ),
        )),
      ],
    );
  }

  IconData _kindIcon(String kind) {
    switch (kind) {
      case 'image': return Icons.image;
      case 'video': return Icons.videocam;
      case 'pdf': return Icons.picture_as_pdf;
      default: return Icons.description;
    }
  }

  void _showFileTools(SecureDriveFile file) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_fix_high),
              title: const Text('Optimize File'),
              onTap: () {
                Navigator.pop(ctx);
                _optimizeFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.transform),
              title: const Text('Convert File'),
              onTap: () {
                Navigator.pop(ctx);
                _convertFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _optimizeFile(SecureDriveFile file) async {
    final tempPath = await widget.drive.decryptToTemp(file);
    if (tempPath == null || !mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SmartCompressionSheet(
        filePath: tempPath,
        onComplete: (result, keep) async {
          Navigator.pop(context);
          if (!result.success) {
            try { await File(tempPath).delete(); } catch (_) {}
            _loadStats();
            return;
          }
          try {
            if (keep) {
              await widget.drive.importCompressedFile(
                compression: result,
                originalName: result.newName ?? file.name,
                folder: file.folder,
              );
            } else {
              await widget.drive.replaceFileWithCompressed(
                originalFile: file,
                compression: result,
              );
            }
            if (mounted) {
              FloatingNotificationService.instance.show(
                'Optimization saved ${result.savedPercentage.toInt()}% space!',
                type: AppNotificationType.success,
              );
            }
          } catch (e) {
            if (mounted) {
              FloatingNotificationService.instance.show(
                'Failed to save: $e',
                type: AppNotificationType.error,
              );
            }
          }
          try { await File(tempPath).delete(); } catch (_) {}
          _loadStats();
        },
      ),
    );
  }

  Future<void> _convertFile(SecureDriveFile file) async {
    final tempPath = await widget.drive.decryptToTemp(file);
    if (tempPath == null || !mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DocumentConversionSheet(
        filePath: tempPath,
        onComplete: (result, keep) async {
          Navigator.pop(context);
          if (!result.success) {
            try { await File(tempPath).delete(); } catch (_) {}
            _loadStats();
            return;
          }
          try {
            final convertedFile = File(result.path);
            if (!await convertedFile.exists()) {
              FloatingNotificationService.instance.show('Converted file not found', type: AppNotificationType.error);
              return;
            }
            final convertedSize = await convertedFile.length();
            final newExt = result.path.split('.').last;
            final baseName = file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name;
            final newName = '$baseName.$newExt';
            
            final cr = CompressionResult(
              path: result.path,
              originalSize: convertedSize,
              compressedSize: convertedSize,
              newName: newName,
            );
            if (keep) {
              await widget.drive.importCompressedFile(
                compression: cr,
                originalName: newName,
                folder: file.folder,
              );
            } else {
              // Note: replaceFileWithCompressed might not rename the file, we can just replace the blob and keep the name, or update name.
              // To update name properly when replacing, we should ideally use a method that supports renaming, but for now we import and delete old.
              await widget.drive.importCompressedFile(
                compression: cr,
                originalName: newName,
                folder: file.folder,
              );
              await widget.drive.deleteFile(file);
            }
            if (mounted) {
              FloatingNotificationService.instance.show(
                'File converted successfully!',
                type: AppNotificationType.success,
              );
            }
          } catch (e) {
            if (mounted) {
              FloatingNotificationService.instance.show(
                'Failed to save converted file: $e',
                type: AppNotificationType.error,
              );
            }
          }
          try { await File(tempPath).delete(); } catch (_) {}
          _loadStats();
        },
      ),
    );
  }

  void _showFilePickerDialog({required bool optimize}) {
    final stats = _stats;
    if (stats == null) return;
    
    List<SecureDriveFile> files;
    if (optimize) {
      files = stats.compressibleFiles;
    } else {
      final convertibleExts = ['txt', 'docx', 'pptx', 'pdf', 'jpg', 'jpeg', 'png', 'webp'];
      files = stats.allFiles.where((f) {
        final ext = f.name.split('.').last.toLowerCase();
        return convertibleExts.contains(ext);
      }).toList();
    }
    
    if (files.isEmpty) {
      FloatingNotificationService.instance.show(
        optimize ? 'No compressible files found' : 'No files available for conversion',
        type: AppNotificationType.info,
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                optimize ? 'Select File to Optimize' : 'Select File to Convert',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
            ),
            const Divider(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 400),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: files.length,
                itemBuilder: (_, i) {
                  final f = files[i];
                  return ListTile(
                    leading: Icon(_kindIcon(f.kind), color: Theme.of(context).colorScheme.primary),
                    title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    subtitle: Text(_insightsSvc.formatSize(f.size), style: const TextStyle(fontSize: 12)),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (optimize) {
                        _optimizeFile(f);
                      } else {
                        _convertFile(f);
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOptimizerPicker() {
    final stats = _stats;
    if (stats == null) return;
    if (stats.compressibleFiles.isEmpty) {
      FloatingNotificationService.instance.show(
        'No compressible files found',
        type: AppNotificationType.info,
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SmartOptimizerSheet(
        drive: widget.drive,
        files: stats.compressibleFiles,
        onRefresh: _loadStats,
      ),
    );
  }

  void _showConverterPicker() => _showFilePickerDialog(optimize: false);

  void _showDuplicates() {
    final stats = _stats;
    if (stats == null || stats.duplicates.isEmpty) {
      FloatingNotificationService.instance.show('No duplicates found', type: AppNotificationType.info);
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final currentStats = _stats;
            final duplicates = currentStats?.duplicates ?? [];
            if (duplicates.isEmpty) {
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Center(
                    child: Text(
                      'All duplicates resolved!', 
                      style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                ),
              );
            }

            return SafeArea(
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Duplicate Files',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: duplicates.length,
                        itemBuilder: (_, i) {
                          final group = duplicates[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    group.first.name,
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                  ),
                                  Text(
                                    'Size: ${_insightsSvc.formatSize(group.first.size)}',
                                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                  ),
                                  const SizedBox(height: 8),
                                  ...group.map((file) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    leading: const Icon(Icons.copy, size: 20),
                                    title: Text('Folder: ${file.folder}'),
                                    subtitle: Text('Added: ${file.createdAt.toLocal().toString().split('.')[0]}', style: const TextStyle(fontSize: 11)),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (c) => AlertDialog(
                                            title: const Text('Delete duplicate?'),
                                            content: const Text('This will permanently delete this copy.'),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                              FilledButton(
                                                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                                onPressed: () => Navigator.pop(c, true), 
                                                child: const Text('Delete'),
                                              ),
                                            ],
                                          )
                                        );
                                        if (confirm == true) {
                                          await widget.drive.deleteFile(file);
                                          await _loadStats();
                                          setModalState(() {});
                                          if (mounted) setState((){});
                                        }
                                      },
                                    ),
                                  )),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        );
      },
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_compress/video_compress.dart';
import '../models/drive_file.dart';
import '../services/compression_service.dart';
import '../services/drive_service.dart';
import '../services/floating_notification_service.dart';
import '../services/storage_insights_service.dart';

class SmartOptimizerSheet extends StatefulWidget {
  final DriveService drive;
  final List<SecureDriveFile> files;
  final VoidCallback onRefresh;

  const SmartOptimizerSheet({
    super.key,
    required this.drive,
    required this.files,
    required this.onRefresh,
  });

  @override
  State<SmartOptimizerSheet> createState() => _SmartOptimizerSheetState();
}

class _SmartOptimizerSheetState extends State<SmartOptimizerSheet> {
  bool _scanning = true;
  bool _optimizing = false;
  double _optimizationProgress = 0;
  int _filesProcessed = 0;
  int _filesSkipped = 0;

  final _insightsSvc = StorageInsightsService.instance;

  final _fileAnalyses = <String, Map<String, dynamic>>{};
  final _selectedFiles = <String>{};
  final _results = <String, CompressionResult>{};

  int _totalPotentialSavings = 0;

  @override
  void initState() {
    super.initState();
    for (final f in widget.files) {
      _selectedFiles.add(f.id);
    }
    _scanFiles();
  }

  Future<void> _scanFiles() async {
    for (final file in widget.files) {
      final ext = p.extension(file.name).toLowerCase();
      final size = file.size;

      bool isImage = ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.bmp', '.gif'].contains(ext);
      bool isVideo = ['.mp4', '.mov', '.m4v', '.mkv', '.avi', '.wmv', '.flv'].contains(ext);
      bool isPDF = ext == '.pdf';

      bool shouldCompress = false;
      int estimatedSize = size;

      if (isImage) { 
        shouldCompress = true;
        estimatedSize = (size * 0.3).toInt(); 
      } else if (isVideo) { 
        shouldCompress = true;
        estimatedSize = (size * 0.4).toInt(); 
      } else if (isPDF) { 
        shouldCompress = true;
        estimatedSize = (size * 0.8).toInt(); // Estimate 20% savings for PDF
      }

      _fileAnalyses[file.id] = {
        'shouldCompress': shouldCompress,
        'isImage': isImage,
        'isVideo': isVideo,
        'isPDF': isPDF,
        'originalSize': size,
        'estimatedSize': estimatedSize,
      };

      if (shouldCompress) {
        final saved = (size - estimatedSize).clamp(0, size);
        _totalPotentialSavings += saved;
      }
    }

    if (mounted) {
      setState(() => _scanning = false);
    }
  }

  Future<void> _startOptimization() async {
    if (_selectedFiles.isEmpty) {
      FloatingNotificationService.instance.show(
        'No files selected for optimization',
        type: AppNotificationType.info,
      );
      return;
    }

    setState(() {
      _optimizing = true;
      _optimizationProgress = 0;
      _filesProcessed = 0;
      _filesSkipped = 0;
    });

    final compressionService = CompressionService.instance;
    try {
      await VideoCompress.deleteAllCache();
    } catch (_) {}
    
    final selected = widget.files
        .where((f) => _selectedFiles.contains(f.id))
        .toList();

    int total = selected.length;
    int processed = 0;
    int totalSavedBytes = 0;

    for (final file in selected) {
      if (!mounted) break;

      final analysis = _fileAnalyses[file.id];
      if (analysis == null || analysis['shouldCompress'] != true) {
        _filesSkipped++;
        processed++;
        _optimizationProgress = processed / total;
        if (mounted) setState(() {});
        continue;
      }

      try {
        final tempPath = await widget.drive.decryptToTemp(file);
        if (tempPath == null || !mounted) {
          _filesSkipped++;
          processed++;
          _optimizationProgress = processed / total;
          if (mounted) setState(() {});
          continue;
        }

        CompressionResult result;

        if (analysis['isImage'] == true) {
          result = await compressionService.compressImage(
            tempPath,
            options: const ImageCompressionOptions(
              quality: 80,
              maxWidth: 1920,
              maxHeight: 1920,
            ),
          );
        } else if (analysis['isVideo'] == true) {
          result = await compressionService.compressVideo(
            tempPath,
            options: const VideoCompressionOptions(
              quality: VideoQuality.MediumQuality,
            ),
          );
        } else if (analysis['isPDF'] == true) {
          result = await compressionService.compressPDF(
            tempPath,
            options: const PDFCompressionOptions(quality: 80),
          );
        } else {
          result = CompressionResult.failure('Unsupported type');
        }

        if (result.success && result.compressedSize < result.originalSize) {
          // Import new version
          await widget.drive.importCompressedFile(
            compression: result,
            originalName: result.newName ?? file.name,
            folder: file.folder,
          );
          // Delete old version to prevent duplicates
          await widget.drive.deleteFile(file);

          totalSavedBytes += result.originalSize - result.compressedSize;
          _results[file.id] = result;
          _filesProcessed++;
        } else {
          _filesSkipped++;
        }

        try {
          await File(tempPath).delete();
        } catch (_) {}
      } catch (e) {
        _filesSkipped++;
      }

      processed++;
      _optimizationProgress = processed / total;
      if (mounted) setState(() {});
    }

    if (!mounted) return;

    FloatingNotificationService.instance.show(
      _filesProcessed > 0
          ? 'Optimized $_filesProcessed files, saved ${_insightsSvc.formatSize(totalSavedBytes)}!'
          : 'No files were optimized',
      type: _filesProcessed > 0
          ? AppNotificationType.success
          : AppNotificationType.info,
    );

    setState(() => _optimizing = false);

    widget.onRefresh();

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(cs),
            const SizedBox(height: 24),
            if (_scanning)
              _buildScanningState(cs)
            else if (_optimizing)
              _buildOptimizingState(cs)
            else ...[
              _buildSavingsSummary(cs),
              const SizedBox(height: 16),
              Expanded(
                child: _buildFileList(cs),
              ),
              const SizedBox(height: 16),
              _buildActionButton(cs),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    return Column(
      children: [
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: cs.onSurfaceVariant.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_fix_high, color: Colors.green, size: 24),
            ),
            const SizedBox(width: 12),
            Text(
              'Smart Optimizer',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildScanningState(ColorScheme cs) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 24),
          Text(
            'Scanning files for optimization...',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Analyzing file types, sizes, and compression potential',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildOptimizingState(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          SizedBox(
            height: 80,
            width: 80,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: _optimizationProgress > 0 ? _optimizationProgress : null,
                  strokeWidth: 8,
                  strokeCap: StrokeCap.round,
                  backgroundColor: cs.primary.withValues(alpha: 0.1),
                ),
                Text(
                  '${(_optimizationProgress * 100).toInt()}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: cs.primary,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Optimizing Files...',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            'Processing ${widget.files.where((f) => _selectedFiles.contains(f.id)).length} files',
            style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 16),
          if (_filesProcessed > 0 || _filesSkipped > 0)
            Text(
              '$_filesProcessed optimized, $_filesSkipped skipped',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
        ],
      ),
    );
  }

  Widget _buildSavingsSummary(ColorScheme cs) {
    final selectedCount = _selectedFiles.length;
    final totalCount = widget.files.length;
    final savings = _insightsSvc.formatSize(_totalPotentialSavings);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.savings, color: Colors.green, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Potential Savings: $savings',
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                Text(
                  '$selectedCount of $totalCount files selected',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                if (_selectedFiles.length == totalCount) {
                  _selectedFiles.clear();
                } else {
                  _selectedFiles.addAll(widget.files.map((f) => f.id));
                }
              });
            },
            child: Text(
              _selectedFiles.length == totalCount ? 'Deselect All' : 'Select All',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList(ColorScheme cs) {
    if (widget.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 48, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              'No files need optimization',
              style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: widget.files.length,
      separatorBuilder: (context, index) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final file = widget.files[i];
        final analysis = _fileAnalyses[file.id];
        final isSelected = _selectedFiles.contains(file.id);
        final canCompress = analysis?['shouldCompress'] == true;
        final estimated = analysis?['estimatedSize'] as int? ?? file.size;
        final saved = file.size - estimated;

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isSelected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.3),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: InkWell(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selectedFiles.remove(file.id);
                } else {
                  _selectedFiles.add(file.id);
                }
              });
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selectedFiles.add(file.id);
                        } else {
                          _selectedFiles.remove(file.id);
                        }
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: canCompress
                          ? cs.primary.withValues(alpha: 0.1)
                          : cs.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _kindIcon(file.kind),
                      color: canCompress ? cs.primary : cs.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_insightsSvc.formatSize(file.size)}${saved > 0 ? ' \u2192 ~${_insightsSvc.formatSize(estimated)}' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            color: saved > 0 ? Colors.green : cs.onSurfaceVariant,
                            fontWeight: saved > 0 ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (saved > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '-${_insightsSvc.formatSize(saved)}',
                        style: TextStyle(
                          color: Colors.green.shade700,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButton(ColorScheme cs) {
    final count = _selectedFiles.length;

    return FilledButton.icon(
      onPressed: _scanning || _optimizing || count == 0
          ? null
          : _startOptimization,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 6,
        shadowColor: cs.primary.withValues(alpha: 0.4),
        textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
      ),
      icon: const Icon(Icons.auto_fix_high),
      label: Text(count > 0 ? 'Optimize $count File${count > 1 ? 's' : ''}' : 'Select Files'),
    );
  }

  IconData _kindIcon(String kind) {
    switch (kind) {
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'pdf':
        return Icons.picture_as_pdf;
      default:
        return Icons.description;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}

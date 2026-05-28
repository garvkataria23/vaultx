import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart';
import '../services/compression_service.dart';
import '../services/floating_notification_service.dart';

class SmartCompressionSheet extends StatefulWidget {
  final String filePath;
  final Function(CompressionResult result, bool keepOriginal) onComplete;

  const SmartCompressionSheet({
    super.key,
    required this.filePath,
    required this.onComplete,
  });

  @override
  State<SmartCompressionSheet> createState() => _SmartCompressionSheetState();
}

class _SmartCompressionSheetState extends State<SmartCompressionSheet> {
  bool _analyzing = true;
  Map<String, dynamic>? _analysis;
  CompressionMode _mode = CompressionMode.smart;
  bool _keepOriginal = true;
  bool _compressing = false;
  double _progress = 0;
  late TextEditingController _nameCtrl;

  // Custom options
  int _imageQuality = 80;
  VideoQuality _videoQuality = VideoQuality.DefaultQuality;
  Subscription? _videoProgressSub;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: _getInitialCustomName());
    _analyze();
  }

  @override
  void dispose() {
    _videoProgressSub?.unsubscribe();
    _nameCtrl.dispose();
    CompressionService.instance.cancelVideoCompression();
    super.dispose();
  }

  String _getInitialCustomName() {
    final name = widget.filePath.split(Platform.pathSeparator).last;
    final parts = name.split('.');
    if (parts.length > 1) {
      final ext = parts.last;
      parts.removeLast();
      return '${parts.join('.')}_optimized.$ext';
    }
    return '${name}_optimized';
  }

  Future<void> _analyze() async {
    try {
      final result = await CompressionService.instance.analyzeFile(widget.filePath);
      if (mounted) {
        setState(() {
          _analysis = result;
          _analyzing = false;
          if (result['shouldCompress'] == true) {
            _mode = CompressionMode.smart;
          } else {
            _mode = CompressionMode.original;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _analyzing = false);
        FloatingNotificationService.instance.show('Analysis failed: $e', error: true);
      }
    }
  }

  Future<void> _startCompression() async {
    if (_compressing) return;
    setState(() => _compressing = true);

    if (_mode == CompressionMode.smart) {
      // Smart mode uses analysis-driven defaults in _getImageOptions / _getVideoOptions
    }

    _progress = 0;
    if (mounted) setState(() {});

    try {
      await VideoCompress.deleteAllCache();
    } catch (_) {}

    try {
      CompressionResult result;
      if (_analysis?['isImage'] == true) {
        final options = _getImageOptions();
        result = await CompressionService.instance.compressImage(
          widget.filePath,
          options: options,
        );
      } else if (_analysis?['isVideo'] == true) {
        final options = _getVideoOptions();
        _videoProgressSub?.unsubscribe();
        try {
          _videoProgressSub = CompressionService.instance.videoProgress.subscribe(
            (p) {
              if (mounted) {
                setState(() => _progress = p / 100);
              }
            },
            onError: (e) {
              debugPrint('[SmartCompressionSheet] Video progress error: $e');
            },
          );
        } catch (e) {
          debugPrint('[SmartCompressionSheet] Failed to subscribe to progress: $e');
        }
        try {
          result = await CompressionService.instance.compressVideo(
            widget.filePath,
            options: options,
          );
        } catch (e) {
          debugPrint('[SmartCompressionSheet] Video compression exception: $e');
          result = CompressionResult.failure(e.toString());
        } finally {
          _videoProgressSub?.unsubscribe();
          _videoProgressSub = null;
        }
      } else if (_analysis?['isPDF'] == true) {
        result = await CompressionService.instance.compressPDF(
          widget.filePath,
          options: PDFCompressionOptions(quality: _getPDFQuality()),
        );
      } else {
        result = CompressionResult.failure('Unsupported file type for optimization');
      }

      if (!mounted) return;

      if (result.success) {
        final actuallySmaller = result.compressedSize > 0 && result.compressedSize < result.originalSize;

        if (!actuallySmaller) {
          FloatingNotificationService.instance.show(
            'File is already fully optimized.',
            type: AppNotificationType.info,
          );
          widget.onComplete(
            CompressionResult(
              path: widget.filePath,
              success: true,
              originalSize: result.originalSize,
              compressedSize: result.originalSize,
            ),
            _keepOriginal,
          );
        } else {
          FloatingNotificationService.instance.show(
            'Optimization saved ${result.savedPercentage.toInt()}% space!',
            type: AppNotificationType.success,
          );
          final finalResult = CompressionResult(
            path: result.path,
            newName: _keepOriginal ? _nameCtrl.text : null,
            originalSize: result.originalSize,
            compressedSize: result.compressedSize,
          );
          widget.onComplete(finalResult, _keepOriginal);
        }
      } else {
        _compressing = false;
        if (mounted) setState(() {});
        FloatingNotificationService.instance.show(
          'Compression failed: ${result.error}',
          type: AppNotificationType.error,
        );
      }
    } catch (e) {
      _compressing = false;
      if (mounted) {
        setState(() {});
        FloatingNotificationService.instance.show(
          'An unexpected error occurred during compression: $e',
          type: AppNotificationType.error,
        );
      }
    }
  }

  ImageCompressionOptions _getImageOptions() {
    switch (_mode) {
      case CompressionMode.normal:
        return const ImageCompressionOptions(quality: 92, keepExif: true);
      case CompressionMode.smart:
        return const ImageCompressionOptions(quality: 75, maxWidth: 1920, maxHeight: 1920);
      case CompressionMode.high:
        return const ImageCompressionOptions(quality: 40, maxWidth: 1200, maxHeight: 1200);
      case CompressionMode.custom:
        return ImageCompressionOptions(quality: _imageQuality);
      case CompressionMode.original:
        return const ImageCompressionOptions(quality: 100);
    }
  }

  VideoCompressionOptions _getVideoOptions() {
    switch (_mode) {
      case CompressionMode.normal:
        return const VideoCompressionOptions(quality: VideoQuality.DefaultQuality);
      case CompressionMode.smart:
        return const VideoCompressionOptions(quality: VideoQuality.MediumQuality);
      case CompressionMode.high:
        return const VideoCompressionOptions(quality: VideoQuality.LowQuality);
      case CompressionMode.custom:
        return VideoCompressionOptions(quality: _videoQuality);
      case CompressionMode.original:
        return const VideoCompressionOptions();
    }
  }

  int _getPDFQuality() {
    switch (_mode) {
      case CompressionMode.normal: return 85;
      case CompressionMode.smart:  return 60;
      case CompressionMode.high:   return 30;
      case CompressionMode.custom: return _imageQuality;
      case CompressionMode.original: return 100;
    }
  }

  String _getModeDescription() {
    switch (_mode) {
      case CompressionMode.normal:
        return 'Quality-first: light optimization, preserves original dimensions.';
      case CompressionMode.smart:
        return 'Balanced: adaptive optimization for best quality-to-size ratio.';
      case CompressionMode.high:
        return 'Maximum reduction: stronger optimization, lower quality acceptable.';
      case CompressionMode.custom:
        return 'Fine-tune quality and resolution settings manually.';
      case CompressionMode.original:
        return 'No compression applied. File remains unchanged.';
    }
  }

  int _getEstimatedSize(int originalSize) {
    switch (_mode) {
      case CompressionMode.normal:
        return (originalSize * 0.80).toInt();
      case CompressionMode.smart:
        return (originalSize * 0.55).toInt();
      case CompressionMode.high:
        return (originalSize * 0.30).toInt();
      case CompressionMode.custom:
        return (originalSize * 0.55).toInt();
      case CompressionMode.original:
        return originalSize;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
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
            if (_analyzing)
              Expanded(child: _buildAnalyzingState(cs))
            else if (_compressing)
              Expanded(child: _buildCompressingState(cs))
            else ...[
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _buildOptionsContent(cs),
                ),
              ),
              const SizedBox(height: 16),
              _buildCompressButton(cs),
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
                color: cs.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.auto_fix_high, color: cs.primary, size: 24),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Smart Media Optimizer',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAnalyzingState(ColorScheme cs) {
    return const Column(
      children: [
        SizedBox(height: 20),
        CircularProgressIndicator(),
        SizedBox(height: 24),
        Text('Analyzing file properties...', style: TextStyle(fontWeight: FontWeight.w600)),
        SizedBox(height: 20),
      ],
    );
  }

  Widget _buildOptionsContent(ColorScheme cs) {
    final isImage = _analysis?['isImage'] == true;
    final isVideo = _analysis?['isVideo'] == true;
    final isPDF = _analysis?['isPDF'] == true;
    final canCompress = isImage || isVideo || isPDF;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_analysis?['originalSize'] != null)
          _buildAnalysisSummary(cs),
        const SizedBox(height: 20),
        Text(
          'Compression Mode',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 12),
        _buildModeTile(
          CompressionMode.normal,
          'Normal Compression',
          'Light optimization, preserves quality',
          Icons.tune,
          cs,
        ),
        _buildModeTile(
          CompressionMode.smart,
          'Smart Compression',
          'Best balance of quality and size (Recommended)',
          Icons.auto_awesome,
          cs,
        ),
        _buildModeTile(
          CompressionMode.high,
          'High Compression',
          'Maximum size reduction',
          Icons.compress,
          cs,
        ),
        _buildModeTile(
          CompressionMode.original,
          'Original Quality',
          'No compression, keep original file as is',
          Icons.image,
          cs,
        ),
        if (canCompress)
          _buildModeTile(
            CompressionMode.custom,
            'Custom Settings',
            'Manually adjust quality and resolution',
            Icons.settings_suggest,
            cs,
          ),
        if (_mode == CompressionMode.custom) _buildCustomControls(cs),
        const SizedBox(height: 12),
        _buildModeDetail(cs),
        const SizedBox(height: 24),
        _buildPostActionOptions(cs),
      ],
    );
  }

  Widget _buildModeDetail(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _getModeDescription(),
              style: TextStyle(
                fontSize: 12,
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisSummary(ColorScheme cs) {
    final original = _analysis!['originalSize'] as int;
    final estimated = _getEstimatedSize(original);
    final saved = (original - estimated).clamp(0, original);
    final percent = original > 0 ? ((saved / original) * 100).toInt() : 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.analytics_outlined, color: cs.primary, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Estimated Savings: $percent%',
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'From ${_formatSize(original)} to ~${_formatSize(estimated)}',
                  style: TextStyle(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _buildPostActionOptions(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Output Options',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildChoiceChip(
                  label: 'Replace Original',
                  selected: !_keepOriginal,
                  onTap: () => setState(() => _keepOriginal = false),
                  cs: cs,
                ),
              ),
              Expanded(
                child: _buildChoiceChip(
                  label: 'Keep Both',
                  selected: _keepOriginal,
                  onTap: () => setState(() => _keepOriginal = true),
                  cs: cs,
                ),
              ),
            ],
          ),
        ),
        if (_keepOriginal) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: 'Optimized File Name',
              prefixIcon: const Icon(Icons.edit_note),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.2),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCompressButton(ColorScheme cs) {
    final isOriginal = _mode == CompressionMode.original;
    return FilledButton.icon(
      onPressed: _compressing ? null : _startCompression,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 6,
        shadowColor: cs.primary.withValues(alpha: 0.4),
        textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
      ),
      icon: Icon(isOriginal ? Icons.arrow_forward : Icons.bolt),
      label: Text(isOriginal ? 'Continue' : 'Compress Now'),
    );
  }

  Widget _buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return Material(
      color: selected ? cs.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      elevation: selected ? 2 : 0,
      shadowColor: cs.primary.withValues(alpha: 0.3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? cs.onPrimary : cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeTile(
    CompressionMode mode,
    String title,
    String subtitle,
    IconData icon,
    ColorScheme cs,
  ) {
    final selected = _mode == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? cs.primary.withValues(alpha: 0.08) : cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => setState(() => _mode = mode),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5),
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: selected ? cs.primary.withValues(alpha: 0.1) : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: selected ? cs.primary : cs.onSurfaceVariant, size: 20),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: selected ? cs.primary : cs.onSurface,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_circle, color: cs.primary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCustomControls(ColorScheme cs) {
    final isImage = _analysis?['isImage'] == true;
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImage) ...[
            Text('Image Quality: $_imageQuality%', style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(
              value: _imageQuality.toDouble(),
              min: 10,
              max: 100,
              divisions: 18,
              onChanged: (v) => setState(() => _imageQuality = v.toInt()),
            ),
          ] else ...[
            const Text('Target Resolution:', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            DropdownButton<VideoQuality>(
              value: _videoQuality,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: VideoQuality.LowQuality, child: Text('Low (360p)')),
                DropdownMenuItem(value: VideoQuality.MediumQuality, child: Text('Medium (720p)')),
                DropdownMenuItem(value: VideoQuality.DefaultQuality, child: Text('Default (High)')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _videoQuality = v);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompressingState(ColorScheme cs) {
    return Column(
      children: [
        const SizedBox(height: 20),
        SizedBox(
          height: 100,
          width: 100,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: _progress > 0 ? _progress : null,
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
                backgroundColor: cs.primary.withValues(alpha: 0.1),
              ),
              if (_progress > 0)
                Text(
                  '${(_progress * 100).toInt()}%',
                  style: TextStyle(fontWeight: FontWeight.w900, color: cs.primary),
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        Text(
          'Compressing Media...',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          _progress > 0 
            ? 'Processing bitstreams...'
            : 'Applying optimization...',
          style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 24),
        if (_analysis?['isVideo'] == true)
          OutlinedButton.icon(
            onPressed: () => CompressionService.instance.cancelVideoCompression(),
            icon: const Icon(Icons.cancel),
            label: const Text('Cancel Compression'),
          ),
      ],
    );
  }
}
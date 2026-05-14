import 'package:flutter/material.dart';
import '../services/conversion_service.dart';
import '../services/floating_notification_service.dart';

class DocumentConversionSheet extends StatefulWidget {
  final String filePath;
  final Function(ConversionResult result, bool keepOriginal) onComplete;

  const DocumentConversionSheet({
    super.key,
    required this.filePath,
    required this.onComplete,
  });

  @override
  State<DocumentConversionSheet> createState() => _DocumentConversionSheetState();
}

class _DocumentConversionSheetState extends State<DocumentConversionSheet> {
  ConversionFormat? _targetFormat;
  bool _converting = false;
  bool _keepOriginal = true;
  String _ext = '';

  @override
  void initState() {
    super.initState();
    _ext = widget.filePath.split('.').last.toLowerCase();
    _setDefaults();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _setDefaults() {
    final formats = _getAvailableFormats();
    if (formats.isNotEmpty) {
      _targetFormat = formats.first;
    }
  }

  List<ConversionFormat> _getAvailableFormats() {
    if (_ext == 'txt') return [ConversionFormat.pdf, ConversionFormat.docx];
    if (_ext == 'docx') return [ConversionFormat.pdf, ConversionFormat.txt];
    if (_ext == 'pptx') return [ConversionFormat.pdf, ConversionFormat.txt];
    if (_ext == 'pdf') return [ConversionFormat.txt];
    if (['jpg', 'jpeg', 'png', 'webp'].contains(_ext)) {
      return [
        ConversionFormat.pdf,
        ConversionFormat.jpg,
        ConversionFormat.png,
        ConversionFormat.webp,
      ];
    }
    return [];
  }

  Future<void> _startConversion() async {
    if (_targetFormat == null || _converting) return;

    setState(() => _converting = true);

    try {
      final result = await ConversionService.instance.convert(
        inputPath: widget.filePath,
        targetFormat: _targetFormat!,
      );

      if (mounted) {
        if (result.success) {
          FloatingNotificationService.instance.show(
            'File converted successfully!',
            type: AppNotificationType.success,
          );
          widget.onComplete(result, _keepOriginal);
        } else {
          setState(() => _converting = false);
          FloatingNotificationService.instance.show(
            'Conversion failed: ${result.error}',
            type: AppNotificationType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _converting = false);
        FloatingNotificationService.instance.show(
          'An unexpected error occurred: $e',
          type: AppNotificationType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final formats = _getAvailableFormats();

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
            if (_converting)
              _buildConvertingState(cs)
            else ...[
              Text(
                'Target Format',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 16),
              _buildFormatGrid(formats, cs),
              const SizedBox(height: 24),
              _buildPostActionOptions(cs),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: (_targetFormat != null && !_converting) ? _startConversion : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 6,
                  shadowColor: cs.primary.withValues(alpha: 0.4),
                  textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                ),
                icon: Icon(_converting ? Icons.hourglass_top : Icons.auto_fix_high),
                label: Text(
                  _converting ? 'Converting...' : 'Convert Now',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFormatGrid(List<ConversionFormat> formats, ColorScheme cs) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.1,
      ),
      itemCount: formats.length,
      itemBuilder: (context, index) {
        final f = formats[index];
        final isSelected = _targetFormat == f;
        return Material(
          color: isSelected ? cs.primary : cs.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: () => setState(() => _targetFormat = f),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5),
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _getFormatIcon(f),
                    color: isSelected ? cs.onPrimary : cs.primary,
                    size: 28,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    f.name.toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: isSelected ? cs.onPrimary : cs.onSurface,
                      fontSize: 12,
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

  IconData _getFormatIcon(ConversionFormat f) {
    switch (f) {
      case ConversionFormat.pdf: return Icons.picture_as_pdf;
      case ConversionFormat.docx: return Icons.description;
      case ConversionFormat.txt: return Icons.article;
      case ConversionFormat.jpg:
      case ConversionFormat.png:
      case ConversionFormat.webp: return Icons.image;
      default: return Icons.insert_drive_file;
    }
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.transform, color: cs.primary, size: 24),
            ),
            const SizedBox(width: 12),
            Text(
              'File Converter',
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

  Widget _buildPostActionOptions(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Output Strategy',
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
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            _keepOriginal 
              ? 'Creates a new converted file in the same folder.' 
              : 'Warning: Original file will be permanently replaced.',
            style: TextStyle(
              fontSize: 11, 
              color: _keepOriginal ? cs.onSurfaceVariant : cs.error,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
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

  Widget _buildConvertingState(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          const SizedBox(height: 20),
          SizedBox(
            width: 80,
            height: 80,
            child: CircularProgressIndicator(
              strokeWidth: 6,
              strokeCap: StrokeCap.round,
              backgroundColor: cs.primary.withValues(alpha: 0.1),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Converting File...',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${_ext.toUpperCase()} \u2192 ${_targetFormat?.name.toUpperCase() ?? '...'}',
            style: TextStyle(
              color: cs.primary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Processing and optimizing output...',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

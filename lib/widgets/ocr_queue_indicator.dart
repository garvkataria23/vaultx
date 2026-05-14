import 'package:flutter/material.dart';

import '../services/ocr_queue_service.dart';

class OcrQueueIndicator extends StatefulWidget {
  const OcrQueueIndicator({
    super.key,
    required this.service,
    this.onResults,
    this.onClose,
  });

  final OcrQueueService service;
  final void Function(List<OcrJob> completedJobs)? onResults;
  final VoidCallback? onClose;

  @override
  State<OcrQueueIndicator> createState() => _OcrQueueIndicatorState();
}

class _OcrQueueIndicatorState extends State<OcrQueueIndicator> {
  bool _resultsHandled = false;
  bool _needsRebuild = false;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onQueueChanged);
    super.dispose();
  }

  void _onQueueChanged() {
    if (!mounted) return;
    if (_needsRebuild) return;
    _needsRebuild = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _needsRebuild = false;
      setState(() {});
      if (!_resultsHandled &&
          !widget.service.isProcessing &&
          widget.service.completedCount > 0) {
        _resultsHandled = true;
        widget.onResults?.call(widget.service.completedJobs);
      }
    });
  }

  Color _stateColor(OcrJobState state, ColorScheme cs) {
    return switch (state) {
      OcrJobState.queued => cs.onSurface.withValues(alpha: 0.5),
      OcrJobState.preprocessing => cs.tertiary,
      OcrJobState.processing => cs.primary,
      OcrJobState.completed => cs.primary,
      OcrJobState.failed => cs.error,
      OcrJobState.cancelled => cs.onSurface.withValues(alpha: 0.4),
    };
  }

  IconData _stateIcon(OcrJobState state) {
    return switch (state) {
      OcrJobState.queued => Icons.hourglass_empty,
      OcrJobState.preprocessing => Icons.tune,
      OcrJobState.processing => Icons.text_snippet,
      OcrJobState.completed => Icons.check_circle,
      OcrJobState.failed => Icons.error,
      OcrJobState.cancelled => Icons.cancel,
    };
  }

  String _stateLabel(OcrJobState state) {
    return switch (state) {
      OcrJobState.queued => 'Queued',
      OcrJobState.preprocessing => 'Preprocessing',
      OcrJobState.processing => 'OCR',
      OcrJobState.completed => 'Done',
      OcrJobState.failed => 'Failed',
      OcrJobState.cancelled => 'Cancelled',
    };
  }

  int _activeCount(List<OcrJob> queue) {
    return queue
        .where(
          (j) =>
              j.state == OcrJobState.preprocessing ||
              j.state == OcrJobState.processing,
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (service.queue.isEmpty) return const SizedBox.shrink();

    final progress = service.totalCount > 0
        ? service.completedCount / service.totalCount
        : 0.0;
    final active = _activeCount(service.queue);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.text_snippet, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    active > 0
                        ? 'Processing ${service.completedCount + active} of ${service.totalCount}'
                        : '${service.completedCount} of ${service.totalCount} processed',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Dismiss',
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: active > 0 ? null : progress,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 8),
            ...service.queue.map((job) => _buildJobTile(job, theme, cs)),
            if (service.pendingCount > 0 || active > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: service.cancelAll,
                      icon: const Icon(Icons.cancel, size: 16),
                      label: const Text('Cancel all'),
                      style: TextButton.styleFrom(
                        foregroundColor: cs.error,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildJobTile(OcrJob job, ThemeData theme, ColorScheme cs) {
    final subtitle = StringBuffer(_stateLabel(job.state));
    if (job.state == OcrJobState.completed && job.preprocessingResult != null) {
      final r = job.preprocessingResult!;
      if (r.wasResized) {
        subtitle.write(' resized');
      }
      subtitle.write(
        ' ${(r.originalSizeBytes / 1024).toStringAsFixed(0)}K\u2192${(r.optimizedSizeBytes / 1024).toStringAsFixed(0)}K',
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            _stateIcon(job.state),
            size: 14,
            color: _stateColor(job.state, cs),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.attachmentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _stateColor(job.state, cs),
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle.toString(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          if (job.state == OcrJobState.failed && job.error != null)
            Tooltip(
              message: job.error!,
              child: Icon(Icons.info_outline, size: 14, color: cs.error),
            ),
          if (job.state == OcrJobState.failed)
            IconButton(
              onPressed: () => widget.service.retry(job.id),
              icon: const Icon(Icons.refresh, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Retry',
            ),
          if (job.state == OcrJobState.completed ||
              job.state == OcrJobState.cancelled)
            IconButton(
              onPressed: () => widget.service.removeJob(job.id),
              icon: const Icon(Icons.close, size: 14),
              visualDensity: VisualDensity.compact,
              tooltip: 'Remove',
            ),
        ],
      ),
    );
  }
}

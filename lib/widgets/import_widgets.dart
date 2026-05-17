import 'package:flutter/material.dart';
import '../services/note_import_service.dart';

class NoteImportProgressDialog extends StatelessWidget {
  const NoteImportProgressDialog({
    super.key,
    required this.stage,
    required this.progress,
    required this.message,
    this.current,
    this.total,
  });

  final ImportStage stage;
  final double progress;
  final String message;
  final int? current;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            SizedBox(
              height: 80,
              width: 80,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: stage == ImportStage.completed ? 1.0 : (stage == ImportStage.failed ? 0.0 : progress),
                    strokeWidth: 6,
                    backgroundColor: cs.outlineVariant.withValues(alpha: 0.3),
                    color: stage == ImportStage.failed ? cs.error : cs.primary,
                  ),
                  if (stage == ImportStage.completed)
                    Icon(Icons.check_circle, color: cs.primary, size: 48)
                  else if (stage == ImportStage.failed)
                    Icon(Icons.error_outline, color: cs.error, size: 48)
                  else
                    Text('${(progress * 100).toInt()}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _getStageTitle(stage),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (current != null && total != null) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: current! / total!,
                borderRadius: BorderRadius.circular(10),
                minHeight: 6,
              ),
              const SizedBox(height: 8),
              Text(
                '$current / $total files',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getStageTitle(ImportStage stage) {
    switch (stage) {
      case ImportStage.preparing: return 'Preparing Import';
      case ImportStage.extracting: return 'Extracting ZIP';
      case ImportStage.reading: return 'Reading Folders';
      case ImportStage.importing: return 'Processing Notes';
      case ImportStage.media: return 'Handling Media';
      case ImportStage.saving: return 'Securing Data';
      case ImportStage.finalizing: return 'Finalizing';
      case ImportStage.completed: return 'Import Successful';
      case ImportStage.failed: return 'Import Failed';
    }
  }
}

class ImportSuccessDialog extends StatelessWidget {
  const ImportSuccessDialog({super.key, required this.stats});
  final ImportStats stats;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.check_circle_outline, color: Colors.green),
          SizedBox(width: 12),
          Text('Import Complete'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStatRow(context, 'Total Notes', '${stats.totalNotes}', Icons.notes),
          _buildStatRow(context, 'Folders Created', '${stats.totalFolders}', Icons.folder_open),
          _buildStatRow(context, 'Media Scanned', '${stats.totalMedia}', Icons.image_outlined),
          if (stats.failedFiles > 0)
            _buildStatRow(context, 'Failed Files', '${stats.failedFiles}', Icons.warning_amber, color: cs.error),
          const Divider(),
          _buildStatRow(context, 'Time Taken', '${stats.timeTaken.inSeconds}s', Icons.timer_outlined),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'view'),
          child: const Text('View Notes'),
        ),
      ],
    );
  }

  Widget _buildStatRow(BuildContext context, String label, String value, IconData icon, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
        ],
      ),
    );
  }
}

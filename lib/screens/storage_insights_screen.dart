import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/auth.dart';
import '../services/services.dart';

class StorageInsightsScreen extends StatefulWidget {
  const StorageInsightsScreen({
    super.key,
    required this.masterKey,
    required this.kind,
    required this.authService,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService authService;

  @override
  State<StorageInsightsScreen> createState() => _StorageInsightsScreenState();
}

class _StorageInsightsScreenState extends State<StorageInsightsScreen> {
  late final BackupOptimizer _optimizer;
  late final BackupService _backupService;
  StorageInsights? _insights;
  bool _loading = true;
  bool _optimizing = false;

  @override
  void initState() {
    super.initState();
    _backupService = BackupService(
      masterKey: widget.masterKey,
      kind: widget.kind,
      authService: widget.authService,
    );
    _optimizer = BackupOptimizer(_backupService);
    _loadInsights();
  }

  Future<void> _loadInsights() async {
    setState(() => _loading = true);
    final insights = await _optimizer.calculateInsights();
    if (mounted) {
      setState(() {
        _insights = insights;
        _loading = false;
      });
    }
  }

  Future<void> _optimizeNow() async {
    final drive = GoogleDriveBackupService(authService: widget.authService);
    final authenticated = await drive.restoreSession() != null;
    
    if (!authenticated) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to Google Drive first.')),
        );
      }
      return;
    }

    setState(() => _optimizing = true);
    
    try {
      final success = await drive.uploadBackup(({bool compressMedia = false}) async {
        final result = await _backupService.createBackup(compressMedia: compressMedia);
        return result.data;
      }, useArchive: true);

      if (mounted) {
        if (success) {
          FloatingNotificationService.instance.show('Cloud backup optimized successfully');
          _loadInsights();
        } else {
          FloatingNotificationService.instance.show('Optimization failed', error: true);
        }
      }
    } finally {
      if (mounted) setState(() => _optimizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Storage Insights')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildOverviewCard(cs),
                const SizedBox(height: 16),
                _buildSavingsBreakdown(cs),
                const SizedBox(height: 16),
                if (_insights!.largeFilesSuggestions.isNotEmpty)
                  _buildLargeFilesCard(cs),
                const SizedBox(height: 24),
                _buildOptimizationAction(cs),
              ],
            ),
    );
  }

  Widget _buildOverviewCard(ColorScheme cs) {
    final i = _insights!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statItem('Local Items', '${i.totalLocalItems}', cs),
                _statItem('Excluded', '${i.totalExcludedItems}', cs, color: Colors.orange),
                _statItem('Cloud Items', '${i.totalCloudItems}', cs, color: Colors.green),
              ],
            ),
            const Divider(height: 32),
            Text(
              'Current Backup Size: ${_formatBytes(i.totalCloudSizeBytes)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavingsBreakdown(ColorScheme cs) {
    final i = _insights!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Potential Savings', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _savingsRow('Notes', i.categorySavings['notes'] ?? 0, cs),
            _savingsRow('Files', i.categorySavings['files'] ?? 0, cs),
            _savingsRow('Passwords', i.categorySavings['passwords'] ?? 0, cs),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total Potential Savings', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  _formatBytes(i.potentialSavingsBytes),
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLargeFilesCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text('Large Files Detected', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'These files take up significant cloud space. Consider marking them "Local Only".',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            ..._insights!.largeFilesSuggestions.map((s) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('• $s', style: const TextStyle(fontSize: 13)),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildOptimizationAction(ColorScheme cs) {
    final i = _insights!;
    final canOptimize = i.potentialSavingsBytes > 0;

    return Column(
      children: [
        if (canOptimize)
          Text(
            _optimizer.getOptimizationSummary(i),
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _optimizing ? null : _optimizeNow,
            icon: _optimizing 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_fix_high),
            label: Text(_optimizing ? 'Optimizing...' : 'Optimize Cloud Backup Now'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'This item will remain on your device but will no longer occupy cloud backup storage.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _statItem(String label, String value, ColorScheme cs, {Color? color}) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color ?? cs.onSurface)),
        Text(label, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
  }

  Widget _savingsRow(String label, int bytes, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Text(_formatBytes(bytes), style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}

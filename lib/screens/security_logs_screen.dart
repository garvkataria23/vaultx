import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/services.dart';
import '../models/models.dart';
import '../widgets/widgets.dart';

/// Displays intruder selfies, failed unlock attempts, and security audit events.
/// Uses [VaultAuthService.intruderLogKey] for decryption — the same key used
/// when the photo was captured.
class SecurityLogsScreen extends StatefulWidget {
  const SecurityLogsScreen({
    super.key,
    required this.auth,
    this.isDecoy = false,
  });
  final VaultAuthService auth;
  final bool isDecoy;

  @override
  State<SecurityLogsScreen> createState() => _SecurityLogsScreenState();
}

class _SecurityLogsScreenState extends State<SecurityLogsScreen> {
  List<IntruderLogEntry> _intruderLogs = [];
  List<Map<String, dynamic>> _auditLogs = [];
  int _failedPinAttempts = 0;
  bool _loading = true;
  Uint8List? _intruderKey;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    if (widget.isDecoy) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      _intruderKey = await widget.auth.intruderLogKey();

      final intruderBox = Hive.box('vaultx_intruder');
      final allEntries = intruderBox.values
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      final intruderLogs = allEntries.map((json) {
        try {
          return IntruderLogEntry.fromJson(json);
        } catch (_) {
          return null;
        }
      }).whereType<IntruderLogEntry>().toList();

      intruderLogs.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      final auditBox = Hive.box('vaultx_audit');
      final allLogs = auditBox.values
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      final failedCount = allLogs
          .where((l) => (l['event'] as String? ?? '').contains('Failed'))
          .length;

      if (mounted) {
        setState(() {
          _intruderLogs = intruderLogs;
          _auditLogs = allLogs.reversed.toList();
          _failedPinAttempts = failedCount;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('SecurityLogsScreen._loadLogs: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Uint8List? get _key => _intruderKey;

  Future<void> _viewIntruderPhoto(SecureAttachment attachment) async {
    if (_key == null) return;
    try {
      final tempPath = await EncryptedBlobService(_key!).decryptAttachmentToTemp(
        'intruder',
        attachment,
      );
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Intruder Photo',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Image.file(
                File(tempPath),
                fit: BoxFit.contain,
                width: double.infinity,
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Captured: ${attachment.createdAt.toLocal()}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
      try {
        await File(tempPath).delete();
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        FloatingNotificationService.instance.show('Failed to decrypt photo: $e');
      }
    }
  }

  Future<void> _deleteEntry(IntruderLogEntry entry) async {
    try {
      if (entry.attachment != null && _key != null) {
        try {
          final file = File(entry.attachment!.encryptedPath);
          if (await file.exists()) {
            await EncryptedBlobService.secureDeletePath(
              entry.attachment!.encryptedPath,
            );
          }
        } catch (_) {}
      }
      await Hive.box('vaultx_intruder').delete(entry.id);
      await AuditLog.write('Intruder log entry deleted');
      _loadLogs();
    } catch (e) {
      debugPrint('SecurityLogsScreen._deleteEntry: $e');
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all intruder logs?'),
        content: const Text(
          'This will permanently delete all captured intruder photos '
          'and log entries. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final box = Hive.box('vaultx_intruder');
    for (final entry in _intruderLogs) {
      if (entry.attachment != null && _key != null) {
        try {
          final file = File(entry.attachment!.encryptedPath);
          if (await file.exists()) {
            await EncryptedBlobService.secureDeletePath(
              entry.attachment!.encryptedPath,
            );
          }
        } catch (_) {}
      }
    }
    await box.clear();
    await AuditLog.write('All intruder logs cleared');
    _loadLogs();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.isDecoy) {
      return const EmptyState(
        icon: Icons.shield,
        title: 'Unavailable',
        body: 'Security logs are not accessible in decoy mode.',
      );
    }

    final hasIntruderLogs = _intruderLogs.isNotEmpty;
    final hasAuditLogs = _auditLogs.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Security Logs'),
        actions: [
          if (_failedPinAttempts > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Chip(
                  label: Text('$_failedPinAttempts failed'),
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          if (hasIntruderLogs)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear all intruder logs',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: !hasIntruderLogs && !hasAuditLogs
          ? const EmptyState(
              icon: Icons.shield_outlined,
              title: 'No security events',
              body:
                  'Failed unlock attempts and intruder photos will appear here.',
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_failedPinAttempts > 0) ...[
                  Card(
                    color: Theme.of(context)
                        .colorScheme
                        .errorContainer
                        .withValues(alpha: 0.3),
                    child: ListTile(
                      leading: Icon(
                        Icons.warning,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        '$_failedPinAttempts failed unlock attempt${_failedPinAttempts > 1 ? 's' : ''}',
                      ),
                      subtitle: const Text(
                        'Intruder photos are encrypted and stored locally.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (hasIntruderLogs) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Intruder Photos',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ..._intruderLogs.map(
                    (entry) => _IntruderPhotoCard(
                      entry: entry,
                      intruderKey: _key,
                      onView: () {
                        if (entry.attachment != null) {
                          _viewIntruderPhoto(entry.attachment!);
                        }
                      },
                      onDelete: () => _deleteEntry(entry),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                if (hasAuditLogs) ...[
                  Text(
                    'Activity Log',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ..._auditLogs
                      .take(50)
                      .map(
                        (log) => Card(
                          child: ListTile(
                            leading: Icon(
                              _securityIcon(log['event'] as String? ?? ''),
                              color: _securityColor(
                                log['event'] as String? ?? '',
                              ),
                            ),
                            title: Text(log['event'] as String? ?? ''),
                            subtitle: Text(
                              DateTime.tryParse(
                                    log['ts'] as String? ?? '',
                                  )?.toLocal().toString() ??
                                  '',
                            ),
                          ),
                        ),
                      ),
                ],
              ],
            ),
    );
  }

  IconData _securityIcon(String event) {
    if (event.contains('Failed')) return Icons.warning;
    if (event.contains('intruder')) return Icons.camera_front;
    if (event.contains('initialized')) return Icons.security;
    if (event.contains('backup')) return Icons.backup;
    if (event.contains('deleted') || event.contains('wipe')) {
      return Icons.delete;
    }
    if (event.contains('save')) return Icons.save;
    return Icons.info_outline;
  }

  Color _securityColor(String event) {
    final cs = Theme.of(context).colorScheme;
    if (event.contains('Failed') || event.contains('intruder')) return cs.error;
    if (event.contains('wipe')) return cs.error;
    if (event.contains('initialized')) return cs.primary;
    if (event.contains('backup')) return cs.primary;
    return cs.onSurfaceVariant;
  }
}

class _IntruderPhotoCard extends StatelessWidget {
  const _IntruderPhotoCard({
    required this.entry,
    required this.intruderKey,
    required this.onView,
    required this.onDelete,
  });

  final IntruderLogEntry entry;
  final Uint8List? intruderKey;
  final VoidCallback onView;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasPhoto = entry.attachment != null && intruderKey != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: SizedBox(
          width: 48,
          height: 48,
          child: hasPhoto
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: FutureBuilder<String>(
                    future: EncryptedBlobService(intruderKey!)
                        .decryptAttachmentToTemp(
                      'intruder',
                      entry.attachment!,
                    ),
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data != null) {
                        return Image.file(
                          File(snapshot.data!),
                          fit: BoxFit.cover,
                          cacheWidth: 144,
                          cacheHeight: 144,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.broken_image,
                            color: cs.onSurfaceVariant,
                          ),
                        );
                      }
                      return Icon(
                        Icons.image,
                        color: cs.primary,
                      );
                    },
                  ),
                )
              : Icon(Icons.camera_front, color: cs.primary),
        ),
        title: Text('Attempt #${entry.attemptNumber}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.timestamp.toLocal().toString()),
            Text(
              _authMethodLabel(entry.authMethod),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasPhoto)
              TextButton(
                onPressed: onView,
                child: const Text('View'),
              ),
            IconButton(
              icon: Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
              tooltip: 'Delete entry',
            ),
          ],
        ),
      ),
    );
  }

  String _authMethodLabel(String method) {
    switch (method) {
      case 'password':
        return 'Main vault password';
      case 'hidden_password':
        return 'Hidden vault password';
      case 'pin':
        return 'PIN';
      default:
        return method;
    }
  }
}

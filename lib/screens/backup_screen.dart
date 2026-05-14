import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import '../services/services.dart';
import 'restore_screen.dart';

/// Backup & Restore management screen.
///
/// Shows backup history, health status, allows creating new backups,
/// and restoring from previous versions with progress reporting,
/// integrity verification, and detailed restore summaries.
import 'storage_insights_screen.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    required this.masterKey,
    required this.kind,
    required this.authService,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService authService;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  GoogleDriveBackupService? _drive;
  BackupService? _backupService;
  List<BackupVersion> _versions = [];
  BackupProgress? _progress;
  bool _gdriveSigningIn = false;
  bool _gdriveUploading = false;
  bool _gdriveRestoring = false;
  String? _googleEmail;
  String? _error;
  BackupState _backupState = const BackupState();
  String _backupPhase = '';
  bool _restoreSessionRunning = false;
  bool _optimizeMedia = true;
  bool _useArchiveBackup = true;

  @override
  void initState() {
    super.initState();
    _drive = GoogleDriveBackupService(authService: widget.authService);
    _backupService = BackupService(
      masterKey: widget.masterKey,
      kind: widget.kind,
      authService: widget.authService,
      onProgress: _onProgress,
    );
    _backupState = BackupState.load();
    _recoverStaleLock();
    _restoreSession();
  }

  Future<void> _recoverStaleLock() async {
    final state = BackupState.load();
    if (state.isInProgress) {
      final bool isStale;
      if (state.lastBackupAt != null) {
        isStale = DateTime.now().toUtc().difference(state.lastBackupAt!) > const Duration(hours: 2);
      } else {
        isStale = true;
      }
      if (isStale) {
        debugPrint('BACKUP SCREEN: STALE LOCK RECOVERED on startup');
        await BackupState.save(const BackupState());
        _backupState = const BackupState();
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final drive = _drive;
    if (drive == null || _restoreSessionRunning) return;
    _restoreSessionRunning = true;
    final email = await drive.restoreSession();
    _restoreSessionRunning = false;
    if (mounted) {
      setState(() => _googleEmail = email);
      if (email != null) _refreshVersions();
    }
  }

  Future<void> _signIn() async {
    final drive = _drive;
    if (drive == null || _gdriveSigningIn) return;
    setState(() {
      _gdriveSigningIn = true;
      _error = null;
    });
    try {
      final ok = await drive.signIn();
      if (mounted) {
        if (ok) {
          _googleEmail = drive.signedInEmail;
          await _refreshVersions();
        } else {
          setState(() => _error = 'Sign in was cancelled.');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Sign in failed: $e');
    } finally {
      if (mounted) setState(() => _gdriveSigningIn = false);
    }
  }

  Future<void> _refreshVersions() async {
    final versions = await _drive?.listBackups() ?? [];
    _backupState = BackupState.load();
    if (mounted) setState(() => _versions = versions);
  }

  void _onProgress(BackupProgress progress) {
    if (mounted) setState(() => _progress = progress);
  }

  Future<void> _createBackup() async {
    if (_gdriveUploading || _gdriveRestoring) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Backup'),
        content: Text(
          _backupState.lastBackupAt != null
              ? 'Last backup: ${_formatTimestamp(_backupState.lastBackupAt!)}\n\n'
                'This will upload your current vault data to Google Drive.\n'
                'Estimated size: ${_formatBytes(_backupState.lastBackupSizeBytes)}'
              : 'This will upload your current vault data to Google Drive.\n'
                'This is your first backup — it may take a while.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Backup Now')),
        ],
      ),
    );
    if (proceed != true) return;

    debugPrint('BACKUP START: manual backup requested');

    setState(() {
      _gdriveUploading = true;
      _error = null;
      _backupPhase = 'Generating backup data...';
    });

    try {
      final ok = await _drive!.uploadBackup(({bool compressMedia = false}) async {
        final result = await _backupService!.createBackup(compressMedia: compressMedia);
        setState(() => _backupPhase = 'Uploading to Google Drive...');
        return result.data;
      }, verificationService: _backupService,
         onPhaseChange: (phase) {
           if (mounted) setState(() => _backupPhase = phase);
         },
         compressMedia: _optimizeMedia,
         useArchive: _useArchiveBackup,
      );

      if (mounted) {
        if (ok) {
          setState(() => _backupPhase = '');
          await _refreshVersions();
          _backupState = BackupState.load();
          if (mounted) {
            FloatingNotificationService.instance.show('Backup completed and verified successfully');
          }
        } else {
          setState(() {
            _error = 'Backup failed. Upload or integrity verification did not pass.';
            _backupPhase = '';
          });
          FloatingNotificationService.instance.show(
            'Backup failed. Please check your connection.',
            type: AppNotificationType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Backup failed: $e';
          _backupPhase = '';
        });
        FloatingNotificationService.instance.show(
          'Backup failed: $e',
          type: AppNotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _gdriveUploading = false;
          _progress = null;
        });
      }
    }
  }

  void _openRestoreScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RestoreScreen(
          authService: widget.authService,
          driveService: _drive!,
          masterKey: widget.masterKey,
          kind: widget.kind,
        ),
      ),
    );
  }

  Future<void> _restoreBackup(BackupVersion version, {bool merge = false}) async {
    if (_gdriveRestoring || _gdriveUploading) return;
    final sizeLabel = _formatBytes(version.totalSizeBytes);
    final warning = merge
        ? 'Existing data with matching IDs will be preserved.\n\n'
          'Recommended for restoring after reinstall or on a new device.'
        : 'WARNING: This will REPLACE all existing vault data!\n'
          'Current data will be LOST.\n\n'
          'Consider creating a backup first.';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(merge ? 'Merge Backup' : 'Restore Backup'),
        content: Text(
          'Backup from: ${version.label}\n'
          'Size: $sizeLabel\n'
          '${version.mainNoteCount} notes'
          '${version.hiddenNoteCount > 0 ? ', ${version.hiddenNoteCount} hidden' : ''}'
          '${version.driveFileCount > 0 ? ', ${version.driveFileCount} drive files' : ''}\n\n'
          '$warning',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: merge ? null : FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(merge ? 'Merge' : 'Replace All'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _gdriveRestoring = true;
      _error = null;
    });

    try {
      debugPrint('RESTORE: downloading version ${version.label} (${version.fileName})');
      final data = await _drive!.downloadVersion(version);
      if (data == null) {
        debugPrint('RESTORE FAILED: download returned null');
        if (mounted) setState(() => _error = 'Failed to download backup. It may be corrupted.');
        return;
      }
      debugPrint('RESTORE: download succeeded, keys=${data.keys.join(", ")}');
      debugPrint('RESTORE: has authBundle=${data.containsKey("authBundle")}, has manifest=${data.containsKey("manifest")}');
      debugPrint('RESTORE: mainVault records=${(data["mainVault"] as List?)?.length ?? 0}');

      final result = await _backupService!.restoreBackup(
        data,
        mode: merge ? RestoreMode.merge : RestoreMode.replace,
        mainMasterKey: widget.masterKey,
      );

      debugPrint('RESTORE: result success=${result.success}, error=${result.error}');

      if (mounted) {
        if (result.success) {
          _backupState = _backupState.copyWith(
            totalRestoresPerformed: _backupState.totalRestoresPerformed + 1,
          );
          await BackupState.save(_backupState);

          if (!mounted) return;
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Restore Complete'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(result.summary),
                  if (!result.verificationPassed) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Verification issues: ${result.verificationWarnings.join(', ')}',
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontSize: 13),
                    ),
                  ],
                ],
              ),
              actions: [
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
              ],
            ),
          );
          await _refreshVersions();
          debugPrint('UI REFRESH COMPLETE: backup restore screen refreshed');
        } else {
          setState(() => _error = result.error ?? 'Restore failed for unknown reason');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Restore error: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _gdriveRestoring = false;
          _progress = null;
        });
      }
    }
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  Widget _buildHealthIndicator(BackupHealth health) {
    switch (health) {
      case BackupHealth.ok:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 14),
            SizedBox(width: 4),
            Text('Healthy', style: TextStyle(fontSize: 12, color: Colors.green)),
          ],
        );
      case BackupHealth.warning:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning, color: Colors.orange, size: 14),
            SizedBox(width: 4),
            Text('Warning', style: TextStyle(fontSize: 12, color: Colors.orange)),
          ],
        );
      case BackupHealth.error:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error, color: Colors.red, size: 14),
            SizedBox(width: 4),
            Text('Error', style: TextStyle(fontSize: 12, color: Colors.red)),
          ],
        );
      case BackupHealth.never:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, color: Colors.grey, size: 14),
            SizedBox(width: 4),
            Text('Never backed up', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Google Account section ──────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.cloud, color: cs.primary),
                      const SizedBox(width: 8),
                      Text('Google Drive', style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_googleEmail != null) ...[
                    Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_googleEmail!, style: Theme.of(context).textTheme.bodySmall),
                        ),
                      ],
                    ),
                    FilledButton.icon(
                      onPressed: (_gdriveUploading || _gdriveRestoring) ? null : _createBackup,
                      icon: _gdriveUploading
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload),
                      label: Text(_gdriveUploading ? 'Uploading...' : 'Create Backup Now'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: (_gdriveUploading || _gdriveRestoring) ? null : () => _openRestoreScreen(),
                      icon: const Icon(Icons.restore),
                      label: const Text('Restore from Google Drive'),
                    ),
                  ] else ...[
                    Text(
                      'Sign in to enable encrypted cloud backups.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style: TextStyle(color: cs.error, fontSize: 13),
                          softWrap: true,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: _gdriveSigningIn ? null : _signIn,
                      icon: _gdriveSigningIn
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(_gdriveSigningIn ? 'Connecting...' : 'Sign in with Google'),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (_googleEmail != null) ...[
            const SizedBox(height: 16),

            // ── Backup Status ────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.monitor_heart, color: cs.primary),
                        const SizedBox(width: 8),
                        Text('Backup Status', style: Theme.of(context).textTheme.titleSmall),
                        const Spacer(),
                        _buildHealthIndicator(_backupState.health),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_backupState.lastBackupAt != null) ...[
                      _infoRow(Icons.access_time, 'Last backup', _formatTimestamp(_backupState.lastBackupAt!)),
                      const SizedBox(height: 4),
                      _infoRow(Icons.storage, 'Size', _formatBytes(_backupState.lastBackupSizeBytes)),
                      const SizedBox(height: 4),
                      _infoRow(Icons.replay, 'Total backups', '${_backupState.totalBackupsCreated}'),
                      const SizedBox(height: 4),
                      if (_backupState.lastError != null)
                        _infoRow(Icons.error_outline, 'Last error', _backupState.lastError!, color: cs.error),
                    ] else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No backup has been created yet. Create your first backup to secure your data.',
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ── Create Backup ─────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.backup, color: cs.primary),
                        const SizedBox(width: 8),
                        Text('Create Backup', style: Theme.of(context).textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Backs up all vaults, secure drive files, settings, and credentials.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (_error != null && !_gdriveUploading && !_gdriveRestoring)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style: TextStyle(color: cs.error, fontSize: 13),
                          softWrap: true,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: (_gdriveUploading || _gdriveRestoring) ? null : _createBackup,
                      icon: _gdriveUploading
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload),
                      label: Text(_gdriveUploading ? 'Uploading...' : 'Create Backup Now'),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _optimizeMedia,
                      onChanged: (v) => setState(() => _optimizeMedia = v),
                      title: const Text('Smart Optimization', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text('Compress images/videos before backup to save cloud space', style: TextStyle(fontSize: 12)),
                      secondary: Icon(Icons.auto_fix_high, color: cs.primary, size: 20),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _useArchiveBackup,
                      onChanged: (v) => setState(() => _useArchiveBackup = v),
                      title: const Text('Use Smart Compressed Backup (Beta)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text('Significantly reduces backup size and improves upload/restore speed using V2 archive format.', style: TextStyle(fontSize: 12)),
                      secondary: Icon(Icons.folder_zip, color: cs.primary, size: 20),
                    ),
                    const Divider(height: 24),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => StorageInsightsScreen(
                              masterKey: widget.masterKey,
                              kind: widget.kind,
                              authService: widget.authService,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.insights),
                      label: const Text('View Storage Insights & Optimize'),
                    ),

                    if (_gdriveUploading && _progress != null)
                      _buildProgressView(),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ── Backup History ────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.history, color: cs.primary),
                        const SizedBox(width: 8),
                        Text('Backup History', style: Theme.of(context).textTheme.titleSmall),
                        const Spacer(),
                        if (_versions.isNotEmpty)
                          Text(
                            '${_versions.length} backup${_versions.length == 1 ? '' : 's'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_versions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No backups yet',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    else
                      ...List.generate(_versions.length, (i) {
                        final v = _versions[i];
                        final sizeLabel = _formatBytes(v.totalSizeBytes);
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.restore_page, color: cs.primary, size: 20),
                          title: Text(v.label, style: const TextStyle(fontSize: 14)),
                          subtitle: Text(
                            '$sizeLabel · ${v.mainNoteCount} notes${v.hiddenNoteCount > 0 ? ' · ${v.hiddenNoteCount} hidden' : ''}${v.driveFileCount > 0 ? ' · ${v.driveFileCount} drive files' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'restore') _restoreBackup(v);
                              if (action == 'merge') _restoreBackup(v, merge: true);
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'restore', child: Text('Replace restore')),
                              const PopupMenuItem(value: 'merge', child: Text('Merge restore')),
                            ],
                          ),
                        );
                      }),

                    const Divider(height: 8),
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 14, color: cs.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(
                          'Last backup: ${_drive?.lastBackupAt ?? "Never"}',
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // ── Restore progress ──────────────────────────────────────────
            if (_gdriveRestoring && _progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _buildProgressView(),
              ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, {Color? color}) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 14, color: color ?? cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text('$label: ', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        Expanded(
          child: Text(
            value,
            style: TextStyle(fontSize: 12, color: color ?? cs.onSurface),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressView() {
    if (_progress == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final p = _progress!;

    // Calculate overall progress
    var totalItems = 0;
    var completedItems = 0;
    for (final c in p.components) {
      if (c.totalItems > 0) {
        totalItems += c.totalItems;
        completedItems += c.itemsProcessed;
      }
    }
    final progress = totalItems > 0 ? completedItems / totalItems : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: progress > 0 ? progress : null,
                    color: p.overallState == BackupOperationState.failed ? cs.error : cs.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  p.overallState == BackupOperationState.completed
                      ? 'Completed'
                      : p.overallState == BackupOperationState.failed
                      ? 'Failed'
                      : 'In progress...',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_backupPhase.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _backupPhase,
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ),
            if (p.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  p.error!,
                  style: TextStyle(color: cs.error, fontSize: 13),
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 3,
                ),
              ),
            ...p.components.map((c) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  _componentIcon(c.state),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.component.name,
                      style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                    ),
                  ),
                  if (c.totalItems > 0)
                    Text(
                      '${c.itemsProcessed}/${c.totalItems}',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.error_outline, size: 14, color: cs.error),
                    ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  Widget _componentIcon(BackupOperationState state) {
    switch (state) {
      case BackupOperationState.pending:
        return const SizedBox(width: 16, height: 16);
      case BackupOperationState.inProgress:
        return const SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case BackupOperationState.completed:
        return const Icon(Icons.check_circle, size: 16, color: Colors.green);
      case BackupOperationState.failed:
        return const Icon(Icons.error, size: 16, color: Colors.red);
    }
  }
}

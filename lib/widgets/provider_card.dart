import 'package:flutter/material.dart';

import '../models/backup.dart';
import '../services/backup_manager.dart';
import '../services/format_utils.dart';

/// A card displaying a cloud provider's status, quota, and controls.
///
/// Shows:
/// - Connected/disconnected state with account email
/// - Storage usage bar (animated progress indicator)
/// - Last backup time
/// - Upload progress (when active)
/// - Enable/disable toggle
/// - Backup button
class ProviderCard extends StatefulWidget {
  const ProviderCard({
    super.key,
    required this.manager,
    required this.provider,
    this.onSignIn,
    this.onBackup,
    this.onRestore,
  });

  final BackupManager manager;
  final CloudProvider provider;
  final VoidCallback? onSignIn;
  final VoidCallback? onBackup;
  final VoidCallback? onRestore;

  @override
  State<ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<ProviderCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _barAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _barAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOutCubic,
    );
    widget.manager.addListener(_onManagerChange);
    _animController.forward();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChange);
    _animController.dispose();
    super.dispose();
  }

  void _onManagerChange() {
    if (mounted) setState(() {});
    final info = widget.manager.getStorageInfo(widget.provider);
    if (info.totalBytes > 0) {
      _animController.forward(from: 0.0);
    }
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return 'Never';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  String _getMegaStatusText(MegaConnectionState? state) {
    switch (state) {
      case MegaConnectionState.connecting:
        return 'Connecting to MEGA...';
      case MegaConnectionState.restoring:
        return 'Restoring session...';
      case MegaConnectionState.fetchingNodes:
        return 'Fetching nodes...';
      case MegaConnectionState.failed:
        return 'Connection failed';
      case MegaConnectionState.ready:
        return 'Connected';
      case null:
        return 'Connecting...';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final state = widget.manager.getState(widget.provider);
    final info = widget.manager.getStorageInfo(widget.provider);
    final isConnected = state.connected;
    final isUploading = state.uploading;
    final isReconnecting = state.isReconnecting;
    final isMegaNotReady = widget.provider == CloudProvider.mega && state.megaState != MegaConnectionState.ready;
    final name = widget.provider.displayName;

    final color = switch (widget.provider) {
      CloudProvider.googleDrive => Colors.blue,
      CloudProvider.mega => Colors.red,
    };
    final icon = switch (widget.provider) {
      CloudProvider.googleDrive => Icons.cloud_queue,
      CloudProvider.mega => Icons.cloud_done_outlined,
    };

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              cs.surface,
              cs.surfaceContainerHighest.withValues(alpha: 0.2),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row ──────────────────────────────────────────────
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                        if (isConnected && state.email != null) ...[
                          if (widget.provider == CloudProvider.mega && state.megaState != MegaConnectionState.ready)
                            Text(
                              _getMegaStatusText(state.megaState),
                              style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500),
                            )
                          else
                            Text(
                              state.email!,
                              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                            )
                        ]
                        else if (isReconnecting)
                          Text(
                            widget.provider == CloudProvider.mega ? 'Connecting to MEGA...' : 'Reconnecting...',
                            style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500),
                          )
                        else if (!isConnected)
                          Text(
                            'Not connected',
                            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (isUploading || isReconnecting || isMegaNotReady)
                    const _AnimatedSyncIcon()
                  else
                    _StatusBadge(isConnected: isConnected),
                ],
              ),
              const SizedBox(height: 24),

              // ── Storage Quota Bar ──────────────────────────────────────
              if (isConnected && info.totalBytes > 0) ...[
                _StorageBarWidget(
                  animation: _barAnimation,
                  fraction: info.usageFraction,
                  usedBytes: info.usedBytes,
                  totalBytes: info.totalBytes,
                  color: color,
                ),
                const SizedBox(height: 20),
              ],

              // ── Stats Row ──────────────────────────────────────────────
              if (isConnected) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _StatItem(
                      label: 'Last Sync',
                      value: _formatTimestamp(DateTime.tryParse(state.lastBackupAt ?? '')),
                      icon: Icons.history,
                    ),
                    _StatItem(
                      label: 'Backups',
                      value: '${info.backupFileCount} files',
                      icon: Icons.folder_zip_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],

              // ── Upload progress ─────────────────────────────────────────
              if (isUploading) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              state.uploadPhase ?? 'Uploading...',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: cs.primary),
                            ),
                          ),
                          Text(
                            '${(state.uploadProgress * 100).toStringAsFixed(0)}%',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: cs.primary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: state.uploadProgress > 0 ? state.uploadProgress : null,
                          minHeight: 6,
                          backgroundColor: cs.surface,
                          valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ── Actions ─────────────────────────────────────────────────
              if (isConnected)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (isUploading || isReconnecting || isMegaNotReady) ? null : widget.onBackup,
                        icon: const Icon(Icons.backup_outlined, size: 18),
                        label: const Text('Backup'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (isUploading || isReconnecting || isMegaNotReady) ? null : widget.onRestore,
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('Restore'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                )

              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isReconnecting ? null : widget.onSignIn,
                    icon: const Icon(Icons.link, size: 18),
                    label: Text(isReconnecting ? 'Reconnecting...' : 'Connect Provider'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),

              // ── Error ───────────────────────────────────────────────────
              if (state.error != null && !isUploading)
                Container(
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: cs.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          state.error!,
                          style: TextStyle(fontSize: 12, color: cs.error),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isConnected;

  const _StatusBadge({required this.isConnected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isConnected ? Colors.green : cs.error).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: (isConnected ? Colors.green : cs.error).withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: isConnected ? Colors.green : cs.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'Connected' : 'Disconnected',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: isConnected ? Colors.green.shade700 : cs.error,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _AnimatedSyncIcon extends StatefulWidget {
  const _AnimatedSyncIcon();

  @override
  State<_AnimatedSyncIcon> createState() => _AnimatedSyncIconState();
}

class _AnimatedSyncIconState extends State<_AnimatedSyncIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(Icons.sync, color: Theme.of(context).colorScheme.primary, size: 20),
    );
  }
}

/// Animated storage usage bar showing used/free space with percentage.
class _StorageBarWidget extends StatelessWidget {
  final Animation<double> animation;
  final double fraction;
  final int usedBytes;
  final int totalBytes;
  final Color color;

  const _StorageBarWidget({
    required this.animation,
    required this.fraction,
    required this.usedBytes,
    required this.totalBytes,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final freeBytes = totalBytes - usedBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${formatBytes(usedBytes)} / ${formatBytes(totalBytes)} used',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const Spacer(),
            Text(
              '${(fraction * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: fraction > 0.9 ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        AnimatedBuilder(
          animation: animation,
          builder: (context, _) => ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction * animation.value,
              minHeight: 8,
              backgroundColor: cs.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Free: ${formatBytes(freeBytes)}',
          style: TextStyle(fontSize: 11, color: Colors.green.shade700),
        ),
      ],
    );
  }
}

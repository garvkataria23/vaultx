import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drive_file.dart';
import 'swipe_action_tile.dart';

class DriveFileTile extends StatelessWidget {
  const DriveFileTile({
    super.key,
    required this.file,
    this.onTap,
    this.onDelete,
    this.onFavorite,
    this.onMove,
    this.onTogglePin,
    this.onToggleArchive,
    this.onShare,
    this.onCompress,
    this.onConvert,
    this.onToggleBackup,
  });

  final SecureDriveFile file;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onFavorite;
  final void Function(String folder)? onMove;
  final VoidCallback? onTogglePin;
  final VoidCallback? onToggleArchive;
  final VoidCallback? onShare;
  final VoidCallback? onCompress;
  final VoidCallback? onConvert;
  final VoidCallback? onToggleBackup;

  IconData _kindIcon() {
    switch (file.kind) {
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'document':
        return Icons.description;
      case 'id':
        return Icons.badge;
      case 'password':
        return Icons.key;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _kindColor(ColorScheme cs) {
    switch (file.kind) {
      case 'image':
        return Colors.green;
      case 'video':
        return Colors.blue;
      case 'pdf':
        return Colors.red;
      case 'document':
        return Colors.orange;
      case 'id':
        return Colors.purple;
      case 'password':
        return Colors.amber;
      default:
        return cs.onSurface.withValues(alpha: 0.6);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kindColor = _kindColor(cs);

    return SwipeActionTile(
      isPinned: file.pinned,
      isArchived: file.archived,
      onAction: (action) {
        switch (action) {
          case SwipeAction.pin:
            onTogglePin?.call();
          case SwipeAction.archive:
            onToggleArchive?.call();
          case SwipeAction.share:
            onShare?.call();
          case SwipeAction.move:
            _showFolderPicker(context);
          case SwipeAction.delete:
            onDelete?.call();
        }
      },
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _showActions(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kindColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(_kindIcon(), color: kindColor, size: 22),
                      if (file.pinned)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Icon(Icons.push_pin, size: 12, color: cs.primary),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (file.backupExcluded)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.cloud_off,
                                size: 12,
                                color: cs.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              '${file.sizeLabel}  ·  ${file.folder}${file.backupExcluded ? '  ·  Local only' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (file.favorite)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.star, size: 16, color: Colors.amber),
                  ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'favorite':
                        onFavorite?.call();
                      case 'pin':
                        onTogglePin?.call();
                      case 'archive':
                        onToggleArchive?.call();
                      case 'share':
                        onShare?.call();
                      case 'compress':
                        onCompress?.call();
                      case 'convert':
                        onConvert?.call();
                      case 'move':
                        _showFolderPicker(context);
                      case 'backup':
                        onToggleBackup?.call();
                      case 'delete':
                        onDelete?.call();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'favorite',
                      child: Text(
                        file.favorite ? 'Remove favorite' : 'Add favorite',
                      ),
                    ),
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(file.pinned ? 'Unpin' : 'Pin'),
                    ),
                    if (['image', 'video', 'pdf'].contains(file.kind))
                      const PopupMenuItem(
                        value: 'compress',
                        child: Text('Optimize & Compress'),
                      ),
                    if (['image', 'pdf', 'document', 'txt'].contains(file.kind))
                      const PopupMenuItem(
                        value: 'convert',
                        child: Text('Optimize & Convert'),
                      ),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(file.archived ? 'Restore' : 'Archive'),
                    ),
                    PopupMenuItem(
                      value: 'share',
                      child: const Text('Share'),
                    ),
                    if (onMove != null)
                      PopupMenuItem(
                        value: 'move',
                        child: const Text('Move to folder'),
                      ),
                    PopupMenuItem(
                      value: 'backup',
                      child: Text(
                        file.backupExcluded ? 'Include in Backup' : 'Local Only',
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    HapticFeedback.mediumImpact();
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(file.favorite ? Icons.star : Icons.star_border, color: file.favorite ? Colors.amber : null),
              title: Text(file.favorite ? 'Remove favorite' : 'Add favorite'),
              onTap: () {
                Navigator.pop(ctx);
                onFavorite?.call();
              },
            ),
            ListTile(
              leading: Icon(file.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(file.pinned ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.pop(ctx);
                onTogglePin?.call();
              },
            ),
            ListTile(
              leading: Icon(file.archived ? Icons.unarchive : Icons.archive),
              title: Text(file.archived ? 'Restore from archive' : 'Archive'),
              onTap: () {
                Navigator.pop(ctx);
                onToggleArchive?.call();
              },
            ),
            if (['image', 'video', 'pdf'].contains(file.kind))
              ListTile(
                leading: const Icon(Icons.auto_fix_high),
                title: const Text('Optimize & Compress'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCompress?.call();
                },
              ),
            if (['image', 'pdf', 'document', 'txt'].contains(file.kind))
              ListTile(
                leading: const Icon(Icons.transform),
                title: const Text('Optimize & Convert'),
                onTap: () {
                  Navigator.pop(ctx);
                  onConvert?.call();
                },
              ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(ctx);
                onShare?.call();
              },
            ),
            if (onMove != null)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Move to folder'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showFolderPicker(context);
                },
              ),
            ListTile(
              leading: Icon(
                file.backupExcluded ? Icons.cloud_off : Icons.cloud_done,
                color: file.backupExcluded ? cs.onSurfaceVariant : cs.primary,
              ),
              title: Text(
                file.backupExcluded ? 'Include in Backup' : 'Local Only',
              ),
              subtitle: file.backupExcluded
                  ? Text(
                      'Stored only on this device',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                onToggleBackup?.call();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete?.call();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFolderPicker(BuildContext context) {
    if (onMove == null) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Move to folder',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ...SecureDriveFile.folders.map(
              (f) => ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f),
                onTap: () {
                  Navigator.pop(ctx);
                  onMove?.call(f);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

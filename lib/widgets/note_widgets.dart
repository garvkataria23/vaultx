import 'package:flutter/material.dart';

import '../models/models.dart';
import 'smart_category_badge.dart';
import 'swipe_action_tile.dart';

/// Card displaying a single secure note in the notes list.
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.onTap,
    required this.onDelete,
    required this.onToggleArchive,
    required this.onToggleFavorite,
    required this.onTogglePin,
    required this.onShare,
    required this.onMove,
    this.onToggleBackup,
    this.category,
    this.relevanceScore,
  });
  final SecureNote note;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggleArchive;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTogglePin;
  final VoidCallback onShare;
  final VoidCallback onMove;
  final VoidCallback? onToggleBackup;
  final String? category;
  final double? relevanceScore;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SwipeActionTile(
      isPinned: note.pinned,
      isArchived: note.archived,
      onAction: (action) {
        switch (action) {
          case SwipeAction.pin:
            onTogglePin();
          case SwipeAction.archive:
            onToggleArchive();
          case SwipeAction.share:
            onShare();
          case SwipeAction.move:
            onMove();
          case SwipeAction.delete:
            onDelete();
        }
      },
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          onTap: onTap,
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(switch (note.type) {
                  NoteType.checklist => Icons.checklist,
                  NoteType.voice => Icons.mic,
                  NoteType.drawing => Icons.brush,
                  _ => Icons.description,
                }, color: cs.primary),
                if (category != null)
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: SmartCategoryBadge(category: category!, size: 10),
                  ),
                if (note.pinned)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Icon(Icons.push_pin, size: 14, color: cs.primary),
                  ),
              ],
            ),
          ),
          title: Row(
            children: [
              if (note.favorite)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.star, size: 16, color: Colors.amber),
                ),
              Expanded(
                child: Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (relevanceScore != null && relevanceScore! < 0.9)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '${(relevanceScore! * 100).round()}%',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              if (note.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.attach_file,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              if (note.locked)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.lock, size: 16, color: cs.onSurfaceVariant),
                ),
              if (note.backupExcluded)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.cloud_off,
                    size: 16,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              if (note.ocrText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.text_snippet,
                    size: 16,
                    color: cs.primary.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              '${note.folder}  ${note.tags.map((e) => '#$e').join(' ')}\n${note.body}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  note.favorite ? Icons.star : Icons.star_border,
                  color: note.favorite ? Colors.amber : cs.onSurfaceVariant,
                  size: 20,
                ),
                onPressed: onToggleFavorite,
                tooltip: note.favorite ? 'Unfavorite' : 'Favorite',
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'pin') onTogglePin();
                  if (v == 'fav') onToggleFavorite();
                  if (v == 'archive') onToggleArchive();
                  if (v == 'share') onShare();
                  if (v == 'move') onMove();
                  if (v == 'backup') onToggleBackup?.call();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(note.pinned ? 'Unpin' : 'Pin'),
                  ),
                  PopupMenuItem(
                    value: 'fav',
                    child: Text(note.favorite ? 'Unfavorite' : 'Favorite'),
                  ),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(note.archived ? 'Restore' : 'Archive'),
                  ),
                  PopupMenuItem(
                    value: 'share',
                    child: const Text('Share'),
                  ),
                  PopupMenuItem(
                    value: 'move',
                    child: const Text('Move to folder'),
                  ),
                  PopupMenuItem(
                    value: 'backup',
                    child: Text(
                      note.backupExcluded ? 'Include in Backup' : 'Local Only',
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for selecting a note type when creating a new note.
class NoteTypePicker extends StatelessWidget {
  const NoteTypePicker({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.description),
            title: const Text('Text note'),
            onTap: () => Navigator.pop(context, NoteType.text),
          ),
          ListTile(
            leading: const Icon(Icons.checklist),
            title: const Text('Checklist'),
            onTap: () => Navigator.pop(context, NoteType.checklist),
          ),
          ListTile(
            leading: const Icon(Icons.mic),
            title: const Text('Voice note'),
            onTap: () => Navigator.pop(context, NoteType.voice),
          ),
          ListTile(
            leading: const Icon(Icons.brush),
            title: const Text('Drawing'),
            onTap: () => Navigator.pop(context, NoteType.drawing),
          ),
        ],
      ),
    );
  }
}

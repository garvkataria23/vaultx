import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    required this.onToggleLock,
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
  final VoidCallback onToggleLock;
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
                  NoteType.todo => Icons.playlist_add_check,
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
                  if (v == 'lock') onToggleLock();
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
                    value: 'lock',
                    child: Text(note.locked ? 'Unlock' : 'Lock'),
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

class ModernNoteCard extends StatelessWidget {
  const ModernNoteCard({
    super.key,
    required this.note,
    required this.onTap,
    required this.onDelete,
    required this.onToggleArchive,
    required this.onToggleFavorite,
    required this.onTogglePin,
    required this.onToggleLock,
    required this.onShare,
    required this.onMove,
    this.isGrid = false,
    this.category,
    this.isSelected = false,
    this.isSelectionMode = false,
    this.onSelectionToggle,
  });

  final SecureNote note;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggleArchive;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleLock;
  final VoidCallback onShare;
  final VoidCallback onMove;
  final bool isGrid;
  final String? category;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback? onSelectionToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final timeStr = _formatDate(note.updatedAt);

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
      child: GestureDetector(
        onTap: (isSelected || isSelectionMode) ? onSelectionToggle : onTap,
        onLongPress: () {
          HapticFeedback.heavyImpact();
          onSelectionToggle?.call();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          decoration: BoxDecoration(
            gradient: isSelected ? null : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.surfaceContainerLow,
                cs.surfaceContainerHighest.withValues(alpha: 0.6),
              ],
            ),
            color: isSelected ? cs.primaryContainer.withValues(alpha: 0.7) : null,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected 
                  ? cs.primary 
                  : (note.pinned 
                      ? cs.primary.withValues(alpha: 0.5) 
                      : cs.outlineVariant.withValues(alpha: 0.4)),
              width: (note.pinned || isSelected) ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Grid View usually provides bounded height via childAspectRatio.
              // List View and Masonry View (in a Column) provide unbounded height.
              final bool hasBoundedHeight = constraints.hasBoundedHeight;
              
              return Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                if (note.pinned && !isSelected)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(Icons.push_pin, size: 16, color: cs.primary),
                                  ),
                                Expanded(
                                  child: Text(
                                    note.title.isEmpty ? 'Untitled Note' : note.title,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                      color: isSelected ? cs.onPrimaryContainer : cs.onSurface,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (note.locked)
                                  Icon(Icons.lock_outline, size: 16, color: cs.primary),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              note.locked ? 'Content Locked' : note.body,
                              style: TextStyle(
                                fontSize: 14,
                                color: isSelected 
                                    ? cs.onPrimaryContainer.withValues(alpha: 0.8) 
                                    : cs.onSurfaceVariant.withValues(alpha: 0.8),
                                height: 1.4,
                              ),
                              maxLines: isGrid ? 4 : 8,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (hasBoundedHeight) const Spacer() else const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              isSelected 
                                  ? cs.primary.withValues(alpha: 0.15)
                                  : cs.surfaceContainerHighest.withValues(alpha: 0.4),
                            ],
                          ),
                          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              switch (note.type) {
                                NoteType.checklist => Icons.checklist_rtl_outlined,
                                NoteType.todo => Icons.playlist_add_check_outlined,
                                NoteType.voice => Icons.mic_none_outlined,
                                NoteType.drawing => Icons.brush_outlined,
                                _ => Icons.notes_outlined,
                              },
                              size: 14,
                              color: isSelected ? cs.primary : cs.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              timeStr,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isSelected 
                                    ? cs.onPrimaryContainer.withValues(alpha: 0.6) 
                                    : cs.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                            ),
                            const Spacer(),
                            if (category != null)
                              SmartCategoryBadge(category: category!, size: 8),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: onToggleFavorite,
                              child: Icon(
                                note.favorite ? Icons.star : Icons.star_outline,
                                size: 18,
                                color: note.favorite ? Colors.amber : (isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (isSelected)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.check, size: 14, color: cs.onPrimary),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
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
            leading: const Icon(Icons.playlist_add_check),
            title: const Text('Todo List'),
            onTap: () => Navigator.pop(context, NoteType.todo),
          ),          ListTile(
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

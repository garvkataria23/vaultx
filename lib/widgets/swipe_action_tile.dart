import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

enum SwipeAction { pin, archive, share, move, delete }

class SwipeActionTile extends StatelessWidget {
  const SwipeActionTile({
    super.key,
    required this.child,
    required this.onAction,
    this.isPinned = false,
    this.isArchived = false,
    this.confirmDelete = true,
  });

  final Widget child;
  final Function(SwipeAction action) onAction;
  final bool isPinned;
  final bool isArchived;
  final bool confirmDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Slidable(
      key: ValueKey(child.hashCode),
      // Swipe Right actions (Reveal actions from left)
      startActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.4,
        children: [
          SlidableAction(
            onPressed: (_) => onAction(SwipeAction.pin),
            backgroundColor: Colors.amber,
            foregroundColor: Colors.white,
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            label: isPinned ? 'Unpin' : 'Pin',
          ),
          SlidableAction(
            onPressed: (_) => onAction(SwipeAction.archive),
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
            icon: isArchived ? Icons.unarchive : Icons.archive,
            label: isArchived ? 'Unarchive' : 'Archive',
          ),
        ],
      ),
      // Swipe Left actions (Reveal actions from right)
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.6,
        children: [
          SlidableAction(
            onPressed: (_) => onAction(SwipeAction.share),
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            icon: Icons.share,
            label: 'Share',
          ),
          SlidableAction(
            onPressed: (_) => onAction(SwipeAction.move),
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            icon: Icons.drive_file_move,
            label: 'Move',
          ),
          SlidableAction(
            onPressed: (_) async {
              if (confirmDelete) {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Confirm Delete'),
                    content: const Text('Are you sure you want to permanently delete this item?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(backgroundColor: cs.error),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) onAction(SwipeAction.delete);
              } else {
                onAction(SwipeAction.delete);
              }
            },
            backgroundColor: cs.error,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: 'Delete',
          ),
        ],
      ),
      child: child,
    );
  }
}

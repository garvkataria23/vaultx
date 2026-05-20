import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({
    super.key,
    required this.trashService,
  });

  final TrashService trashService;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashItem> _items = [];
  bool _loading = true;
  final Set<String> _selectedIds = {};
  bool _isMultiSelect = false;

  @override
  void initState() {
    super.initState();
    _load();
    AuditLog.write('TRASH OPENED');
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.trashService.loadAllTrash();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      _isMultiSelect = _selectedIds.isNotEmpty;
    });
  }

  void _selectAll() {
    setState(() {
      for (final item in _items) {
        _selectedIds.add(item.id);
      }
      _isMultiSelect = true;
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedIds.clear();
      _isMultiSelect = false;
    });
  }

  Future<void> _restoreSelected() async {
    final toRestore = _items.where((item) => _selectedIds.contains(item.id)).toList();
    for (final item in toRestore) {
      await widget.trashService.restore(item);
    }
    _selectedIds.clear();
    _isMultiSelect = false;
    await _load();
    FloatingNotificationService.instance.show('Items restored');
  }

  Future<void> _restoreAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore All'),
        content: const Text('Restore all items in trash?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore All')),
        ],
      ),
    );
    if (confirm == true) {
      for (final item in _items) {
        await widget.trashService.restore(item);
      }
      await _load();
      FloatingNotificationService.instance.show('All items restored');
    }
  }

  Future<void> _deleteSelectedForever() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Permanently'),
        content: Text('Delete ${_selectedIds.length} items forever? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final toDelete = _items.where((item) => _selectedIds.contains(item.id)).toList();
      for (final item in toDelete) {
        await widget.trashService.deleteForever(item);
      }
      _selectedIds.clear();
      _isMultiSelect = false;
      await _load();
      FloatingNotificationService.instance.show('Items permanently deleted');
    }
  }

  Future<void> _emptyTrash() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty Trash'),
        content: const Text('Permanently delete all items in trash? This action is irreversible.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Empty Trash'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.trashService.emptyTrash();
      await _load();
      FloatingNotificationService.instance.show('Trash emptied');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: _isMultiSelect 
          ? IconButton(icon: const Icon(Icons.close), onPressed: _deselectAll)
          : null,
        title: Text(_isMultiSelect ? '${_selectedIds.length} selected' : 'Trash'),
        actions: [
          if (_isMultiSelect) ...[
            IconButton(icon: const Icon(Icons.restore), onPressed: _restoreSelected, tooltip: 'Restore'),
            IconButton(icon: const Icon(Icons.delete_forever, color: Colors.red), onPressed: _deleteSelectedForever, tooltip: 'Delete forever'),
          ] else if (_items.isNotEmpty) ...[
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'restore_all') _restoreAll();
                if (v == 'empty_trash') _emptyTrash();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'restore_all', child: Text('Restore All')),
                const PopupMenuItem(
                  value: 'empty_trash', 
                  child: Text('Empty Trash', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _buildEmptyState(cs)
              : Column(
                  children: [
                    SelectionBanner(
                      selectedCount: _selectedIds.length,
                      totalCount: _items.length,
                      onSelectAll: _selectAll,
                      onClear: _deselectAll,
                      itemName: 'items',
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _items.length,
                        itemBuilder: (_, i) => _buildTrashCard(_items[i], cs),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.delete_outline, size: 72, color: cs.onSurface.withValues(alpha: 0.2)),
          const SizedBox(height: 16),
          Text(
            'Trash is empty',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 8),
          const Text('Deleted items will stay here for 30 days before being permanently removed.'),
        ],
      ),
    );
  }

  Widget _buildTrashCard(TrashItem item, ColorScheme cs) {
    final isSelected = _selectedIds.contains(item.id);
    final days = item.daysRemaining;
    
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: isSelected ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected ? BorderSide(color: cs.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () => _toggleSelect(item.id),
        onTap: () {
          if (_isMultiSelect) {
            _toggleSelect(item.id);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _buildTypeIcon(item, cs),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title.isEmpty ? 'Untitled' : item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Deleted ${_formatDate(item.deletedAt)} • $days days left',
                      style: TextStyle(
                        fontSize: 12, 
                        color: days <= 3 ? Colors.red : cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    if (item.vaultKind == VaultKind.hidden)
                       Padding(
                         padding: const EdgeInsets.only(top: 4),
                         child: Row(
                           children: [
                             Icon(Icons.visibility_off, size: 12, color: cs.primary),
                             const SizedBox(width: 4),
                             Text('Hidden Vault', style: TextStyle(fontSize: 10, color: cs.primary, fontWeight: FontWeight.bold)),
                           ],
                         ),
                       ),
                  ],
                ),
              ),
              if (!_isMultiSelect)
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'restore') {
                      await widget.trashService.restore(item);
                      _load();
                      FloatingNotificationService.instance.show('Item restored');
                    } else if (v == 'delete') {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete Permanently'),
                          content: const Text('This item will be deleted forever.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: Colors.red),
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await widget.trashService.deleteForever(item);
                        _load();
                        FloatingNotificationService.instance.show('Item permanently deleted');
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'restore', child: Text('Restore')),
                    const PopupMenuItem(
                      value: 'delete', 
                      child: Text('Delete Permanently', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              if (_isMultiSelect)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleSelect(item.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeIcon(TrashItem item, ColorScheme cs) {
    IconData iconData;
    Color iconColor;
    Color bgColor;

    if (item.type == 'note') {
      iconData = Icons.description;
      iconColor = cs.primary;
      bgColor = cs.primaryContainer.withValues(alpha: 0.3);
    } else if (item.type == 'folder') {
      iconData = Icons.folder;
      iconColor = Colors.orange;
      bgColor = Colors.orange.withValues(alpha: 0.1);
    } else {
      // file
      iconData = Icons.insert_drive_file;
      iconColor = cs.secondary;
      bgColor = cs.secondaryContainer.withValues(alpha: 0.3);
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(iconData, color: iconColor, size: 20),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

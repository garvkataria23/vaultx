import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({
    super.key,
    required this.trashService,
    required this.auth,
    this.repo,
  });

  final TrashService trashService;
  final VaultAuthService auth;
  final VaultRepository? repo;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashItem> _allItems = [];
  List<TrashItem> _filteredItems = [];
  bool _loading = true;
  final Set<String> _selectedIds = {};
  bool _isMultiSelect = false;
  
  String _searchQuery = '';
  String _filterType = 'all';
  String _sortBy = 'newest';

  Map<String, dynamic> _stats = {};

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
      final stats = await widget.trashService.getTrashStats();
      if (!mounted) return;
      setState(() {
        _allItems = items;
        _stats = stats;
        _applyFiltersAndSort();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _applyFiltersAndSort() {
    var items = List<TrashItem>.from(_allItems);

    // Filter
    if (_searchQuery.isNotEmpty) {
      items = items.where((i) => i.title.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    }
    if (_filterType != 'all') {
      if (_filterType == 'images') {
        items = items.where((i) => i.type == 'file' && (i.originalItem as SecureDriveFile).kind == 'image').toList();
      } else if (_filterType == 'videos') {
        items = items.where((i) => i.type == 'file' && (i.originalItem as SecureDriveFile).kind == 'video').toList();
      } else if (_filterType == 'documents') {
        items = items.where((i) => i.type == 'file' && ['document', 'pdf'].contains((i.originalItem as SecureDriveFile).kind)).toList();
      } else {
        items = items.where((i) => i.type == _filterType).toList();
      }
    }

    // Sort
    switch (_sortBy) {
      case 'oldest':
        items.sort((a, b) => a.deletedAt.compareTo(b.deletedAt));
        break;
      case 'size':
        items.sort((a, b) => b.size.compareTo(a.size));
        break;
      case 'name':
        items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case 'newest':
      default:
        items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
        break;
    }

    setState(() {
      _filteredItems = items;
    });
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
      for (final item in _filteredItems) {
        _selectedIds.add(item.id);
      }
      _isMultiSelect = true;
    });
  }

  void _selectNext50() {
    setState(() {
      int count = 0;
      for (final item in _filteredItems) {
        if (!_selectedIds.contains(item.id)) {
          _selectedIds.add(item.id);
          count++;
        }
        if (count >= 50) break;
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

  Future<bool> _authenticate() async {
    final bioEnabled = await widget.auth.isBiometricUnlockAvailable();
    if (bioEnabled) {
      if (await widget.auth.authenticateBiometric()) return true;
    }
    
    // Password fallback
    if (widget.repo == null) return false;
    final ctrl = TextEditingController();
    final secret = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Authorize Action'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Verify')),
        ],
      ),
    );
    if (secret == null || secret.isEmpty) return false;
    var result = widget.repo!.kind == VaultKind.hidden 
        ? await widget.auth.unlockHidden(secret) 
        : await widget.auth.unlockWithPassword(secret);
    result = await widget.auth.verify(result);
    return result.ok && result.kind == widget.repo!.kind;
  }

  Future<void> _restoreSelected() async {
    final toRestore = _allItems.where((item) => _selectedIds.contains(item.id)).toList();
    if (toRestore.isEmpty) return;

    bool needsAuth = toRestore.any((i) => i.vaultKind == VaultKind.hidden || i.type == 'password');
    if (needsAuth && !await _authenticate()) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore items?'),
        content: Text('Restore ${toRestore.length} selected ${toRestore.length == 1 ? 'item' : 'items'} to their original locations?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    int restoredCount = 0;
    int failCount = 0;
    for (final item in toRestore) {
      try {
        await widget.trashService.restore(item);
        restoredCount++;
      } catch (e) {
        failCount++;
        debugPrint('TRASH RESTORE ERROR: ${item.title}: $e');
      }
    }
    _selectedIds.clear();
    _isMultiSelect = false;
    await _load();
    if (mounted) {
      if (failCount == 0) {
        FloatingNotificationService.instance.show('${restoredCount} ${restoredCount == 1 ? 'item' : 'items'} restored');
      } else {
        FloatingNotificationService.instance.show(
          '$restoredCount restored, $failCount failed',
          error: true,
        );
      }
    }
  }

  Future<void> _deleteSelectedForever() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Permanently'),
        content: Text('Delete ${_selectedIds.length} items forever? This action is irreversible.'),
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
    if (confirm != true) return;

    if (!await _authenticate()) return;

    final toDelete = _allItems.where((item) => _selectedIds.contains(item.id)).toList();
    for (final item in toDelete) {
      await widget.trashService.deleteForever(item);
    }
    _selectedIds.clear();
    _isMultiSelect = false;
    await _load();
    FloatingNotificationService.instance.show('Items permanently deleted');
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
    if (confirm != true) return;

    if (!await _authenticate()) return;

    await widget.trashService.emptyTrash();
    await _load();
    FloatingNotificationService.instance.show('Trash emptied');
  }

  int _currentRetentionDays() =>
      Hive.box('vaultx_settings').get('trashRetentionDays', defaultValue: 30) as int;

  String _retentionLabel(int days) {
    if (days == 0) return 'Immediate';
    if (days == 1) return '1 Day';
    return '$days Days';
  }

  Future<void> _saveRetention(int days) async {
    final box = Hive.box('vaultx_settings');
    await box.put('trashRetentionDays', days);
    await widget.trashService.updateRetentionForAll(days);
    await _load();
    await AuditLog.write('TRASH RETENTION PERIOD UPDATED TO $days DAYS');
    if (!mounted) return;
    FloatingNotificationService.instance.show(
      days == 0
          ? 'Trash retention: Immediate — items will be permanently deleted'
          : 'Trash auto cleanup every $days days',
    );
  }

  void _showRetentionSheet() {
    final box = Hive.box('vaultx_settings');
    final current = box.get('trashRetentionDays', defaultValue: 30) as int;
    final presets = [30, 7, 15, 90, 0];
    bool isCustom = !presets.contains(current);
    int customVal = isCustom ? current : 30;
    final customCtrl = TextEditingController(text: isCustom ? '$customVal' : '');

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) {
          final cs = Theme.of(ctx).colorScheme;
          bool showingCustom = isCustom;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.auto_delete, color: cs.primary, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Auto Delete',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(
                            'Auto delete after: ${_retentionLabel(showingCustom ? customVal : current)}',
                            style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ...presets.map((d) {
                final sel = !showingCustom && current == d;
                return ListTile(
                  leading: Icon(
                    sel ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: sel ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
                    size: 22,
                  ),
                  title: Text(
                    d == 0 ? 'Immediately' : '$d Days',
                    style: TextStyle(
                      fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                      color: d == 0 && sel ? Colors.red : null,
                    ),
                  ),
                  subtitle: d == 0
                      ? Text('No recovery after delete',
                          style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5)))
                      : null,
                  trailing: sel
                      ? Icon(Icons.check, color: cs.primary, size: 20)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _saveRetention(d);
                  },
                );
              }),
              ListTile(
                leading: Icon(
                  showingCustom ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: showingCustom ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
                  size: 22,
                ),
                title: const Text('Custom Days'),
                trailing: showingCustom
                    ? Icon(Icons.check, color: cs.primary, size: 20)
                    : null,
                onTap: () {
                  setInner(() {
                    showingCustom = true;
                    isCustom = true;
                  });
                },
              ),
              if (showingCustom)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: customCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Enter days',
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            suffixText: 'days',
                            suffixStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: () {
                          final v = int.tryParse(customCtrl.text);
                          if (v == null || v <= 0) return;
                          Navigator.pop(ctx);
                          _saveRetention(v);
                        },
                        child: const Text('Apply'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
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
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'select_all') _selectAll();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'select_all',
                  child: Text(
                    _selectedIds.length >= _filteredItems.length
                        ? 'Deselect All'
                        : 'Select All',
                  ),
                ),
              ],
            ),
          ] else if (_allItems.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                showSearch(
                  context: context,
                  delegate: _TrashSearchDelegate(
                    items: _allItems,
                    onQueryChanged: (q) {
                      setState(() => _searchQuery = q);
                      _applyFiltersAndSort();
                    },
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.auto_delete),
              tooltip: 'Auto Delete',
              onPressed: _showRetentionSheet,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'empty_trash') _emptyTrash();
              },
              itemBuilder: (_) => [
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
          : _allItems.isEmpty
              ? _buildEmptyState(cs)
              : Column(
                  children: [
                    _buildStatsBanner(cs),
                    _buildFilterRow(cs),
                    if (_isMultiSelect)
                      SelectionBanner(
                        selectedCount: _selectedIds.length,
                        totalCount: _filteredItems.length,
                        onSelectAll: _selectAll,
                        onClear: _deselectAll,
                        itemName: 'items',
                      ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _filteredItems.length,
                        itemBuilder: (_, i) => _buildTrashCard(_filteredItems[i], cs),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildStatsBanner(ColorScheme cs) {
    final size = _stats['size'] as int? ?? 0;
    final count = _stats['count'] as int? ?? 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStatItem('Items', count.toString(), Icons.inventory_2_outlined, cs),
              const SizedBox(width: 24),
              _buildStatItem('Size', _formatSize(size), Icons.storage_outlined, cs),
            ],
          ),
          ...[
            const SizedBox(height: 8),
            Text(
              'Trash auto cleanup every ${_retentionLabel(_currentRetentionDays())}',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, ColorScheme cs) {
    return Row(
      children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text(label, style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.6))),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterRow(ColorScheme cs) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _buildFilterChip('all', 'All', cs),
          _buildFilterChip('note', 'Notes', cs),
          _buildFilterChip('file', 'Files', cs),
          _buildFilterChip('password', 'Passwords', cs),
          _buildFilterChip('images', 'Images', cs),
          _buildFilterChip('videos', 'Videos', cs),
          _buildFilterChip('documents', 'Docs', cs),
          const SizedBox(width: 12),
          const VerticalDivider(width: 24),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _sortBy,
            underline: const SizedBox(),
            style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w600),
            icon: Icon(Icons.sort, size: 18, color: cs.primary),
            onChanged: (v) {
              if (v != null) {
                setState(() => _sortBy = v);
                _applyFiltersAndSort();
              }
            },
            items: const [
              DropdownMenuItem(value: 'newest', child: Text('Newest')),
              DropdownMenuItem(value: 'oldest', child: Text('Oldest')),
              DropdownMenuItem(value: 'size', child: Text('Largest')),
              DropdownMenuItem(value: 'name', child: Text('Name')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label, ColorScheme cs) {
    final selected = _filterType == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (s) {
          setState(() => _filterType = value);
          _applyFiltersAndSort();
        },
        labelStyle: TextStyle(fontSize: 12, color: selected ? cs.onPrimary : cs.onSurface),
        selectedColor: cs.primary,
        padding: const EdgeInsets.symmetric(horizontal: 4),
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
          const Text('Items here will be permanently deleted after the retention period.'),
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
                      'Deleted ${_formatDate(item.deletedAt)} • ${item.originalFolder ?? 'Root'}',
                      style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5)),
                    ),
                    if (days >= 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '$days days until permanent deletion',
                          style: TextStyle(fontSize: 11, color: days <= 3 ? Colors.red : cs.onSurface.withValues(alpha: 0.4)),
                        ),
                      ),
                  ],
                ),
              ),
              if (!_isMultiSelect)
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'restore') {
                      bool needsAuth = item.vaultKind == VaultKind.hidden || item.type == 'password';
                      if (needsAuth && !await _authenticate()) return;
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
                      if (confirm != true) return;
                      if (!await _authenticate()) return;
                      await widget.trashService.deleteForever(item);
                      _load();
                      FloatingNotificationService.instance.show('Item permanently deleted');
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

    switch (item.type) {
      case 'note':
        iconData = Icons.description;
        iconColor = cs.primary;
        bgColor = cs.primaryContainer.withValues(alpha: 0.3);
        break;
      case 'folder':
        iconData = Icons.folder;
        iconColor = Colors.orange;
        bgColor = Colors.orange.withValues(alpha: 0.1);
        break;
      case 'password':
        iconData = Icons.lock_outline;
        iconColor = Colors.green;
        bgColor = Colors.green.withValues(alpha: 0.1);
        break;
      case 'file':
      default:
        final file = item.originalItem as SecureDriveFile;
        iconData = _getFileIcon(file.kind);
        iconColor = cs.secondary;
        bgColor = cs.secondaryContainer.withValues(alpha: 0.3);
        break;
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

  IconData _getFileIcon(String kind) {
    switch (kind) {
      case 'image': return Icons.image;
      case 'video': return Icons.videocam;
      case 'audio': return Icons.audiotrack;
      case 'pdf': return Icons.picture_as_pdf;
      case 'document': return Icons.description;
      default: return Icons.insert_drive_file;
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _TrashSearchDelegate extends SearchDelegate {
  final List<TrashItem> items;
  final Function(String) onQueryChanged;

  _TrashSearchDelegate({required this.items, required this.onQueryChanged});

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));
  }

  @override
  Widget buildResults(BuildContext context) {
    onQueryChanged(query);
    return const SizedBox();
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final results = items.where((i) => i.title.toLowerCase().contains(query.toLowerCase())).toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) => ListTile(
        title: Text(results[i].title),
        onTap: () {
          onQueryChanged(query);
          close(context, null);
        },
      ),
    );
  }
}

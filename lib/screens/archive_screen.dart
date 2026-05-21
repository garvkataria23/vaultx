import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';
import 'note_editor.dart';
import 'add_edit_password_screen.dart';

enum _ArchiveSort { dateArchived, name, type }

class _ArchiveItem {
  final String id;
  final String title;
  final String subtitle;
  final String type;
  final bool isPassword;
  final DateTime archivedAt;
  final SecureNote? note;
  final PasswordEntry? passwordEntry;

  _ArchiveItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.isPassword,
    required this.archivedAt,
    this.note,
    this.passwordEntry,
  });
}

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({
    super.key,
    required this.repo,
    required this.passwordVault,
    required this.auth,
  });

  final VaultRepository repo;
  final PasswordVaultService passwordVault;
  final VaultAuthService auth;

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<_ArchiveItem> _items = [];
  List<_ArchiveItem> _filtered = [];
  List<SecureNote> _allNotes = [];
  bool _loading = true;
  String _query = '';
  _ArchiveSort _sort = _ArchiveSort.dateArchived;
  final _searchCtrl = TextEditingController();
  final Set<String> _selectedIds = {};
  bool _isMultiSelect = false;

  @override
  void initState() {
    super.initState();
    _load();
    AuditLog.write('ARCHIVE OPENED');
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final notes = await widget.repo.loadNotes();
      _allNotes = notes;
      final archivedNotes = notes.where((n) => n.archived).toList();

      final archivedPasswords =
          await widget.passwordVault.loadArchivedEntries();

      final items = <_ArchiveItem>[];
      for (final n in archivedNotes) {
        items.add(_ArchiveItem(
          id: n.id,
          title: n.title.isEmpty ? 'Untitled' : n.title,
          subtitle: n.body,
          type: n.type.name,
          isPassword: false,
          archivedAt: n.updatedAt,
          note: n,
        ));
      }
      for (final p in archivedPasswords) {
        items.add(_ArchiveItem(
          id: p.id,
          title: p.serviceName.isEmpty ? 'Untitled' : p.serviceName,
          subtitle: p.username.isNotEmpty ? p.username : p.url,
          type: 'password',
          isPassword: true,
          archivedAt: p.archivedAt ?? p.updatedAt,
          passwordEntry: p,
        ));
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _applyFilter();
      });
      AuditLog.write('ARCHIVE QUERY RESULT COUNT ${items.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openNote(SecureNote note) async {
    final updated = note.copyWith(
      viewCount: note.viewCount + 1,
      lastViewedAt: DateTime.now(),
    );
    await widget.repo.save(updated);

    if (!mounted) return;
    final blobs = EncryptedBlobService(widget.repo.masterKey);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditor(
          note: updated,
          blobs: blobs,
          allNotes: _allNotes,
          onAutoSave: (edited) async {
            await widget.repo.save(edited);
          },
        ),
      ),
    );
    _load();
  }

  Future<void> _openPassword(PasswordEntry entry) async {
    final result = await Navigator.of(context).push<PasswordEntry>(
      MaterialPageRoute(
        builder: (_) => AddEditPasswordScreen(
          entry: entry,
          service: widget.passwordVault,
        ),
      ),
    );
    if (result != null && mounted) {
      await widget.passwordVault.save(result);
      _load();
    }
  }

  void _applyFilter() {
    var result = List<_ArchiveItem>.from(_items);

    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      result = result.where((item) {
        return item.title.toLowerCase().contains(q) ||
            item.subtitle.toLowerCase().contains(q) ||
            item.type.toLowerCase().contains(q);
      }).toList();
    }

    switch (_sort) {
      case _ArchiveSort.dateArchived:
        result.sort((a, b) => b.archivedAt.compareTo(a.archivedAt));
        break;
      case _ArchiveSort.name:
        result.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case _ArchiveSort.type:
        result.sort((a, b) {
          final typeCmp = a.type.compareTo(b.type);
          if (typeCmp != 0) return typeCmp;
          return b.archivedAt.compareTo(a.archivedAt);
        });
        break;
    }

    _filtered = result;
  }

  Future<bool> _authenticateForAction(String title) async {
    // Enable screen protection during sensitive operations
    await SecurityPlatform.enableScreenProtection();

    final bioEnabled = await widget.auth.isBiometricUnlockAvailable();
    if (bioEnabled) {
      final ok = await widget.auth.authenticateBiometric();
      if (ok) return true;
    }

    if (!mounted) return false;

    // Fallback to password/PIN
    final ctrl = TextEditingController();
    final secret = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your ${widget.repo.kind == VaultKind.hidden ? 'hidden vault' : 'master'} password to continue.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.repo.kind == VaultKind.hidden
                    ? 'Hidden vault password'
                    : 'Master password',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (val) => Navigator.of(dialogCtx).pop(val),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(ctrl.text),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (secret == null || secret.isEmpty) return false;
    
    var result = widget.repo.kind == VaultKind.hidden
        ? await widget.auth.unlockHidden(secret)
        : await widget.auth.unlockWithPassword(secret);
    
    result = await widget.auth.verify(result);
    final success = result.ok && result.kind == widget.repo.kind;
    
    if (!success && mounted) {
      FloatingNotificationService.instance.show('Authentication failed: Invalid password', error: true);
    }
    
    return success;
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
      for (final item in _filtered) {
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

  Future<void> _bulkAction(String action) async {
    final selectedItems = _items.where((item) => _selectedIds.contains(item.id)).toList();
    if (selectedItems.isEmpty) return;

    final authenticated = await _authenticateForAction('Bulk $action');
    if (!authenticated) return;

    if (action == 'restore') {
      for (final item in selectedItems) {
        if (item.isPassword && item.passwordEntry != null) {
          await widget.passwordVault.save(item.passwordEntry!.copyWith(archived: false));
        } else if (item.note != null) {
          await widget.repo.save(item.note!.copyWith(archived: false));
        }
      }
      FloatingNotificationService.instance.show('${selectedItems.length} items restored');
    } else if (action == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Move ${selectedItems.length} items to Trash?'),
          content: const Text('Selected items will be moved to trash.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true), 
              child: const Text('Move to Trash'),
            ),
          ],
        ),
      );
      if (confirm == true) {
        for (final item in selectedItems) {
          if (item.isPassword && item.passwordEntry != null) {
            await widget.passwordVault.moveToTrash(item.passwordEntry!);
          } else if (item.note != null) {
            await widget.repo.moveToTrash(item.note!);
          }
        }
        FloatingNotificationService.instance.show('${selectedItems.length} items moved to trash');
      }
    }

    _deselectAll();
    await _load();
  }

  Future<void> _restoreNote(SecureNote note) async {
    await widget.repo.save(note.copyWith(archived: false));
    await AuditLog.write('ITEM RESTORED note ${note.id}');
    await _load();
  }

  Future<void> _restorePassword(PasswordEntry entry) async {
    await widget.passwordVault.save(entry.copyWith(archived: false));
    await AuditLog.write('ITEM RESTORED password ${entry.id}');
    await _load();
  }

  Future<void> _deleteNote(SecureNote note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Trash'),
        content: Text('Move "${note.title}" to trash?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await widget.repo.moveToTrash(note);
      if (!mounted) return;
      FloatingNotificationService.instance.show('Note moved to trash');
      await _load();
    }
  }

  Future<void> _deletePassword(PasswordEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Trash'),
        content: Text('Move "${entry.serviceName}" to trash?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await widget.passwordVault.moveToTrash(entry);
      if (!mounted) return;
      FloatingNotificationService.instance.show('Password moved to trash');
      await _load();
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
        title: Text(_isMultiSelect ? '${_selectedIds.length} selected' : 'Archive'),
        actions: [
          if (_isMultiSelect) ...[
            IconButton(icon: const Icon(Icons.unarchive), onPressed: () => _bulkAction('restore'), tooltip: 'Restore'),
            IconButton(icon: const Icon(Icons.delete_forever, color: Colors.red), onPressed: () => _bulkAction('delete'), tooltip: 'Delete forever'),
          ] else ...[
            PopupMenuButton<_ArchiveSort>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort',
              onSelected: (s) {
                setState(() {
                  _sort = s;
                  _applyFilter();
                });
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: _ArchiveSort.dateArchived,
                  checked: _sort == _ArchiveSort.dateArchived,
                  child: const Text('Date archived'),
                ),
                CheckedPopupMenuItem(
                  value: _ArchiveSort.name,
                  checked: _sort == _ArchiveSort.name,
                  child: const Text('Name'),
                ),
                CheckedPopupMenuItem(
                  value: _ArchiveSort.type,
                  checked: _sort == _ArchiveSort.type,
                  child: const Text('Type'),
                ),
              ],
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SelectionBanner(
                  selectedCount: _selectedIds.length,
                  totalCount: _filtered.length,
                  onSelectAll: _selectAll,
                  onClear: _deselectAll,
                  itemName: 'items',
                ),
                if (_items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search archived items\u2026',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() {
                                    _query = '';
                                    _applyFilter();
                                  });
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (v) {
                        setState(() {
                          _query = v;
                          _applyFilter();
                        });
                      },
                    ),
                  ),
                Expanded(
                  child: _filtered.isEmpty
                      ? _buildEmptyState(cs)
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) =>
                              _buildItemCard(_filtered[i], cs),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    final hasAny = _items.isNotEmpty;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasAny ? Icons.search_off : Icons.archive_outlined,
            size: 72,
            color: cs.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            hasAny ? 'No matching archived items' : 'Archive is empty',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasAny
                ? 'Try a different search term'
                : 'Archived notes and passwords will appear here',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(_ArchiveItem item, ColorScheme cs) {
    final isSelected = _selectedIds.contains(item.id);

    return SwipeActionTile(
      isArchived: true,
      onAction: (action) {
        if (action == SwipeAction.archive) {
          // In archive screen, swipe archive means restore
          final p = item.passwordEntry;
          final n = item.note;
          if (item.isPassword && p != null) {
            _restorePassword(p);
          } else if (n != null) {
            _restoreNote(n);
          }
        } else if (action == SwipeAction.delete) {
          final p = item.passwordEntry;
          final n = item.note;
          if (item.isPassword && p != null) {
            _deletePassword(p);
          } else if (n != null) {
            _deleteNote(n);
          }
        }
      },
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: isSelected ? cs.primaryContainer.withValues(alpha: 0.7) : null,
        child: InkWell(
          onTap: () {
            if (_isMultiSelect) {
              _toggleSelect(item.id);
            } else {
              if (item.isPassword && item.passwordEntry != null) {
                _openPassword(item.passwordEntry!);
              } else if (item.note != null) {
                _openNote(item.note!);
              }
            }
          },
          onLongPress: () {
            HapticFeedback.heavyImpact();
            _toggleSelect(item.id);
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isSelected 
                        ? cs.primary 
                        : (item.isPassword
                          ? cs.tertiaryContainer.withValues(alpha: 0.3)
                          : cs.primaryContainer.withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isSelected ? Icons.check : (item.isPassword ? Icons.lock : Icons.description),
                    color: isSelected ? cs.onPrimary : (item.isPassword ? cs.tertiary : cs.primary),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: isSelected ? cs.onPrimaryContainer : null,
                        ),
                      ),
                      if (item.subtitle.isNotEmpty)
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isSelected 
                                ? cs.onPrimaryContainer.withValues(alpha: 0.6)
                                : cs.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _ArchiveTypeBadge(type: item.type, cs: cs, isSelected: isSelected),
                          const SizedBox(width: 8),
                          Text(
                            _formatDate(item.archivedAt),
                            style: TextStyle(
                              fontSize: 11,
                              color: isSelected 
                                  ? cs.onPrimaryContainer.withValues(alpha: 0.6)
                                  : cs.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!_isMultiSelect) ...[
                  IconButton(
                    icon: Icon(Icons.unarchive, color: cs.primary),
                    tooltip: 'Restore',
                    onPressed: () {
                      if (item.isPassword && item.passwordEntry != null) {
                        _restorePassword(item.passwordEntry!);
                      } else if (item.note != null) {
                        _restoreNote(item.note!);
                      }
                    },
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'delete') {
                        if (item.isPassword && item.passwordEntry != null) {
                          _deletePassword(item.passwordEntry!);
                        } else if (item.note != null) {
                          _deleteNote(item.note!);
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_forever, color: Colors.red),
                          title: Text(
                            'Delete permanently',
                            style: TextStyle(color: Colors.red),
                          ),
                          dense: true,
                        ),
                      ),
                    ],
                  ),
                ] else
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleSelect(item.id),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

class _ArchiveTypeBadge extends StatelessWidget {
  const _ArchiveTypeBadge({required this.type, required this.cs, this.isSelected = false});
  final String type;
  final ColorScheme cs;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected 
            ? cs.onPrimaryContainer.withValues(alpha: 0.1)
            : cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        type == 'password' ? 'Password' : type,
        style: TextStyle(
          fontSize: 11,
          color: isSelected ? cs.onPrimaryContainer : cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

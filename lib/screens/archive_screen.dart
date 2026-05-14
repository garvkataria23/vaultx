import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../widgets/swipe_action_tile.dart';

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
  });

  final VaultRepository repo;
  final PasswordVaultService passwordVault;

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<_ArchiveItem> _items = [];
  List<_ArchiveItem> _filtered = [];
  bool _loading = true;
  String _query = '';
  _ArchiveSort _sort = _ArchiveSort.dateArchived;
  final _searchCtrl = TextEditingController();

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
        title: const Text('Delete permanently'),
        content: Text('Permanently delete "${note.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await widget.repo.secureDelete(note);
      if (!mounted) return;
      FloatingNotificationService.instance.show('Note permanently deleted');
      await _load();
    }
  }

  Future<void> _deletePassword(PasswordEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete permanently'),
        content: Text('Permanently delete "${entry.serviceName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await widget.passwordVault.delete(entry.id);
      if (!mounted) return;
      FloatingNotificationService.instance.show('Password permanently deleted');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archive'),
        actions: [
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
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
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
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: item.isPassword
                      ? cs.tertiaryContainer.withValues(alpha: 0.3)
                      : cs.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  item.isPassword ? Icons.lock : Icons.description,
                  color: item.isPassword ? cs.tertiary : cs.primary,
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
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (item.subtitle.isNotEmpty)
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _ArchiveTypeBadge(type: item.type, cs: cs),
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(item.archivedAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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
            ],
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
  const _ArchiveTypeBadge({required this.type, required this.cs});
  final String type;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        type == 'password' ? 'Password' : type,
        style: TextStyle(
          fontSize: 11,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

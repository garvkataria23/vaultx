import 'dart:async';

import 'package:flutter/material.dart';
import '../services/services.dart';
import 'package:flutter/services.dart';

import '../models/password_entry.dart';
import 'add_edit_password_screen.dart';
import '../widgets/swipe_action_tile.dart';

enum _PwSort { newest, alphabetical, recentlyUsed }

class PasswordManagerScreen extends StatefulWidget {
  const PasswordManagerScreen({super.key, required this.service});

  final PasswordVaultService service;

  @override
  State<PasswordManagerScreen> createState() => _PasswordManagerScreenState();
}

class _PasswordManagerScreenState extends State<PasswordManagerScreen> {
  List<PasswordEntry> _entries = [];
  List<PasswordEntry> _filtered = [];
  bool _loading = true;
  String _query = '';
  _PwSort _sort = _PwSort.newest;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final entries = await widget.service.loadActiveEntries();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _applyFilter();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    var result = List<PasswordEntry>.from(_entries);

    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      result = result.where((e) {
        return e.serviceName.toLowerCase().contains(q) ||
            e.username.toLowerCase().contains(q) ||
            e.url.toLowerCase().contains(q) ||
            e.tags.any((t) => t.toLowerCase().contains(q));
      }).toList();
    }

    switch (_sort) {
      case _PwSort.newest:
        result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        break;
      case _PwSort.alphabetical:
        result.sort((a, b) =>
            a.serviceName.toLowerCase().compareTo(b.serviceName.toLowerCase()));
        break;
      case _PwSort.recentlyUsed:
        result.sort((a, b) {
          final aTime = a.lastUsedAt ?? a.updatedAt;
          final bTime = b.lastUsedAt ?? b.updatedAt;
          return bTime.compareTo(aTime);
        });
        break;
    }

    _filtered = result;
  }

  Future<void> _openAdd() async {
    final blank = await widget.service.createBlank();
    if (!mounted) return;
    final result = await Navigator.of(context).push<PasswordEntry>(
      MaterialPageRoute(
        builder: (_) =>
            AddEditPasswordScreen(entry: blank, service: widget.service),
      ),
    );
    if (result != null && mounted) {
      await widget.service.save(result);
      await _load();
    }
  }

  Future<void> _openEdit(PasswordEntry entry) async {
    final result = await Navigator.of(context).push<PasswordEntry>(
      MaterialPageRoute(
        builder: (_) =>
            AddEditPasswordScreen(entry: entry, service: widget.service),
      ),
    );
    if (result != null && mounted) {
      await widget.service.save(result);
      await _load();
    }
  }

  Future<void> _deleteEntry(PasswordEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete password'),
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
      await widget.service.delete(entry.id);
      await _load();
    }
  }

  Future<void> _copyPassword(String password) async {
    await ClipboardGuard.copySensitive(password);
    if (!mounted) return;
    context.showFloatingNotification('Password copied — auto-cleared after 30s');
  }

  Future<void> _copyUsername(String username) async {
    await Clipboard.setData(ClipboardData(text: username));
    if (!mounted) return;
    FloatingNotificationService.instance.show('Username copied');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Password Manager'),
        actions: [
          PopupMenuButton<_PwSort>(
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
                value: _PwSort.newest,
                checked: _sort == _PwSort.newest,
                child: const Text('Newest'),
              ),
              CheckedPopupMenuItem(
                value: _PwSort.alphabetical,
                checked: _sort == _PwSort.alphabetical,
                child: const Text('Alphabetical'),
              ),
              CheckedPopupMenuItem(
                value: _PwSort.recentlyUsed,
                checked: _sort == _PwSort.recentlyUsed,
                child: const Text('Recently Used'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_entries.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search passwords\u2026',
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
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) =>
                              _buildEntryCard(_filtered[i], cs),
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'passwordManagerFab',
        onPressed: _openAdd,
        icon: const Icon(Icons.lock),
        label: const Text('Add Password'),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            size: 72,
            color: cs.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'No saved passwords yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to add your first password entry',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
          ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: _openAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add Password'),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(PasswordEntry entry, ColorScheme cs) {
    return SwipeActionTile(
      isPinned: entry.favorite,
      isArchived: entry.archived,
      onAction: (action) {
        switch (action) {
          case SwipeAction.pin:
            widget.service.save(entry.copyWith(favorite: !entry.favorite)).then((_) => _load());
          case SwipeAction.archive:
            widget.service.save(entry.copyWith(
              archived: !entry.archived,
              archivedAt: !entry.archived ? DateTime.now() : null,
            )).then((_) => _load());
          case SwipeAction.share:
            _copyPassword(entry.password);
          case SwipeAction.move:
            _openEdit(entry);
          case SwipeAction.delete:
            _deleteEntry(entry);
        }
      },
      child: _PasswordEntryCard(
        entry: entry,
        onEdit: () => _openEdit(entry),
        onDelete: () => _deleteEntry(entry),
        onCopyPassword: () => _copyPassword(entry.password),
        onCopyUsername: () => _copyUsername(entry.username),
      ),
    );
  }
}

class _PasswordEntryCard extends StatefulWidget {
  const _PasswordEntryCard({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
    required this.onCopyPassword,
    required this.onCopyUsername,
  });

  final PasswordEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCopyPassword;
  final VoidCallback onCopyUsername;

  @override
  State<_PasswordEntryCard> createState() => _PasswordEntryCardState();
}

class _PasswordEntryCardState extends State<_PasswordEntryCard> {
  var _revealed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entry = widget.entry;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onEdit,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Service name row
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.lock, color: cs.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.serviceName.isEmpty
                              ? 'Untitled'
                              : entry.serviceName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        if (entry.username.isNotEmpty)
                          Text(
                            entry.username,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'copy_user':
                          widget.onCopyUsername();
                        case 'copy_pass':
                          widget.onCopyPassword();
                        case 'edit':
                          widget.onEdit();
                        case 'delete':
                          widget.onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'copy_user',
                        child: ListTile(
                          leading: Icon(Icons.person),
                          title: Text('Copy username'),
                          dense: true,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'copy_pass',
                        child: ListTile(
                          leading: Icon(Icons.content_copy),
                          title: Text('Copy password'),
                          dense: true,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit),
                          title: Text('Edit'),
                          dense: true,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete, color: Colors.red),
                          title: Text(
                            'Delete',
                            style: TextStyle(color: Colors.red),
                          ),
                          dense: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Password field
              if (entry.password.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _revealed
                              ? entry.password
                              : '•' * entry.password.length.clamp(8, 30),
                          style: TextStyle(
                            fontFamily: _revealed ? null : 'monospace',
                            fontSize: 14,
                            letterSpacing: _revealed ? 0 : 2,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _revealed
                              ? Icons.visibility_off
                              : Icons.visibility,
                          size: 18,
                        ),
                        onPressed: () =>
                            setState(() => _revealed = !_revealed),
                        tooltip: _revealed ? 'Hide' : 'Reveal',
                      ),
                      IconButton(
                        icon: const Icon(Icons.content_copy, size: 18),
                        onPressed: widget.onCopyPassword,
                        tooltip: 'Copy',
                      ),
                    ],
                  ),
                ),

              // Tags and metadata
              if (entry.tags.isNotEmpty || entry.url.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (entry.url.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.link,
                          size: 14,
                          color: cs.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ...entry.tags.map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.tertiaryContainer.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            t,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

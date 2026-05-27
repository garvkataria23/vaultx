import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/note_views_renderer.dart';

enum SmartCategory {
  recent('Recent Notes', Icons.history, 'Recently updated or viewed'),
  pinned('Pinned Notes', Icons.push_pin, 'Important notes pinned to top'),
  aiSuggested('AI Suggested', Icons.auto_awesome, 'Notes with summaries or OCR'),
  frequentlyOpened('Frequently Opened', Icons.bolt, 'Your most accessed notes'),
  large('Large Notes', Icons.storage, 'Notes with significant content or attachments'),
  unread('Unread Notes', Icons.mark_as_unread, 'Notes you haven\'t opened recently'),
  today('Today', Icons.today, 'Created or updated today'),
  thisWeek('This Week', Icons.calendar_view_week, 'Created or updated this week'),
  media('Media Notes', Icons.perm_media, 'Notes with images, voice, or drawings');

  final String label;
  final IconData icon;
  final String description;

  const SmartCategory(this.label, this.icon, this.description);
}

enum _SmartSortBy { category, newest, oldest, alphabetical }

class SmartViewScreen extends StatefulWidget {
  const SmartViewScreen({
    super.key,
    required this.notes,
    required this.repo,
    required this.blobs,
    this.vaultKind = VaultKind.main,
  });

  final List<SecureNote> notes;
  final VaultRepository? repo;
  final EncryptedBlobService? blobs;
  final VaultKind vaultKind;

  @override
  State<SmartViewScreen> createState() => _SmartViewScreenState();
}

class _SmartViewScreenState extends State<SmartViewScreen> {
  SmartCategory? _selectedCategory;
  List<SecureNote> _filteredNotes = [];
  NoteViewMode _viewMode = NoteViewMode.grid;

  // Filter state
  Set<NoteType> _typeFilter = {};
  String? _folderFilter;
  _SmartSortBy _sortBy = _SmartSortBy.category;

  bool get _filtersActive =>
      _typeFilter.isNotEmpty ||
      _folderFilter != null;

  List<String> get _allFolders =>
      widget.notes.map((n) => n.folder).toSet().toList()..sort();

  @override
  void initState() {
    super.initState();
    _selectCategory(SmartCategory.recent);
  }

  void _selectCategory(SmartCategory category) {
    setState(() {
      _selectedCategory = category;
      _filteredNotes = _applyFilters(category);
    });
  }

  List<SecureNote> _applyFilters(SmartCategory category) {
    final now = DateTime.now();
    var notes = widget.notes.where((n) => !n.archived && !n.deleted).toList();

    if (_typeFilter.isNotEmpty) {
      notes = notes.where((n) => _typeFilter.contains(n.type)).toList();
    }

    if (_folderFilter != null) {
      notes = notes.where((n) => n.folder == _folderFilter).toList();
    }

    switch (category) {
      case SmartCategory.recent:
        notes..sort((a, b) {
          final timeA = a.lastOpenedAt ?? a.updatedAt;
          final timeB = b.lastOpenedAt ?? b.updatedAt;
          return timeB.compareTo(timeA);
        });
      case SmartCategory.pinned:
        notes = notes.where((n) => n.pinned).toList();
      case SmartCategory.aiSuggested:
        notes = notes.where((n) => n.summary.isNotEmpty || n.ocrText.isNotEmpty || n.transcript.isNotEmpty).toList();
      case SmartCategory.frequentlyOpened:
        notes = notes.where((n) => n.viewCount > 0).toList()
          ..sort((a, b) => b.viewCount.compareTo(a.viewCount));
      case SmartCategory.large:
        notes..sort((a, b) {
          final sizeA = a.body.length + a.attachments.fold(0, (sum, att) => sum + att.size);
          final sizeB = b.body.length + b.attachments.fold(0, (sum, att) => sum + att.size);
          return sizeB.compareTo(sizeA);
        });
      case SmartCategory.unread:
        notes = notes.where((n) => n.viewCount == 0).toList();
      case SmartCategory.today:
        notes = notes.where((n) => 
          (n.createdAt.year == now.year && n.createdAt.month == now.month && n.createdAt.day == now.day) ||
          (n.updatedAt.year == now.year && n.updatedAt.month == now.month && n.updatedAt.day == now.day)
        ).toList();
      case SmartCategory.thisWeek:
        final weekAgo = now.subtract(const Duration(days: 7));
        notes = notes.where((n) => n.updatedAt.isAfter(weekAgo) || n.createdAt.isAfter(weekAgo)).toList();
      case SmartCategory.media:
        notes = notes.where((n) => n.attachments.isNotEmpty || n.type != NoteType.text).toList();
    }

    if (_sortBy != _SmartSortBy.category) {
      switch (_sortBy) {
        case _SmartSortBy.newest:
          notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        case _SmartSortBy.oldest:
          notes.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
        case _SmartSortBy.alphabetical:
          notes.sort((a, b) => a.title.compareTo(b.title));
        case _SmartSortBy.category:
          break;
      }
    }

    return notes;
  }

  Future<void> _openNote(SecureNote note) async {
    await NavigationService.openNote(
      context: context,
      note: note,
      repo: widget.repo,
      blobs: widget.blobs,
      allNotes: widget.notes,
      onSave: (edited) async {
        if (widget.repo != null) {
          await widget.repo!.save(edited);
        }
      },
    );
    
    _selectCategory(_selectedCategory!);
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SmartFilterSheet(
        typeFilter: _typeFilter,
        folderFilter: _folderFilter,
        sortBy: _sortBy,
        allFolders: _allFolders,
        onApply: (types, folder, sort) {
          setState(() {
            _typeFilter = types;
            _folderFilter = folder;
            _sortBy = sort;
            _filteredNotes = _applyFilters(_selectedCategory!);
          });
          Navigator.of(ctx).pop();
        },
        onReset: () {
          setState(() {
            _typeFilter = {};
            _folderFilter = null;
            _sortBy = _SmartSortBy.category;
            _filteredNotes = _applyFilters(_selectedCategory!);
          });
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Smart View',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (_filtersActive)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_typeFilter.length + (_folderFilter != null ? 1 : 0)}',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onPrimaryContainer),
                          ),
                        ),
                      ),
                    Stack(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.filter_list),
                          onPressed: _showFilterSheet,
                          tooltip: 'Filters',
                        ),
                        if (_filtersActive)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                    IconButton(
                      icon: Icon(noteViewIcons[_viewMode]),
                      onPressed: () {
                        setState(() {
                          _viewMode = _viewMode == NoteViewMode.grid ? NoteViewMode.list : NoteViewMode.grid;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  _buildCategorySelector(cs),
                  const Divider(height: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 32),
                      child: NoteViewsRenderer(
                        mode: _viewMode,
                        notes: _filteredNotes,
                        blobs: widget.blobs,
                        onTap: _openNote,
                        onToggleFavorite: (n) async {
                          if (widget.repo != null) {
                            await widget.repo!.save(n.copyWith(favorite: !n.favorite));
                            _selectCategory(_selectedCategory!);
                          }
                        },
                        onTogglePin: (n) async {
                          if (widget.repo != null) {
                            await widget.repo!.save(n.copyWith(pinned: !n.pinned));
                            _selectCategory(_selectedCategory!);
                          }
                        },
                        categories: const {},
                        hasMore: false,
                        onLoadMore: () {},
                        onDelete: (n) {},
                        onToggleArchive: (n) {},
                        onToggleLock: (n) {},
                        onShare: (n) {},
                        onMove: (n) {},
                        padding: EdgeInsets.fromLTRB(
                          16,
                          16,
                          16,
                          MediaQuery.of(context).viewPadding.bottom + 80,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategorySelector(ColorScheme cs) {
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        itemCount: SmartCategory.values.length,
        itemBuilder: (context, index) {
          final cat = SmartCategory.values[index];
          final isSelected = _selectedCategory == cat;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkWell(
              onTap: () => _selectCategory(cat),
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 80,
                decoration: BoxDecoration(
                  color: isSelected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? cs.primary : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      cat.icon,
                      size: 20,
                      color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      cat.label.split(' ')[0],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SmartFilterSheet extends StatefulWidget {
  final Set<NoteType> typeFilter;
  final String? folderFilter;
  final _SmartSortBy sortBy;
  final List<String> allFolders;
  final void Function(Set<NoteType>, String?, _SmartSortBy) onApply;
  final VoidCallback onReset;

  const _SmartFilterSheet({
    required this.typeFilter,
    required this.folderFilter,
    required this.sortBy,
    required this.allFolders,
    required this.onApply,
    required this.onReset,
  });

  @override
  State<_SmartFilterSheet> createState() => _SmartFilterSheetState();
}

class _SmartFilterSheetState extends State<_SmartFilterSheet> {
  late Set<NoteType> _types;
  late String? _folder;
  late _SmartSortBy _sort;

  @override
  void initState() {
    super.initState();
    _types = Set.from(widget.typeFilter);
    _folder = widget.folderFilter;
    _sort = widget.sortBy;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 440,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Filters',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onReset,
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: [
                  Text('Note Type', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: NoteType.values.map((t) {
                      final selected = _types.contains(t);
                      return FilterChip(
                        label: Text(t.name[0].toUpperCase() + t.name.substring(1)),
                        selected: selected,
                        onSelected: (val) {
                          setState(() {
                            if (val) { _types.add(t); } else { _types.remove(t); }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  Text('Folder', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    value: _folder,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All folders')),
                      ...widget.allFolders.map((f) =>
                        DropdownMenuItem(value: f, child: Text(f))),
                    ],
                    onChanged: (v) => setState(() => _folder = v),
                  ),
                  const SizedBox(height: 20),
                  Text('Sort By', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _SmartSortBy.values.map((s) {
                      final selected = _sort == s;
                      return ChoiceChip(
                        label: Text(_sortLabel(s)),
                        selected: selected,
                        onSelected: (_) => setState(() => _sort = s),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => widget.onApply(_types, _folder, _sort),
                  child: const Text('Apply Filters'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _sortLabel(_SmartSortBy s) {
    switch (s) {
      case _SmartSortBy.category: return 'Category';
      case _SmartSortBy.newest: return 'Newest';
      case _SmartSortBy.oldest: return 'Oldest';
      case _SmartSortBy.alphabetical: return 'A-Z';
    }
  }
}

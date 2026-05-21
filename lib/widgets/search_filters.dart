import 'package:flutter/material.dart';

/// Filter options available in the smart search.
enum FilterChipType {
  type,
  folder,
  sort,
  pinned,
  favorite,
  attachments,
  category,
}

/// Animated filter chips bar for the smart search interface.
class SearchFiltersBar extends StatefulWidget {
  const SearchFiltersBar({
    super.key,
    this.activeFilters = const {},
    this.selectedType,
    this.selectedFolder,
    this.selectedSort,
    this.selectedCategory,
    this.selectedPinned,
    this.selectedFavorite,
    this.selectedAttachments,
    this.folders = const [],
    this.categories = const [],
    this.onFilterChanged,
    this.onClearAll,
  });

  final Set<FilterChipType> activeFilters;
  final String? selectedType;
  final String? selectedFolder;
  final String? selectedSort;
  final String? selectedCategory;
  final bool? selectedPinned;
  final bool? selectedFavorite;
  final bool? selectedAttachments;
  final List<String> folders;
  final List<String> categories;
  final void Function(FilterChipType type, dynamic value)? onFilterChanged;
  final VoidCallback? onClearAll;

  @override
  State<SearchFiltersBar> createState() => _SearchFiltersBarState();
}

class _SearchFiltersBarState extends State<SearchFiltersBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<double> _expandAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _expandAnim = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutCubic,
    );
    if (widget.activeFilters.isNotEmpty) _animCtrl.forward();
  }

  @override
  void didUpdateWidget(SearchFiltersBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeFilters.isNotEmpty && !_animCtrl.isAnimating) {
      _animCtrl.forward();
    } else if (widget.activeFilters.isEmpty && _animCtrl.isCompleted) {
      _animCtrl.reverse();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SizeTransition(
      sizeFactor: _expandAnim,
      axisAlignment: -1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 2),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _buildTypeChip(cs),
                if (widget.folders.length > 1) _buildFolderChip(cs),
                _buildSortChip(cs),
                _buildCategoryChip(cs),
                _buildPinnedChip(cs),
                _buildFavoriteChip(cs),
                _buildAttachmentsChip(cs),
                if (_hasAnyActive)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ActionChip(
                      avatar: Icon(Icons.clear_all, size: 16, color: cs.error),
                      label: Text(
                        'Clear',
                        style: TextStyle(fontSize: 12, color: cs.error),
                      ),
                      onPressed: widget.onClearAll,
                      backgroundColor: cs.errorContainer.withValues(alpha: 0.2),
                      side: BorderSide(color: cs.error.withValues(alpha: 0.3)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool get _hasAnyActive =>
      widget.selectedType != null ||
      widget.selectedCategory != null ||
      widget.selectedPinned != null ||
      widget.selectedFavorite != null ||
      widget.selectedAttachments != null;

  Widget _buildTypeChip(ColorScheme cs) {
    final label = widget.selectedType ?? 'All types';
    final isActive = widget.selectedType != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isActive,
        avatar: Icon(Icons.description, size: 15),
        onSelected: (v) => _showTypePicker(cs),
        selectedColor: cs.primaryContainer,
        checkmarkColor: cs.onPrimaryContainer,
      ),
    );
  }

  Widget _buildFolderChip(ColorScheme cs) {
    final label = widget.selectedFolder ?? 'Folders';
    final isActive = widget.selectedFolder != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isActive,
        avatar: Icon(Icons.folder, size: 15),
        onSelected: (v) => _showFolderPicker(cs),
        selectedColor: cs.primaryContainer,
        checkmarkColor: cs.onPrimaryContainer,
      ),
    );
  }

  Widget _buildSortChip(ColorScheme cs) {
    final labels = {'date': 'Date', 'title': 'Title', 'priority': 'Priority'};
    final label = labels[widget.selectedSort] ?? 'Date';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: true,
        avatar: Icon(Icons.sort, size: 15),
        onSelected: (v) => _showSortPicker(cs),
        selectedColor: cs.secondaryContainer,
        checkmarkColor: cs.onSecondaryContainer,
      ),
    );
  }

  Widget _buildCategoryChip(ColorScheme cs) {
    if (widget.categories.isEmpty) return const SizedBox.shrink();
    final label = widget.selectedCategory ?? 'Category';
    final isActive = widget.selectedCategory != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isActive,
        avatar: Icon(Icons.category, size: 15),
        onSelected: (v) => _showCategoryPicker(cs),
        selectedColor: cs.primaryContainer,
        checkmarkColor: cs.onPrimaryContainer,
      ),
    );
  }

  Widget _buildPinnedChip(ColorScheme cs) {
    final isActive = widget.selectedPinned != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          isActive
              ? (widget.selectedPinned! ? 'Pinned' : 'Unpinned')
              : 'Pinned',
          style: const TextStyle(fontSize: 12),
        ),
        selected: isActive,
        avatar: Icon(Icons.push_pin, size: 15),
        onSelected: (v) {
          if (isActive) {
            widget.onFilterChanged?.call(FilterChipType.pinned, null);
          } else {
            widget.onFilterChanged?.call(FilterChipType.pinned, true);
          }
        },
        selectedColor: cs.primaryContainer,
        checkmarkColor: cs.onPrimaryContainer,
      ),
    );
  }

  Widget _buildFavoriteChip(ColorScheme cs) {
    final isActive = widget.selectedFavorite != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          isActive
              ? (widget.selectedFavorite! ? 'Favorites' : 'Unfaved')
              : 'Favorites',
          style: const TextStyle(fontSize: 12),
        ),
        selected: isActive,
        avatar: Icon(Icons.star, size: 15),
        onSelected: (v) {
          if (isActive) {
            widget.onFilterChanged?.call(FilterChipType.favorite, null);
          } else {
            widget.onFilterChanged?.call(FilterChipType.favorite, true);
          }
        },
        selectedColor: cs.primaryContainer,
        checkmarkColor: cs.onPrimaryContainer,
      ),
    );
  }

  Widget _buildAttachmentsChip(ColorScheme cs) {
    final isActive = widget.selectedAttachments != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          isActive ? 'Has files' : 'Attachments',
          style: const TextStyle(fontSize: 12),
        ),
        selected: isActive,
        avatar: Icon(Icons.attach_file, size: 15),
        onSelected: (v) {
          if (isActive) {
            widget.onFilterChanged?.call(FilterChipType.attachments, null);
          } else {
            widget.onFilterChanged?.call(FilterChipType.attachments, true);
          }
        },
        selectedColor: cs.primaryContainer,
        checkmarkColor: cs.onPrimaryContainer,
      ),
    );
  }

  void _showTypePicker(ColorScheme cs) {
    final types = ['text', 'checklist', 'voice', 'drawing'];
    _showPicker(
      title: 'Note type',
      items: ['All', ...types],
      selected: widget.selectedType,
      onSelect: (v) {
        widget.onFilterChanged?.call(
          FilterChipType.type,
          v == 'All' ? null : v,
        );
      },
    );
  }

  void _showFolderPicker(ColorScheme cs) {
    _showPicker(
      title: 'Folder',
      items: ['All', ...widget.folders],
      selected: widget.selectedFolder,
      onSelect: (v) {
        widget.onFilterChanged?.call(
          FilterChipType.folder,
          v == 'All' ? null : v,
        );
      },
    );
  }

  void _showSortPicker(ColorScheme cs) {
    _showPicker(
      title: 'Sort by',
      items: ['Date', 'Title', 'Priority'],
      selected: _sortLabel(widget.selectedSort),
      onSelect: (v) {
        final map = {'Date': 'date', 'Title': 'title', 'Priority': 'priority'};
        widget.onFilterChanged?.call(FilterChipType.sort, map[v] ?? 'date');
      },
    );
  }

  void _showCategoryPicker(ColorScheme cs) {
    _showPicker(
      title: 'Category',
      items: ['All', ...widget.categories],
      selected: _capitalize(widget.selectedCategory ?? ''),
      onSelect: (v) {
        widget.onFilterChanged?.call(
          FilterChipType.category,
          v == 'All' ? null : v.toLowerCase(),
        );
      },
    );
  }

  void _showPicker({
    required String title,
    required List<String> items,
    required String? selected,
    required void Function(String) onSelect,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ...items.map(
              (item) => ListTile(
                title: Text(item),
                trailing: item == selected || _matchesSelected(item, selected)
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  onSelect(item);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  bool _matchesSelected(String item, String? selected) {
    if (selected == null) return item == 'All';
    return item.toLowerCase() == selected.toLowerCase();
  }

  String _sortLabel(String? sort) {
    switch (sort) {
      case 'title':
        return 'Title';
      case 'priority':
        return 'Priority';
      default:
        return 'Date';
    }
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return '${s[0].toUpperCase()}${s.substring(1)}';
  }
}

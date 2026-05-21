import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';

enum NoteViewMode {
  grid,
  list,
  compact,
  detailed,
  masonry,
  timeline,
  folder,
  gallery,
  calendar,
  smart,
}

const Map<NoteViewMode, IconData> noteViewIcons = {
  NoteViewMode.grid: Icons.grid_view_rounded,
  NoteViewMode.list: Icons.view_list_rounded,
  NoteViewMode.compact: Icons.view_headline_rounded,
  NoteViewMode.detailed: Icons.view_agenda_rounded,
  NoteViewMode.masonry: Icons.dashboard_rounded,
  NoteViewMode.timeline: Icons.timeline_rounded,
  NoteViewMode.folder: Icons.folder_copy_rounded,
  NoteViewMode.gallery: Icons.photo_library_rounded,
  NoteViewMode.calendar: Icons.calendar_month_rounded,
  NoteViewMode.smart: Icons.auto_awesome_mosaic_rounded,
};

const Map<NoteViewMode, String> noteViewNames = {
  NoteViewMode.grid: 'Grid',
  NoteViewMode.list: 'List',
  NoteViewMode.compact: 'Compact',
  NoteViewMode.detailed: 'Detailed',
  NoteViewMode.masonry: 'Masonry',
  NoteViewMode.timeline: 'Timeline',
  NoteViewMode.folder: 'Folders',
  NoteViewMode.gallery: 'Gallery',
  NoteViewMode.calendar: 'Calendar',
  NoteViewMode.smart: 'Smart View',
};

class NoteViewsRenderer extends StatefulWidget {
  const NoteViewsRenderer({
    super.key,
    required this.mode,
    required this.notes,
    required this.categories,
    required this.onTap,
    required this.onDelete,
    required this.onToggleArchive,
    required this.onToggleFavorite,
    required this.onTogglePin,
    required this.onToggleLock,
    required this.onShare,
    required this.onMove,
    required this.onLoadMore,
    required this.hasMore,
    this.selectedIds = const {},
    this.onSelectionToggle,
    this.blobs,
    this.padding,
  });

  final NoteViewMode mode;
  final List<SecureNote> notes;
  final Map<String, String> categories;
  final void Function(SecureNote) onTap;
  final void Function(SecureNote) onDelete;
  final void Function(SecureNote) onToggleArchive;
  final void Function(SecureNote) onToggleFavorite;
  final void Function(SecureNote) onTogglePin;
  final void Function(SecureNote) onToggleLock;
  final void Function(SecureNote) onShare;
  final void Function(SecureNote) onMove;
  final VoidCallback onLoadMore;
  final bool hasMore;
  final Set<String> selectedIds;
  final void Function(SecureNote)? onSelectionToggle;
  final EncryptedBlobService? blobs;
  final EdgeInsetsGeometry? padding;

  @override
  State<NoteViewsRenderer> createState() => _NoteViewsRendererState();
}

class _NoteViewsRendererState extends State<NoteViewsRenderer> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (widget.hasMore) widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[NoteViewsRenderer] Building mode: ${widget.mode.name} with ${widget.notes.length} notes');

    if (widget.notes.isEmpty) {
      debugPrint('[NoteViewsRenderer] Showing empty state for ${widget.mode.name}');
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(noteViewIcons[widget.mode], size: 64, color: Theme.of(context).colorScheme.outlineVariant),
              const SizedBox(height: 16),
              Text('No notes in ${noteViewNames[widget.mode]}', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('Try changing filters or adding a new note.'),
            ],
          ),
        ),
      );
    }

    Widget content;
    switch (widget.mode) {
      case NoteViewMode.grid:
        content = _buildGrid();
        break;
      case NoteViewMode.list:
        content = _buildList();
        break;
      case NoteViewMode.compact:
        content = _buildCompact();
        break;
      case NoteViewMode.detailed:
        content = _buildDetailed();
        break;
      case NoteViewMode.masonry:
        content = _buildMasonry();
        break;
      case NoteViewMode.timeline:
        content = _buildTimeline();
        break;
      case NoteViewMode.folder:
        content = _buildFolder();
        break;
      case NoteViewMode.gallery:
        content = _buildGallery();
        break;
      case NoteViewMode.calendar:
        content = _buildCalendar();
        break;
      case NoteViewMode.smart:
        content = _buildSmart();
        break;
    }

    return content;
  }

  Widget _buildSmart() {
    final analyzer = NoteAnalyzerService();
    
    // Sort all notes globally for grouped categories
    final sortedNotes = List<SecureNote>.from(widget.notes)..sort((a, b) {
      final timeA = a.lastOpenedAt ?? a.updatedAt;
      final timeB = b.lastOpenedAt ?? b.updatedAt;
      return timeB.compareTo(timeA);
    });

    final grouped = analyzer.groupByCategory(sortedNotes);
    
    // Sort categories: put General at the end, and non-empty categories first
    final sortedCategories = NoteCategory.values.toList()
      ..sort((a, b) {
        if (a == NoteCategory.general) return 1;
        if (b == NoteCategory.general) return -1;
        
        final aCount = grouped[a]?.length ?? 0;
        final bCount = grouped[b]?.length ?? 0;
        
        if (aCount > 0 && bCount == 0) return -1;
        if (aCount == 0 && bCount > 0) return 1;
        
        return a.name.compareTo(b.name);
      });

    // No Recent section needed anymore
    return ListView(
      key: const PageStorageKey('smart_view'),
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).viewPadding.bottom + 32),
      children: [
        ...sortedCategories.map((category) {
          final notes = grouped[category] ?? [];
          if (notes.isEmpty) return const SizedBox.shrink();

          final meta = SmartOrganizationService.getCategoryMetadata(category);
          final cs = Theme.of(context).colorScheme;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: ExpansionTile(
              key: PageStorageKey('cat_${category.name}'),
              leading: Text(meta.icon, style: const TextStyle(fontSize: 24)),
              title: Text(
                meta.label,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${notes.length} notes \u2022 ${meta.description}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              shape: const RoundedRectangleBorder(side: BorderSide.none),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: notes.map((n) => _buildCard(n, isDetailed: true)).toList(),
            ),
          );
        }),
      ],
    );
  }

  // _buildRecentSection removed as per requirements.

  Widget _buildCard(SecureNote note, {bool isGrid = false, bool isCompact = false, bool isDetailed = false}) {
    final isSelected = widget.selectedIds.contains(note.id);

    if (isCompact) {
      final cs = Theme.of(context).colorScheme;
      return Card(
        key: ValueKey('compact_${note.id}'),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: isSelected ? cs.primaryContainer : null,
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          leading: isSelected ? Icon(Icons.check_circle, color: cs.primary) : null,
          title: Text(note.title.isEmpty ? 'Untitled' : note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(DateFormat.yMd().format(note.updatedAt), style: const TextStyle(fontSize: 10)),
          onTap: isSelected ? () => widget.onSelectionToggle?.call(note) : () => widget.onTap(note),
          onLongPress: () {
            HapticFeedback.heavyImpact();
            widget.onSelectionToggle?.call(note);
          },
        ),
      );
    }

    if (isDetailed) {
      final cs = Theme.of(context).colorScheme;
      return Card(
        key: ValueKey('detailed_${note.id}'),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: isSelected ? cs.primaryContainer : null,
        child: InkWell(
          onTap: isSelected ? () => widget.onSelectionToggle?.call(note) : () => widget.onTap(note),
          onLongPress: () {
            HapticFeedback.heavyImpact();
            widget.onSelectionToggle?.call(note);
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(note.title.isEmpty ? 'Untitled' : note.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (isSelected) Icon(Icons.check_circle, color: cs.primary, size: 20)
                    else if (note.pinned) const Icon(Icons.push_pin, size: 16),
                  ],
                ),
                const SizedBox(height: 8),
                Text(note.body.isEmpty ? 'No additional text' : note.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  children: note.tags.map((t) => Chip(label: Text(t, style: const TextStyle(fontSize: 10)), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)).toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(DateFormat.yMMMd().add_jm().format(note.updatedAt), style: const TextStyle(fontSize: 11)),
                    if (note.attachments.isNotEmpty)
                      Row(
                        children: [
                          const Icon(Icons.attach_file, size: 12),
                          const SizedBox(width: 4),
                          Text('${note.attachments.length}', style: const TextStyle(fontSize: 11)),
                        ],
                      )
                  ],
                )
              ],
            ),
          ),
        ),
      );
    }

    return ModernNoteCard(
      key: ValueKey('modern_${note.id}'),
      note: note,
      isGrid: isGrid,
      category: widget.categories[note.id],
      isSelected: isSelected,
      onSelectionToggle: () => widget.onSelectionToggle?.call(note),
      onTap: () => widget.onTap(note),
      onDelete: () => widget.onDelete(note),
      onToggleArchive: () => widget.onToggleArchive(note),
      onToggleFavorite: () => widget.onToggleFavorite(note),
      onTogglePin: () => widget.onTogglePin(note),
      onToggleLock: () => widget.onToggleLock(note),
      onShare: () => widget.onShare(note),
      onMove: () => widget.onMove(note),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      key: const PageStorageKey('grid_view'),
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) => _buildCard(widget.notes[i], isGrid: true),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      key: const PageStorageKey('list_view'),
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.all(12),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) {
        // In List view, we use isGrid: false so it doesn't try to fill height
        return _buildCard(widget.notes[i], isGrid: false);
      },
    );
  }

  Widget _buildCompact() {
    return ListView.builder(
      key: const PageStorageKey('compact_view'),
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) => _buildCard(widget.notes[i], isCompact: true),
    );
  }

  Widget _buildDetailed() {
    return ListView.builder(
      key: const PageStorageKey('detailed_view'),
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) => _buildCard(widget.notes[i], isDetailed: true),
    );
  }

  Widget _buildMasonry() {
    // Masonry requires variable heights, so we MUST use isGrid: false 
    // to avoid the Spacer() in ModernNoteCard.
    final left = <SecureNote>[];
    final right = <SecureNote>[];
    for (int i = 0; i < widget.notes.length; i++) {
      if (i % 2 == 0) {
        left.add(widget.notes[i]);
      } else {
        right.add(widget.notes[i]);
      }
    }
    return SingleChildScrollView(
      key: const PageStorageKey('masonry_view'),
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: widget.padding ?? const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: left.map((n) => _buildCard(n, isGrid: false)).toList(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              children: right.map((n) => _buildCard(n, isGrid: false)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    // Group notes by Today, Yesterday, This Week, Older
    final Map<String, List<SecureNote>> groups = {
      'Today': [],
      'Yesterday': [],
      'This Week': [],
      'Older': [],
    };
    
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeek = today.subtract(const Duration(days: 7));

    for (final note in widget.notes) {
      final d = DateTime(note.updatedAt.year, note.updatedAt.month, note.updatedAt.day);
      if (d == today) {
        groups['Today']!.add(note);
      } else if (d == yesterday) {
        groups['Yesterday']!.add(note);
      } else if (d.isAfter(thisWeek)) {
        groups['This Week']!.add(note);
      } else {
        groups['Older']!.add(note);
      }
    }

    return ListView(
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.all(16),
      children: groups.entries.where((e) => e.value.isNotEmpty).map((e) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(e.key, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
            ),
            ...e.value.map((n) => _buildCard(n, isDetailed: true)),
            const SizedBox(height: 16),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildFolder() {
    // Group by folder
    final Map<String, List<SecureNote>> folders = {};
    for (final note in widget.notes) {
      folders.putIfAbsent(note.folder, () => []).add(note);
    }
    
    final keys = folders.keys.toList()..sort();
    
    return ListView.builder(
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.all(12),
      itemCount: keys.length,
      itemBuilder: (ctx, i) {
        final folder = keys[i];
        final fnotes = folders[folder]!;
        return ExpansionTile(
          leading: const Icon(Icons.folder),
          title: Text(folder),
          subtitle: Text('${fnotes.length} notes'),
          children: fnotes.map((n) => _buildCard(n, isCompact: true)).toList(),
        );
      },
    );
  }

  Widget _buildGallery() {
    final imageNotes = widget.notes.where((n) => n.attachments.any((a) => a.kind == 'image')).toList();
    if (imageNotes.isEmpty) {
      return const Center(child: Text('No notes with images'));
    }
    return GridView.builder(
      controller: _scrollController,
      padding: widget.padding ?? const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.0,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: imageNotes.length,
      itemBuilder: (context, i) {
        final note = imageNotes[i];
        final imageAttachment = note.attachments.firstWhere((a) => a.kind == 'image');
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => widget.onTap(note),
            child: Stack(
              fit: StackFit.expand,
              children: [
                EncryptedThumbnail(
                  noteId: note.id,
                  attachment: imageAttachment,
                  blobs: widget.blobs,
                ),
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.all(8),
                    child: Text(note.title.isEmpty ? 'Untitled' : note.title, style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 1),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCalendar() {
    final Map<String, List<SecureNote>> dateMap = {};
    for (final note in widget.notes) {
      final date = DateFormat.yMMMd().format(note.createdAt);
      dateMap.putIfAbsent(date, () => []).add(note);
    }
    final keys = dateMap.keys.toList();
    return ListView.builder(
      controller: _scrollController,
      padding: widget.padding,
      itemCount: keys.length,
      itemBuilder: (ctx, i) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(keys[i], style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...dateMap[keys[i]]!.map((n) => _buildCard(n, isCompact: true)),
          ],
        );
      },
    );
  }
}

class ViewSwitcherSheet extends StatelessWidget {
  const ViewSwitcherSheet({super.key, required this.currentMode, required this.onModeSelected});
  
  final NoteViewMode currentMode;
  final ValueChanged<NoteViewMode> onModeSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('View Layout', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 1.2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: NoteViewMode.values.length,
              itemBuilder: (ctx, i) {
                final mode = NoteViewMode.values[i];
                final isSelected = mode == currentMode;
                final cs = Theme.of(context).colorScheme;
                return InkWell(
                  onTap: () {
                    onModeSelected(mode);
                    Navigator.pop(context);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isSelected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(noteViewIcons[mode], color: isSelected ? cs.onPrimaryContainer : cs.onSurface),
                        const SizedBox(height: 8),
                        Text(noteViewNames[mode]!, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: isSelected ? cs.onPrimaryContainer : cs.onSurface)),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

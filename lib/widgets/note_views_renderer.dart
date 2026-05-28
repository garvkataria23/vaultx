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
    this.isSelectionMode = false,
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
  final bool isSelectionMode;
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
      padding: EdgeInsets.fromLTRB(12, 8, 12, MediaQuery.of(context).viewPadding.bottom + 80),
      children: [
        ...sortedCategories.map((category) {
          final notes = grouped[category] ?? [];
          if (notes.isEmpty) return const SizedBox.shrink();

          final meta = SmartOrganizationService.getCategoryMetadata(category);
          final cs = Theme.of(context).colorScheme;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3)),
            ),
            child: ExpansionTile(
              key: PageStorageKey('cat_${category.name}'),
              leading: Text(meta.icon, style: const TextStyle(fontSize: 20)),
              title: Text(
                meta.label,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              subtitle: Text(
                '${notes.length} notes',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              shape: const RoundedRectangleBorder(side: BorderSide.none),
              childrenPadding: const EdgeInsets.only(bottom: 4),
              children: notes.map((n) => _buildCard(n, isDetailed: true)).toList(),
            ),
          );
        }),
      ],
    );
  }

  // _buildRecentSection removed as per requirements.

  Widget _buildCard(SecureNote note, {bool isGrid = false, bool isCompact = false, bool isDetailed = false, bool isList = false}) {
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
          onTap: (isSelected || widget.isSelectionMode) ? () => widget.onSelectionToggle?.call(note) : () => widget.onTap(note),
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
        color: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        child: Container(
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
              color: isSelected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.4),
              width: isSelected ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 20, offset: const Offset(0, 8)),
            ],
          ),
          child: InkWell(
            onTap: (isSelected || widget.isSelectionMode) ? () => widget.onSelectionToggle?.call(note) : () => widget.onTap(note),
            onLongPress: () {
              HapticFeedback.heavyImpact();
              widget.onSelectionToggle?.call(note);
            },
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text(note.title.isEmpty ? 'Untitled' : note.title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: cs.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (isSelected) Icon(Icons.check_circle, color: cs.primary, size: 20)
                      else if (note.pinned) Icon(Icons.push_pin, size: 16, color: cs.primary),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(note.body.isEmpty ? 'No additional text' : note.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    children: note.tags.map((t) => Chip(
                      label: Text(t, style: TextStyle(fontSize: 10, color: cs.primary)),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      backgroundColor: cs.primary.withValues(alpha: 0.1),
                      side: BorderSide.none,
                    )).toList(),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.access_time, size: 12, color: cs.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(DateFormat.yMMMd().add_jm().format(note.updatedAt), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                          ],
                        ),
                        if (note.attachments.isNotEmpty)
                          Row(
                            children: [
                              const Icon(Icons.attach_file, size: 12),
                              const SizedBox(width: 4),
                              Text('${note.attachments.length}', style: const TextStyle(fontSize: 11)),
                            ],
                          )
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (isList) {
      final cs = Theme.of(context).colorScheme;
      final timeStr = _formatListDate(note.updatedAt);
      return SwipeActionTile(
        isPinned: note.pinned,
        isArchived: note.archived,
        onAction: (action) {
          switch (action) {
            case SwipeAction.pin: widget.onTogglePin(note);
            case SwipeAction.archive: widget.onToggleArchive(note);
            case SwipeAction.share: widget.onShare(note);
            case SwipeAction.move: widget.onMove(note);
            case SwipeAction.delete: widget.onDelete(note);
          }
        },
        child: InkWell(
          onTap: (isSelected || widget.isSelectionMode) ? () => widget.onSelectionToggle?.call(note) : () => widget.onTap(note),
          onLongPress: () {
            HapticFeedback.heavyImpact();
            widget.onSelectionToggle?.call(note);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: isSelected ? cs.primaryContainer.withValues(alpha: 0.4) : null,
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.2)),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (note.pinned && !isSelected)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(Icons.push_pin, size: 13, color: cs.primary),
                            ),
                          Expanded(
                            child: Text(
                              note.title.isEmpty ? 'Untitled' : note.title,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: isSelected ? cs.onPrimaryContainer : cs.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        note.locked ? 'Content Locked' : (note.body.isEmpty ? 'No content' : note.body),
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected ? cs.onPrimaryContainer.withValues(alpha: 0.6) : cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: isSelected ? cs.onPrimaryContainer.withValues(alpha: 0.5) : cs.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    if (note.attachments.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Icon(Icons.attach_file, size: 13, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
                    ],
                  ],
                ),
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.check_circle, color: cs.primary, size: 20),
                  ),
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
      isSelectionMode: widget.isSelectionMode,
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

  String _formatListDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return DateFormat.MMMd().format(date);
  }

  Widget _buildGrid() {
    return GridView.builder(
      key: const PageStorageKey('grid_view'),
      controller: _scrollController,
      padding: widget.padding ?? EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).viewPadding.bottom + 80),
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
      padding: widget.padding ?? EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).viewPadding.bottom + 80),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) {
        return _buildCard(widget.notes[i], isList: true);
      },
    );
  }

  Widget _buildCompact() {
    return ListView.builder(
      key: const PageStorageKey('compact_view'),
      controller: _scrollController,
      padding: widget.padding ?? EdgeInsets.fromLTRB(0, 8, 0, MediaQuery.of(context).viewPadding.bottom + 80),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) => _buildCard(widget.notes[i], isCompact: true),
    );
  }

  Widget _buildDetailed() {
    return ListView.builder(
      key: const PageStorageKey('detailed_view'),
      controller: _scrollController,
      padding: widget.padding ?? EdgeInsets.fromLTRB(0, 8, 0, MediaQuery.of(context).viewPadding.bottom + 80),
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
      padding: widget.padding ?? EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).viewPadding.bottom + 80),
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
      padding: widget.padding ?? EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewPadding.bottom + 80),
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
      padding: widget.padding ?? EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).viewPadding.bottom + 80),
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
    return GridView.builder(
      key: const PageStorageKey('gallery_view'),
      controller: _scrollController,
      padding: widget.padding ?? EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).viewPadding.bottom + 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.72,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: widget.notes.length,
      itemBuilder: (context, i) {
        final note = widget.notes[i];
        return GalleryNoteCard(
          note: note,
          blobs: widget.blobs,
          isSelected: widget.selectedIds.contains(note.id),
          isSelectionMode: widget.isSelectionMode,
          onTap: () => widget.onTap(note),
          onSelectionToggle: () => widget.onSelectionToggle?.call(note),
          onDelete: () => widget.onDelete(note),
          onTogglePin: () => widget.onTogglePin(note),
          onToggleFavorite: () => widget.onToggleFavorite(note),
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
      padding: widget.padding ?? EdgeInsets.fromLTRB(0, 0, 0, MediaQuery.of(context).viewPadding.bottom + 80),
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

class GalleryNoteCard extends StatelessWidget {
  const GalleryNoteCard({
    super.key,
    required this.note,
    this.blobs,
    this.isSelected = false,
    this.isSelectionMode = false,
    required this.onTap,
    required this.onSelectionToggle,
    required this.onDelete,
    required this.onTogglePin,
    required this.onToggleFavorite,
  });

  final SecureNote note;
  final EncryptedBlobService? blobs;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onSelectionToggle;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasImage = note.attachments.any((a) => a.kind == 'image');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              GestureDetector(
                onTap: (isSelected || isSelectionMode) ? onSelectionToggle : onTap,
                onLongPress: () {
                  HapticFeedback.heavyImpact();
                  onSelectionToggle();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isSelected 
                          ? cs.primary 
                          : cs.outlineVariant.withValues(alpha: 0.1),
                      width: isSelected ? 2.5 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildPreview(context, hasImage),
                ),
              ),
              if (isSelected)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.check, size: 14, color: cs.onPrimary),
                  ),
                ),
              if (note.pinned && !isSelected)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(Icons.push_pin, size: 12, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                note.title.isEmpty ? 'Untitled' : note.title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  letterSpacing: -0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                _formatDate(note.updatedAt),
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, bool hasImage) {
    final cs = Theme.of(context).colorScheme;
    
    if (note.locked) {
      return Center(
        child: Icon(Icons.lock_outline, color: cs.onSurfaceVariant.withValues(alpha: 0.3), size: 28),
      );
    }

    if (hasImage) {
      final img = note.attachments.firstWhere((a) => a.kind == 'image');
      return EncryptedThumbnail(
        noteId: note.id,
        attachment: img,
        blobs: blobs,
        fit: BoxFit.cover,
      );
    }

    switch (note.type) {
      case NoteType.checklist:
        return _buildChecklistPreview(cs);
      case NoteType.todo:
        return _buildTodoPreview(cs);
      case NoteType.voice:
        return _buildVoicePreview(cs);
      case NoteType.drawing:
        return _buildDrawingPreview(cs);
      case NoteType.text:
      default:
        return _buildTextPreview(cs);
    }
  }

  Widget _buildTextPreview(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Text(
        note.body,
        style: TextStyle(
          fontSize: 9,
          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          height: 1.2,
        ),
        maxLines: 10,
        overflow: TextOverflow.fade,
      ),
    );
  }

  Widget _buildChecklistPreview(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: note.checklist.take(6).map((item) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            children: [
              Icon(
                item.done ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                size: 9,
                color: item.done ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  item.text,
                  style: TextStyle(
                    fontSize: 8,
                    color: item.done ? cs.onSurfaceVariant.withValues(alpha: 0.4) : cs.onSurfaceVariant,
                    decoration: item.done ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildTodoPreview(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: note.todoList.take(6).map((task) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(
                  color: _getPriorityColor(task.priority),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  task.text,
                  style: TextStyle(
                    fontSize: 8,
                    color: task.done ? cs.onSurfaceVariant.withValues(alpha: 0.4) : cs.onSurfaceVariant,
                    decoration: task.done ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }

  Color _getPriorityColor(TodoPriority priority) {
    switch (priority) {
      case TodoPriority.high: return Colors.red;
      case TodoPriority.medium: return Colors.orange;
      case TodoPriority.low: return Colors.blue;
    }
  }

  Widget _buildVoicePreview(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic, color: cs.primary.withValues(alpha: 0.3), size: 32),
          if (note.transcript.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                note.transcript,
                style: TextStyle(fontSize: 7, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDrawingPreview(ColorScheme cs) {
    return Center(
      child: Icon(Icons.brush, color: cs.primary.withValues(alpha: 0.3), size: 36),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return DateFormat.jm().format(date);
    }
    return DateFormat.yMMMd().format(date);
  }
}

class ViewSwitcherSheet extends StatelessWidget {
  const ViewSwitcherSheet({super.key, required this.currentMode, required this.onModeSelected});
  
  final NoteViewMode currentMode;
  final ValueChanged<NoteViewMode> onModeSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: Text(
            'View Layout',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
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
                    Text(
                      noteViewNames[mode]!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? cs.onPrimaryContainer : cs.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

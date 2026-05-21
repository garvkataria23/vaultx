import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/note_views_renderer.dart';
import 'note_editor.dart';

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

  @override
  void initState() {
    super.initState();
    // Default to Recent
    _selectCategory(SmartCategory.recent);
  }

  void _selectCategory(SmartCategory category) {
    setState(() {
      _selectedCategory = category;
      _filteredNotes = _applyFilter(category);
    });
  }

  List<SecureNote> _applyFilter(SmartCategory category) {
    final now = DateTime.now();
    final notes = widget.notes.where((n) => !n.archived && !n.deleted).toList();

    switch (category) {
      case SmartCategory.recent:
        return notes..sort((a, b) {
          final timeA = a.lastOpenedAt ?? a.updatedAt;
          final timeB = b.lastOpenedAt ?? b.updatedAt;
          return timeB.compareTo(timeA);
        });
      case SmartCategory.pinned:
        return notes.where((n) => n.pinned).toList();
      case SmartCategory.aiSuggested:
        return notes.where((n) => n.summary.isNotEmpty || n.ocrText.isNotEmpty || n.transcript.isNotEmpty).toList();
      case SmartCategory.frequentlyOpened:
        return notes.where((n) => n.viewCount > 0).toList()
          ..sort((a, b) => b.viewCount.compareTo(a.viewCount));
      case SmartCategory.large:
        return notes..sort((a, b) {
          final sizeA = a.body.length + a.attachments.fold(0, (sum, att) => sum + att.size);
          final sizeB = b.body.length + b.attachments.fold(0, (sum, att) => sum + att.size);
          return sizeB.compareTo(sizeA);
        });
      case SmartCategory.unread:
        // We consider unread if viewCount is 0
        return notes.where((n) => n.viewCount == 0).toList();
      case SmartCategory.today:
        return notes.where((n) => 
          (n.createdAt.year == now.year && n.createdAt.month == now.month && n.createdAt.day == now.day) ||
          (n.updatedAt.year == now.year && n.updatedAt.month == now.month && n.updatedAt.day == now.day)
        ).toList();
      case SmartCategory.thisWeek:
        final weekAgo = now.subtract(const Duration(days: 7));
        return notes.where((n) => n.updatedAt.isAfter(weekAgo) || n.createdAt.isAfter(weekAgo)).toList();
      case SmartCategory.media:
        return notes.where((n) => n.attachments.isNotEmpty || n.type != NoteType.text).toList();
    }
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
    
    // Refresh the list if we return
    _selectCategory(_selectedCategory!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            AppBar(
              title: const Text('Smart View'),
              actions: [
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
            Expanded(
              child: Column(
                children: [
                  _buildCategorySelector(cs),
                  const Divider(height: 1),
                  Expanded(
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
                      categories: const {}, // Default empty
                      hasMore: false,
                      onLoadMore: () {},
                      onDelete: (n) {},
                      onToggleArchive: (n) {},
                      onToggleLock: (n) {},
                      onShare: (n) {},
                      onMove: (n) {},
                      // Add padding to handle navigation bar
                      padding: EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        MediaQuery.of(context).viewPadding.bottom + 64,
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
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: SmartCategory.values.length,
        itemBuilder: (context, index) {
          final cat = SmartCategory.values[index];
          final isSelected = _selectedCategory == cat;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkWell(
              onTap: () => _selectCategory(cat),
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 90,
                decoration: BoxDecoration(
                  color: isSelected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected ? cs.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      cat.icon,
                      color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      cat.label.split(' ')[0], // Short name
                      style: TextStyle(
                        fontSize: 12,
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _selectedCategory?.icon ?? Icons.auto_awesome,
            size: 64,
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No ${_selectedCategory?.label.toLowerCase() ?? "notes"} found',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

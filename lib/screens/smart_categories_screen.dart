import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';

/// Screen that displays notes organized into auto-detected intelligent categories.
class SmartCategoriesScreen extends StatefulWidget {
  const SmartCategoriesScreen({
    super.key,
    required this.notes,
    this.onNoteTap,
  });

  final List<SecureNote> notes;
  final ValueChanged<SecureNote>? onNoteTap;

  @override
  State<SmartCategoriesScreen> createState() => _SmartCategoriesScreenState();
}

class _SmartCategoriesScreenState extends State<SmartCategoriesScreen> {
  late SmartOrganizationService _orgService;
  Map<NoteCategory, List<SecureNote>> _categories = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _orgService = SmartOrganizationService(widget.notes);
    _computeCategories();
  }

  void _computeCategories() {
    setState(() => _isLoading = true);
    // Computation is usually fast enough for sync, but we use a small delay 
    // to ensure smooth entry animation
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      setState(() {
        _categories = _orgService.getSmartCategories();
        _isLoading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // Sort categories: General at the end, others by note count
    final sortedCategories = _categories.keys.toList()
      ..sort((a, b) {
        if (a == NoteCategory.general) return 1;
        if (b == NoteCategory.general) return -1;
        return _categories[b]!.length.compareTo(_categories[a]!.length);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Organization'),
        actions: [
          IconButton(
            onPressed: _computeCategories,
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-analyze vault',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : sortedCategories.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: sortedCategories.length,
                  itemBuilder: (ctx, i) {
                    final cat = sortedCategories[i];
                    final notes = _categories[cat]!;
                    final meta = SmartOrganizationService.getCategoryMetadata(cat);
                    
                    return _CategorySection(
                      meta: meta,
                      notes: notes,
                      onNoteTap: widget.onNoteTap,
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
          Icon(Icons.auto_awesome_outlined, size: 64, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
          const SizedBox(height: 16),
          Text(
            'No categories detected',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text('Try adding more notes to see smart organization in action.'),
        ],
      ),
    );
  }
}

class _CategorySection extends StatefulWidget {
  const _CategorySection({
    required this.meta,
    required this.notes,
    this.onNoteTap,
  });

  final CategoryMetadata meta;
  final List<SecureNote> notes;
  final ValueChanged<SecureNote>? onNoteTap;

  @override
  State<_CategorySection> createState() => _CategorySectionState();
}

class _CategorySectionState extends State<_CategorySection> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              widget.meta.icon,
              style: const TextStyle(fontSize: 20),
            ),
          ),
          title: Text(
            widget.meta.label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            '${widget.notes.length} notes',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  Divider(color: cs.outlineVariant.withValues(alpha: 0.3)),
                  const SizedBox(height: 8),
                  ...widget.notes.take(10).map((n) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      n.type == NoteType.checklist ? Icons.check_box_outlined : Icons.description_outlined,
                      size: 18,
                    ),
                    title: Text(
                      n.title.isEmpty ? 'Untitled' : n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: n.body.isNotEmpty 
                      ? Text(n.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))
                      : null,
                    trailing: const Icon(Icons.chevron_right, size: 16),
                    onTap: () => widget.onNoteTap?.call(n),
                  )),
                  if (widget.notes.length > 10)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '+ ${widget.notes.length - 10} more notes',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontStyle: FontStyle.italic),
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
}

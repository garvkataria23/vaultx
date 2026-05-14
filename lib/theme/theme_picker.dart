import 'package:flutter/material.dart';
import '../services/floating_notification_service.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public entry-point — call this from your settings screen
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showThemePicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ThemePickerSheet(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal sheet widget
// ─────────────────────────────────────────────────────────────────────────────

class _ThemePickerSheet extends StatefulWidget {
  const _ThemePickerSheet();

  @override
  State<_ThemePickerSheet> createState() => _ThemePickerSheetState();
}

class _ThemePickerSheetState extends State<_ThemePickerSheet>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _search;
  late final ScrollController _chipScroll;

  String _selectedCategory = 'All';
  String _query = '';

  // Build the ordered, deduplicated category list once
  static final List<String> _categories = () {
    final raw = AppThemes.all.map((t) => t.category).toSet().toList();
    // Preferred order
    const preferred = [
      'Dark',
      'AMOLED',
      'Neon',
      'Monochrome',
      'Nature',
      'Premium',
      'Warm',
      'Cool',
      'Pastel Dark',
      'Retro',
      'Light',
      'Pastel',
      'Special',
      'Accessibility',
    ];
    final sorted = [
      ...preferred.where(raw.contains),
      ...raw.where((c) => !preferred.contains(c)),
    ];
    return sorted;
  }();

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
    _chipScroll = ScrollController();
  }

  @override
  void dispose() {
    _search.dispose();
    _chipScroll.dispose();
    super.dispose();
  }

  List<VaultTheme> get _filtered {
    var list = AppThemes.all;
    if (_selectedCategory != 'All') {
      list = list.where((t) => t.category == _selectedCategory).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where(
            (t) =>
                t.name.toLowerCase().contains(q) ||
                t.category.toLowerCase().contains(q),
          )
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final provider = context.watch<ThemeProvider>();
    final filtered = _filtered;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      snap: true,
      snapSizes: const [0.5, 0.92, 0.96],
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // ── Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),

              // ── Header row
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Appearance',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${AppThemes.all.length} themes available',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Active theme badge
                    _ActiveThemeBadge(theme: provider.current),
                  ],
                ),
              ),

              // ── Search bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'Search themes…',
                    hintStyle: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.4),
                      fontSize: 14,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: cs.onSurface.withValues(alpha: 0.4),
                      size: 20,
                    ),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // ── Category chips
              SizedBox(
                height: 34,
                child: ListView.separated(
                  controller: _chipScroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemCount: _categories.length + 1,
                  itemBuilder: (_, i) {
                    final label = i == 0 ? 'All' : _categories[i - 1];
                    final selected = _selectedCategory == label;
                    return _CategoryChip(
                      label: label,
                      selected: selected,
                      onTap: () => setState(() => _selectedCategory = label),
                    );
                  },
                ),
              ),

              const SizedBox(height: 12),

              // ── Theme grid
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.palette_outlined,
                              size: 48,
                              color: cs.onSurface.withValues(alpha: 0.2),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No themes found',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 0.78,
                            ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final t = filtered[i];
                          final isActive = provider.current.id == t.id;
                          return _ThemeCard(
                            vaultTheme: t,
                            isActive: isActive,
                            onTap: () async {
                              final name = t.name;
                              try {
                                await provider.setTheme(t);
                                if (!mounted) return;
                                FloatingNotificationService.instance.show('$name applied');
                              } catch (e) {
                                if (!mounted) return;
                                FloatingNotificationService.instance.show('Failed: $e');
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active theme badge (top-right of header)
// ─────────────────────────────────────────────────────────────────────────────

class _ActiveThemeBadge extends StatelessWidget {
  const _ActiveThemeBadge({required this.theme});
  final VaultTheme theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.fabBg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.fabBg.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: theme.fabBg,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            theme.name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.fabBg,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Category filter chip
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? cs.primary : cs.outline.withValues(alpha: 0.35),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? cs.onPrimary
                : cs.onSurface.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual theme card
// ─────────────────────────────────────────────────────────────────────────────

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.vaultTheme,
    required this.isActive,
    required this.onTap,
  });
  final VaultTheme vaultTheme;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = vaultTheme;
    final borderColor = isActive
        ? t.fabBg
        : t.cardBorder.withValues(alpha: 0.6);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: t.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: isActive ? 2 : 1),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: t.fabBg.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Preview area
              Expanded(child: _ThemePreview(vaultTheme: t)),

              // ── Label area
              Container(
                color: t.scaffoldBg,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.brightness == Brightness.dark
                                  ? Colors.white.withValues(alpha: 0.9)
                                  : Colors.black.withValues(alpha: 0.85),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          Text(
                            t.category,
                            style: TextStyle(
                              color: t.brightness == Brightness.dark
                                  ? Colors.white.withValues(alpha: 0.38)
                                  : Colors.black.withValues(alpha: 0.38),
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isActive)
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: t.fabBg,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          color: t.fabFg,
                          size: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mini UI preview inside each card
// ─────────────────────────────────────────────────────────────────────────────

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.vaultTheme});
  final VaultTheme vaultTheme;

  @override
  Widget build(BuildContext context) {
    final t = vaultTheme;
    final textHigh = t.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.80);
    final textLow = t.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.3);

    return Container(
      color: t.scaffoldBg,
      padding: const EdgeInsets.all(7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // AppBar strip
          Container(
            height: 14,
            decoration: BoxDecoration(
              color: t.appBarBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: t.cardBorder.withValues(alpha: 0.5)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 5,
                  decoration: BoxDecoration(
                    color: textHigh.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Spacer(),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: t.fabBg,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Card row
          Row(
            children: [
              _MiniCard(t: t, textHigh: textHigh, textLow: textLow, flex: 3),
              const SizedBox(width: 4),
              _MiniCard(t: t, textHigh: textHigh, textLow: textLow, flex: 2),
            ],
          ),
          const SizedBox(height: 4),
          // Input field mock
          Container(
            height: 12,
            decoration: BoxDecoration(
              color: t.inputFill,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: t.inputBorder),
            ),
          ),
          const SizedBox(height: 4),
          // Nav bar
          Container(
            height: 16,
            decoration: BoxDecoration(
              color: t.navBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: t.cardBorder.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(3, (i) {
                final active = i == 0;
                return Container(
                  width: active ? 20 : 12,
                  height: 5,
                  decoration: BoxDecoration(
                    color: active ? t.navIndicator : t.navBg,
                    borderRadius: BorderRadius.circular(2),
                    border: active
                        ? Border.all(color: t.fabBg.withValues(alpha: 0.5))
                        : null,
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard({
    required this.t,
    required this.textHigh,
    required this.textLow,
    required this.flex,
  });
  final VaultTheme t;
  final Color textHigh;
  final Color textLow;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Container(
        height: 28,
        decoration: BoxDecoration(
          color: t.cardBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: t.cardBorder),
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: double.infinity,
              height: 4,
              decoration: BoxDecoration(
                color: textHigh.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 3),
            Container(
              width: double.infinity * 0.6,
              height: 3,
              decoration: BoxDecoration(
                color: textLow,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact settings tile (drop into your settings list)
// ─────────────────────────────────────────────────────────────────────────────

class ThemePickerTile extends StatelessWidget {
  const ThemePickerTile({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    final t = provider.current;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ListTile(
      onTap: () => showThemePicker(context),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: t.fabBg.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.fabBg.withValues(alpha: 0.3)),
        ),
        child: Icon(Icons.palette_rounded, color: t.fabBg, size: 20),
      ),
      title: Text(
        'Theme',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${t.name} · ${t.category}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Color swatch strip
          _ColorStrip(vaultTheme: t),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            color: cs.onSurface.withValues(alpha: 0.3),
            size: 20,
          ),
        ],
      ),
    );
  }
}

class _ColorStrip extends StatelessWidget {
  const _ColorStrip({required this.vaultTheme});
  final VaultTheme vaultTheme;

  @override
  Widget build(BuildContext context) {
    final colors = [
      vaultTheme.seedColor,
      vaultTheme.fabBg,
      vaultTheme.navIndicator,
      vaultTheme.cardBg,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: colors.map((Color c) {
        return Container(
          width: 8,
          height: 24,
          decoration: BoxDecoration(color: c),
        );
      }).toList(),
    );
  }
}
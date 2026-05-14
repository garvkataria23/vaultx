import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../theme/theme_generator.dart';
import '../theme/theme_provider.dart';
import '../services/floating_notification_service.dart';

/// Full-screen custom theme builder.
/// Push via: Navigator.push(context, MaterialPageRoute(builder: (_) => const CustomThemeCreatorScreen()));
class CustomThemeCreatorScreen extends StatefulWidget {
  const CustomThemeCreatorScreen({super.key});

  @override
  State<CustomThemeCreatorScreen> createState() =>
      _CustomThemeCreatorScreenState();
}

class _CustomThemeCreatorScreenState extends State<CustomThemeCreatorScreen> {
  Color _seed = const Color(0xff6c63ff);
  Brightness _brightness = Brightness.dark;
  final _nameCtrl = TextEditingController(text: 'My Theme');
  bool _applying = false;

  late VaultTheme _preview;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  void _rebuild() {
    try {
      _preview = ThemeGenerator.fromSeed(
        id: 'custom_preview',
        name: _nameCtrl.text.isEmpty ? 'Custom' : _nameCtrl.text,
        seedColor: _seed,
        brightness: _brightness,
      );
    } catch (_) {
      _preview = AppThemes.byId(AppThemes.defaultThemeId);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Theme'),
        actions: [
          TextButton.icon(
            onPressed: _applying ? null : _applyTheme,
            icon: _applying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(_applying ? 'Applying\u2026' : 'Apply'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Live Preview ──────────────────────────────────────────────
            _LivePreview(vaultTheme: _preview),

            const SizedBox(height: 24),

            // ── Name ──────────────────────────────────────────────────────
            Text(
              'Theme Name',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              onChanged: (_) => setState(_rebuild),
              decoration: const InputDecoration(hintText: 'e.g. My Ocean'),
            ),

            const SizedBox(height: 20),

            // ── Brightness toggle ─────────────────────────────────────────
            Text(
              'Mode',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<Brightness>(
              segments: const [
                ButtonSegment(
                  value: Brightness.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode_rounded),
                ),
                ButtonSegment(
                  value: Brightness.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode_rounded),
                ),
              ],
              selected: {_brightness},
              onSelectionChanged: (s) => setState(() {
                _brightness = s.first;
                _rebuild();
              }),
            ),

            const SizedBox(height: 20),

            // ── Hue slider ────────────────────────────────────────────────
            Text(
              'Hue',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 4),
            _HueSlider(
              hue: HSLColor.fromColor(_seed).hue,
              onChanged: (h) {
                final hsl = HSLColor.fromColor(_seed);
                setState(() {
                  _seed = hsl.withHue(h).toColor();
                  _rebuild();
                });
              },
            ),

            const SizedBox(height: 16),

            // ── Saturation ────────────────────────────────────────────────
            Text(
              'Saturation',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 4),
            Slider(
              value: HSLColor.fromColor(_seed).saturation,
              min: 0,
              max: 1,
              onChanged: (v) {
                final hsl = HSLColor.fromColor(_seed);
                setState(() {
                  _seed = hsl.withSaturation(v).toColor();
                  _rebuild();
                });
              },
            ),

            const SizedBox(height: 16),

            // ── Lightness ─────────────────────────────────────────────────
            Text(
              'Seed Lightness',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 4),
            Slider(
              value: HSLColor.fromColor(_seed).lightness,
              min: 0.2,
              max: 0.85,
              onChanged: (v) {
                final hsl = HSLColor.fromColor(_seed);
                setState(() {
                  _seed = hsl.withLightness(v).toColor();
                  _rebuild();
                });
              },
            ),

            const SizedBox(height: 24),

            // ── Preset seed palette ───────────────────────────────────────
            Text(
              'Quick Seeds',
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 10),
            _QuickSeeds(
              current: _seed,
              onPick: (c) => setState(() {
                _seed = c;
                _rebuild();
              }),
            ),

            const SizedBox(height: 32),

            FilledButton.icon(
              onPressed: _applying ? null : _applyTheme,
              icon: _applying
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.palette_rounded),
              label: Text(_applying ? 'Applying\u2026' : 'Apply Theme'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyTheme() async {
    if (_applying || !mounted) return;
    setState(() => _applying = true);
    try {
      final provider = context.read<ThemeProvider>();
      final theme = VaultTheme(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        name: _preview.name,
        category: _preview.category,
        seedColor: _preview.seedColor,
        brightness: _preview.brightness,
        scaffoldBg: _preview.scaffoldBg,
        cardBg: _preview.cardBg,
        navBg: _preview.navBg,
        navIndicator: _preview.navIndicator,
        inputFill: _preview.inputFill,
        inputBorder: _preview.inputBorder,
        inputFocusBorder: _preview.inputFocusBorder,
        fabBg: _preview.fabBg,
        fabFg: _preview.fabFg,
        appBarBg: _preview.appBarBg,
        cardBorder: _preview.cardBorder,
      );
      await provider.setTheme(theme);
      if (!mounted) return;
      context.showFloatingNotification('Theme applied');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      FloatingNotificationService.instance.show('Failed to apply theme: $e', error: true);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live preview card
// ─────────────────────────────────────────────────────────────────────────────

class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.vaultTheme});
  final VaultTheme vaultTheme;

  @override
  Widget build(BuildContext context) {
    final t = vaultTheme;
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: t.scaffoldBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.cardBorder),
        boxShadow: [
          BoxShadow(
            color: t.fabBg.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // AppBar
          Container(
            height: 28,
            decoration: BoxDecoration(
              color: t.appBarBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: t.cardBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(
                  t.name,
                  style: TextStyle(
                    color: t.brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.85)
                        : Colors.black.withValues(alpha: 0.8),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: t.fabBg,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Cards row
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.cardBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: t.cardBorder),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 60,
                          height: 7,
                          decoration: BoxDecoration(
                            color: t.brightness == Brightness.dark
                                ? Colors.white.withValues(alpha: 0.75)
                                : Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: t.brightness == Brightness.dark
                                ? Colors.white.withValues(alpha: 0.28)
                                : Colors.black.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.inputFill,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: t.inputBorder),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Nav bar
          Container(
            height: 28,
            decoration: BoxDecoration(
              color: t.navBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: t.cardBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(4, (i) {
                final active = i == 0;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: active
                      ? BoxDecoration(
                          color: t.navIndicator,
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Container(
                    width: 14,
                    height: 5,
                    decoration: BoxDecoration(
                      color: active
                          ? t.fabBg
                          : (t.brightness == Brightness.dark
                                ? Colors.white.withValues(alpha: 0.25)
                                : Colors.black.withValues(alpha: 0.25)),
                      borderRadius: BorderRadius.circular(3),
                    ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Hue spectrum slider
// ─────────────────────────────────────────────────────────────────────────────

class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onChanged});
  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: LinearGradient(
              colors: List.generate(
                36,
                (i) => HSLColor.fromAHSL(1, i * 10.0, 0.85, 0.55).toColor(),
              ),
            ),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 0,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
          ),
          child: Slider(value: hue, min: 0, max: 359, onChanged: onChanged),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quick seed color bubbles
// ─────────────────────────────────────────────────────────────────────────────

class _QuickSeeds extends StatelessWidget {
  const _QuickSeeds({required this.current, required this.onPick});
  final Color current;
  final ValueChanged<Color> onPick;

  static const _seeds = <Color>[
    Color(0xff14b8a6), // teal
    Color(0xff0ea5e9), // sky
    Color(0xff6366f1), // indigo
    Color(0xff8b5cf6), // violet
    Color(0xffa855f7), // purple
    Color(0xffec4899), // pink
    Color(0xfff43f5e), // rose
    Color(0xffef4444), // red
    Color(0xfff97316), // orange
    Color(0xfff59e0b), // amber
    Color(0xff84cc16), // lime
    Color(0xff22c55e), // green
    Color(0xff10b981), // emerald
    Color(0xff06b6d4), // cyan
    Color(0xff3b82f6), // blue
    Color(0xffe2e8f0), // slate white
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _seeds.map((c) {
        final active = (c.toARGB32() == current.toARGB32());
        return GestureDetector(
          onTap: () => onPick(c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? Colors.white : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: active
                  ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 8)]
                  : [],
            ),
            child: active
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

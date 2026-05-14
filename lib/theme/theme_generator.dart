import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Fallback theme used when seed-based generation fails.
const _fallback = VaultTheme(
  id: 'fallback',
  name: 'Default',
  category: 'Custom',
  seedColor: Color(0xff14b8a6),
  brightness: Brightness.dark,
  scaffoldBg: Color(0xff070a0f),
  cardBg: Color(0xff101720),
  navBg: Color(0xff0b1118),
  navIndicator: Color(0xff12312e),
  inputFill: Color(0xff0f1720),
  inputBorder: Color(0xff223041),
  inputFocusBorder: Color(0xff2dd4bf),
  fabBg: Color(0xff2dd4bf),
  fabFg: Color(0xff02100f),
  appBarBg: Color(0xff070a0f),
  cardBorder: Color(0xff1f2a37),
);

/// Generates a [VaultTheme] from any seed color + brightness.
///
/// Safe: all methods wrap generation in try-catch and fall back to [_fallback].
class ThemeGenerator {
  ThemeGenerator._();

  // ── Public API ─────────────────────────────────────────────────────────────

  static VaultTheme fromSeed({
    required String id,
    required String name,
    required Color seedColor,
    Brightness brightness = Brightness.dark,
    String category = 'Custom',
  }) {
    try {
      final seed = _sanitize(seedColor);
      return brightness == Brightness.dark
          ? _buildDark(id: id, name: name, seed: seed, category: category)
          : _buildLight(id: id, name: name, seed: seed, category: category);
    } catch (_) {
      return VaultTheme(
        id: id,
        name: name,
        category: category,
        seedColor: _fallback.seedColor,
        brightness: _fallback.brightness,
        scaffoldBg: _fallback.scaffoldBg,
        cardBg: _fallback.cardBg,
        navBg: _fallback.navBg,
        navIndicator: _fallback.navIndicator,
        inputFill: _fallback.inputFill,
        inputBorder: _fallback.inputBorder,
        inputFocusBorder: _fallback.inputFocusBorder,
        fabBg: _fallback.fabBg,
        fabFg: _fallback.fabFg,
        appBarBg: _fallback.appBarBg,
        cardBorder: _fallback.cardBorder,
      );
    }
  }

  /// Ensure the seed is a valid color with a defined hue.
  /// Handles NaN, Infinity, negative, and degenerate edge cases.
  static Color _sanitize(Color c) {
    final hsl = HSLColor.fromColor(c);
    final hRaw = hsl.hue;
    final h = (hRaw.isNaN || hRaw.isInfinite || hRaw.isNegative)
        ? 180.0
        : hRaw % 360;
    final sRaw = hsl.saturation;
    final s = (sRaw.isNaN || sRaw < 0.01) ? 0.6 : sRaw.clamp(0.0, 1.0);
    final lRaw = hsl.lightness;
    final l = (lRaw.isNaN || lRaw.isInfinite) ? 0.5 : lRaw.clamp(0.01, 0.99);
    if (s != sRaw || l != lRaw || h != hRaw) {
      return HSLColor.fromAHSL(c.a, h, s, l).toColor();
    }
    return c;
  }

  // ── Dark builder ────────────────────────────────────────────────────────────

  static VaultTheme _buildDark({
    required String id,
    required String name,
    required Color seed,
    required String category,
  }) {
    final hsl = HSLColor.fromColor(seed);
    final h = hsl.hue % 360;
    final s = hsl.saturation.clamp(0.2, 1.0);

    // Clear contrast hierarchy:
    //   scaffold  <  nav  <  card / inputFill  <  borders
    final scaffoldBg = _hsla(h, s * 0.20, 0.055);
    final navBg = _hsla(h, s * 0.22, 0.07);
    final cardBg = _hsla(h, s * 0.18, 0.09);
    final inputFill = _hsla(h, s * 0.18, 0.085);
    final navIndicator = _hsla(h, s * 0.30, 0.15);
    final cardBorder = _hsla(h, s * 0.15, 0.16);
    final inputBorder = _hsla(h, s * 0.22, 0.20);
    final inputFocusBorder = _hsla(h, s.clamp(0.5, 1.0), 0.60);
    final fabBg = _hsla(h, s.clamp(0.55, 1.0), 0.55);
    final fabFg = _hsla(h, 0.30, 0.035);

    return VaultTheme(
      id: id,
      name: name,
      category: category,
      seedColor: seed,
      brightness: Brightness.dark,
      scaffoldBg: scaffoldBg,
      cardBg: cardBg,
      navBg: navBg,
      navIndicator: navIndicator,
      inputFill: inputFill,
      inputBorder: inputBorder,
      inputFocusBorder: inputFocusBorder,
      fabBg: fabBg,
      fabFg: fabFg,
      appBarBg: scaffoldBg,
      cardBorder: cardBorder,
    );
  }

  // ── Light builder ───────────────────────────────────────────────────────────

  static VaultTheme _buildLight({
    required String id,
    required String name,
    required Color seed,
    required String category,
  }) {
    final hsl = HSLColor.fromColor(seed);
    final h = hsl.hue % 360;
    final s = hsl.saturation.clamp(0.2, 1.0);

    // Clean light surfaces with subtle tinting.
    final scaffoldBg = _hsla(h, s * 0.15, 0.965);
    final cardBg = const Color(0xffffffff);
    final navBg = _hsla(h, s * 0.12, 0.92);
    final navIndicator = _hsla(h, s * 0.28, 0.84);
    final inputFill = _hsla(h, s * 0.10, 0.945);
    final inputBorder = _hsla(h, s * 0.20, 0.80);
    final inputFocusBorder = _hsla(h, s.clamp(0.45, 0.85), 0.45);
    final fabBg = _hsla(h, s.clamp(0.50, 0.85), 0.45);
    const fabFg = Color(0xffffffff);
    final cardBorder = _hsla(h, s * 0.10, 0.78);

    return VaultTheme(
      id: id,
      name: name,
      category: category,
      seedColor: seed,
      brightness: Brightness.light,
      scaffoldBg: scaffoldBg,
      cardBg: cardBg,
      navBg: navBg,
      navIndicator: navIndicator,
      inputFill: inputFill,
      inputBorder: inputBorder,
      inputFocusBorder: inputFocusBorder,
      fabBg: fabBg,
      fabFg: fabFg,
      appBarBg: scaffoldBg,
      cardBorder: cardBorder,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Shorthand: build a Color from clamped HSL components.
  static Color _hsla(double hue, double sat, double light) {
    final h = ((hue % 360) + 360) % 360;
    return HSLColor.fromAHSL(
      1.0,
      h,
      sat.clamp(0.0, 1.0),
      light.clamp(0.0, 1.0),
    ).toColor();
  }

  // ── Batch generation ────────────────────────────────────────────────────────

  /// Generate both dark AND light variants from a single seed.
  static List<VaultTheme> pair({
    required String idPrefix,
    required String name,
    required Color seedColor,
  }) {
    return [
      fromSeed(
        id: '${idPrefix}_dark',
        name: '$name Dark',
        seedColor: seedColor,
        brightness: Brightness.dark,
      ),
      fromSeed(
        id: '${idPrefix}_light',
        name: '$name Light',
        seedColor: seedColor,
        brightness: Brightness.light,
      ),
    ];
  }

  /// Generate a palette of 6 evenly-spaced hues from a single seed.
  static List<VaultTheme> spectrum({
    required String idPrefix,
    Brightness brightness = Brightness.dark,
  }) {
    const hues = <double>[0, 60, 120, 180, 240, 300];
    const names = ['Red', 'Yellow', 'Green', 'Cyan', 'Blue', 'Magenta'];
    return List.generate(6, (i) {
      final seed = HSLColor.fromAHSL(1, hues[i], 0.75, 0.55).toColor();
      return fromSeed(
        id: '${idPrefix}_${names[i].toLowerCase()}',
        name: names[i],
        seedColor: seed,
        brightness: brightness,
        category: 'Generated',
      );
    });
  }
}

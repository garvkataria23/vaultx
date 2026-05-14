import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  static const _kThemeKey = 'vaultx_theme_id';

  VaultTheme _current = AppThemes.byId(AppThemes.defaultThemeId);
  ThemeData? _cachedThemeData;
  bool _initialized = false;
  bool _disposed = false;

  VaultTheme get current => _current;
  ThemeData get themeData {
    _cachedThemeData ??= _current.toThemeData();
    return _cachedThemeData!;
  }

  bool get isDark => _current.brightness == Brightness.dark;
  bool get isInitialized => _initialized;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Loads saved theme from disk. Call once at app start (before runApp or
  /// inside a FutureBuilder / ProviderScope init).
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_kThemeKey);
    if (savedId != null && !_disposed) {
      _current = AppThemes.byId(savedId);
    }
    if (!_disposed) {
      _initialized = true;
      _cachedThemeData = null;
      notifyListeners();
    }
  }

  /// Switch to a different theme and persist the choice.
  Future<void> setTheme(VaultTheme theme) async {
    if (_disposed) return;
    _current = theme;
    _cachedThemeData = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (!_disposed) {
      await prefs.setString(_kThemeKey, theme.id);
    }
  }

  /// Switch by ID (safe – falls back to default on unknown id).
  Future<void> setThemeById(String id) => setTheme(AppThemes.byId(id));

  /// Convenience: toggle between the first dark and first light theme.
  Future<void> toggleBrightness() async {
    if (isDark) {
      await setTheme(AppThemes.light.first);
    } else {
      await setTheme(AppThemes.dark.first);
    }
  }
}

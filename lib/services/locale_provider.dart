import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'audit_log.dart';

class LocaleProvider extends ChangeNotifier {
  Locale? _locale;

  Locale? get locale => _locale;

  LocaleProvider() {
    _loadLocale();
  }

  void _loadLocale() {
    if (!Hive.isBoxOpen('vaultx_settings')) return;
    final box = Hive.box('vaultx_settings');
    final String? languageCode = box.get('languageCode');
    if (languageCode != null) {
      _locale = Locale(languageCode);
      AuditLog.write('LOCALE_RESTORED: $languageCode');
    } else {
      _locale = null; // Use system default
    }
    notifyListeners();
  }

  Future<void> setLocale(Locale? locale) async {
    _locale = locale;
    if (!Hive.isBoxOpen('vaultx_settings')) return;
    final box = Hive.box('vaultx_settings');
    if (locale == null) {
      await box.delete('languageCode');
      AuditLog.write('LANGUAGE_CHANGED: system_default');
    } else {
      await box.put('languageCode', locale.languageCode);
      AuditLog.write('LANGUAGE_CHANGED: ${locale.languageCode}');
    }
    AuditLog.write('LOCALE_APPLIED: ${locale?.languageCode ?? 'system'}');
    notifyListeners();
  }
}

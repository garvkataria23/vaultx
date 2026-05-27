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
    final String? stored = box.get('languageCode');
    final String? country = box.get('languageCountry');
    if (stored != null) {
      _locale = country != null ? Locale(stored, country) : Locale(stored);
      AuditLog.write('LOCALE_RESTORED: $stored${country != null ? '_$country' : ''}');
    } else {
      _locale = null;
    }
    notifyListeners();
  }

  Future<void> setLocale(Locale? locale) async {
    _locale = locale;
    if (!Hive.isBoxOpen('vaultx_settings')) return;
    final box = Hive.box('vaultx_settings');
    if (locale == null) {
      await box.delete('languageCode');
      await box.delete('languageCountry');
      AuditLog.write('LANGUAGE_CHANGED: system_default');
    } else {
      await box.put('languageCode', locale.languageCode);
      if (locale.countryCode != null) {
        await box.put('languageCountry', locale.countryCode);
      } else {
        await box.delete('languageCountry');
      }
      AuditLog.write('LANGUAGE_CHANGED: ${locale.languageCode}${locale.countryCode != null ? '_${locale.countryCode}' : ''}');
    }
    AuditLog.write('LOCALE_APPLIED: ${locale?.languageCode ?? 'system'}');
    notifyListeners();
  }
}

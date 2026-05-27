import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vaultx/l10n/app_localizations.dart';
import '../services/services.dart';

class LanguagePickerScreen extends StatefulWidget {
  const LanguagePickerScreen({super.key});

  @override
  State<LanguagePickerScreen> createState() => _LanguagePickerScreenState();
}

class _LanguagePickerScreenState extends State<LanguagePickerScreen> {
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Top global and Indian languages as requested
  final List<Map<String, String>> _languages = [
    {'name': 'System Default', 'native': 'System Default', 'code': 'system'},
    {'name': 'English', 'native': 'English', 'code': 'en'},
    {'name': 'Hindi', 'native': 'हिन्दी', 'code': 'hi'},
    {'name': 'Marathi', 'native': 'मराठी', 'code': 'mr'},
    {'name': 'Gujarati', 'native': 'ગુજરાતી', 'code': 'gu'},
    {'name': 'Tamil', 'native': 'தமிழ்', 'code': 'ta'},
    {'name': 'Telugu', 'native': 'తెలుగు', 'code': 'te'},
    {'name': 'Kannada', 'native': 'ಕನ್ನಡ', 'code': 'kn'},
    {'name': 'Malayalam', 'native': 'മലയാളം', 'code': 'ml'},
    {'name': 'Punjabi', 'native': 'ਪੰਜਾਬੀ', 'code': 'pa'},
    {'name': 'Bengali', 'native': 'বাংলা', 'code': 'bn'},
    {'name': 'Urdu', 'native': 'اردو', 'code': 'ur'},
    {'name': 'Japanese', 'native': '日本語', 'code': 'ja'},
    {'name': 'Chinese Simplified', 'native': '简体中文', 'code': 'zh'},
    {'name': 'Chinese Traditional', 'native': '繁體中文', 'code': 'zh_TW'},
    {'name': 'Korean', 'native': '한국어', 'code': 'ko'},
    {'name': 'Arabic', 'native': 'العربية', 'code': 'ar'},
    {'name': 'French', 'native': 'Français', 'code': 'fr'},
    {'name': 'German', 'native': 'Deutsch', 'code': 'de'},
    {'name': 'Spanish', 'native': 'Español', 'code': 'es'},
    {'name': 'Italian', 'native': 'Italiano', 'code': 'it'},
    {'name': 'Portuguese', 'native': 'Português', 'code': 'pt'},
    {'name': 'Russian', 'native': 'Русский', 'code': 'ru'},
    {'name': 'Turkish', 'native': 'Türkçe', 'code': 'tr'},
    {'name': 'Thai', 'native': 'ไทย', 'code': 'th'},
    {'name': 'Vietnamese', 'native': 'Tiếng Việt', 'code': 'vi'},
    // Add more to reach 200+ if needed, but these cover the major ones requested
  ];

  List<Map<String, String>> get _filteredLanguages {
    if (_searchQuery.isEmpty) return _languages;
    return _languages.where((lang) {
      final name = lang['name']!.toLowerCase();
      final native = lang['native']!.toLowerCase();
      final query = _searchQuery.toLowerCase();
      return name.contains(query) || native.contains(query);
    }).toList();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final currentLocale = context.watch<LocaleProvider>().locale;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.selectLanguage),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: l10n.searchLanguage,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
        ),
      ),
      body: _filteredLanguages.isEmpty
          ? Center(child: Text(l10n.noLanguageFound))
          : ListView.builder(
              itemCount: _filteredLanguages.length,
              itemBuilder: (context, index) {
                final lang = _filteredLanguages[index];
                final isSelected = (lang['code'] == 'system' && currentLocale == null) ||
                    (currentLocale?.languageCode == lang['code']);

                return ListTile(
                  title: Text(lang['native']!),
                  subtitle: Text(lang['name']!),
                  trailing: isSelected ? Icon(Icons.check, color: cs.primary) : null,
                  onTap: () async {
                    if (lang['code'] == 'system') {
                      await context.read<LocaleProvider>().setLocale(null);
                    } else {
                      await context.read<LocaleProvider>().setLocale(Locale(lang['code']!));
                    }
                    if (context.mounted) Navigator.pop(context);
                  },
                );
              },
            ),
    );
  }
}

import 'package:hive_flutter/hive_flutter.dart';

import '../models/note.dart';

class SearchIndexService {
  SearchIndexService._();
  static final SearchIndexService instance = SearchIndexService._();

  static const _boxName = 'vaultx_search_index';
  Box? _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  Box get _b => _box!;

  /// Index a single note — splits title + body + transcript into tokens, maps each to note ID.
  Future<void> indexNote(SecureNote note) async {
    final tokens = _tokenize('${note.title} ${note.body} ${note.ocrText} ${note.transcript} ${note.summary} ${note.tags.join(' ')}');
    final noteId = note.id;
    for (final token in tokens) {
      final key = 'idx:$token';
      final existing = _b.get(key, defaultValue: <String>[]) as List<String>;
      if (!existing.contains(noteId)) {
        existing.add(noteId);
        await _b.put(key, existing);
      }
    }
  }

  /// Remove a note from the index.
  Future<void> removeNote(String id) async {
    final keys = _b.keys.where((k) => k.toString().startsWith('idx:'));
    for (final key in keys) {
      final existing = _b.get(key, defaultValue: <String>[]) as List<String>;
      if (existing.contains(id)) {
        existing.remove(id);
        if (existing.isEmpty) {
          await _b.delete(key);
        } else {
          await _b.put(key, existing);
        }
      }
    }
  }

  /// Rebuild the entire index from a list of notes.
  Future<void> rebuild(List<SecureNote> notes) async {
    final idxKeys = _b.keys.where((k) => k.toString().startsWith('idx:')).toList();
    for (final k in idxKeys) {
      await _b.delete(k);
    }
    for (final note in notes) {
      await indexNote(note);
    }
  }

  /// Search the index — returns note IDs that match any token in the query.
  Set<String> search(String query) {
    final queryTokens = _tokenize(query);
    if (queryTokens.isEmpty) return {};
    final results = <String>{};
    for (final token in queryTokens) {
      final matched = _b.keys.where((k) {
        final keyStr = k.toString();
        if (!keyStr.startsWith('idx:')) return false;
        final storedToken = keyStr.substring(4);
        return storedToken.startsWith(token) || token.startsWith(storedToken);
      });
      for (final k in matched) {
        final ids = _b.get(k, defaultValue: <String>[]) as List<String>;
        results.addAll(ids);
      }
    }
    return results;
  }

  /// Exact prefix match on the index for autocomplete-style lookups.
  List<String> suggestions(String prefix) {
    if (prefix.isEmpty) return [];
    final lower = prefix.toLowerCase();
    return _b.keys
        .where((k) => k.toString().startsWith('idx:$lower'))
        .map((k) => k.toString().substring(4))
        .take(10)
        .toList();
  }

  List<String> _tokenize(String text) {
    final cleaned = text.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), ' ');
    return cleaned.split(RegExp(r'\s+')).where((t) => t.length >= 2).toSet().toList();
  }
}

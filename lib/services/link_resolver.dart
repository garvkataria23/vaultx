import '../models/note.dart';

/// Resolves `[[Note Title]]` wiki-link syntax to note IDs.
///
/// Maintains a title→id index for fast lookup.
/// Supports exact and fuzzy (case-insensitive, prefix) matching.
class LinkResolver {
  LinkResolver();

  /// Index of lowercase title → list of note IDs
  final _titleIndex = <String, List<String>>{};

  /// All notes currently in the index.
  int get indexedCount => _titleIndex.length;

  /// Rebuild the title index from a list of notes.
  void rebuild(List<SecureNote> notes) {
    _titleIndex.clear();
    for (final note in notes) {
      final key = note.title.trim().toLowerCase();
      if (key.isEmpty) continue;
      _titleIndex.putIfAbsent(key, () => []).add(note.id);
    }
  }

  /// Add or update a single note in the index.
  void indexNote(SecureNote note) {
    final key = note.title.trim().toLowerCase();
    if (key.isEmpty) return;
    _titleIndex.putIfAbsent(key, () => []).add(note.id);
  }

  /// Remove a note from the index.
  void removeNote(String noteId, String title) {
    final key = title.trim().toLowerCase();
    final ids = _titleIndex[key];
    if (ids != null) {
      ids.remove(noteId);
      if (ids.isEmpty) _titleIndex.remove(key);
    }
  }

  /// Extract all `[[wiki-link]]` references from [text].
  static List<String> extractWikiLinks(String text) {
    final matches = RegExp(r'\[\[(.+?)\]\]').allMatches(text);
    return matches.map((m) => m.group(1)!.trim()).where((t) => t.isNotEmpty).toList();
  }

  /// Resolve a single wiki-link title to a note ID.
  /// Returns the first matching note ID, or null.
  String? resolve(String linkTitle) {
    final key = linkTitle.trim().toLowerCase();
    if (key.isEmpty) return null;

    // Exact match
    if (_titleIndex.containsKey(key)) {
      return _titleIndex[key]!.first;
    }

    // Prefix match (find notes whose title starts with the link text)
    for (final entry in _titleIndex.entries) {
      if (entry.key.startsWith(key) || entry.key.contains(key)) {
        return entry.value.first;
      }
    }

    return null;
  }

  /// Resolve all wiki-links in [text] to note IDs.
  /// Returns [linkIds] parameter mutated with resolved note IDs.
  List<String> resolveAll(String text) {
    final titles = extractWikiLinks(text);
    final ids = <String>{};
    for (final title in titles) {
      final id = resolve(title);
      if (id != null) ids.add(id);
    }
    return ids.toList();
  }

  /// Compute the set of note IDs that link *to* [noteId] (backlinks).
  List<String> computeBacklinks(String noteId, List<SecureNote> allNotes, {bool rebuildFirst = true}) {
    if (rebuildFirst) rebuild(allNotes);
    final backlinks = <String>[];
    for (final note in allNotes) {
      if (note.id == noteId) continue;
      if (note.links.contains(noteId)) {
        backlinks.add(note.id);
      }
    }
    return backlinks;
  }
}

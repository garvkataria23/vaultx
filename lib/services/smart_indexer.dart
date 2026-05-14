import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// Result from a fuzzy search query.
class SearchMatch {
  final SecureNote note;
  final double score;
  final String? matchedField;
  final String? matchedSnippet;

  const SearchMatch({
    required this.note,
    required this.score,
    this.matchedField,
    this.matchedSnippet,
  });

  Map<String, dynamic> toJson() => {
    'note': note.toJson(),
    'score': score,
    'matchedField': matchedField,
    'matchedSnippet': matchedSnippet,
  };

  factory SearchMatch.fromJson(Map<String, dynamic> json) => SearchMatch(
    note: json['note'] is Map
        ? SecureNote.fromJson(Map<String, dynamic>.from(json['note'] as Map))
        : SecureNote(id: '', title: '', body: '', type: NoteType.text, createdAt: DateTime.now(), updatedAt: DateTime.now()),
    score: (json['score'] as num?)?.toDouble() ?? 0.0,
    matchedField: json['matchedField'] as String?,
    matchedSnippet: json['matchedSnippet'] as String?,
  );
}

/// Filters that can be applied to a search.
class SearchFilters {
  final String query;
  final String? folder;
  final String? sort;
  final NoteType? noteType;
  final bool? pinned;
  final bool? favorite;
  final bool? hasAttachments;
  final bool? archived;
  final int? minPriority;
  final int? maxPriority;
  final String? category;

  const SearchFilters({
    this.query = '',
    this.folder,
    this.sort,
    this.noteType,
    this.pinned,
    this.favorite,
    this.hasAttachments,
    this.archived,
    this.minPriority,
    this.maxPriority,
    this.category,
  });

  Map<String, dynamic> toJson() => {
    'query': query,
    'folder': folder,
    'sort': sort,
    'noteType': noteType?.name,
    'pinned': pinned,
    'favorite': favorite,
    'hasAttachments': hasAttachments,
    'archived': archived,
    'minPriority': minPriority,
    'maxPriority': maxPriority,
    'category': category,
  };

  factory SearchFilters.fromJson(Map<String, dynamic> json) => SearchFilters(
    query: json['query'] as String? ?? '',
    folder: json['folder'] as String?,
    sort: json['sort'] as String?,
    noteType: json['noteType'] is String
        ? NoteType.values.byName(json['noteType'] as String)
        : null,
    pinned: json['pinned'] as bool?,
    favorite: json['favorite'] as bool?,
    hasAttachments: json['hasAttachments'] as bool?,
    archived: json['archived'] is bool ? json['archived'] as bool : null,
    minPriority: json['minPriority'] as int?,
    maxPriority: json['maxPriority'] as int?,
    category: json['category'] as String?,
  );

  SearchFilters copyWith({
    String? query,
    String? folder,
    String? sort,
    NoteType? noteType,
    bool? pinned,
    bool? favorite,
    bool? hasAttachments,
    bool? archived,
    int? minPriority,
    int? maxPriority,
    String? category,
  }) {
    return SearchFilters(
      query: query ?? this.query,
      folder: folder ?? this.folder,
      sort: sort ?? this.sort,
      noteType: noteType ?? this.noteType,
      pinned: pinned ?? this.pinned,
      favorite: favorite ?? this.favorite,
      hasAttachments: hasAttachments ?? this.hasAttachments,
      archived: archived ?? this.archived,
      minPriority: minPriority ?? this.minPriority,
      maxPriority: maxPriority ?? this.maxPriority,
      category: category ?? this.category,
    );
  }
}

/// Background text indexer providing fuzzy search and content matching.
///
/// All processing is local and synchronous for small vaults,
/// using efficient algorithms for memory-safe search.
class SmartIndexerService {
  /// Levenshtein distance between two strings.
  static int _levenshtein(String a, String b) {
    if (a.length < b.length) {
      final tmp = a;
      a = b;
      b = tmp;
    }
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.generate(b.length + 1, (i) => 0);
    for (var i = 0; i < a.length; i++) {
      curr[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        curr[j + 1] = min(min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
  }

  /// Returns a similarity score 0.0–1.0 for two strings using normalized
  /// Levenshtein distance. 1.0 = identical.
  static double _similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    final dist = _levenshtein(a.toLowerCase(), b.toLowerCase());
    final maxLen = max(a.length, b.length);
    if (maxLen == 0) return 1.0;
    return 1.0 - (dist / maxLen);
  }

  /// Tokenize a string into lowercase words.
  static List<String> _tokens(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  /// Weighted search across note fields.
  ///
  /// Returns matches sorted by descending score.
  static List<SearchMatch> search(
    List<SecureNote> notes,
    SearchFilters filters,
  ) {
    final q = filters.query.trim().toLowerCase();
    final results = <SearchMatch>[];

    for (final note in notes) {
      if (filters.archived != null && note.archived != filters.archived) {
        continue;
      }
      if (filters.noteType != null && note.type != filters.noteType) {
        continue;
      }
      if (filters.folder != null && note.folder != filters.folder) continue;
      if (filters.pinned != null && note.pinned != filters.pinned) continue;
      if (filters.favorite != null && note.favorite != filters.favorite) {
        continue;
      }
      if (filters.hasAttachments != null &&
          (note.attachments.isNotEmpty) != filters.hasAttachments) {
        continue;
      }
      final minP = filters.minPriority;
      if (minP != null && note.priority < minP) continue;
      final maxP = filters.maxPriority;
      if (maxP != null && note.priority > maxP) continue;

      if (q.isEmpty) {
        results.add(SearchMatch(note: note, score: 1.0));
        continue;
      }

      double bestScore = 0.0;
      String? bestField;
      String? bestSnippet;

      void scoreField(String fieldValue, String fieldName) {
        final lower = fieldValue.toLowerCase();
        if (lower.contains(q)) {
          final score = q.length / lower.length;
          if (score > bestScore) {
            bestScore = max(bestScore, 0.9 + score * 0.1);
            bestField = fieldName;
            final idx = lower.indexOf(q);
            final start = max(0, idx - 40);
            final end = min(fieldValue.length, idx + q.length + 40);
            bestSnippet =
                (start > 0 ? '...' : '') +
                fieldValue.substring(start, end) +
                (end < fieldValue.length ? '...' : '');
          }
        }
      }

      void scoreFuzzy(String fieldValue, String fieldName, double weight) {
        final sim = _similarity(
          q,
          fieldValue.length > 60 ? fieldValue.substring(0, 60) : fieldValue,
        );
        if (sim > 0.5) {
          final score = sim * weight;
          if (score > bestScore) {
            bestScore = score;
            bestField = fieldName;
            bestSnippet = fieldValue.length > 120
                ? '${fieldValue.substring(0, 120)}...'
                : fieldValue;
          }
        }
      }

      scoreField(note.title, 'title');
      scoreField(note.body, 'body');
      scoreField(note.folder, 'folder');

      for (final tag in note.tags) {
        scoreField(tag, 'tag');
      }

      if (note.ocrText.isNotEmpty) {
        scoreField(note.ocrText, 'ocr text');
      }

      if (bestScore < 0.8) {
        scoreFuzzy(note.title, 'title (fuzzy)', 0.9);
        if (bestScore < 0.6) {
          scoreFuzzy(note.body, 'body (fuzzy)', 0.6);
        }
      }

      if (bestScore > 0) {
        results.add(
          SearchMatch(
            note: note,
            score: bestScore,
            matchedField: bestField,
            matchedSnippet: bestSnippet,
          ),
        );
      }
    }

    results.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      if (filters.sort == 'title') {
        return a.note.title.compareTo(b.note.title);
      }
      if (filters.sort == 'priority') {
        return a.note.priority.compareTo(b.note.priority);
      }
      return b.note.updatedAt.compareTo(a.note.updatedAt);
    });

    return results;
  }

  /// Extract search suggestions from the note corpus.
  static List<String> suggestions(List<SecureNote> notes) {
    final seen = <String>{};
    final result = <String>[];
    for (final note in notes) {
      for (final token in _tokens(note.title)) {
        if (seen.add(token) && token.length > 2) result.add(token);
      }
      for (final token in _tokens(note.body)) {
        if (seen.add(token) && token.length > 3) result.add(token);
      }
      for (final tag in note.tags) {
        if (seen.add(tag.toLowerCase())) result.add('#$tag');
      }
    }
    result.sort((a, b) => a.length.compareTo(b.length));
    return result;
  }

  /// Async version of [search] that runs in a background isolate via [compute].
  static Future<List<SearchMatch>> searchAsync(
    List<SecureNote> notes,
    SearchFilters filters,
  ) async {
    final result = await compute(_searchWork, {
      'notes': notes.map((n) => n.toJson()).toList(),
      'filters': filters.toJson(),
    });
    return (result as List)
        .map((e) => SearchMatch.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Async version of [suggestions] that runs in a background isolate.
  static Future<List<String>> suggestionsAsync(List<SecureNote> notes) async {
    return compute(
      _suggestionsWork,
      notes.map((n) => n.toJson()).toList(),
    );
  }
}

List<Map<String, dynamic>> _searchWork(Map<String, dynamic> input) {
  final notes = (input['notes'] as List)
      .map((e) => SecureNote.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
  final filters = SearchFilters.fromJson(
    Map<String, dynamic>.from(input['filters'] as Map),
  );
  return SmartIndexerService.search(notes, filters).map((m) => m.toJson()).toList();
}

List<String> _suggestionsWork(List<Map<String, dynamic>> notesJson) {
  final notes = notesJson
      .map((e) => SecureNote.fromJson(e))
      .toList();
  return SmartIndexerService.suggestions(notes);
}

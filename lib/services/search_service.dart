import 'dart:async';

import '../models/models.dart';
import 'note_analyzer.dart';
import 'smart_indexer.dart';

/// High-level search orchestrator that combines indexing, analysis, and filters.
///
/// Handles async lifecycle safety and provides debounced search for UI input.
class SearchService {
  SearchService() {
    _init();
  }

  NoteAnalyzerService? _analyzer;
  Timer? _debounceTimer;
  Completer<void>? _readyCompleter;

  void _init() {
    _readyCompleter = Completer<void>();
    _analyzer = NoteAnalyzerService();
    _readyCompleter?.complete();
  }

  /// Whether the service is ready to process queries.
  bool get isReady => _readyCompleter?.isCompleted ?? false;

  /// Await until the service is fully initialized.
  Future<void> get ready => _readyCompleter?.future ?? Future.value();

  /// Perform a search with optional category awareness.
  ///
  /// Returns matches sorted by relevance. Pass [allNotes] when available
  /// to enable duplicate detection and category grouping.
  List<SearchMatch> search(
    List<SecureNote> notes,
    SearchFilters filters, {
    List<SecureNote>? allNotes,
  }) {
    if (_isNoOp(filters)) {
      final results = notes
          .map((n) => SearchMatch(note: n, score: 1.0))
          .toList();
      _applySort(results, filters.sort);
      return results;
    }

    final filtered = _applyCategoryFilter(notes, filters);
    return SmartIndexerService.search(filtered, filters);
  }

  /// Async version of [search] that runs the indexer in a background isolate.
  Future<List<SearchMatch>> searchAsync(
    List<SecureNote> notes,
    SearchFilters filters, {
    List<SecureNote>? allNotes,
  }) async {
    if (_isNoOp(filters)) {
      final results = notes
          .map((n) => SearchMatch(note: n, score: 1.0))
          .toList();
      _applySort(results, filters.sort);
      return results;
    }

    final filtered = _applyCategoryFilter(notes, filters);
    return SmartIndexerService.searchAsync(filtered, filters);
  }

  bool _isNoOp(SearchFilters filters) =>
      filters.query.isEmpty &&
      filters.noteType == null &&
      filters.folder == null &&
      filters.pinned == null &&
      filters.favorite == null &&
      filters.hasAttachments == null &&
      filters.category == null;

  List<SecureNote> _applyCategoryFilter(
    List<SecureNote> notes,
    SearchFilters filters,
  ) {
    if (filters.category == null || _analyzer == null) return notes;
    final category = NoteCategory.values.firstWhere(
      (c) => c.name == filters.category,
      orElse: () => NoteCategory.general,
    );
    return notes.where((n) {
      final analysis = _analyzer!.analyze(n);
      return analysis.category == category;
    }).toList();
  }

  /// Get search suggestions based on note corpus.
  List<String> getSuggestions(List<SecureNote> notes) {
    return SmartIndexerService.suggestions(notes);
  }

  /// Get category breakdown for all notes.
  Map<NoteCategory, List<SecureNote>> getCategories(List<SecureNote> notes) {
    if (_analyzer == null) return {};
    // Get category for each note
    final result = <NoteCategory, List<SecureNote>>{};
    for (final note in notes) {
      final cat = _analyzer!.analyze(note).category;
      result.putIfAbsent(cat, () => []).add(note);
    }
    return result;
  }

  /// Get notes that contain sensitive data.
  List<SecureNote> getSensitiveNotes(List<SecureNote> notes) {
    if (_analyzer == null) return [];
    return _analyzer!.notesWithSensitiveData(notes);
  }

  /// Get duplicate groups.
  List<List<SecureNote>> getDuplicates(List<SecureNote> notes) {
    if (_analyzer == null) return [];
    return _analyzer!.findDuplicates(notes);
  }

  /// Debounced search for use with live text input.
  void debouncedSearch(String query, void Function() onReady) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 150), onReady);
  }

  /// Cancel any pending debounced search.
  void cancelDebounce() {
    _debounceTimer?.cancel();
  }

  void dispose() {
    _debounceTimer?.cancel();
    _readyCompleter = null;
    _analyzer = null;
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _applySort(List<SearchMatch> results, String? sort) {
    if (sort == 'title') {
      results.sort((a, b) => a.note.title.compareTo(b.note.title));
    } else if (sort == 'priority') {
      results.sort((a, b) => a.note.priority.compareTo(b.note.priority));
    } else {
      results.sort((a, b) => b.note.updatedAt.compareTo(a.note.updatedAt));
    }
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'note_analyzer.dart';
import 'search_index_service.dart';
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

  /// Pre-filter notes using the persistent search index for faster queries.
  Future<List<SecureNote>> _prefilterByIndex(List<SecureNote> notes, String query) async {
    if (query.isEmpty) return notes;
    final matchedIds = await SearchIndexService.instance.search(query);
    if (matchedIds.isEmpty) return notes;
    return notes.where((n) => matchedIds.contains(n.id)).toList();
  }

  /// Perform a search with optional category awareness.
  ///
  /// Returns matches sorted by relevance. Pass [allNotes] when available
  /// to enable duplicate detection and category grouping.
  Future<List<SearchMatch>> search(
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

    // Fast-path: use persistent index to narrow candidate pool by query.
    var candidates = notes;
    if (filters.query.isNotEmpty) {
      candidates = await _prefilterByIndex(notes, filters.query);
    }

    final filtered = _applyCategoryFilter(candidates, filters);
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

    var candidates = notes;
    if (filters.query.isNotEmpty) {
      candidates = await _prefilterByIndex(notes, filters.query);
    }

    final filtered = _applyCategoryFilter(candidates, filters);
    return SmartIndexerService.searchAsync(filtered, filters);
  }

  bool _isNoOp(SearchFilters filters) =>
      filters.query.isEmpty &&
      filters.noteType == null &&
      filters.folder == null &&
      filters.pinned == null &&
      filters.favorite == null &&
      filters.hasAttachments == null &&
      filters.category == null &&
      filters.hasImages == null &&
      filters.hasPdfs == null &&
      filters.hasAudio == null &&
      filters.hasVideo == null &&
      filters.isLocked == null &&
      filters.isImportedZip == null &&
      (filters.tags == null || filters.tags!.isEmpty);

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
  
  /// Async search suggestions based on note corpus.
  Future<List<String>> getSuggestionsAsync(List<SecureNote> notes) async {
    return SmartIndexerService.suggestionsAsync(notes);
  }

  /// Get category breakdown for all notes.
  Map<NoteCategory, List<SecureNote>> getCategories(List<SecureNote> notes) {
    if (_analyzer == null) return {};
    final result = <NoteCategory, List<SecureNote>>{};
    for (final note in notes) {
      final cat = _analyzer!.analyze(note).category;
      result.putIfAbsent(cat, () => []).add(note);
    }
    return result;
  }

  /// Async category breakdown running without isolate to prevent serialization overhead.
  Future<Map<NoteCategory, List<SecureNote>>> getCategoriesAsync(List<SecureNote> notes) async {
    if (notes.isEmpty) return {};
    await Future.delayed(Duration.zero);
    return getCategories(notes);
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
    results.sort((a, b) {
      switch (sort) {
        case 'titleAsc':
        case 'title':
        case 'A-Z':
          return a.note.title.toLowerCase().compareTo(b.note.title.toLowerCase());
        case 'priority':
          return b.note.priority.compareTo(a.note.priority);
        case 'dateAsc':
        case 'oldest':
        case 'Oldest':
          return a.note.createdAt.compareTo(b.note.createdAt);
        case 'updatedDesc':
        case 'lastEdited':
        case 'Last Edited':
          return b.note.updatedAt.compareTo(a.note.updatedAt);
        case 'sizeDesc':
        case 'largest':
        case 'Largest Notes':
          final sizeA = a.note.body.length + a.note.attachments.fold(0, (sum, att) => sum + att.size);
          final sizeB = b.note.body.length + b.note.attachments.fold(0, (sum, att) => sum + att.size);
          return sizeB.compareTo(sizeA);
        case 'dateDesc':
        case 'newest':
        case 'Newest':
        default:
          return b.note.createdAt.compareTo(a.note.createdAt);
      }
    });
  }
}

Map<String, List<Map<String, dynamic>>> _categoriesWork(List<Map<String, dynamic>> notesJson) {
  final analyzer = NoteAnalyzerService();
  final notes = notesJson.map((e) => SecureNote.fromJson(e)).toList();
  final result = <String, List<Map<String, dynamic>>>{};
  for (final note in notes) {
    final cat = analyzer.analyze(note).category;
    result.putIfAbsent(cat.name, () => []).add(note.toJson());
  }
  return result;
}

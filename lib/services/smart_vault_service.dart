import 'dart:math';
import 'dart:collection';

import '../models/models.dart';
import 'note_analyzer.dart';
import 'summarization_service.dart';

class SmartVaultResult {
  final String type;
  final String title;
  final String? subtitle;
  final List<SecureNote> notes;
  final double relevance;
  final String? summary;

  const SmartVaultResult({
    required this.type,
    required this.title,
    this.subtitle,
    this.notes = const [],
    this.relevance = 1.0,
    this.summary,
  });
}

class AIMemory {
  final String key;
  final String instruction;
  final DateTime createdAt;

  const AIMemory({
    required this.key,
    required this.instruction,
    required this.createdAt,
  });
}

class SmartVaultService {
  final NoteAnalyzerService _analyzer = NoteAnalyzerService();

  final List<AIMemory> _memories = [];
  late final Map<String, Set<String>> _thematicIndex = _buildThematicIndex();

  SmartVaultService();

  Map<String, Set<String>> _buildThematicIndex() {
    return {
      'cricket': {'cricket', 'match', 'batting', 'bowling', 'score', 'ipl', 't20', 'test', 'odi', 'sports', 'team', 'player', 'wicket', 'run'},
      'finance': {'finance', 'money', 'bank', 'account', 'payment', 'transaction', 'budget', 'expense', 'income', 'investment', 'stock', 'tax', 'salary', 'loan', 'credit', 'debit', 'invoice', 'receipt'},
      'password': {'password', 'login', 'credential', 'account', 'username', 'secret', 'auth', 'authentication', 'key', 'token', 'access'},
      'backup': {'backup', 'restore', 'mega', 'drive', 'google', 'cloud', 'sync', 'storage', 'export', 'import'},
      'flutter': {'flutter', 'dart', 'widget', 'app', 'mobile', 'code', 'snippet', 'framework', 'development'},
      'internship': {'internship', 'intern', 'job', 'work', 'career', 'experience', 'learning', 'training', 'placement', 'opportunity'},
      'health': {'health', 'doctor', 'medical', 'medicine', 'fitness', 'exercise', 'workout', 'diet', 'nutrition', 'symptom'},
      'travel': {'travel', 'trip', 'flight', 'hotel', 'booking', 'vacation', 'holiday', 'destination', 'tour'},
      'tech': {'tech', 'code', 'programming', 'software', 'hardware', 'computer', 'app', 'api', 'server', 'database'},
      'education': {'education', 'study', 'course', 'lecture', 'exam', 'assignment', 'class', 'learning', 'research'},
      'work': {'work', 'meeting', 'project', 'office', 'task', 'deadline', 'colleague', 'client', 'presentation'},
      'personal': {'personal', 'diary', 'journal', 'thought', 'idea', 'note', 'reminder', 'goal', 'habit'},
      'car': {'car', 'vehicle', 'auto', 'red', 'blue', 'black', 'white', 'drive', 'fuel', 'service', 'maintenance'},
      'screenshot': {'screenshot', 'image', 'photo', 'picture', 'capture', 'screen', 'attachment', 'media'},
    };
  }

  final List<Map<String, String>> _intentPatterns = [
    {'pattern': r'(?i)^(summarize|summary|summarise|gist|tl;dr|tl dr)\s+', 'intent': 'summarize'},
    {'pattern': r'(?i)(duplicate|duplicates|duplicated|find\s+(same|similar|copy))', 'intent': 'duplicates'},
    {'pattern': r'(?i)(related|similar|like|same\s+as)', 'intent': 'related'},
    {'pattern': r'(?i)(pin|memory|remember|prioritize|prioritise)', 'intent': 'memory'},
    {'pattern': r'(?i)(tag|label|categorize|categorise|suggest\s+tags)', 'intent': 'tags'},
    {'pattern': r'(?i)(hidden\s+connection|find\s+connection|relate|link\s+note)', 'intent': 'connections'},
    {'pattern': r'(?i)(image|screenshot|picture|photo|media)', 'intent': 'media'},
    {'pattern': r'(?i)(voice|audio|recording|recorded)', 'intent': 'voice'},
    {'pattern': r'(?i)(insight|insights|most\s+worked|trending|popular)', 'intent': 'insights'},
    {'pattern': r'(?i)(folder|group|organize|organise|auto\s*folder|smart\s*folder)', 'intent': 'folders'},
    {'pattern': r'(?i)(today|what\s+did\s+I\s+work|recent|latest|what\s+worked)', 'intent': 'recent'},
    {'pattern': r'(?i)(from|since|last|past|this|previous)\s+(week|month|year|day|today|yesterday)', 'intent': 'timeline'},
    {'pattern': r'(?i)(ask|tell|what|who|when|where|why|how|did|does|is|are)\s+', 'intent': 'ask'},
    {'pattern': r'(?i)(find|show|get|search|display|list)\s+.*(note|notes)', 'intent': 'search'},
    {'pattern': r'(?i)(open|go\s+to|navigate\s+to)\s+(home|drive|security|settings|game)', 'intent': 'navigate'},
  ];

  String _detectIntent(String query) {
    for (final entry in _intentPatterns) {
      if (RegExp(entry['pattern']!).hasMatch(query)) {
        return entry['intent']!;
      }
    }
    return 'search';
  }

  List<String> _expandQuery(String query) {
    final expanded = <String>{};
    final lower = query.toLowerCase();
    final words = lower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();

    for (final word in words) {
      expanded.add(word);
      for (final entry in _thematicIndex.entries) {
        if (entry.value.contains(word)) {
          expanded.addAll(entry.value);
        }
      }
    }
    return expanded.toList();
  }

  List<SecureNote> _filterByTime(List<SecureNote> notes, String query) {
    final now = DateTime.now();
    final lower = query.toLowerCase();

    Duration? range;
    if (lower.contains('today') || lower.contains('this day')) {
      range = const Duration(days: 1);
    } else if (lower.contains('yesterday')) {
      final yesterday = now.subtract(const Duration(days: 1));
      return notes.where((n) =>
        n.createdAt.year == yesterday.year &&
        n.createdAt.month == yesterday.month &&
        n.createdAt.day == yesterday.day).toList();
    } else if (lower.contains('this week')) {
      range = const Duration(days: 7);
    } else if (lower.contains('last week')) {
      final start = now.subtract(const Duration(days: 14));
      final end = now.subtract(const Duration(days: 7));
      return notes.where((n) =>
        n.createdAt.isAfter(start) && n.createdAt.isBefore(end)).toList();
    } else if (lower.contains('this month')) {
      range = const Duration(days: 30);
    } else if (lower.contains('last month')) {
      final start = now.subtract(const Duration(days: 60));
      final end = now.subtract(const Duration(days: 30));
      return notes.where((n) =>
        n.createdAt.isAfter(start) && n.createdAt.isBefore(end)).toList();
    } else if (lower.contains('this year')) {
      range = const Duration(days: 365);
    } else if (lower.contains('last year')) {
      final start = now.subtract(const Duration(days: 730));
      final end = now.subtract(const Duration(days: 365));
      return notes.where((n) =>
        n.createdAt.isAfter(start) && n.createdAt.isBefore(end)).toList();
    } else if (lower.contains('past 7') || lower.contains('7 days') || lower.contains('one week')) {
      range = const Duration(days: 7);
    } else if (lower.contains('past 30') || lower.contains('30 days') || lower.contains('one month')) {
      range = const Duration(days: 30);
    } else if (lower.contains('past 90') || lower.contains('90 days') || lower.contains('three month')) {
      range = const Duration(days: 90);
    }

    if (range != null) {
      final cutoff = now.subtract(range);
      return notes.where((n) => n.createdAt.isAfter(cutoff)).toList();
    }

    return notes;
  }

  List<SecureNote> _filterByFolder(List<SecureNote> notes, String query) {
    final lower = query.toLowerCase();
    final folderKeywords = <String, String>{
      'finance': 'Finance', 'bank': 'Finance', 'money': 'Finance',
      'work': 'Work', 'office': 'Work', 'project': 'Work',
      'personal': 'Personal', 'diary': 'Personal',
      'tech': 'Tech', 'code': 'Tech', 'programming': 'Tech',
      'health': 'Health', 'medical': 'Health', 'fitness': 'Health',
      'education': 'Education', 'study': 'Education', 'college': 'Education',
      'shopping': 'Shopping', 'receipt': 'Receipts',
      'travel': 'Travel', 'trip': 'Travel',
      'password': 'Passwords', 'login': 'Passwords',
    };

    for (final entry in folderKeywords.entries) {
      if (lower.contains(entry.key)) {
        return notes.where((n) =>
          n.folder.toLowerCase() == entry.value.toLowerCase()).toList();
      }
    }
    return notes;
  }

  double _tfIdfSimilarity(String text, List<String> queryTerms) {
    if (queryTerms.isEmpty || text.isEmpty) return 0.0;

    final lower = text.toLowerCase();
    final tokens = lower.split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return 0.0;

    final tf = HashMap<String, double>();
    final totalTerms = tokens.length;
    for (final token in tokens) {
      tf[token] = (tf[token] ?? 0.0) + 1.0 / totalTerms;
    }

    double score = 0.0;
    for (final term in queryTerms) {
      final termLower = term.toLowerCase();
      double termScore = 0.0;

      for (final entry in tf.entries) {
        if (entry.key == termLower) {
          termScore += entry.value * 1.0;
        } else if (entry.key.startsWith(termLower) || termLower.startsWith(entry.key)) {
          termScore += entry.value * 0.7;
        } else if (_levenshteinSimilarity(entry.key, termLower) > 0.7) {
          termScore += entry.value * 0.5;
        }
      }

      if (termScore > 0) {
        final idf = 1.0 + log(1.0 / (1.0 + termScore));
        score += termScore * idf;
      }
    }

    return score;
  }

  double _levenshteinSimilarity(String a, String b) {
    if (a.length < b.length) {
      final tmp = a; a = b; b = tmp;
    }
    if (b.isEmpty) return a.isEmpty ? 1.0 : 0.0;

    var prev = List.generate(b.length + 1, (i) => i);
    var curr = List.generate(b.length + 1, (i) => 0);

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

    final maxLen = max(a.length, b.length);
    return 1.0 - (prev[b.length] / maxLen);
  }

  SecureNote? _findBestMention(List<SecureNote> notes, String query) {
    final lower = query.toLowerCase();
    final stopWords = {'the', 'a', 'an', 'is', 'are', 'was', 'were', 'my', 'our', 'your', 'his', 'her', 'its', 'their', 'about', 'from', 'where', 'what', 'when', 'how', 'show', 'find', 'get', 'list', 'display', 'search', 'note', 'notes', 'all', 'with', 'that', 'this', 'these', 'those'};

    final words = lower
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2 && !stopWords.contains(w))
        .toList();

    if (words.isEmpty) return null;

    final expandedTerms = _expandQuery(query);
    final queryTerms = [...words, ...expandedTerms];

    SecureNote? best;
    double bestScore = 0.0;

    for (final note in notes) {
      final text = '${note.title} ${note.body} ${note.summary} ${note.ocrText} ${note.transcript}';
      double score = _tfIdfSimilarity(text, queryTerms);

      if (note.title.isNotEmpty) {
        final titleScore = _tfIdfSimilarity(note.title, words) * 2.0;
        score += titleScore;
      }

      for (final tag in note.tags) {
        if (words.any((w) => tag.toLowerCase().contains(w))) {
          score += 1.5;
        }
      }

      final noteWords = note.body.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
      for (final qWord in words) {
        if (noteWords.contains(qWord)) {
          score += 1.0;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        best = note;
      }
    }

    return bestScore > 0.5 ? best : null;
  }

  List<SecureNote> _findRelatedNotesByContent(SecureNote note, List<SecureNote> allNotes) {
    final results = <_ScoredNote>[];
    final noteTokens = _tokenSet('${note.title} ${note.body} ${note.summary}');

    for (final other in allNotes) {
      if (other.id == note.id) continue;
      final otherTokens = _tokenSet('${other.title} ${other.body} ${other.summary}');
      if (noteTokens.isEmpty || otherTokens.isEmpty) continue;

      final intersection = noteTokens.intersection(otherTokens).length;
      final union = noteTokens.union(otherTokens).length;
      final jaccard = union > 0 ? intersection / union : 0.0;

      final sharedTags = note.tags.toSet().intersection(other.tags.toSet()).length;
      final tagScore = sharedTags * 0.2;

      final totalScore = jaccard * 0.8 + tagScore * 0.2;
      if (totalScore > 0.15) {
        results.add(_ScoredNote(other, totalScore));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(5).map((r) => r.note).toList();
  }

  Set<String> _tokenSet(String text) {
    return text.toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length > 2)
        .toSet();
  }

  String? _extractDateQuery(String query) {
    final lower = query.toLowerCase();
    if (lower.contains('today')) return 'today';
    if (lower.contains('yesterday')) return 'yesterday';
    if (lower.contains('this week')) return 'this week';
    if (lower.contains('last week')) return 'last week';
    if (lower.contains('this month')) return 'this month';
    if (lower.contains('last month')) return 'last month';
    if (lower.contains('this year')) return 'this year';
    if (lower.contains('last year')) return 'last year';
    if (lower.contains('last 7') || lower.contains('past 7') || lower.contains('7 days')) return '7 days';
    if (lower.contains('last 30') || lower.contains('past 30') || lower.contains('30 days')) return '30 days';
    return null;
  }

  String? _extractTopic(String query) {
    final lower = query.toLowerCase();
    final stopWords = {'the', 'a', 'an', 'is', 'are', 'was', 'were', 'my', 'our', 'your', 'his', 'her', 'its', 'their', 'about', 'from', 'where', 'what', 'when', 'how', 'show', 'find', 'get', 'list', 'display', 'search', 'note', 'notes', 'all', 'with', 'that', 'this', 'these', 'those', 'me', 'i', 'wrote', 'write', 'written', 'containing', 'for', 'in', 'on', 'at', 'by', 'to', 'of', 'and', 'or', 'if', 'then', 'else'};

    final words = lower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
    final contentWords = words.where((w) => w.length > 2 && !stopWords.contains(w)).toList();

    if (contentWords.length <= 3) {
      return contentWords.join(' ');
    }

    final dateWords = {'today', 'yesterday', 'week', 'month', 'year', 'day', 'last', 'this', 'past', 'previous'};
    final filtered = contentWords.where((w) => !dateWords.contains(w)).toList();
    return filtered.take(3).join(' ');
  }

  List<String> _generateSmartSuggestions(List<SecureNote> notes) {
    final suggestions = <String>[
      'Show notes from today',
      'Find backup notes',
      'Show recent work',
      'Find passwords',
      'Find my cricket notes',
      'Summarize my finance notes',
    ];

    if (notes.any((n) => n.attachments.isNotEmpty && n.attachments.any((a) => a.kind == 'image'))) {
      suggestions.add('Show notes containing screenshots');
    }

    if (notes.any((n) => n.type == NoteType.voice)) {
      suggestions.add('Find voice recordings');
    }

    if (notes.any((n) => n.tags.contains('work') || n.folder.toLowerCase() == 'work')) {
      suggestions.add('What did I work on today');
    }

    return suggestions;
  }

  String _generateSummary(List<SecureNote> notes, String topic) {
    if (notes.isEmpty) return '';
    if (notes.length == 1) {
      final s = SummarizationService.summarize(notes[0].body, maxSentences: 3);
      return s.isNotEmpty ? s : notes[0].body.length > 200 ? '${notes[0].body.substring(0, 200)}...' : notes[0].body;
    }

    final combined = notes.map((n) => '${n.title}: ${n.body}').join('\n');
    final s = SummarizationService.summarize(combined, maxSentences: 4);
    return s.isNotEmpty ? s : 'Found ${notes.length} notes about "$topic"';
  }

  String _generateInsight(List<SecureNote> notes) {
    if (notes.isEmpty) return 'Start creating notes to see insights';

    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    const monthAgo = Duration(days: 30);

    final thisWeek = notes.where((n) => n.createdAt.isAfter(weekAgo)).toList();
    final thisMonth = notes.where((n) => n.createdAt.isAfter(now.subtract(monthAgo))).toList();

    final folderCounts = <String, int>{};
    for (final n in notes) {
      folderCounts[n.folder] = (folderCounts[n.folder] ?? 0) + 1;
    }
    final topFolder = folderCounts.entries.fold<MapEntry<String, int>?>(
      null,
      (best, curr) => best == null || curr.value > best.value ? curr : best,
    );

    final tagCounts = <String, int>{};
    for (final n in notes) {
      for (final tag in n.tags) {
        tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      }
    }
    final topTag = tagCounts.entries.fold<MapEntry<String, int>?>(
      null,
      (best, curr) => best == null || curr.value > best.value ? curr : best,
    );

    final parts = <String>[];
    parts.add('You have ${notes.length} total notes');

    if (thisWeek.isNotEmpty) {
      parts.add('${thisWeek.length} created this week');
    }

    if (thisMonth.isNotEmpty) {
      parts.add('${thisMonth.length} this month');
    }

    if (topFolder != null) {
      parts.add('Most used folder: ${topFolder.key} (${topFolder.value} notes)');
    }

    if (topTag != null) {
      parts.add('Most used tag: #${topTag.key} (${topTag.value} notes)');
    }

    return parts.join(' • ');
  }

  String? _findHiddenConnection(List<SecureNote> allNotes) {
    if (allNotes.length < 2) return 'Add more notes to discover hidden connections';

    for (var i = 0; i < allNotes.length; i++) {
      for (var j = i + 1; j < allNotes.length; j++) {
        final a = allNotes[i];
        final b = allNotes[j];
        final aTokens = _tokenSet('${a.title} ${a.body}');
        final bTokens = _tokenSet('${b.title} ${b.body}');
        final shared = aTokens.intersection(bTokens);

        if (shared.length >= 3) {
          final sharedWords = shared.take(3).join(', ');
          return '"${a.title}" relates to "${b.title}" via shared terms: $sharedWords';
        }
      }
    }

    for (var i = 0; i < allNotes.length; i++) {
      for (var j = i + 1; j < allNotes.length; j++) {
        final a = allNotes[i];
        final b = allNotes[j];
        final sharedTags = a.tags.toSet().intersection(b.tags.toSet());
        if (sharedTags.isNotEmpty && a.folder != b.folder) {
          return '"${a.title}" and "${b.title}" share tags #${sharedTags.first} across different folders';
        }
      }
    }

    return null;
  }

  Future<SmartVaultResult> _handleConnections(List<SecureNote> notes) async {
    final connection = _findHiddenConnection(notes);
    if (connection == null) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No hidden connections found',
        subtitle: 'Connections appear when notes share topics across different contexts',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'connections',
      title: '🔗 Hidden Connection Found',
      subtitle: connection,
      notes: notes,
    );
  }

  String? _getPinnedMemoryResponse(String query) {
    final lower = query.toLowerCase();

    for (final memory in _memories) {
      if (lower.contains(memory.key.toLowerCase())) {
        return memory.instruction;
      }
    }

    if (lower.contains('pin') || lower.contains('remember') || lower.contains('prioritize') || lower.contains('prioritise')) {
      final words = lower.split(RegExp(r'[^a-z0-9]+'));
      final idx = words.indexWhere((w) => w == 'pin' || w == 'remember' || w == 'prioritize' || w == 'prioritise');
      if (idx >= 0 && idx + 1 < words.length) {
        final subject = words.sublist(idx + 1).where((w) => w.length > 2).join(' ');
        if (subject.isNotEmpty) {
          final key = subject.split(' ').first;
          _memories.add(AIMemory(
            key: key,
            instruction: 'Always prioritize notes about $subject',
            createdAt: DateTime.now(),
          ));
          return '🧠 I\'ll remember to prioritize "$subject" in future searches';
        }
      }
    }

    return null;
  }

  Future<SmartVaultResult> processQuery(String query, List<SecureNote> allNotes) async {
    final lower = query.trim().toLowerCase();
    if (lower.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'Ask me anything about your notes',
        subtitle: 'Try: "find my cricket notes" or "summarize finance notes"',
      );
    }

    final intent = _detectIntent(query);
    final activeNotes = allNotes.where((n) => !n.archived && !n.deleted).toList();

    final memoryResponse = _getPinnedMemoryResponse(query);
    if (memoryResponse != null) {
      return SmartVaultResult(
        type: 'memory',
        title: memoryResponse,
        notes: [],
      );
    }

    switch (intent) {
      case 'summarize':
        return _handleSummarize(query, activeNotes);
      case 'timeline':
        return _handleTimeline(query, activeNotes);
      case 'related':
        return _handleRelated(query, activeNotes);
      case 'tags':
        return _handleTags(query, activeNotes);
      case 'ask':
        return _handleAsk(query, activeNotes);
      case 'duplicates':
        return _handleDuplicates(activeNotes);
      case 'media':
        return _handleMedia(activeNotes);
      case 'insights':
        return _handleInsights(activeNotes);
      case 'voice':
        return _handleVoice(activeNotes);
      case 'connections':
        return _handleConnections(activeNotes);
      case 'navigate':
        return _handleNavigate(query);
      case 'memory':
        return SmartVaultResult(type: 'memory', title: 'Say "pin [topic]" or "remember [topic]" to set AI memory', notes: []);
      case 'recent':
        return _handleRecent(query, activeNotes);
      case 'folders':
        return _handleFolders(activeNotes);
      default:
        return _handleSearch(query, activeNotes);
    }
  }

  Future<SmartVaultResult> _handleSearch(String query, List<SecureNote> notes) async {
    final dateFiltered = _filterByTime(notes, query);
    final folderFiltered = _filterByFolder(dateFiltered, query);
    final hasTimeFilter = dateFiltered.length < notes.length;
    final hasFolderFilter = folderFiltered.length < dateFiltered.length;

    final matchedNote = _findBestMention(folderFiltered, query);

    if (matchedNote != null) {
      final snippet = _extractSnippet(matchedNote, query);
      return SmartVaultResult(
        type: 'note',
        title: matchedNote.title,
        subtitle: snippet,
        notes: [matchedNote],
        relevance: 1.0,
      );
    }

    if (hasTimeFilter || hasFolderFilter) {
      return SmartVaultResult(
        type: 'search',
        title: 'Found ${folderFiltered.length} notes',
        subtitle: _extractDateQuery(query) != null ? 'From ${_extractDateQuery(query)}' : null,
        notes: folderFiltered,
        relevance: 0.8,
      );
    }

    final expandedTerms = _expandQuery(query);
    final scored = <_ScoredNote>[];
    for (final note in notes) {
      final text = '${note.title} ${note.body} ${note.summary} ${note.ocrText} ${note.transcript}';
      double score = _tfIdfSimilarity(text, expandedTerms);
      if (note.title.isNotEmpty) {
        score += _tfIdfSimilarity(note.title, query.split(' ')) * 2.0;
      }
      if (score > 0.1) {
        scored.add(_ScoredNote(note, score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final results = scored.take(20).toList();

    if (results.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: 'No relevant notes found',
        subtitle: 'Try rephrasing your query or check different folders',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'search',
      title: 'Found ${results.length} relevant notes',
      subtitle: 'Best match: ${results.first.note.title}',
      notes: results.map((r) => r.note).toList(),
      relevance: results.first.score,
    );
  }

  Future<SmartVaultResult> _handleSummarize(String query, List<SecureNote> notes) async {
    final topic = _extractTopic(query);
    if (topic == null || topic.isEmpty) {
      return const SmartVaultResult(type: 'error', title: 'What would you like me to summarize?');
    }

    final matchedNote = _findBestMention(notes, query);
    if (matchedNote != null) {
      final summary = SummarizationService.summarize(matchedNote.body, maxSentences: 3);
      return SmartVaultResult(
        type: 'summary',
        title: 'Summary: ${matchedNote.title}',
        subtitle: summary.isNotEmpty ? summary : matchedNote.body.length > 200
            ? '${matchedNote.body.substring(0, 200)}...' : matchedNote.body,
        notes: [matchedNote],
      );
    }

    final topicNotes = <_ScoredNote>[];
    final expandedTerms = _expandQuery(query);
    for (final note in notes) {
      final text = '${note.title} ${note.body} ${note.summary}'.toLowerCase();
      final score = _tfIdfSimilarity(text, expandedTerms);
      if (score > 0.2) {
        topicNotes.add(_ScoredNote(note, score));
      }
    }
    topicNotes.sort((a, b) => b.score.compareTo(a.score));
    final relevant = topicNotes.take(5).map((r) => r.note).toList();

    if (relevant.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: 'No notes found about "$topic"',
        notes: [],
      );
    }

    final summary = _generateSummary(relevant, topic);
    return SmartVaultResult(
      type: 'summary',
      title: 'Summary of ${relevant.length} notes about "$topic"',
      subtitle: summary,
      notes: relevant,
    );
  }

  Future<SmartVaultResult> _handleTimeline(String query, List<SecureNote> notes) async {
    final timeRange = _extractDateQuery(query);
    final filtered = timeRange != null ? _filterByTime(notes, query) : notes;

    if (filtered.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: timeRange != null ? 'No notes from $timeRange' : 'No notes found',
        notes: [],
      );
    }

    filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return SmartVaultResult(
      type: 'timeline',
      title: '${filtered.length} notes ${timeRange ?? 'over time'}',
      subtitle: 'From ${filtered.last.createdAt.toString().substring(0, 10)} to ${filtered.first.createdAt.toString().substring(0, 10)}',
      notes: filtered,
    );
  }

  Future<SmartVaultResult> _handleRelated(String query, List<SecureNote> notes) async {
    final matchedNote = _findBestMention(notes, query);
    if (matchedNote == null) {
      return const SmartVaultResult(type: 'empty', title: 'Which note do you want related notes for?');
    }

    final related = _findRelatedNotesByContent(matchedNote, notes);
    if (related.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: 'No related notes found for "${matchedNote.title}"',
        notes: [matchedNote],
      );
    }

    return SmartVaultResult(
      type: 'related',
      title: 'Related to "${matchedNote.title}"',
      subtitle: 'Found ${related.length} related notes',
      notes: related,
    );
  }

  Future<SmartVaultResult> _handleTags(String query, List<SecureNote> notes) async {
    final matchedNote = _findBestMention(notes, query);
    final target = matchedNote ?? (notes.isNotEmpty ? notes.first : null);

    if (target == null) {
      return const SmartVaultResult(type: 'empty', title: 'No notes to generate tags for');
    }

    final analysis = _analyzer.analyze(target);
    final suggestedTags = analysis.suggestedTags;

    if (suggestedTags.isEmpty) {
      return SmartVaultResult(
        type: 'tags',
        title: 'Suggested tags for "${target.title}"',
        subtitle: 'No new tags suggested (existing: ${target.tags.join(", ")})',
        notes: [target],
      );
    }

    return SmartVaultResult(
      type: 'tags',
      title: 'Suggested tags for "${target.title}"',
      subtitle: 'Try adding: ${suggestedTags.take(5).join(", ")}',
      notes: [target],
    );
  }

  Future<SmartVaultResult> _handleAsk(String query, List<SecureNote> notes) async {
    final answerNote = _findBestMention(notes, query);
    if (answerNote == null) {
      final expandedTerms = _expandQuery(query);
      final scored = <_ScoredNote>[];
      for (final note in notes) {
        final text = '${note.title} ${note.body} ${note.summary}';
        final score = _tfIdfSimilarity(text, expandedTerms);
        if (score > 0.15) scored.add(_ScoredNote(note, score));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));

      if (scored.isEmpty) {
        return SmartVaultResult(
          type: 'empty',
          title: 'I couldn\'t find an answer in your notes',
          subtitle: 'Try a different question or check your note content',
          notes: [],
        );
      }

      final best = scored.first.note;
      final snippet = _extractSnippet(best, query);
      return SmartVaultResult(
        type: 'answer',
        title: 'Based on "${best.title}"',
        subtitle: snippet,
        notes: [best],
      );
    }

    final snippet = _extractSnippet(answerNote, query);
    return SmartVaultResult(
      type: 'answer',
      title: 'Found in "${answerNote.title}"',
      subtitle: snippet,
      notes: [answerNote],
    );
  }

  String _extractSnippet(SecureNote note, String query) {
    final lower = note.body.toLowerCase();
    final qLower = query.toLowerCase();
    final words = qLower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 2).toList();

    int bestIdx = -1;
    String bestWord = '';

    for (final word in words) {
      final idx = lower.indexOf(word);
      if (idx >= 0 && (bestIdx == -1 || idx < bestIdx)) {
        bestIdx = idx;
        bestWord = word;
      }
    }

    if (bestIdx >= 0) {
      final start = max(0, bestIdx - 50);
      final end = min(note.body.length, bestIdx + bestWord.length + 50);
      return '${start > 0 ? "..." : ""}${note.body.substring(start, end)}${end < note.body.length ? "..." : ""}';
    }

    return note.body.length > 150 ? '${note.body.substring(0, 150)}...' : note.body;
  }

  Future<SmartVaultResult> _handleDuplicates(List<SecureNote> notes) async {
    final duplicates = <List<SecureNote>>[];
    final checked = <String>{};

    for (var i = 0; i < notes.length; i++) {
      if (checked.contains(notes[i].id)) continue;
      final group = <SecureNote>[notes[i]];
      for (var j = i + 1; j < notes.length; j++) {
        if (checked.contains(notes[j].id)) continue;
        final sim = _contentSimilarity(notes[i], notes[j]);
        if (sim > 0.75) {
          group.add(notes[j]);
          checked.add(notes[j].id);
        }
      }
      if (group.length > 1) duplicates.add(group);
      checked.add(notes[i].id);
    }

    if (duplicates.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No duplicate notes detected',
        subtitle: 'All your notes appear to be unique',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'duplicates',
      title: 'Found ${duplicates.length} duplicate groups',
      subtitle: '${duplicates.fold(0, (sum, g) => sum + g.length)} notes involved',
      notes: duplicates.expand((g) => g).toList(),
    );
  }

  Future<SmartVaultResult> _handleMedia(List<SecureNote> notes) async {
    final withImages = notes.where((n) =>
      n.attachments.any((a) => a.kind == 'image')).toList();

    if (withImages.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No image notes found',
        subtitle: 'Notes with image attachments will appear here',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'media',
      title: '${withImages.length} notes contain images',
      notes: withImages,
    );
  }

  Future<SmartVaultResult> _handleInsights(List<SecureNote> notes) async {
    if (notes.isEmpty) {
      return const SmartVaultResult(
        type: 'insights',
        title: 'No data yet',
        subtitle: 'Start creating notes to see insights',
        notes: [],
      );
    }

    final insight = _generateInsight(notes);
    return SmartVaultResult(
      type: 'insights',
      title: '📊 Smart Insights',
      subtitle: insight,
      notes: notes,
    );
  }

  Future<SmartVaultResult> _handleVoice(List<SecureNote> notes) async {
    final voiceNotes = notes.where((n) =>
      n.type == NoteType.voice || n.transcript.isNotEmpty).toList();

    if (voiceNotes.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No voice recordings found',
        subtitle: 'Record voice notes to see them here',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'voice',
      title: '${voiceNotes.length} voice recordings',
      notes: voiceNotes,
    );
  }

  Future<SmartVaultResult> _handleRecent(String query, List<SecureNote> notes) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayNotes = notes.where((n) =>
      n.updatedAt.isAfter(todayStart) || n.createdAt.isAfter(todayStart)).toList();

    if (todayNotes.isEmpty) {
      final recentWeek = notes.where((n) =>
        n.updatedAt.isAfter(now.subtract(const Duration(days: 7)))).toList();
      if (recentWeek.isEmpty) {
        return const SmartVaultResult(
          type: 'empty',
          title: 'No recent activity found',
          subtitle: 'Your recent notes will appear here',
          notes: [],
        );
      }
      recentWeek.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return SmartVaultResult(
        type: 'recent',
        title: 'This week\'s activity',
        subtitle: '${recentWeek.length} notes updated this week',
        notes: recentWeek,
      );
    }

    todayNotes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return SmartVaultResult(
      type: 'recent',
      title: 'Today\'s activity',
      subtitle: 'You worked on ${todayNotes.length} notes today',
      notes: todayNotes,
    );
  }

  Future<SmartVaultResult> _handleNavigate(String query) async {
    final lower = query.toLowerCase();
    String target = 'Unknown';
    if (lower.contains('home')) target = 'Home';
    if (lower.contains('drive')) target = 'Drive';
    if (lower.contains('security')) target = 'Security';
    if (lower.contains('settings')) target = 'Settings';
    if (lower.contains('game')) target = 'VaultX Game';

    return SmartVaultResult(
      type: 'navigate',
      title: 'Navigating to $target',
      subtitle: 'Executing navigation intent...',
    );
  }

  Future<SmartVaultResult> _handleFolders(List<SecureNote> notes) async {
    final folderGroups = <String, List<SecureNote>>{};
    for (final note in notes) {
      folderGroups.putIfAbsent(note.folder, () => []).add(note);
    }

    final suggestions = <String>[];
    final analyzerGroups = _analyzer.groupByCategory(notes);
    for (final entry in analyzerGroups.entries) {
      if (entry.value.length >= 2) {
        final suggestedFolder = _getFolderFromCategory(entry.key);
        if (suggestedFolder != null && !folderGroups.containsKey(suggestedFolder)) {
          suggestions.add('Create "$suggestedFolder" folder for ${entry.value.length} ${entry.key.name} notes');
        }
      }
    }

    if (suggestions.isEmpty) {
      return SmartVaultResult(
        type: 'folders',
        title: '${folderGroups.length} active folders',
        subtitle: 'No new folder suggestions',
        notes: notes,
      );
    }

    return SmartVaultResult(
      type: 'folders',
      title: '${folderGroups.length} folders • ${suggestions.length} suggestions',
      subtitle: suggestions.join('\n'),
      notes: notes,
    );
  }

  double _contentSimilarity(SecureNote a, SecureNote b) {
    final tokensA = _tokenSet('${a.title} ${a.body} ${a.ocrText}');
    final tokensB = _tokenSet('${b.title} ${b.body} ${b.ocrText}');
    if (tokensA.isEmpty && tokensB.isEmpty) return 1.0;
    final intersection = tokensA.intersection(tokensB).length;
    final union = tokensA.union(tokensB).length;
    if (union == 0) return 0.0;
    return intersection / union;
  }

  String? _getFolderFromCategory(NoteCategory category) {
    switch (category) {
      case NoteCategory.finance: return 'Finance';
      case NoteCategory.work: return 'Work';
      case NoteCategory.personal: return 'Personal';
      case NoteCategory.tech: return 'Tech';
      case NoteCategory.health: return 'Health';
      case NoteCategory.education: return 'Education';
      case NoteCategory.shopping: return 'Shopping';
      case NoteCategory.travel: return 'Travel';
      case NoteCategory.passwords: return 'Passwords';
      default: return null;
    }
  }

  Future<List<SmartVaultResult>> processBatch(List<String> queries, List<SecureNote> allNotes) async {
    final results = <SmartVaultResult>[];
    for (final query in queries) {
      results.add(await processQuery(query, allNotes));
    }
    return results;
  }

  Map<String, int> getTopicFrequency(List<SecureNote> notes) {
    final freq = <String, int>{};
    for (final note in notes) {
      final topic = _analyzer.analyze(note).category.name;
      freq[topic] = (freq[topic] ?? 0) + 1;
    }
    return freq;
  }

  SecureNote? getMostWorkedTopic(List<SecureNote> notes) {
    if (notes.isEmpty) return null;
    final sorted = List<SecureNote>.from(notes)
      ..sort((a, b) => (b.viewCount + (b.versions.length)).compareTo(a.viewCount + (a.versions.length)));
    return sorted.first;
  }

  Map<String, int> getActivityByDay(List<SecureNote> notes, {int days = 7}) {
    final now = DateTime.now();
    final result = <String, int>{};
    for (var i = 0; i < days; i++) {
      final day = now.subtract(Duration(days: i));
      final key = '${day.month}/${day.day}';
      result[key] = 0;
    }
    for (final note in notes) {
      final key = '${note.updatedAt.month}/${note.updatedAt.day}';
      if (result.containsKey(key)) {
        result[key] = (result[key] ?? 0) + 1;
      }
    }
    return result;
  }

  List<String> getSuggestions(List<SecureNote> notes) {
    return _generateSmartSuggestions(notes);
  }
}

class _ScoredNote {
  final SecureNote note;
  final double score;
  const _ScoredNote(this.note, this.score);
}

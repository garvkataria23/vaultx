import '../models/models.dart';

/// Categories that notes can be auto-classified into.
enum NoteCategory {
  general,
  finance,
  work,
  personal,
  tech,
  health,
  education,
  shopping,
  travel,
  legal,
  social,
}

/// Result of analyzing a single note.
class NoteAnalysis {
  final NoteCategory category;
  final List<String> suggestedTags;
  final String? suggestedFolder;
  final bool containsSensitiveData;
  final List<String> sensitiveTypes;
  final bool isDuplicate;
  final String? duplicateOfId;

  const NoteAnalysis({
    this.category = NoteCategory.general,
    this.suggestedTags = const [],
    this.suggestedFolder,
    this.containsSensitiveData = false,
    this.sensitiveTypes = const [],
    this.isDuplicate = false,
    this.duplicateOfId,
  });
}

/// Local content analyzer that detects patterns and suggests organization.
///
/// All analysis runs locally — no data leaves the device.
class NoteAnalyzerService {
  NoteAnalyzerService();

  // ── Keyword maps for auto-categorization ──────────────────────────────────

  static const _categoryKeywords = <NoteCategory, List<String>>{
    NoteCategory.finance: [
      'bank',
      'account',
      'money',
      'transaction',
      'payment',
      'invoice',
      'receipt',
      'tax',
      'salary',
      'credit',
      'debit',
      'loan',
      'mortgage',
      'investment',
      'stock',
      'crypto',
      'wallet',
      'balance',
      'budget',
      'expense',
      'income',
      'finance',
      'bill',
      'insurance',
      'refund',
    ],
    NoteCategory.work: [
      'meeting',
      'project',
      'deadline',
      'client',
      'report',
      'presentation',
      'agenda',
      'minutes',
      'task',
      'sprint',
      'review',
      'feedback',
      'proposal',
      'contract',
      'timesheet',
      'email',
      'call',
      'interview',
      'standup',
      'deliverable',
      'milestone',
      'objective',
      'kpi',
    ],
    NoteCategory.personal: [
      'diary',
      'journal',
      'todo',
      'reminder',
      'note',
      'idea',
      'thought',
      'goal',
      'habit',
      'routine',
      'wishlist',
      'bucket',
      'resolution',
      'reflection',
      'gratitude',
      'mood',
      'dream',
      'memory',
    ],
    NoteCategory.tech: [
      'password',
      'api',
      'key',
      'token',
      'secret',
      'config',
      'code',
      'snippet',
      'command',
      'terminal',
      'script',
      'server',
      'database',
      'endpoint',
      'login',
      'credential',
      'ssh',
      'oauth',
      'url',
      'link',
      'protocol',
      'algorithm',
      'query',
      'syntax',
      'bug',
      'deploy',
    ],
    NoteCategory.health: [
      'doctor',
      'appointment',
      'prescription',
      'medication',
      'symptom',
      'diagnosis',
      'therapy',
      'workout',
      'diet',
      'nutrition',
      'vitamin',
      'exercise',
      'sleep',
      'heart',
      'blood',
      'weight',
      'fitness',
      'yoga',
      'vaccine',
      'allergy',
      'insurance',
      'hospital',
      'clinic',
    ],
    NoteCategory.education: [
      'course',
      'lecture',
      'study',
      'exam',
      'test',
      'quiz',
      'homework',
      'assignment',
      'grade',
      'lesson',
      'tutorial',
      'book',
      'article',
      'research',
      'paper',
      'thesis',
      'degree',
      'certificate',
      'training',
      'workshop',
      'seminar',
      'class',
      'note',
      'summary',
      'flashcard',
    ],
    NoteCategory.shopping: [
      'buy',
      'purchase',
      'order',
      'cart',
      'wishlist',
      'grocery',
      'store',
      'shop',
      'price',
      'discount',
      'coupon',
      'deal',
      'offer',
      'delivery',
      'amazon',
      'checkout',
      'return',
      'refund',
      'brand',
      'size',
      'color',
    ],
    NoteCategory.travel: [
      'trip',
      'flight',
      'hotel',
      'booking',
      'itinerary',
      'destination',
      'passport',
      'visa',
      'packing',
      'luggage',
      'tour',
      'map',
      'direction',
      'reservation',
      'checkin',
      'airport',
      'rental',
      'vacation',
      'holiday',
      'road',
      'travel',
      'abroad',
      'sightseeing',
    ],
    NoteCategory.legal: [
      'contract',
      'agreement',
      'terms',
      'policy',
      'disclosure',
      'license',
      'permit',
      'registration',
      'trademark',
      'copyright',
      'will',
      'estate',
      'tenant',
      'lease',
      'notice',
      'waiver',
      'affidavit',
      'attorney',
    ],
    NoteCategory.social: [
      'party',
      'event',
      'invitation',
      'rsvp',
      'celebration',
      'birthday',
      'wedding',
      'anniversary',
      'gathering',
      'friend',
      'family',
      'date',
      'dinner',
      'lunch',
      'coffee',
      'meetup',
      'concert',
      'festival',
    ],
  };

  // ── Sensitive data patterns ───────────────────────────────────────────────

  static final _sensitivePatterns = <Pattern, String>{
    RegExp(r'(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}'):
        'strong password',
    RegExp(
      r'\b(?:api[_-]?key|secret[_-]?key|access[_-]?token)\s*[:=]\s*\S+',
      caseSensitive: false,
    ): 'API key',
    RegExp(r'\b(?:sk[-_]|pk[-_])[a-zA-Z0-9]{20,}\b'): 'secret key',
    RegExp(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'): 'credit card',
    RegExp(r'\b\d{3}-\d{2}-\d{4}\b'): 'SSN',
    RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'): 'email',
    RegExp(r'\b(?:\+?\d{1,3}[-.]?)?\(?\d{3}\)?[-.]?\d{3}[-.]?\d{4}\b'):
        'phone number',
    RegExp(r'\bseed\s*(?:phrase|words|recovery)\b', caseSensitive: false):
        'seed phrase',
    RegExp(r'\bprivate\s*key\b', caseSensitive: false): 'private key',
    RegExp(r'\b(?:mnemonic|passphrase)\b', caseSensitive: false):
        'crypto mnemonic',
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Analyze a single note and return its analysis.
  NoteAnalysis analyze(SecureNote note, {List<SecureNote>? allNotes}) {
    final text = '${note.title} ${note.body} ${note.ocrText}'.toLowerCase();
    final category = _classify(text);
    final suggestedTags = _extractTags(text, note.tags);
    final suggestedFolder = _suggestFolder(category, note.folder);
    final sensitive = _detectSensitive(
      '${note.title}\n${note.body}\n${note.ocrText}',
    );
    final duplicate = allNotes != null ? _findDuplicate(note, allNotes) : null;

    return NoteAnalysis(
      category: category,
      suggestedTags: suggestedTags,
      suggestedFolder: suggestedFolder,
      containsSensitiveData: sensitive.isNotEmpty,
      sensitiveTypes: sensitive,
      isDuplicate: duplicate != null,
      duplicateOfId: duplicate?.id,
    );
  }

  /// Batch analyze all notes.
  List<NoteAnalysis> analyzeAll(List<SecureNote> notes) {
    return notes.map((n) => analyze(n, allNotes: notes)).toList();
  }

  /// Get suggested categories for a list of notes.
  Map<NoteCategory, List<SecureNote>> groupByCategory(List<SecureNote> notes) {
    final grouped = <NoteCategory, List<SecureNote>>{};
    for (final note in notes) {
      final cat = _classify('${note.title} ${note.body} ${note.ocrText}');
      grouped.putIfAbsent(cat, () => []).add(note);
    }
    return grouped;
  }

  /// Find notes with sensitive data.
  List<SecureNote> notesWithSensitiveData(List<SecureNote> notes) {
    return notes.where((n) {
      return _detectSensitive('${n.title}\n${n.body}\n${n.ocrText}').isNotEmpty;
    }).toList();
  }

  /// Find duplicate notes by content similarity.
  List<List<SecureNote>> findDuplicates(List<SecureNote> notes) {
    final duplicates = <List<SecureNote>>[];
    final checked = <String>{};
    for (var i = 0; i < notes.length; i++) {
      if (checked.contains(notes[i].id)) continue;
      final group = <SecureNote>[notes[i]];
      for (var j = i + 1; j < notes.length; j++) {
        if (_contentSimilarity(notes[i], notes[j]) > 0.75) {
          group.add(notes[j]);
          checked.add(notes[j].id);
        }
      }
      if (group.length > 1) duplicates.add(group);
      checked.add(notes[i].id);
    }
    return duplicates;
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  NoteCategory _classify(String text) {
    final scores = <NoteCategory, int>{};
    for (final entry in _categoryKeywords.entries) {
      var score = 0;
      for (final keyword in entry.value) {
        if (text.contains(keyword)) score++;
      }
      if (score > 0) scores[entry.key] = score;
    }
    if (scores.isEmpty) return NoteCategory.general;
    return scores.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  List<String> _extractTags(String text, List<String> existingTags) {
    final seen = <String>{};
    for (final tag in existingTags) {
      seen.add(tag.toLowerCase());
    }
    final suggested = <String>[];
    final words = text.split(RegExp(r'[^a-z0-9#]+'));

    for (final entry in _categoryKeywords.entries) {
      for (final keyword in entry.value) {
        if (words.contains(keyword) && !seen.contains(keyword)) {
          suggested.add(keyword);
          seen.add(keyword);
        }
      }
    }
    // Also extract hashtags
    for (final word in words) {
      if (word.startsWith('#') && word.length > 2 && !seen.contains(word)) {
        suggested.add(word.substring(1));
        seen.add(word);
      }
    }
    return suggested.take(5).toList();
  }

  String? _suggestFolder(NoteCategory category, String currentFolder) {
    if (currentFolder != 'Private' && currentFolder != '') return null;
    switch (category) {
      case NoteCategory.finance:
        return 'Finance';
      case NoteCategory.work:
        return 'Work';
      case NoteCategory.personal:
        return 'Personal';
      case NoteCategory.tech:
        return 'Tech';
      case NoteCategory.health:
        return 'Health';
      case NoteCategory.education:
        return 'Education';
      case NoteCategory.shopping:
        return 'Shopping';
      case NoteCategory.travel:
        return 'Travel';
      case NoteCategory.legal:
        return 'Legal';
      case NoteCategory.social:
        return 'Social';
      default:
        return null;
    }
  }

  List<String> _detectSensitive(String text) {
    final found = <String>[];
    for (final entry in _sensitivePatterns.entries) {
      if (entry.key is RegExp) {
        if ((entry.key as RegExp).hasMatch(text)) {
          found.add(entry.value);
        }
      }
    }
    return found;
  }

  SecureNote? _findDuplicate(SecureNote note, List<SecureNote> allNotes) {
    for (final other in allNotes) {
      if (other.id == note.id) continue;
      if (_contentSimilarity(note, other) > 0.8) return other;
    }
    return null;
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

  Set<String> _tokenSet(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length > 2)
        .toSet();
  }
}

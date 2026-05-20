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
  ideas,
  projects,
  receipts,
  media,
  passwords,
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
  final List<String> relatedNoteIds;

  const NoteAnalysis({
    this.category = NoteCategory.general,
    this.suggestedTags = const [],
    this.suggestedFolder,
    this.containsSensitiveData = false,
    this.sensitiveTypes = const [],
    this.isDuplicate = false,
    this.duplicateOfId,
    this.relatedNoteIds = const [],
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
      'bank', 'account', 'money', 'transaction', 'payment', 'invoice', 'receipt',
      'tax', 'salary', 'credit', 'debit', 'loan', 'mortgage', 'investment',
      'stock', 'crypto', 'wallet', 'balance', 'budget', 'expense', 'income',
      'finance', 'bill', 'insurance', 'refund', 'upi', 'paytm', 'gpay',
    ],
    NoteCategory.work: [
      'meeting', 'project', 'deadline', 'client', 'report', 'presentation',
      'agenda', 'minutes', 'task', 'sprint', 'review', 'feedback', 'proposal',
      'contract', 'timesheet', 'email', 'call', 'interview', 'standup',
      'deliverable', 'milestone', 'objective', 'kpi', 'office', 'boss', 'manager',
    ],
    NoteCategory.personal: [
      'diary', 'journal', 'todo', 'reminder', 'note', 'idea', 'thought', 'goal',
      'habit', 'routine', 'wishlist', 'bucket', 'resolution', 'reflection',
      'gratitude', 'mood', 'dream', 'memory', 'life', 'home',
    ],
    NoteCategory.tech: [
      'password', 'api', 'key', 'token', 'secret', 'config', 'code', 'snippet',
      'command', 'terminal', 'script', 'server', 'database', 'endpoint',
      'login', 'credential', 'ssh', 'oauth', 'url', 'link', 'protocol',
      'algorithm', 'query', 'syntax', 'bug', 'deploy', 'github', 'git', 'flutter',
    ],
    NoteCategory.health: [
      'doctor', 'appointment', 'prescription', 'medication', 'symptom',
      'diagnosis', 'therapy', 'workout', 'diet', 'nutrition', 'vitamin',
      'exercise', 'sleep', 'heart', 'blood', 'weight', 'fitness', 'yoga',
      'vaccine', 'allergy', 'insurance', 'hospital', 'clinic', 'medical',
    ],
    NoteCategory.education: [
      'course', 'lecture', 'study', 'exam', 'test', 'quiz', 'homework',
      'assignment', 'grade', 'lesson', 'tutorial', 'book', 'article',
      'research', 'paper', 'thesis', 'degree', 'certificate', 'training',
      'workshop', 'seminar', 'class', 'note', 'summary', 'flashcard', 'physics',
      'math', 'dbms', 'algorithm', 'college', 'university', 'viva',
    ],
    NoteCategory.shopping: [
      'buy', 'purchase', 'order', 'cart', 'wishlist', 'grocery', 'store',
      'shop', 'price', 'discount', 'coupon', 'deal', 'offer', 'delivery',
      'amazon', 'checkout', 'return', 'refund', 'brand', 'size', 'color',
    ],
    NoteCategory.travel: [
      'trip', 'flight', 'hotel', 'booking', 'itinerary', 'destination',
      'passport', 'visa', 'packing', 'luggage', 'tour', 'map', 'direction',
      'reservation', 'checkin', 'airport', 'rental', 'vacation', 'holiday',
      'road', 'travel', 'abroad', 'sightseeing',
    ],
    NoteCategory.legal: [
      'contract', 'agreement', 'terms', 'policy', 'disclosure', 'license',
      'permit', 'registration', 'trademark', 'copyright', 'will', 'estate',
      'tenant', 'lease', 'notice', 'waiver', 'affidavit', 'attorney',
    ],
    NoteCategory.social: [
      'party', 'event', 'invitation', 'rsvp', 'celebration', 'birthday',
      'wedding', 'anniversary', 'gathering', 'friend', 'family', 'date',
      'dinner', 'lunch', 'coffee', 'meetup', 'concert', 'festival',
    ],
    NoteCategory.ideas: [
      'idea', 'brainstorm', 'innovation', 'concept', 'startup', 'new', 'creative',
      'vision', 'future', 'possibility', 'draft', 'sketch',
    ],
    NoteCategory.projects: [
      'project', 'roadmap', 'phase', 'milestone', 'kanban', 'board', 'team',
      'collaboration', 'status', 'ongoing', 'backlog',
    ],
    NoteCategory.receipts: [
      'receipt', 'invoice', 'bill', 'purchase', 'order', 'transaction',
      'amount', 'total', 'paid', 'gst', 'vat', 'tax',
    ],
    NoteCategory.media: [
      'photo', 'video', 'audio', 'voice', 'recording', 'image', 'picture',
      'gallery', 'album', 'music', 'sound', 'movie', 'film',
    ],
    NoteCategory.passwords: [
      'password', 'login', 'account', 'username', 'credential', 'secret',
      'access', 'security', 'mfa', '2fa', 'otp',
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
    final text = '${note.title} ${note.body} ${note.ocrText} ${note.summary}'.toLowerCase();
    final category = _classify(note, text);
    final suggestedTags = _extractTags(text, note.tags);
    final suggestedFolder = _suggestFolder(category, note.folder);
    final sensitive = _detectSensitive(
      '${note.title}\n${note.body}\n${note.ocrText}',
    );
    final duplicate = allNotes != null ? _findDuplicate(note, allNotes) : null;
    final related = allNotes != null ? _findRelated(note, allNotes) : <String>[];

    return NoteAnalysis(
      category: category,
      suggestedTags: suggestedTags,
      suggestedFolder: suggestedFolder,
      containsSensitiveData: sensitive.isNotEmpty,
      sensitiveTypes: sensitive,
      isDuplicate: duplicate != null,
      duplicateOfId: duplicate?.id,
      relatedNoteIds: related,
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
      final text = '${note.title} ${note.body} ${note.ocrText} ${note.summary}'.toLowerCase();
      final cat = _classify(note, text);
      grouped.putIfAbsent(cat, () => []).add(note);
    }
    return grouped;
  }

  /// Find related notes for a specific note.
  List<SecureNote> findRelatedNotes(SecureNote note, List<SecureNote> allNotes) {
    final relatedIds = _findRelated(note, allNotes);
    return allNotes.where((n) => relatedIds.contains(n.id)).toList();
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

  NoteCategory _classify(SecureNote note, String text) {
    final scores = <NoteCategory, double>{};
    
    // 1. Keyword scoring
    for (final entry in _categoryKeywords.entries) {
      var score = 0.0;
      for (final keyword in entry.value) {
        if (text.contains(keyword)) {
          // Keywords in title or summary have higher weight
          if (note.title.toLowerCase().contains(keyword)) score += 2.0;
          if (note.summary.toLowerCase().contains(keyword)) score += 1.5;
          score += 1.0;
        }
      }
      if (score > 0) scores[entry.key] = score;
    }

    // 2. Attachment-based signals
    for (final att in note.attachments) {
      final name = att.name.toLowerCase();
      if (att.kind == 'image' || att.kind == 'video' || att.kind == 'audio' || att.kind == 'voice') {
        scores[NoteCategory.media] = (scores[NoteCategory.media] ?? 0.0) + 5.0;
      }
      if (name.contains('receipt') || name.contains('bill') || name.contains('invoice')) {
        scores[NoteCategory.receipts] = (scores[NoteCategory.receipts] ?? 0.0) + 5.0;
      }
      if (name.endsWith('.pdf')) {
        scores[NoteCategory.education] = (scores[NoteCategory.education] ?? 0.0) + 1.0;
        scores[NoteCategory.work] = (scores[NoteCategory.work] ?? 0.0) + 1.0;
      }
    }

    // 3. Type-based signals
    if (note.type == NoteType.voice) {
      scores[NoteCategory.media] = (scores[NoteCategory.media] ?? 0.0) + 3.0;
    }

    if (scores.isEmpty) return NoteCategory.general;

    // Pick highest score
    return scores.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  List<String> _findRelated(SecureNote note, List<SecureNote> allNotes) {
    final results = <({String id, double score})>[];
    
    for (final other in allNotes) {
      if (other.id == note.id) continue;
      
      double score = 0.0;
      
      // 1. Direct links (Direct link signal)
      if (note.links.contains(other.id) || note.links.contains(other.title)) score += 10.0;
      if (other.links.contains(note.id) || other.links.contains(note.title)) score += 10.0;
      
      // 2. Shared tags
      final sharedTags = note.tags.toSet().intersection(other.tags.toSet());
      score += sharedTags.length * 3.0;
      
      // 3. Content similarity
      final sim = _contentSimilarity(note, other);
      if (sim > 0.2) score += sim * 15.0;
      
      if (score > 3.0) {
        results.add((id: other.id, score: score));
      }
    }
    
    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(5).map((r) => r.id).toList();
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

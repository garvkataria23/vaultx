import 'dart:math';

/// Privacy-first local text summarization service.
///
/// Uses extractive summarization (sentence scoring by word frequency and
/// position). No data ever leaves the device. No ML dependencies.
class SummarizationService {
  SummarizationService._();

  /// Minimum input length to bother summarizing.
  static const int _minLength = 120;

  /// Generate a summary of [text] with at most [maxSentences] sentences.
  /// Returns an empty string if the text is too short.
  static String summarize(String text, {int maxSentences = 3}) {
    if (text.trim().length < _minLength) return '';

    final sentences = _splitSentences(text.trim());
    if (sentences.length <= maxSentences) return sentences.join(' ');

    return _extractiveSummary(sentences, maxSentences);
  }

  /// Split text into sentences, preserving punctuation.
  static List<String> _splitSentences(String text) {
    // Split on sentence-ending punctuation followed by space or end of string
    final parts = text.split(RegExp(r'(?<=[.!?])\s+(?=[A-Z0-9"])'));
    if (parts.length <= 1) {
      // Fallback: split on newlines for notes without proper punctuation
      return text
          .split(RegExp(r'\n\s*\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    }
    return parts
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Extractive summary: score sentences by word frequency + position.
  static String _extractiveSummary(List<String> sentences, int maxSentences) {
    // Build word frequency map (excluding common stop words)
    final freq = <String, int>{};
    final stopWords = _stopWords;
    for (final sentence in sentences) {
      for (final word in _words(sentence)) {
        if (!stopWords.contains(word) && word.length > 2) {
          freq[word] = (freq[word] ?? 0) + 1;
        }
      }
    }

    if (freq.isEmpty) {
      // Fallback: return first N sentences
      return sentences.take(maxSentences).join(' ');
    }

    final maxFreq = freq.values.reduce(max).toDouble();

    // Score each sentence
    final scored = <_ScoredSentence>[];
    for (var i = 0; i < sentences.length; i++) {
      final sentence = sentences[i];
      final words = _words(sentence);
      if (words.isEmpty) continue;

      // TF score: average normalized frequency of content words
      var tfScore = 0.0;
      for (final w in words) {
        if (freq.containsKey(w)) {
          tfScore += freq[w]! / maxFreq;
        }
      }
      tfScore /= words.length;

      // Position bonus: first and last sentences tend to be important
      final normalizedPos = i / (sentences.length - 1);
      final posBonus = 1.0 - 0.4 * normalizedPos; // 1.0 → 0.6

      // Length bonus: prefer medium-length sentences (10-30 words)
      final lenBonus = words.length >= 8 && words.length <= 35 ? 1.2 : 0.8;

      final score = tfScore * posBonus * lenBonus;
      scored.add(_ScoredSentence(sentence, score, i));
    }

    // Sort by score descending, take top N, re-sort by original position
    scored.sort((a, b) => b.score.compareTo(a.score));
    final topN = scored.take(maxSentences).toList();
    topN.sort((a, b) => a.index.compareTo(b.index));

    return topN.map((s) => s.text).join(' ');
  }

  /// Tokenize sentence into lowercase words.
  static List<String> _words(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r"[^a-z0-9']+"))
        .where((w) => w.isNotEmpty)
        .toList();
  }

  static const _stopWords = <String>{
    'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'had',
    'her', 'was', 'one', 'our', 'out', 'has', 'have', 'been', 'some', 'same',
    'also', 'its', 'than', 'them', 'they', 'this', 'that', 'with', 'from',
    'what', 'when', 'where', 'which', 'who', 'whom', 'will', 'would', 'could',
    'should', 'may', 'might', 'shall', 'into', 'over', 'such', 'only', 'other',
    'more', 'most', 'very', 'just', 'about', 'above', 'after', 'again',
    'then', 'there', 'these', 'those', 'their', 'your', 'because', 'before',
    'between', 'being', 'both', 'does', 'done', 'each', 'every', 'first',
    'here', 'how', 'last', 'like', 'long', 'make', 'much', 'must', 'need',
    'new', 'now', 'own', 'part', 'said', 'see', 'since', 'still', 'take',
    'thing', 'things', 'through', 'time', 'under', 'until', 'up', 'use',
    'used', 'using', 'way', 'well', 'were', 'while', 'years', 'yet', 'next',
    'many', 'even', 'another', 'too', 'any', 'off', 'down', 'got', 'get',
    'put', 'set', 'let', 'tell', 'ask', 'went', 'come', 'came', 'give',
    'know', 'think', 'want', 'look', 'show', 'try', 'leave', 'call', 'keep',
    'find', 'start', 'work', 'play', 'turn', 'help', 'move', 'live',
    'feel', 'seem', 'mean', 'doing', 'having', 'going',
    'making', 'taking', 'looking', 'coming', 'giving', 'finding',
    'keeping', 'starting', 'working', 'playing', 'turning', 'helping',
    'moving', 'living', 'feeling', 'seeming', 'meaning', 'anything',
    'everything', 'something', 'nothing', 'always', 'never', 'sometimes',
    'usually', 'often', 'perhaps', 'maybe',
  };
}

class _ScoredSentence {
  final String text;
  final double score;
  final int index;
  const _ScoredSentence(this.text, this.score, this.index);
}

import 'package:flutter/material.dart';

class SearchHighlightController extends TextEditingController {
  String searchQuery = '';
  int activeMatchIndex = -1;
  final List<TextRange> matches = [];

  static const Color _highlightColor = Color(0x66FFEB3B);
  static const Color _activeMatchColor = Color(0x99FF9800);

  void updateMatches() {
    matches.clear();
    if (searchQuery.isEmpty) {
      activeMatchIndex = -1;
      notifyListeners();
      return;
    }
    final lowerText = text.toLowerCase();
    final lowerQuery = searchQuery.toLowerCase();
    int start = 0;
    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) break;
      matches.add(TextRange(start: index, end: index + searchQuery.length));
      start = index + searchQuery.length;
    }
    if (activeMatchIndex >= matches.length) {
      activeMatchIndex = matches.isEmpty ? -1 : matches.length - 1;
    }
    notifyListeners();
  }

  void setActiveMatch(int index) {
    activeMatchIndex = index;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (searchQuery.isEmpty || matches.isEmpty) {
      return TextSpan(text: text, style: style);
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, m.start), style: style));
      }
      spans.add(TextSpan(
        text: text.substring(m.start, m.end),
        style: style?.copyWith(
          backgroundColor: i == activeMatchIndex ? _activeMatchColor : _highlightColor,
        ),
      ));
      lastEnd = m.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: style));
    }

    return TextSpan(children: spans, style: style);
  }
}

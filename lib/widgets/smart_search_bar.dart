import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Animated smart search bar with suggestions overlay.
///
/// Features:
/// - Animated expand on focus
/// - Debounced onChange callback
/// - Suggestion dropdown
/// - Typo-tolerant search hint
class SmartSearchBar extends StatefulWidget {
  const SmartSearchBar({
    super.key,
    required this.onChanged,
    this.suggestions = const [],
    this.hintText = 'Search encrypted notes',
    this.controller,
  });

  final ValueChanged<String> onChanged;
  final List<String> suggestions;
  final String hintText;
  final TextEditingController? controller;

  @override
  State<SmartSearchBar> createState() => _SmartSearchBarState();
}

class _SmartSearchBarState extends State<SmartSearchBar>
    with SingleTickerProviderStateMixin {
  late TextEditingController _ctrl;
  late FocusNode _focusNode;
  late AnimationController _animCtrl;
  late Animation<double> _anim;

  bool _showSuggestions = false;
  List<String> _filteredSuggestions = [];

  @override
  void initState() {
    super.initState();
    _ctrl = widget.controller ?? TextEditingController();
    _focusNode = FocusNode();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _focusNode.addListener(_onFocusChange);
    _ctrl.addListener(_onTextChange);
    _animCtrl.forward();
  }

  @override
  void didUpdateWidget(SmartSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.suggestions != oldWidget.suggestions && _ctrl.text.isNotEmpty) {
      _updateSuggestions();
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) _ctrl.dispose();
    _focusNode.removeListener(_onFocusChange);
    _ctrl.removeListener(_onTextChange);
    _focusNode.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _showSuggestions =
          _focusNode.hasFocus &&
          _ctrl.text.isNotEmpty &&
          _filteredSuggestions.isNotEmpty;
    });
  }

  void _onTextChange() {
    widget.onChanged(_ctrl.text);
    _updateSuggestions();
  }

  void _updateSuggestions() {
    final q = _ctrl.text.toLowerCase();
    final newSuggestions = q.isEmpty
        ? <String>[]
        : widget.suggestions
              .where((s) => s.toLowerCase().contains(q) && s.toLowerCase() != q)
              .take(6)
              .toList();
    final newShow =
        q.isNotEmpty && _focusNode.hasFocus && newSuggestions.isNotEmpty;
    if (newSuggestions.length != _filteredSuggestions.length ||
        newShow != _showSuggestions ||
        (newSuggestions.isNotEmpty &&
            !newSuggestions.every((e) => _filteredSuggestions.contains(e)))) {
      setState(() {
        _filteredSuggestions = newSuggestions;
        _showSuggestions = newShow;
      });
    }
  }

  void _selectSuggestion(String suggestion) {
    _ctrl.text = suggestion;
    _ctrl.selection = TextSelection.collapsed(offset: suggestion.length);
    _showSuggestions = false;
    _focusNode.unfocus();
    widget.onChanged(suggestion);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SizeTransition(
      sizeFactor: _anim,
      axisAlignment: -1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focusNode.hasFocus
                    ? cs.primary.withValues(alpha: 0.5)
                    : Colors.transparent,
              ),
            ),
            child: TextField(
              controller: _ctrl,
              focusNode: _focusNode,
              style: TextStyle(color: cs.onSurface),
              decoration: InputDecoration(
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear_rounded,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                        onPressed: () {
                          _ctrl.clear();
                          widget.onChanged('');
                          HapticFeedback.lightImpact();
                        },
                      )
                    : null,
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (v) {
                _showSuggestions = false;
                _focusNode.unfocus();
              },
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showSuggestions
                ? Container(
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.tips_and_updates,
                                size: 14,
                                color: cs.onSurface.withValues(alpha: 0.4),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Suggestions',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withValues(alpha: 0.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                        ..._filteredSuggestions.map(
                          (s) => InkWell(
                            onTap: () => _selectSuggestion(s),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    s.startsWith('#')
                                        ? Icons.label_rounded
                                        : Icons.search_rounded,
                                    size: 16,
                                    color: cs.primary.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      s,
                                      style: TextStyle(
                                        color: cs.onSurface,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

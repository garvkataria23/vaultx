import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/services.dart';
import 'login_screen.dart';

class DecoyCalculatorScreen extends StatefulWidget {
  const DecoyCalculatorScreen({super.key, required this.auth});

  final VaultAuthService auth;

  @override
  State<DecoyCalculatorScreen> createState() => _DecoyCalculatorScreenState();
}

class _DecoyCalculatorScreenState extends State<DecoyCalculatorScreen> with SingleTickerProviderStateMixin {
  final List<String> _history = [];
  String _display = '0';
  String _expr = '';
  String _secretBuffer = '';
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  String get _secretPin =>
      Hive.box('vaultx_settings').get('decoyCalculatorSecret', defaultValue: '0000') as String;

  bool get _historyEnabled =>
      Hive.box('vaultx_settings').get('decoyCalculatorHistory', defaultValue: true) as bool;

  void _append(String token) {
    setState(() {
      if (_display == 'Error') {
        _display = '0';
        _expr = '';
      }
      
      // Check for secret PIN sequence
      if (RegExp(r'^\d$').hasMatch(token)) {
        _secretBuffer = (_secretBuffer + token).substring(
          math.max(0, _secretBuffer.length + 1 - 12),
        );
        if (_secretBuffer.endsWith(_secretPin)) {
          _openVault();
          return;
        }
      }

      if (_display == '0' && RegExp(r'^\d$').hasMatch(token)) {
        _display = token;
      } else {
        _display += token;
      }
      _expr += token;
    });
  }

  void _clear() {
    setState(() {
      _display = '0';
      _expr = '';
      _secretBuffer = '';
    });
  }

  void _evaluate() {
    if (_expr.isEmpty) return;
    try {
      final result = _ExpressionEvaluator.evaluate(_expr);
      final formatted = result % 1 == 0
          ? result.toInt().toString()
          : result.toStringAsPrecision(12).replaceFirst(RegExp(r'\.?0+$'), '');
      
      if (_historyEnabled && _expr.isNotEmpty) {
        _history.insert(0, '$_expr = $formatted');
        if (_history.length > 20) _history.removeLast();
      }

      setState(() {
        _display = formatted;
        _expr = '';
        _secretBuffer = '';
      });
    } catch (e) {
      setState(() => _display = 'Error');
    }
  }

  void _openVault() {
    DeadMansService.resetTimer();
    HapticFeedback.mediumImpact();
    
    // Smooth transition to login
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
          opacity: animation,
          child: LoginScreen(auth: widget.auth),
        ),
        transitionDuration: const Duration(milliseconds: 800),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _fadeController,
        child: SafeArea(
          child: GestureDetector(
            onLongPress: _openVault,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    alignment: Alignment.bottomRight,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (_expr.isNotEmpty)
                                Text(
                                  _expr,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 24,
                                  ),
                                ),
                              const SizedBox(height: 8),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _display,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 80,
                                    fontWeight: FontWeight.w200,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
                _buildButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildButtons() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        children: [
          _buildRow(['C', '±', '%', '÷'], [Colors.grey[400]!, Colors.grey[400]!, Colors.grey[400]!, Colors.orange]),
          const SizedBox(height: 12),
          _buildRow(['7', '8', '9', '×'], [const Color(0xFF333333), const Color(0xFF333333), const Color(0xFF333333), Colors.orange]),
          const SizedBox(height: 12),
          _buildRow(['4', '5', '6', '-'], [const Color(0xFF333333), const Color(0xFF333333), const Color(0xFF333333), Colors.orange]),
          const SizedBox(height: 12),
          _buildRow(['1', '2', '3', '+'], [const Color(0xFF333333), const Color(0xFF333333), const Color(0xFF333333), Colors.orange]),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _CalcButton(
                  label: '0',
                  color: const Color(0xFF333333),
                  onTap: () => _tap('0'),
                  wide: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CalcButton(
                  label: '.',
                  color: const Color(0xFF333333),
                  onTap: () => _tap('.'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CalcButton(
                  label: '=',
                  color: Colors.orange,
                  onTap: _evaluate,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRow(List<String> labels, List<Color> colors) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          Expanded(
            child: _CalcButton(
              label: labels[i],
              color: colors[i],
              textColor: colors[i] == Colors.grey[400] ? Colors.black : Colors.white,
              onTap: () => _tap(labels[i]),
            ),
          ),
          if (i < labels.length - 1) const SizedBox(width: 12),
        ],
      ],
    );
  }

  void _tap(String b) {
    HapticFeedback.lightImpact();
    if (b == 'C') {
      _clear();
    } else if (b == '±') {
      // Basic sign toggle
      setState(() {
        if (_display.startsWith('-')) {
          _display = _display.substring(1);
          _expr = _expr.substring(1);
        } else if (_display != '0') {
          _display = '-$_display';
          _expr = '-$_expr';
        }
      });
    } else if (b == '÷') {
      _append('÷');
    } else if (b == '×') {
      _append('×');
    } else {
      _append(b);
    }
  }
}

class _CalcButton extends StatelessWidget {
  const _CalcButton({
    required this.label,
    required this.onTap,
    required this.color,
    this.textColor = Colors.white,
    this.wide = false,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;
  final Color textColor;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: wide ? 2.2 : 1.0,
      child: Material(
        color: color,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            alignment: wide ? Alignment.centerLeft : Alignment.center,
            padding: wide ? const EdgeInsets.only(left: 32) : null,
            child: Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 32,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpressionEvaluator {
  static double evaluate(String input) {
    final clean = input.replaceAll('×', '*').replaceAll('÷', '/');
    final tokens = _tokenize(clean);
    final values = <double>[];
    final ops = <String>[];
    for (final token in tokens) {
      final n = double.tryParse(token);
      if (n != null) {
        values.add(n);
      } else if (token == '(') {
        ops.add(token);
      } else if (token == ')') {
        while (ops.isNotEmpty && ops.last != '(') {
          _apply(values, ops);
        }
        if (ops.isEmpty) throw const FormatException('Missing bracket');
        ops.removeLast();
      } else {
        while (ops.isNotEmpty &&
            ops.last != '(' &&
            _prec(ops.last) >= _prec(token)) {
          _apply(values, ops);
        }
        ops.add(token);
      }
    }
    while (ops.isNotEmpty) {
      _apply(values, ops);
    }
    if (values.length != 1) throw const FormatException('Bad expression');
    return values.single;
  }

  static List<String> _tokenize(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if ('0123456789.'.contains(ch)) {
        buf.write(ch);
      } else if ('+-*/%()'.contains(ch)) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        if (ch == '-' &&
            (out.isEmpty || '+*/%('.contains(out.last)) &&
            i + 1 < s.length &&
            '0123456789.'.contains(s[i + 1])) {
          buf.write(ch);
        } else {
          out.add(ch);
        }
      } else if (ch.trim().isNotEmpty) {
        throw const FormatException('Unexpected character');
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static int _prec(String op) => (op == '+' || op == '-') ? 1 : 2;

  static void _apply(List<double> values, List<String> ops) {
    if (values.length < 2 || ops.isEmpty) throw const FormatException();
    final b = values.removeLast();
    final a = values.removeLast();
    switch (ops.removeLast()) {
      case '+':
        values.add(a + b);
      case '-':
        values.add(a - b);
      case '*':
        values.add(a * b);
      case '/':
        values.add(a / b);
      case '%':
        values.add(a % b);
    }
  }
}

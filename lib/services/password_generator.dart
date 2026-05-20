import 'dart:math';
import 'dart:ui' show Color;

/// Generates cryptographically-random passwords with configurable composition.
class PasswordGenerator {
  static const _lower = 'abcdefghijklmnopqrstuvwxyz';
  static const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _digits = '0123456789';
  static const _symbols = '!@#\$%^&*()-_=+[]{}|;:,.<>?/~';

  static String generate({
    int length = 24,
    bool useLower = true,
    bool useUpper = true,
    bool useDigits = true,
    bool useSymbols = true,
    bool excludeAmbiguous = false,
  }) {
    String chars = '';
    if (useLower) chars += _lower;
    if (useUpper) chars += _upper;
    if (useDigits) chars += _digits;
    if (useSymbols) chars += _symbols;

    if (chars.isEmpty) chars = _lower;
    if (excludeAmbiguous) {
      for (final c in '0O1lI5S'.split('')) {
        chars = chars.replaceAll(c, '');
      }
    }

    final rand = Random.secure();
    final bytes = List<int>.generate(length, (_) => rand.nextInt(chars.length));
    return bytes.map((i) => chars[i]).join();
  }

  static String generatePin({int length = 6}) {
    final rand = Random.secure();
    final bytes = List<int>.generate(length, (_) => rand.nextInt(10));
    return bytes.map((i) => '$i').join();
  }

  static String generatePassphrase({int wordCount = 5, String separator = '-'}) {
    const words = [
      'correct', 'horse', 'battery', 'staple', 'quantum', 'crystal',
      'dragon', 'forest', 'bridge', 'silver', 'winter', 'summer',
      'ocean', 'thunder', 'eagle', 'falcon', 'rocket', 'nebula',
      'cosmic', 'valley', 'garden', 'pirate', 'castle', 'shadow',
      'blaze', 'frost', 'storm', 'bloom', 'coral', 'amber',
    ];
    final rand = Random.secure();
    final selected = List.generate(
      wordCount,
      (_) => words[rand.nextInt(words.length)],
    );
    return selected.join(separator);
  }

  /// Estimates password strength on a 0-4 scale using entropy heuristics.
  /// 0=very weak, 1=weak, 2=fair, 3=strong, 4=very strong.
  static int strength(String password) {
    if (password.isEmpty) return 0;
    var score = 0;
    if (password.length >= 8) score++;
    if (password.length >= 14) score++;
    if (password.length >= 20) score++;
    if (RegExp(r'[a-z]').hasMatch(password) && RegExp(r'[A-Z]').hasMatch(password)) score++;
    if (RegExp(r'\d').hasMatch(password)) score++;
    if (RegExp(r'[!@#\$%^&*()\-_=+\[\]{}|;:,.<>?/~]').hasMatch(password)) score++;
    return score.clamp(0, 4);
  }

  static String strengthLabel(int level) {
    switch (level) {
      case 0: return 'Very weak';
      case 1: return 'Weak';
      case 2: return 'Fair';
      case 3: return 'Strong';
      case 4: return 'Very strong';
      default: return 'Unknown';
    }
  }

  static Color strengthColor(int level) {
    switch (level) {
      case 0: return const Color(0xFFD32F2F);
      case 1: return const Color(0xFFFFA000);
      case 2: return const Color(0xFFFDD835);
      case 3: return const Color(0xFF66BB6A);
      case 4: return const Color(0xFF2E7D32);
      default: return const Color(0xFF9E9E9E);
    }
  }
}

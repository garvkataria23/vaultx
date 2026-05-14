import 'package:flutter/material.dart';

/// Visual badge for note categories.
class SmartCategoryBadge extends StatelessWidget {
  const SmartCategoryBadge({super.key, required this.category, this.size = 14});

  final String category;
  final double size;

  static const _categoryIcons = <String, IconData>{
    'finance': Icons.account_balance,
    'work': Icons.work,
    'personal': Icons.person,
    'tech': Icons.code,
    'health': Icons.favorite,
    'education': Icons.school,
    'shopping': Icons.shopping_cart,
    'travel': Icons.flight,
    'legal': Icons.gavel,
    'social': Icons.group,
  };

  static const _categoryColors = <String, Color>{
    'finance': Color(0xff10b981),
    'work': Color(0xff3b82f6),
    'personal': Color(0xff8b5cf6),
    'tech': Color(0xff06b6d4),
    'health': Color(0xffef4444),
    'education': Color(0xfff59e0b),
    'shopping': Color(0xffec4899),
    'travel': Color(0xff14b8a6),
    'legal': Color(0xff6366f1),
    'social': Color(0xfff97316),
  };

  @override
  Widget build(BuildContext context) {
    final cat = category.toLowerCase();
    final icon = _categoryIcons[cat] ?? Icons.description;
    final color = _categoryColors[cat] ?? Colors.grey;

    return Container(
      width: size + 8,
      height: size + 8,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size / 2 + 2),
      ),
      child: Icon(icon, size: size, color: color),
    );
  }

  /// Get the display name for a category key.
  static String displayName(String category) {
    if (category.isEmpty) return 'General';
    return '${category[0].toUpperCase()}${category.substring(1)}';
  }

  /// Get the icon for a category key.
  static IconData iconFor(String category) {
    return _categoryIcons[category.toLowerCase()] ?? Icons.description;
  }

  /// Get the color for a category key.
  static Color colorFor(String category) {
    return _categoryColors[category.toLowerCase()] ?? Colors.grey;
  }
}

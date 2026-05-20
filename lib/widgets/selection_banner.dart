import 'package:flutter/material.dart';

/// Unified Selection Banner for Gmail-style bulk selection.
class SelectionBanner extends StatelessWidget {
  const SelectionBanner({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.onSelectAll,
    required this.onClear,
    this.itemName = 'items',
  });

  final int selectedCount;
  final int totalCount;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final String itemName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool allSelected = selectedCount >= totalCount && totalCount > 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: selectedCount > 0 ? 48 : 0,
      width: double.infinity,
      color: cs.secondaryContainer.withValues(alpha: 0.5),
      child: selectedCount > 0
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '$selectedCount $itemName selected',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                  const Spacer(),
                  if (!allSelected)
                    TextButton(
                      onPressed: onSelectAll,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text('Select all $totalCount'),
                    ),
                  TextButton(
                    onPressed: onClear,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: cs.error,
                    ),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

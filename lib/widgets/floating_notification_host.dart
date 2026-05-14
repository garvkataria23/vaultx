import 'package:flutter/material.dart';
import '../services/floating_notification_service.dart';

/// Place in MaterialApp.builder for app-wide coverage:
/// ```dart
/// builder: (context, child) =>
///     FloatingNotificationHost(child: child ?? const SizedBox.shrink()),
/// ```
class FloatingNotificationHost extends StatelessWidget {
  const FloatingNotificationHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 80,
              left: 24,
              right: 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _NotificationStack(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Alias for screens that wrap individual Scaffolds.
typedef FloatingNotificationOverlay = FloatingNotificationHost;

class _NotificationStack extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FloatingNotificationService.instance,
      builder: (context, _) {
        final items = FloatingNotificationService.instance.items;
        // Limit to 1 for a cleaner "replacement" feel
        final visible = items.isNotEmpty ? [items.last] : <FloatingNotification>[];
        
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: visible
              .map((n) => _NotificationCard(key: ValueKey(n.id), notification: n))
              .toList(),
        );
      },
    );
  }
}

class _NotificationCard extends StatefulWidget {
  const _NotificationCard({super.key, required this.notification});
  final FloatingNotification notification;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _slide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _fade = CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.6, curve: Curves.easeIn));
    _scale = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _ctrl.reverse();
    FloatingNotificationService.instance.dismiss(widget.notification.id);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final (bg, border, fg, icon) = switch (n.type) {
      AppNotificationType.error => (
          cs.errorContainer,
          cs.error,
          cs.onErrorContainer,
          Icons.error_outline_rounded
        ),
      AppNotificationType.success => (
          cs.primaryContainer,
          cs.primary,
          cs.onPrimaryContainer,
          Icons.check_circle_outline_rounded
        ),
      AppNotificationType.warning => (
          isDark ? const Color(0xFF3E2723) : const Color(0xFFFFF3E0),
          Colors.orange,
          isDark ? Colors.orange[100]! : const Color(0xFFE65100),
          Icons.warning_amber_rounded
        ),
      AppNotificationType.loading => (
          cs.surfaceContainerHighest,
          cs.primary,
          cs.onSurface,
          Icons.hourglass_top_rounded
        ),
      AppNotificationType.info => (
          cs.secondaryContainer,
          cs.secondary,
          cs.onSecondaryContainer,
          Icons.info_outline_rounded
        ),
    };

    return Dismissible(
      key: ValueKey(n.id),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => FloatingNotificationService.instance.dismiss(n.id),
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                elevation: 12,
                shadowColor: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: Container(
                  decoration: BoxDecoration(
                    color: bg.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: border.withValues(alpha: 0.3),
                      width: 1.2,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (n.type == AppNotificationType.loading)
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: border,
                          ),
                        )
                      else
                        Icon(icon, size: 20, color: border),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          n.message,
                          style: TextStyle(
                            color: fg,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: fg.withValues(alpha: 0.4),
                        ),
                        onPressed: _dismiss,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        splashRadius: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}



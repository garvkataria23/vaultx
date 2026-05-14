import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ── Notification mode ─────────────────────────────────────────────────────────

enum FloatingNotificationMode { off, floating, persistent }

// ── Notification type ─────────────────────────────────────────────────────────

enum AppNotificationType { success, error, info, warning, loading }

// ── Model ─────────────────────────────────────────────────────────────────────

class FloatingNotification {
  FloatingNotification({
    required this.id,
    required this.message,
    this.type = AppNotificationType.info,
    this.persistent = false,
    this.progress,
  });

  final String id;
  final String message;
  final AppNotificationType type;
  final bool persistent;
  final double? progress;
}

// ── Service ───────────────────────────────────────────────────────────────────

class FloatingNotificationService extends ChangeNotifier {
  FloatingNotificationService._();
  static final FloatingNotificationService instance =
      FloatingNotificationService._();

  final List<FloatingNotification> _items = [];
  final Map<String, Timer> _timers = {};
  bool _disposed = false;

  List<FloatingNotification> get items => List.unmodifiable(_items);

  void show(
    String message, {
    bool error = false,
    AppNotificationType? type,
    bool? persistent,
    double? progress,
    Duration duration = const Duration(seconds: 4),
    FloatingNotificationMode? mode,
  }) {
    if (_disposed) return;

    // Filter for failed attempts if specified explicitly
    if (mode == FloatingNotificationMode.off) return;

    final resolvedType =
        type ?? (error ? AppNotificationType.error : AppNotificationType.success);
    
    // Heuristic: if it's a security/failed attempt message, check settings.
    // General app feedback (Saved, Deleted, etc) should always show.
    final isSecurity = message.toLowerCase().contains('failed') || 
                       message.toLowerCase().contains('invalid') ||
                       message.toLowerCase().contains('intruder');

    bool resolvedPersistent = persistent ?? false;

    if (isSecurity) {
      final securityMode = _getSecurityNotificationMode();
      if (securityMode == 'off') return;
      if (persistent == null && securityMode == 'persistent') {
        resolvedPersistent = true;
      }
    }

    final id = '${DateTime.now().microsecondsSinceEpoch}_${message.hashCode}';

    // Clear existing to avoid stacking too many (keep max 1 for cleanliness)
    for (final t in _timers.values) { t.cancel(); }
    _timers.clear();
    _items.clear();

    _items.add(FloatingNotification(
      id: id,
      message: message,
      type: resolvedType,
      persistent: resolvedPersistent,
      progress: progress,
    ));
    _safeNotify();

    if (!resolvedPersistent && progress == null) {
      _timers[id] = Timer(duration, () => dismiss(id));
    }
  }

  String _getSecurityNotificationMode() {
    try {
      return Hive.box('vaultx_settings')
          .get('failedAttemptNotifications', defaultValue: 'floating') as String;
    } catch (_) { return 'floating'; }
  }

  String showLoading(String message) {
    if (_disposed) return '';
    final id = '${DateTime.now().microsecondsSinceEpoch}_loading';
    _items.removeWhere((n) => n.message == message);
    _items.add(FloatingNotification(
      id: id, message: message,
      type: AppNotificationType.loading, persistent: true,
    ));
    _safeNotify();
    return id;
  }

  void updateLoading(String id, String message, {bool error = false}) {
    final idx = _items.indexWhere((n) => n.id == id);
    if (idx == -1) { show(message, error: error); return; }
    _items[idx] = FloatingNotification(
      id: id, message: message,
      type: error ? AppNotificationType.error : AppNotificationType.success,
    );
    _safeNotify();
    _timers[id]?.cancel();
    _timers[id] = Timer(const Duration(seconds: 4), () => dismiss(id));
  }

  void dismiss(String id) {
    _timers.remove(id)?.cancel();
    final removed = _items.any((n) => n.id == id);
    _items.removeWhere((n) => n.id == id);
    if (removed) _safeNotify();
  }

  void clear() {
    for (final t in _timers.values) { t.cancel(); }
    _timers.clear();
    _items.clear();
    _safeNotify();
  }

  void _safeNotify() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers.values) { t.cancel(); }
    _timers.clear();
    super.dispose();
  }
}

// ── Context extension ─────────────────────────────────────────────────────────

extension AppNotificationX on BuildContext {
  void showFloatingNotification(
    String message, {
    bool error = false,
    AppNotificationType? type,
    bool? persistent,
    Duration duration = const Duration(seconds: 4),
  }) {
    FloatingNotificationService.instance.show(
      message, error: error, type: type,
      persistent: persistent, duration: duration,
    );
  }
}

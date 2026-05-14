import 'dart:async';

import 'package:flutter/services.dart';

import 'audit_log.dart';
import 'floating_notification_service.dart';

/// Manages sensitive clipboard operations with automatic clearing.
class ClipboardGuard {
  static Timer? _timer;

  static Future<void> copySensitive(
    String value, {
    Duration clearAfter = const Duration(seconds: 30),
  }) async {
    await Clipboard.setData(ClipboardData(text: value));
    _timer?.cancel();
    _timer = Timer(
      clearAfter,
      () => Clipboard.setData(const ClipboardData(text: '')),
    );
    FloatingNotificationService.instance.show(
      'Copied to clipboard. Will be cleared in ${clearAfter.inSeconds}s.',
      type: AppNotificationType.info,
    );
    await AuditLog.write('Sensitive clipboard copied with auto-clear');
  }

  static Future<void> clearNow() async {
    _timer?.cancel();
    await Clipboard.setData(const ClipboardData(text: ''));
  }
}

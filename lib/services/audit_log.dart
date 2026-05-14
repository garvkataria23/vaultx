import 'package:hive_flutter/hive_flutter.dart';

/// Writes timestamped security events to the audit Hive box.
class AuditLog {
  static Future<void> write(String event) async {
    final box = Hive.box('vaultx_audit');
    await box.add({'ts': DateTime.now().toIso8601String(), 'event': event});
  }

  static List<Map<String, dynamic>> all() => Hive.box('vaultx_audit').values
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList()
      .reversed
      .toList();
}

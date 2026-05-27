import 'dart:async';
import 'package:flutter/foundation.dart';

class StartupDiagnostics {
  StartupDiagnostics._();
  static final StartupDiagnostics instance = StartupDiagnostics._();

  static final int _appStartMs = DateTime.now().millisecondsSinceEpoch;

  int? _hiveBoxesOpenMs;
  int? _appStateReadyMs;
  int? _firstFrameMs;
  int? _notesLoadedMs;
  int? _passwordsLoadedMs;
  int? _aiReadyMs;
  bool _reported = false;

  void markHiveBoxesOpen() => _hiveBoxesOpenMs = _now();
  void markAppStateReady() => _appStateReadyMs = _now();
  void markFirstFrame() => _firstFrameMs = _now();
  void markNotesLoaded() => _notesLoadedMs = _now();
  void markPasswordsLoaded() => _passwordsLoadedMs = _now();
  void markAiReady() => _aiReadyMs = _now();

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  String _ms(int? t) {
    if (t == null) return '---';
    return '${t - _appStartMs}ms';
  }

  void report() {
    if (_reported) return;
    _reported = true;

    Future.microtask(() {
      debugPrint('=== STARTUP TIMING ===');
      debugPrint('  STARTUP_MS: ${_ms(_firstFrameMs)}');
      debugPrint('  HIVE_BOXES_OPEN: ${_ms(_hiveBoxesOpenMs)}');
      debugPrint('  APP_STATE_READY: ${_ms(_appStateReadyMs)}');
      debugPrint('  FIRST_FRAME: ${_ms(_firstFrameMs)}');
      debugPrint('  NOTES_LOAD_MS: ${_ms(_notesLoadedMs)}');
      debugPrint('  PASSWORDS_LOAD_MS: ${_ms(_passwordsLoadedMs)}');
      debugPrint('  AI_LOAD_MS: ${_ms(_aiReadyMs)}');
      debugPrint('=== END STARTUP TIMING ===');
    });
  }
}

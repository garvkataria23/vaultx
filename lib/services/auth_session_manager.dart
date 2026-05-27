import 'dart:async';
import 'package:flutter/material.dart';
import 'audit_log.dart';
import '../models/auth.dart';

enum AuthSessionStatus {
  locked,
  authenticated,
}

class AuthSessionManager extends ChangeNotifier {
  static final AuthSessionManager instance = AuthSessionManager._();
  AuthSessionManager._();

  AuthSessionStatus _status = AuthSessionStatus.locked;
  Timer? _relockTimer;
  AuthResult? _sessionAuth;
  int _lockMinutes = 1;

  AuthSessionStatus get status => _status;
  AuthResult? get sessionAuth => _sessionAuth;
  bool get isAuthenticated => _status == AuthSessionStatus.authenticated;

  void markActivity() {
    _resetRelockTimer();
  }

  void updateLockMinutes(int minutes) {
    _lockMinutes = minutes;
  }

  void _resetRelockTimer() {
    _relockTimer?.cancel();
    _relockTimer = Timer(Duration(minutes: _lockMinutes), () {
      lock();
    });
  }

  void authenticate(AuthResult result) {
    _sessionAuth = result;
    _status = AuthSessionStatus.authenticated;
    _resetRelockTimer();
    AuditLog.write('AUTH_SUCCESS: Session started');
    notifyListeners();
  }

  void lock() {
    if (_status == AuthSessionStatus.locked) return;
    _status = AuthSessionStatus.locked;
    _sessionAuth = null;
    _relockTimer?.cancel();
    AuditLog.write('AUTH_LOCKED: Session ended');
    notifyListeners();
  }

  @override
  void dispose() {
    _relockTimer?.cancel();
    super.dispose();
  }
}

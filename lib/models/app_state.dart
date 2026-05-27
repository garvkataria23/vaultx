import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/audit_log.dart';

/// Tracks onboarding, PIN lockout, and strict offline mode.
///
/// All Hive reads are deferred to an async init so the app starts instantly
/// without blocking the main thread during construction.
class VaultAppState extends ChangeNotifier {
  bool _onboardingComplete = false;
  bool _strictOffline = true;
  int _failedPinAttempts = 0;
  int _failedBiometricAttempts = 0;
  DateTime? _pinLockedUntil;
  bool _initialized = false;
  bool _disposed = false;

  bool get onboardingComplete => _onboardingComplete;
  bool get strictOffline => _strictOffline;
  int get failedPinAttempts => _failedPinAttempts;
  int get failedBiometricAttempts => _failedBiometricAttempts;
  bool get isBiometricEscalated => _failedBiometricAttempts >= 5;
  DateTime? get pinLockedUntil => _pinLockedUntil;
  bool get isPinLocked =>
      _pinLockedUntil != null && DateTime.now().isBefore(_pinLockedUntil!);
  bool get isInitialized => _initialized;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Loads persisted state from Hive asynchronously.
  /// Must be called once after Hive boxes are open.
  Future<void> init() async {
    if (_initialized) return;
    if (!Hive.isBoxOpen('vaultx_settings')) {
      _initialized = true;
      _safeNotify();
      return;
    }
    final box = Hive.box('vaultx_settings');
    _onboardingComplete =
        box.get('onboardingComplete', defaultValue: false) as bool;
    _strictOffline = box.get('strictOffline', defaultValue: true) as bool;
    _failedPinAttempts = box.get('failedPinAttempts', defaultValue: 0) as int;
    _failedBiometricAttempts =
        box.get('failedBiometricAttempts', defaultValue: 0) as int;
    final lockRaw = box.get('pinLockedUntil') as String?;
    _pinLockedUntil = lockRaw == null ? null : DateTime.tryParse(lockRaw);
    _initialized = true;
    _safeNotify();
  }

  Future<void> completeOnboarding() async {
    _onboardingComplete = true;
    await Hive.box('vaultx_settings').put('onboardingComplete', true);
    _safeNotify();
  }

  Future<void> setStrictOffline(bool value) async {
    _strictOffline = value;
    await Hive.box('vaultx_settings').put('strictOffline', value);
    _safeNotify();
  }

  Future<void> recordFailedPinAttempt() async {
    _failedPinAttempts++;
    await AuditLog.write('Failed password unlock attempt (PIN/Pass #$_failedPinAttempts)');
    if (_failedPinAttempts >= 5) {
      _pinLockedUntil = DateTime.now().add(const Duration(minutes: 15));
      await Hive.box(
        'vaultx_settings',
      ).put('pinLockedUntil', _pinLockedUntil!.toIso8601String());
      await AuditLog.write('Security escalation: PIN lockout active for 15 minutes');
    }
    await Hive.box(
      'vaultx_settings',
    ).put('failedPinAttempts', _failedPinAttempts);
    _safeNotify();
  }

  Future<void> recordFailedBiometricAttempt() async {
    _failedBiometricAttempts++;
    await AuditLog.write('Failed biometric unlock attempt (#$_failedBiometricAttempts)');
    if (_failedBiometricAttempts >= 5) {
      await AuditLog.write('Security escalation: Biometric mandatory password required');
    }
    await Hive.box('vaultx_settings')
        .put('failedBiometricAttempts', _failedBiometricAttempts);
    _safeNotify();
  }

  Future<void> resetPinAttempts() async {
    _failedPinAttempts = 0;
    _pinLockedUntil = null;
    await Hive.box('vaultx_settings').put('failedPinAttempts', 0);
    await Hive.box('vaultx_settings').delete('pinLockedUntil');
    _safeNotify();
  }

  Future<void> resetBiometricAttempts() async {
    _failedBiometricAttempts = 0;
    await Hive.box('vaultx_settings').put('failedBiometricAttempts', 0);
    _safeNotify();
  }
}

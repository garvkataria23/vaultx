import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/auth_service.dart';
import '../services/auth_session_manager.dart';
import '../services/audit_log.dart';

/// Wraps the app's Navigator to handle session lifecycle:
/// - Auto-triggers biometric auth on init/resume when vault is initialized
/// - Tracks user activity to reset the auto-lock timer
/// - Does NOT replace the Navigator child with LoginScreen —
///   VaultBootstrap/VaultHomeWrapper handles that.
class VaultAuthGuard extends StatefulWidget {
  const VaultAuthGuard({super.key, required this.child});
  final Widget child;

  @override
  State<VaultAuthGuard> createState() => _VaultAuthGuardState();
}

class _VaultAuthGuardState extends State<VaultAuthGuard> with WidgetsBindingObserver {
  final _auth = VaultAuthService();
  bool _isAuthenticating = false;
  bool _autoAuthCancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthSessionManager.instance.addListener(_onSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoAuth());
  }

  @override
  void dispose() {
    AuthSessionManager.instance.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!AuthSessionManager.instance.isAuthenticated && !_autoAuthCancelled) {
      _maybeAutoAuth();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_autoAuthCancelled) {
      _maybeAutoAuth();
    }
  }

  Future<void> _maybeAutoAuth() async {
    if (_autoAuthCancelled) return;
    final session = AuthSessionManager.instance;
    if (session.isAuthenticated) {
      session.markActivity();
      return;
    }
    if (_isAuthenticating) return;

    // Do not auto-auth if vault is not even setup yet
    final isInit = await _auth.isInitialized().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugPrint('AUTH_TIMEOUT: _auth.isInitialized() in _maybeAutoAuth');
        return false;
      },
    );
    if (!isInit) return;

    // Do not auto-auth if biometric is escalated
    if (!context.mounted) return;
    // ignore: use_build_context_synchronously
    final appState = context.read<VaultAppState>();
    if (appState.isBiometricEscalated) return;

    if (mounted) setState(() => _isAuthenticating = true);
    await AuditLog.write('AUTH_START');

    try {
      final available = await _auth.isBiometricUnlockAvailable().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('AUTH_TIMEOUT: isBiometricUnlockAvailable in _maybeAutoAuth');
          return false;
        },
      );
      if (!available) {
        await AuditLog.write('PASSWORD_FALLBACK');
        if (mounted) setState(() => _isAuthenticating = false);
        return;
      }

      final types = await _auth.getAvailableBiometrics().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('AUTH_TIMEOUT: getAvailableBiometrics in _maybeAutoAuth');
          return [];
        },
      );
      final hasFace = types.contains(BiometricType.face);

      if (hasFace) {
        await AuditLog.write('FACE_AVAILABLE');
      }

      final result = await _auth.unlockWithBiometric();
      final verified = await _auth.verify(result);

      if (verified.ok) {
        if (hasFace) {
          await AuditLog.write('FACE_SUCCESS');
        } else {
          await AuditLog.write('FINGERPRINT_SUCCESS');
        }
        await AuditLog.write('AUTH_SUCCESS');
        session.authenticate(verified);
      } else {
        await AuditLog.write('AUTH_FAILED: ${verified.error}');
        _autoAuthCancelled = true;
      }
    } catch (e) {
      await AuditLog.write('AUTH_FAILED: $e');
      _autoAuthCancelled = true;
    } finally {
      if (mounted) setState(() => _isAuthenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => AuthSessionManager.instance.markActivity(),
      onPointerMove: (_) => AuthSessionManager.instance.markActivity(),
      child: widget.child,
    );
  }
}

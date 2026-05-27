import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';
import 'restore_screen.dart';
import 'recovery_screen.dart';
import '../services/auth_session_manager.dart';

/// Login screen — password and biometric unlock.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});
  final VaultAuthService auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  final _secret = TextEditingController();
  bool _secretVisible = false;

  _VaultMode _mode = _VaultMode.main;

  bool _biometricAvailable = false;
  String _biometricLabel = 'Biometrics';
  IconData _biometricIcon = Icons.fingerprint;
  bool _biometricBusy = false;
  bool _passwordBusy = false;
  String? _error;
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBiometric(autoPrompt: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _errorTimer?.cancel();
    _secret.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Redundant: VaultAuthGuard handles auto-auth on resume.
    // We only update availability info here.
    if (state == AppLifecycleState.resumed) {
      _checkBiometric(autoPrompt: false);
    }
  }

  Future<void> _checkBiometric({bool autoPrompt = false}) async {
    final available = await widget.auth.isBiometricUnlockAvailable().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugPrint('AUTH_TIMEOUT: isBiometricUnlockAvailable in _checkBiometric');
        return false;
      },
    );
    if (!mounted) return;

    if (available) {
      final label = await widget.auth.biometricTypeLabel();
      if (!mounted) return;
      final icon = await widget.auth.biometricTypeIcon();
      if (!mounted) return;
      
      setState(() {
        _biometricAvailable = true;
        _biometricLabel = label;
        _biometricIcon = icon;
      });
    } else {
      if (mounted) setState(() => _biometricAvailable = false);
    }

    if (autoPrompt && _biometricAvailable && !_biometricBusy && _mode == _VaultMode.main) {
      final appState = context.read<VaultAppState>();
      if (!appState.isBiometricEscalated) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && _biometricAvailable && !_biometricBusy) {
            _unlockWithBiometric();
          }
        });
      }
    }
  }

  Future<void> _unlockWithBiometric() async {
    if (_biometricBusy) return;
    if (mounted) {
      setState(() {
        _biometricBusy = true;
        _error = null;
      });
    }

    try {
      AuthResult result = await widget.auth.unlockWithBiometric();
      if (!mounted) return;
      result = await widget.auth.verify(result);

      if (!mounted) return;

      if (result.ok) {
        context.read<VaultAppState>().resetBiometricAttempts();
        _navigateHome(result);
        return;
      }

      if (result.error != null && !result.error!.contains('cancelled')) {
        await context.read<VaultAppState>().recordFailedBiometricAttempt();
      }

      if (mounted) {
        setState(() {
          _biometricBusy = false;
          _error = result.error;
        });
      }
    } catch (e) {
      debugPrint('BIOMETRIC_ERROR: $e');
      if (mounted) {
        setState(() {
          _biometricBusy = false;
          _error = 'Biometric authentication failed. Try again.';
        });
      }
    }
  }

  Future<void> _unlockWithPassword() async {
    if (_passwordBusy) return;
    if (_secret.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    setState(() {
      _passwordBusy = true;
      _error = null;
    });

    try {
      AuthResult result;
      switch (_mode) {
        case _VaultMode.main:
          result = await widget.auth.unlockWithPassword(_secret.text);
        case _VaultMode.hidden:
          result = await widget.auth.unlockHidden(_secret.text);
      }

      result = await widget.auth.verify(result);

      if (!mounted) return;

      if (result.ok) {
        final appState = context.read<VaultAppState>();
        appState.resetPinAttempts();
        appState.resetBiometricAttempts();
        setState(() => _passwordBusy = false);
        _checkForRestoreAfterLogin(result);
        return;
      }

      await AuditLog.write('Failed password unlock attempt');
      await _handleFailedAttempt();
      if (!mounted) return;
      final notifSetting = Hive.box('vaultx_settings').get('failedAttemptNotifications', defaultValue: 'persistent') as String;
      setState(() {
        _passwordBusy = false;
        _error = result.error ?? 'Invalid password';
      });
      final mode = switch (notifSetting) {
        'off' => FloatingNotificationMode.off,
        'persistent' => FloatingNotificationMode.persistent,
        _ => FloatingNotificationMode.floating,
      };
      FloatingNotificationService.instance.show(
        result.error ?? 'Invalid password',
        error: true,
        mode: mode,
        duration: notifSetting == 'persistent' ? const Duration(minutes: 15) : const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('LOGIN_ERROR: $e');
      if (mounted) {
        setState(() {
          _passwordBusy = false;
          _error = 'Unexpected error. Please try again.';
        });
      }
    }
  }

  Future<void> _checkForRestoreAfterLogin(AuthResult result) async {
    if (result.kind != VaultKind.main) {
      _navigateHome(result);
      return;
    }

    if (_hasLocalVaultData()) {
      _navigateHome(result);
      return;
    }

    final autoRestore = Hive.box('vaultx_settings').get('autoRestore', defaultValue: false) as bool;

    try {
      final driveService = GoogleDriveBackupService(
        authService: widget.auth,
        masterKey: result.masterKey,
      );
      
      final restoredEmail = await driveService.restoreSession();
      if (restoredEmail == null) {
        _navigateHome(result);
        return;
      }

      final hasBackup = await driveService.hasBackup();
      if (!hasBackup) {
        _navigateHome(result);
        return;
      }

      if (!mounted) return;

      final popResult = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => RestoreScreen(
            authService: widget.auth,
            driveService: driveService,
            masterKey: result.masterKey ?? Uint8List(0),
            kind: result.kind,
            autoRestore: autoRestore,
            onComplete: (success) {
              if (success) {
                FloatingNotificationService.instance.show('Vault data restored successfully');
              }
            },
          ),
        ),
      );

      if (!mounted) return;

      if (popResult != null && _isBase64MasterKey(popResult)) {
        final masterKey = base64Decode(popResult);
        final pendingResult = AuthResult.pending(masterKey, 'masterVerifier', result.kind);
        final verifiedResult = await widget.auth.verify(pendingResult);
        if (mounted) {
          _navigateHome(verifiedResult.ok ? verifiedResult : result);
        }
      } else {
        _navigateHome(result);
      }
    } catch (e) {
      if (mounted) _navigateHome(result);
    }
  }

  bool _hasLocalVaultData() {
    try {
      return Hive.box('vaultx_records').isNotEmpty ||
          Hive.box('vaultx_drive').isNotEmpty ||
          Hive.box('vaultx_passwords').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleFailedAttempt() async {
    if (!mounted) return;
    final appState = context.read<VaultAppState>();
    await appState.recordFailedPinAttempt();

    if (!mounted) return;
    final settingsBox = Hive.box('vaultx_settings');
    final enabled = settingsBox.get('intruderCaptureEnabled', defaultValue: true) as bool;
    if (!enabled) return;

    final threshold = settingsBox.get('intruderCaptureThreshold', defaultValue: 3) as int;
    if (appState.failedPinAttempts < threshold) return;

    final cooldownOk = await IntruderSelfieService.isCooldownElapsed();
    if (!cooldownOk) return;

    try {
      final key = await widget.auth.intruderLogKey();
      final attachment = await IntruderSelfieService.capture(key);
      if (attachment != null) {
        await IntruderSelfieService.markCaptureTime();
        final entry = IntruderLogEntry(
          id: attachment.id,
          timestamp: DateTime.now(),
          attemptNumber: appState.failedPinAttempts,
          authMethod: _mode == _VaultMode.hidden ? 'hidden_password' : 'password',
          attachment: attachment,
        );
        await Hive.box('vaultx_intruder').put(attachment.id, entry.toJson());
      }
    } catch (_) {}
  }

  bool _isBase64MasterKey(String s) {
    try {
      final bytes = base64Decode(s);
      return bytes.length == 32;
    } catch (_) {
      return false;
    }
  }

  void _navigateHome(AuthResult result) {
    try {
      DeadMansService.resetTimer();
    } catch (_) {
      // resetTimer is fire-and-forget; ignore failures so authenticate always runs
    }
    AuthSessionManager.instance.authenticate(result);
  }

  void _showForgotPasswordOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Text(
                'Reset vault access',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose how you\'d like to regain access to your vault.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              if (_biometricAvailable) ...[
                ListTile(
                  leading: Icon(_biometricIcon, color: Theme.of(ctx).colorScheme.primary),
                  title: const Text('Use biometrics'),
                  subtitle: const Text('Verify identity to reset your password'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _resetWithBiometric();
                  },
                ),
                const Divider(height: 1),
              ],
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('Use recovery code'),
                subtitle: const Text('Enter one of your recovery codes'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openRecoveryScreen();
                },
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _resetWithBiometric() async {
    if (_biometricBusy) return;
    setState(() {
      _biometricBusy = true;
      _error = null;
    });

    try {
      AuthResult result = await widget.auth.unlockWithBiometric();
      if (!mounted) return;
      result = await widget.auth.verify(result);

      if (!mounted) return;

      if (result.ok && result.masterKey != null) {
        setState(() => _biometricBusy = false);
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RecoveryScreen(
              auth: widget.auth,
              preVerifiedMasterKey: result.masterKey,
            ),
          ),
        );
        return;
      }

      if (mounted) {
        setState(() {
          _biometricBusy = false;
          _error = result.error;
        });
      }
    } catch (e) {
      debugPrint('RESET_BIOMETRIC_ERROR: $e');
      if (mounted) {
        setState(() {
          _biometricBusy = false;
          _error = 'Biometric authentication failed. Try again.';
        });
      }
    }
  }

  void _openRecoveryScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecoveryScreen(auth: widget.auth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final appState = context.watch<VaultAppState>();
    final biometricEscalated = appState.isBiometricEscalated;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: PremiumSurface(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
                children: [
                  Icon(Icons.lock_outline, size: 56, color: cs.primary),
                  const SizedBox(height: 16),
                  Text(
                    _mode == _VaultMode.hidden ? 'Hidden Vault' : 'Notex',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 12),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SecurityPill(icon: Icons.screenshot_monitor, label: 'Screen shield'),
                      SecurityPill(icon: Icons.key, label: 'Key stays local'),
                    ],
                  ),
                  const SizedBox(height: 32),

                  if (_biometricAvailable && _mode == _VaultMode.main) ...[
                    if (biometricEscalated)
                      Container(
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.only(bottom: 24),
                        decoration: BoxDecoration(
                          color: cs.errorContainer.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: cs.error.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: cs.error),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Too many biometric attempts. Enter password to continue.',
                                style: TextStyle(color: cs.error, fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _BiometricCard(
                        busy: _biometricBusy,
                        onTap: _unlockWithBiometric,
                        icon: _biometricIcon,
                        label: _biometricLabel,
                      ),
                      const SizedBox(height: 20),
                    ],
                    Row(
                      children: [
                        Expanded(child: Divider(color: cs.outlineVariant)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            biometricEscalated ? 'password required' : 'or use password',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                        Expanded(child: Divider(color: cs.outlineVariant)),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],

                  TextField(
                    controller: _secret,
                    obscureText: !_secretVisible,
                    decoration: InputDecoration(
                      labelText: _mode == _VaultMode.hidden ? 'Hidden vault password' : 'Master password',
                      suffixIcon: IconButton(
                        icon: Icon(_secretVisible ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _secretVisible = !_secretVisible),
                      ),
                    ),
                    onSubmitted: (_) => _unlockWithPassword(),
                  ),

                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: TextStyle(color: cs.error)),
                    ),

                  const SizedBox(height: 16),

                  FilledButton.icon(
                    onPressed: _passwordBusy ? null : _unlockWithPassword,
                    icon: _passwordBusy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary),
                          )
                        : const Icon(Icons.password),
                    label: Text(_passwordBusy ? 'Unlocking\u2026' : 'Unlock with password'),
                  ),

                  const SizedBox(height: 16),

                  TextButton(
                    onPressed: () {
                      setState(() {
                        _mode = _mode == _VaultMode.hidden ? _VaultMode.main : _VaultMode.hidden;
                        _error = null;
                        _secret.clear();
                        _secretVisible = false;
                      });
                    },
                    child: Text(_mode == _VaultMode.hidden ? 'Return to main vault' : 'Open hidden vault'),
                  ),

                  if (_mode == _VaultMode.main) ...[
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _showForgotPasswordOptions,
                      style: TextButton.styleFrom(foregroundColor: cs.onSurfaceVariant),
                      child: Text(
                        'Forgot password?',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _VaultMode { main, hidden }

class _BiometricCard extends StatelessWidget {
  const _BiometricCard({
    required this.busy,
    required this.onTap,
    required this.icon,
    required this.label,
  });
  final bool busy;
  final VoidCallback onTap;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: busy ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 32),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: busy ? cs.primary.withValues(alpha: 0.5) : cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: busy
                    ? SizedBox(
                        key: const ValueKey('loading'),
                        width: 52,
                        height: 52,
                        child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
                      )
                    : Container(
                        key: const ValueKey('icon'),
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
                        child: Icon(icon, size: 36, color: cs.primary),
                      ),
              ),
              const SizedBox(height: 16),
              Text(
                busy ? 'Authenticating\u2026' : 'Login with $label',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: busy ? cs.primary : cs.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                busy ? 'Check your device' : 'Fast, secure unlock',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

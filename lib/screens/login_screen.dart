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
import 'vault_home.dart';

/// Login screen — password and biometric unlock.
///
/// Password unlock routes correctly to:
///   main   → real vault
///   hidden → hidden vault (separate Hive box)
///   decoy  → empty fake vault (no real notes ever shown)
///
/// Biometric is only shown for the main vault — not hidden or decoy, since
/// those require explicit password entry to provide deniability.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});
  final VaultAuthService auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _secret = TextEditingController();
  bool _secretVisible = false;

  _VaultMode _mode = _VaultMode.main;

  bool _biometricAvailable = false;
  bool _biometricBusy = false;
  bool _passwordBusy = false;
  String? _error;
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _checkBiometric() async {
    final available = await widget.auth.isBiometricUnlockAvailable();
    if (!mounted) return;
    setState(() => _biometricAvailable = available);
  }

  Future<void> _unlockWithBiometric() async {
    if (_biometricBusy) return;
    setState(() {
      _biometricBusy = true;
      _error = null;
    });

    AuthResult result = await widget.auth.unlockWithBiometric();
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

    setState(() {
      _biometricBusy = false;
      _error = result.error;
    });
  }

  Future<void> _unlockWithPassword() async {
    if (_secret.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    setState(() {
      _passwordBusy = true;
      _error = null;
    });

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
      _checkForRestoreAfterLogin(result);
      return;
    }

    await AuditLog.write('Failed password unlock attempt');
    await _handleFailedAttempt();
    if (!mounted) return;
    final notifSetting =
        Hive.box(
              'vaultx_settings',
            ).get('failedAttemptNotifications', defaultValue: 'persistent')
            as String;
    setState(() {
      _passwordBusy = false;
      _error = null;
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
      duration: notifSetting == 'persistent'
          ? const Duration(minutes: 15)
          : const Duration(seconds: 4),
    );
  }

  /// After successful login, check for existing backup on Google Drive.
  /// If found, show restore prompt. Otherwise navigate directly to vault.
  Future<void> _checkForRestoreAfterLogin(AuthResult result) async {
    // Only check for main vault (not hidden/decoy on login)
    if (result.kind != VaultKind.main) {
      _navigateHome(result);
      return;
    }

    // Check if this is a fresh setup (no local data = potential new device)
    final hasLocalData = _hasLocalVaultData();
    if (hasLocalData) {
      debugPrint(
        'LOGIN RESTORE CHECK: local data exists, skipping auto-restore',
      );
      _navigateHome(result);
      return;
    }

    // Check if auto-restore is enabled in settings
    final autoRestore =
        Hive.box('vaultx_settings').get('autoRestore', defaultValue: false)
            as bool;

    // Try to detect backup silently
    try {
      final driveService = GoogleDriveBackupService(authService: widget.auth);
      final restored = await driveService.restoreSession();
      if (restored == null) {
        debugPrint('LOGIN RESTORE CHECK: no Google session, skipping');
        _navigateHome(result);
        return;
      }

      final hasBackup = await driveService.hasBackup();
      if (!hasBackup) {
        debugPrint('LOGIN RESTORE CHECK: no backup on Drive');
        _navigateHome(result);
        return;
      }

      if (!mounted) return;

      // Backup found — show restore prompt
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
                FloatingNotificationService.instance.show(
                  'Vault data restored successfully',
                );
              }
            },
          ),
        ),
      );

      if (!mounted) return;

      if (popResult != null && _isBase64MasterKey(popResult)) {
        // Restore completed successfully — use the backup's master key
        final masterKey = base64Decode(popResult);
        final pendingResult = AuthResult.pending(
          masterKey,
          'masterVerifier',
          result.kind,
        );
        final verifiedResult = await widget.auth.verify(pendingResult);
        if (mounted) {
          _navigateHome(verifiedResult.ok ? verifiedResult : result);
        }
      } else {
        // Restore was skipped or cancelled — use original result
        _navigateHome(result);
      }
    } catch (e) {
      debugPrint('LOGIN RESTORE CHECK ERROR: $e');
      if (mounted) _navigateHome(result);
    }
  }

  /// Quick check if local vault already has data.
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
    debugPrint('INTRUDER: failed attempt count=${appState.failedPinAttempts}');

    if (!mounted) return;
    final settingsBox = Hive.box('vaultx_settings');
    final enabled =
        settingsBox.get('intruderCaptureEnabled', defaultValue: true) as bool;
    if (!enabled) {
      debugPrint('INTRUDER: capture disabled in settings');
      return;
    }

    final threshold =
        settingsBox.get('intruderCaptureThreshold', defaultValue: 3) as int;
    if (appState.failedPinAttempts < threshold) {
      debugPrint(
        'INTRUDER: below threshold ($threshold), at ${appState.failedPinAttempts}',
      );
      return;
    }

    final cooldownOk = await IntruderSelfieService.isCooldownElapsed();
    if (!cooldownOk) {
      debugPrint('INTRUDER: cooldown active, skipping');
      await AuditLog.write('Intruder capture skipped — cooldown active');
      return;
    }

    try {
      final key = await widget.auth.intruderLogKey();
      final attachment = await IntruderSelfieService.capture(key);
      if (attachment != null) {
        await IntruderSelfieService.markCaptureTime();
        final entry = IntruderLogEntry(
          id: attachment.id,
          timestamp: DateTime.now(),
          attemptNumber: appState.failedPinAttempts,
          authMethod: _mode == _VaultMode.hidden
              ? 'hidden_password'
              : 'password',
          attachment: attachment,
        );
        await Hive.box('vaultx_intruder').put(attachment.id, entry.toJson());
        debugPrint('INTRUDER: log entry saved id=${attachment.id}');
      }
    } catch (e) {
      debugPrint('INTRUDER: capture error: $e');
    }
  }

  /// Returns `true` if [s] is a valid base64-encoded 32-byte master key
  /// (i.e. the result of a successful restore, not a skip/later/cancel).
  bool _isBase64MasterKey(String s) {
    try {
      final bytes = base64Decode(s);
      return bytes.length == 32;
    } catch (_) {
      return false;
    }
  }

  void _navigateHome(AuthResult result) {
    DeadMansService.resetTimer();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VaultHome(auth: widget.auth, authResult: result),
        ),
      );
    });
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
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  Icon(Icons.lock_outline, size: 56, color: cs.primary),
                  const SizedBox(height: 16),
                  Text(
                    _mode == _VaultMode.hidden ? 'Hidden Vault' : 'VaultX',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 12),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SecurityPill(
                        icon: Icons.screenshot_monitor,
                        label: 'Screen shield',
                      ),
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
                          border: Border.all(
                            color: cs.error.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: cs.error),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Too many biometric attempts. Enter password to continue.',
                                style: TextStyle(
                                  color: cs.error,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _BiometricCard(
                        busy: _biometricBusy,
                        onTap: _unlockWithBiometric,
                      ),
                      const SizedBox(height: 20),
                    ],
                    Row(
                      children: [
                        Expanded(child: Divider(color: cs.outlineVariant)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            biometricEscalated
                                ? 'password required'
                                : 'or use password',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
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
                      labelText: _mode == _VaultMode.hidden
                          ? 'Hidden vault password'
                          : 'Master password',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _secretVisible
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => _secretVisible = !_secretVisible),
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
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.onPrimary,
                            ),
                          )
                        : const Icon(Icons.password),
                    label: Text(
                      _passwordBusy
                          ? 'Unlocking\u2026'
                          : 'Unlock with password',
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextButton(
                    onPressed: () {
                      setState(() {
                        _mode = _mode == _VaultMode.hidden
                            ? _VaultMode.main
                            : _VaultMode.hidden;
                        _error = null;
                        _secret.clear();
                        _secretVisible = false;
                      });
                    },
                    child: Text(
                      _mode == _VaultMode.hidden
                          ? 'Return to main vault'
                          : 'Open hidden vault',
                    ),
                  ),
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
  const _BiometricCard({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

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
              color: busy
                  ? cs.primary.withValues(alpha: 0.5)
                  : cs.outlineVariant.withValues(alpha: 0.5),
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
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: cs.primary,
                        ),
                      )
                    : Container(
                        key: const ValueKey('icon'),
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.fingerprint,
                          size: 36,
                          color: cs.primary,
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              Text(
                busy ? 'Authenticating\u2026' : 'Login with Biometrics',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: busy ? cs.primary : cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                busy ? 'Check your device' : 'Fast, secure unlock',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

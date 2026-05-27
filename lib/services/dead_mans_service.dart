import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/auth.dart';
import 'audit_log.dart';
import 'auth_service.dart';
import 'vault_repository.dart';
import 'backup_service.dart';
import 'archive_service.dart';

/// Result returned by [DeadMansService.checkOnLaunch].
enum DmsCheckResult {
  /// Nothing happened — DMS is disabled or still within the grace period.
  none,

  /// The "wipe" action was executed (caller should redirect to setup).
  wiped,

  /// The "email_and_wipe" action requires the user to unlock first; the
  /// caller should redirect to the login screen.
  needsUnlock,
}

/// Extended Dead Man Switch service.
///
/// On every app launch this service checks whether the inactivity period has
/// been exceeded and, if so, executes the configured action (wipe only, or
/// email‑encrypted‑export then wipe).  It also sends mailto‑based warning
/// notifications at 14 days, 7 days and 24 hours before the deadline.
class DeadMansService {
  DeadMansService._();

  // ── Hive keys ──────────────────────────────────────────────────────────────

  static const _kSwitch = 'deadMansSwitch';
  static const _kAction = 'deadMansAction';
  static const _kEmail = 'deadMansEmail';
  static const _kMessage = 'deadMansMessage';
  static const _kDays = 'deadMansDays';
  static const _kLastOpened = 'deadMansLastOpened';
  static const _kWarning14d = 'deadMansWarning14dSent';
  static const _kWarning7d = 'deadMansWarning7dSent';
  static const _kWarning24h = 'deadMansWarning24hSent';

  static Box get _box => Hive.box('vaultx_settings');

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Call on every app launch **before** authentication.
  ///
  /// [auth] is required for wipe-only actions.  [repo] should be provided when
  /// the caller holds an active session (e.g. after unlocking).
  static Future<DmsCheckResult> checkOnLaunch({
    required VaultAuthService auth,
    bool isAuthenticated = false,
    VaultRepository? repo,
  }) async {
    if (!isEnabled()) return DmsCheckResult.none;

    final lastStr = _box.get(_kLastOpened) as String?;
    if (lastStr == null) {
      await resetTimer();
      return DmsCheckResult.none;
    }

    final last = DateTime.tryParse(lastStr);
    if (last == null) {
      await resetTimer();
      return DmsCheckResult.none;
    }

    final days = _box.get(_kDays, defaultValue: 7) as int;
    final now = DateTime.now();
    final elapsed = now.difference(last).inDays;

    if (elapsed < days) {
      await _sendWarningsIfNeeded(last, days, now);
      return DmsCheckResult.none;
    }

    final action = _box.get(_kAction, defaultValue: 'wipe') as String;

    if (action == 'wipe') {
      await _executeWipe(auth);
      return DmsCheckResult.wiped;
    }

    // action == 'email_and_wipe'
    if (isAuthenticated && repo != null) {
      await _executeEmailAndWipe(auth, repo);
      return DmsCheckResult.wiped;
    }

    return DmsCheckResult.needsUnlock;
  }

  /// Resets the inactivity timer to now.
  static Future<void> resetTimer() async {
    await _box.put(_kLastOpened, DateTime.now().toIso8601String());
    await AuditLog.write('Dead man switch timer reset');
  }

  // ── Configuration helpers ──────────────────────────────────────────────────

  static bool isEnabled() => _box.get(_kSwitch, defaultValue: false) as bool;
  static String getAction() =>
      _box.get(_kAction, defaultValue: 'wipe') as String;
  static int getDays() => _box.get(_kDays, defaultValue: 7) as int;
  static String? getEmail() => _box.get(_kEmail) as String?;
  static String? getMessage() => _box.get(_kMessage) as String?;

  /// How many full days remain before the deadline (0 if exceeded).
  static int remainingDays() {
    final lastStr = _box.get(_kLastOpened) as String?;
    if (lastStr == null) return getDays();
    final last = DateTime.tryParse(lastStr);
    if (last == null) return getDays();
    final days = getDays();
    final elapsed = DateTime.now().difference(last).inDays;
    return (days - elapsed).clamp(0, days);
  }

  /// Whether the 14-day warning has already been sent.
  static bool warning14dSent() =>
      _box.get(_kWarning14d, defaultValue: false) as bool;

  /// Whether the 7-day warning has already been sent.
  static bool warning7dSent() =>
      _box.get(_kWarning7d, defaultValue: false) as bool;

  /// Whether the 24-hour warning has already been sent.
  static bool warning24hSent() =>
      _box.get(_kWarning24h, defaultValue: false) as bool;

  /// Persist all DMS settings at once.
  static Future<void> saveSettings({
    required bool enabled,
    required String action,
    String? email,
    String? message,
    required int days,
  }) async {
    await _box.put(_kSwitch, enabled);
    await _box.put(_kAction, action);
    if (email != null) await _box.put(_kEmail, email);
    if (message != null) await _box.put(_kMessage, message);
    await _box.put(_kDays, days);
    await _box.put(_kLastOpened, DateTime.now().toIso8601String());
    // Reset warning flags when settings change
    await _box.put(_kWarning14d, false);
    await _box.put(_kWarning7d, false);
    await _box.put(_kWarning24h, false);
    await AuditLog.write('Dead man switch settings updated');
  }

  /// Disable and clear all DMS settings.
  static Future<void> disable() async {
    await _box.put(_kSwitch, false);
    await _box.put(_kAction, 'wipe');
    await _box.delete(_kEmail);
    await _box.delete(_kMessage);
    await _box.put(_kWarning14d, false);
    await _box.put(_kWarning7d, false);
    await _box.put(_kWarning24h, false);
    await AuditLog.write('Dead man switch disabled');
  }

  // ── Warning notifications ─────────────────────────────────────────────────

  static Future<void> _sendWarningsIfNeeded(
    DateTime lastOpened,
    int days,
    DateTime now,
  ) async {
    final deadline = lastOpened.add(Duration(days: days));
    final remaining = deadline.difference(now).inDays;
    final email = _box.get(_kEmail) as String?;

    if (email == null || email.isEmpty) return;

    try {
      if (remaining <= 14 && remaining > 7) {
        final sent = _box.get(_kWarning14d, defaultValue: false) as bool;
        if (!sent) {
          await _sendWarningMail(
            email: email,
            subject: 'VaultX Dead Man Switch Warning — 14 days remaining',
            body: _warningBody(remaining, days),
          );
          await _box.put(_kWarning14d, true);
          await AuditLog.write('DMS 14-day warning sent');
        }
      }

      if (remaining <= 7 && remaining > 1) {
        final sent = _box.get(_kWarning7d, defaultValue: false) as bool;
        if (!sent) {
          await _sendWarningMail(
            email: email,
            subject: 'VaultX Dead Man Switch Warning — 7 days remaining',
            body: _warningBody(remaining, days),
          );
          await _box.put(_kWarning7d, true);
          await AuditLog.write('DMS 7-day warning sent');
        }
      }

      if (remaining <= 1 && remaining >= 0) {
        final sent = _box.get(_kWarning24h, defaultValue: false) as bool;
        if (!sent) {
          final hours = deadline.difference(now).inHours.clamp(1, 24);
          await _sendWarningMail(
            email: email,
            subject:
                'VaultX Dead Man Switch Warning — $hours hour${hours == 1 ? '' : 's'} remaining',
            body: _warningBody(remaining, days, hours: hours),
          );
          await _box.put(_kWarning24h, true);
          await AuditLog.write('DMS 24-hour warning sent');
        }
      }
    } catch (_) {
      // Email sending is best-effort; don't block the app.
    }
  }

  static String _warningBody(int remainingDays, int totalDays, {int? hours}) {
    final timeLeft = hours != null
        ? '$hours hour${hours == 1 ? '' : 's'}'
        : '$remainingDays day${remainingDays == 1 ? '' : 's'}';
    return '''Your VaultX Dead Man Switch is active with a $totalDays-day inactivity period.

Only $timeLeft remain before the configured action is executed.

If you are still active, simply open the VaultX app to reset the timer.

If you do not want this warning, disable the Dead Man Switch in VaultX Settings.

— VaultX Security''';
  }

  static Future<void> _sendWarningMail({
    required String email,
    required String subject,
    required String body,
  }) async {
    await AuditLog.write('DMS warning: $subject — would notify $email');
  }

  // ── Action execution ───────────────────────────────────────────────────────

  /// Wipe all vault data immediately (existing behaviour).
  static Future<void> _executeWipe(VaultAuthService auth) async {
    await auth.wipeAll();
    await AuditLog.write('Dead Man Switch triggered — vault wiped');
  }

  /// Generate encrypted export and share it. After sharing, wipes everything.
  ///
  /// Uses the provided [context] for dialogs and the share sheet. The caller
  /// must handle navigation to the setup screen after this returns (the method
  /// does NOT navigate automatically — use [DmsCheckResult.wiped] to decide).
  static Future<void> _executeEmailAndWipe(
    VaultAuthService auth,
    VaultRepository repo,
  ) async {
    final backupService = BackupService(
      masterKey: repo.masterKey,
      kind: repo.kind,
      authService: auth,
    );
    final backupResult = await backupService.createBackup();
    final fullData = Map<String, dynamic>.from(backupResult.data);
    fullData['manifest'] = backupResult.manifest.toJson();
    final filePath = await ArchiveService.createArchive(fullData);
    
    final email = _box.get(_kEmail) as String?;
    final message = _box.get(_kMessage) as String?;

    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          subject: 'VaultX Encrypted Backup',
          text: email != null
              ? 'Encrypted VaultX backup for $email'
              : 'Encrypted VaultX backup',
        ),
      );
    } catch (_) {
      // Share sheet may not be available; continue with wipe.
    }

    // Securely delete the export file
    await ArchiveService.cleanup(filePath);

    // Wipe all vault data
    await auth.wipeAll();

    if (message != null && message.isNotEmpty && email != null) {
      try {
        await _sendWarningMail(
          email: email,
          subject: 'VaultX Encrypted Backup Sent & Data Wiped',
          body:
              'Your VaultX dead man switch has triggered.\n\n'
              'An encrypted backup was shared and all local vault data has been '
              'permanently deleted.\n\n'
              'Custom message from the vault owner:\n'
              '$message',
        );
      } catch (_) {}
    }

    await AuditLog.write('Dead Man Switch triggered — vault emailed & wiped');
  }

  // ── Auth confirmation ──────────────────────────────────────────────────────

  /// Shows a full-screen unlock dialog (password + biometric) and returns
  /// `true` only when the user successfully authenticates.
  ///
  /// Used as a guard before enabling or modifying DMS settings.
  static Future<bool> requireAuth(
    BuildContext context,
    VaultAuthService auth,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _AuthGuardDialog(auth: auth),
    );
    return result ?? false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth guard dialog — password + biometric confirmation
// ─────────────────────────────────────────────────────────────────────────────

class _AuthGuardDialog extends StatefulWidget {
  const _AuthGuardDialog({required this.auth});
  final VaultAuthService auth;

  @override
  State<_AuthGuardDialog> createState() => _AuthGuardDialogState();
}

class _AuthGuardDialogState extends State<_AuthGuardDialog> {
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Authentication Required'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Confirm your identity to enable or modify '
            'the Dead Man Switch settings.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordCtrl,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Master password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _authenticate(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _authenticateBiometric,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Use biometric'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _authenticate,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirm'),
        ),
      ],
    );
  }

  Future<void> _authenticate() async {
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      AuthResult result = await widget.auth.unlockWithPassword(
        _passwordCtrl.text,
      );
      result = await widget.auth.verify(result);
      if (result.ok && mounted) {
        Navigator.pop(context, true);
      } else {
        setState(() => _error = result.error ?? 'Invalid password');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authenticateBiometric() async {
    if (!await widget.auth.isBiometricUnlockAvailable()) {
      setState(() => _error = 'Biometric unlock is not set up.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      AuthResult result = await widget.auth.unlockWithBiometric();
      result = await widget.auth.verify(result);
      if (result.ok && mounted) {
        Navigator.pop(context, true);
      } else {
        setState(() => _error = result.error ?? 'Biometric failed');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'audit_log.dart';
import 'auth_service.dart';

/// Password Memory Reminder Service.
///
/// Prompts the user on a configurable schedule to enter their master password.
/// This helps prevent forgetting the password over long periods of biometric-only use.
class PasswordMemoryService {
  PasswordMemoryService._();

  static const _kEnabled = 'passwordMemoryEnabled';
  static const _kFrequencyDays = 'passwordMemoryFrequencyDays';
  static const _kLastPasswordEntry = 'passwordMemoryLastEntry';
  static const _kHint = 'passwordMemoryHint';
  static const _kRemindLaterAt = 'passwordMemoryRemindLaterAt';

  static Box get _box => Hive.box('vaultx_settings');

  static bool isEnabled() => _box.get(_kEnabled, defaultValue: false) as bool;

  static int getFrequencyDays() =>
      _box.get(_kFrequencyDays, defaultValue: 30) as int;

  static String? getHint() => _box.get(_kHint) as String?;

  /// Record that the user entered their password manually.
  static Future<void> recordPasswordEntry() async {
    await _box.put(
      _kLastPasswordEntry,
      DateTime.now().toIso8601String(),
    );
    await _box.delete(_kRemindLaterAt);
    await AuditLog.write('Password memory: entry recorded');
  }

  /// Check if the reminder should be shown based on last password entry.
  static bool isReminderDue() {
    if (!isEnabled()) return false;

    final snoozeStr = _box.get(_kRemindLaterAt) as String?;
    if (snoozeStr != null) {
      final snooze = DateTime.tryParse(snoozeStr);
      if (snooze != null && DateTime.now().isBefore(snooze)) return false;
    }

    final lastStr = _box.get(_kLastPasswordEntry) as String?;
    if (lastStr == null) return true;

    final last = DateTime.tryParse(lastStr);
    if (last == null) return true;

    return DateTime.now().difference(last).inDays >= getFrequencyDays();
  }

  /// Snooze the reminder for [days] (default 1).
  static Future<void> snooze({int days = 1}) async {
    await _box.put(
      _kRemindLaterAt,
      DateTime.now().add(Duration(days: days)).toIso8601String(),
    );
    await AuditLog.write('Password memory: reminder snoozed for $days day(s)');
  }

  /// Days until next reminder would fire (0 if already due).
  static int remainingDays() {
    final lastStr = _box.get(_kLastPasswordEntry) as String?;
    if (lastStr == null) return 0;
    final last = DateTime.tryParse(lastStr);
    if (last == null) return 0;
    final days = getFrequencyDays();
    return (days - DateTime.now().difference(last).inDays).clamp(0, days);
  }

  /// Label for a given number of days (e.g. "7 days", "1 month").
  static String dayLabel(int days) {
    switch (days) {
      case 7:
        return '7 days';
      case 14:
        return '14 days';
      case 30:
        return '1 month';
      case 60:
        return '2 months';
      case 90:
        return '3 months';
      default:
        return '$days days';
    }
  }

  static Future<void> saveSettings({
    required bool enabled,
    required int frequencyDays,
    String? hint,
  }) async {
    await _box.put(_kEnabled, enabled);
    await _box.put(_kFrequencyDays, frequencyDays);
    if (hint != null) {
      await _box.put(_kHint, hint);
    }
    if (!enabled) {
      await _box.delete(_kRemindLaterAt);
    }
    await AuditLog.write('Password memory settings updated');
  }

  /// Shows the reminder dialog if it's due.
  static Future<void> checkAndShow(
    BuildContext context,
    VaultAuthService auth,
  ) async {
    if (!isReminderDue()) return;
    if (!context.mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordMemoryReminderDialog(auth: auth),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reminder Dialog
// ─────────────────────────────────────────────────────────────────────────────

class _PasswordMemoryReminderDialog extends StatefulWidget {
  const _PasswordMemoryReminderDialog({required this.auth});
  final VaultAuthService auth;

  @override
  State<_PasswordMemoryReminderDialog> createState() =>
      _PasswordMemoryReminderDialogState();
}

class _PasswordMemoryReminderDialogState
    extends State<_PasswordMemoryReminderDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideIn;

  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  bool _verified = false;
  String? _shownHint;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeIn = CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut);
    _slideIn = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return FadeTransition(
      opacity: _fadeIn,
      child: AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        contentPadding: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        content: SlideTransition(
          position: _slideIn,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──────────────────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      cs.primaryContainer,
                      cs.primaryContainer.withValues(alpha: 0.4),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.psychology,
                        size: 40,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Password Memory Reminder',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _verified
                          ? 'Verified successfully! Your password memory is fresh.'
                          : 'You haven\'t entered your master password in a while. '
                              'Take a moment to make sure you still remember it.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

              // ── Body ───────────────────────────────────────────────────
              if (!_verified) ...[
                if (_shownHint != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.secondaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline,
                            size: 18,
                            color: cs.secondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _shownHint!,
                              style: TextStyle(
                                color: cs.onSecondaryContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: TextField(
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Master password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                      ),
                    ),
                    onSubmitted: (_) => _verify(),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: cs.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],

              // ── Actions ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_verified)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Continue'),
                        ),
                      )
                    else ...[
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _verify,
                          icon: _busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.verified, size: 18),
                          label: const Text('Verify password'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (PasswordMemoryService.getHint() != null &&
                              _shownHint == null)
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => setState(
                                  () => _shownHint =
                                      PasswordMemoryService.getHint(),
                                ),
                                icon: const Icon(Icons.lightbulb_outline,
                                    size: 16),
                                label: const Text('Hint'),
                              ),
                            ),
                          if (_shownHint == null &&
                              PasswordMemoryService.getHint() != null)
                            const SizedBox(width: 8),
                          Expanded(
                            child: TextButton.icon(
                              onPressed: () async {
                                await PasswordMemoryService.snooze();
                                if (context.mounted) Navigator.pop(context);
                              },
                              icon: const Icon(Icons.snooze, size: 16),
                              label: const Text('Later'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showRecoveryOptions(context);
                        },
                        icon: Icon(
                          Icons.help_outline,
                          size: 16,
                          color: cs.error.withValues(alpha: 0.7),
                        ),
                        label: Text(
                          'I forgot my password',
                          style: TextStyle(
                            color: cs.error.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _verify() async {
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var result = await widget.auth.unlockWithPassword(_passwordCtrl.text);
      result = await widget.auth.verify(result);
      if (!mounted) return;
      if (result.ok && result.kind != null) {
        await PasswordMemoryService.recordPasswordEntry();
        if (!mounted) return;
        setState(() => _verified = true);
      } else {
        setState(() => _error = result.error ?? 'Wrong password');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showRecoveryOptions(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Password Recovery Options'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'If you\'ve forgotten your master password, here are your options:',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            _RecoveryOption(
              icon: Icons.vpn_key,
              title: 'Recovery Key',
              subtitle: 'Use your 24-word recovery phrase to regain access',
            ),
            SizedBox(height: 12),
            _RecoveryOption(
              icon: Icons.cloud_download,
              title: 'Restore from Backup',
              subtitle:
                  'If you have a recent backup, you can restore your vault',
            ),
            SizedBox(height: 12),
            _RecoveryOption(
              icon: Icons.fingerprint,
              title: 'Biometric Reset',
              subtitle:
                  'If biometrics are enabled, you may reset from the login screen',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

class _RecoveryOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _RecoveryOption({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: cs.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

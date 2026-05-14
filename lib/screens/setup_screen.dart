import 'package:flutter/material.dart';

import '../models/auth.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';
import 'login_screen.dart';

/// Initial vault setup screen — creates master password, optional PIN, and decoy PIN.
///
/// Also handles cross-device restore via "Restore from Google Drive".
/// The restore path MUST live here (before any setup runs) so that
/// importAuthBundle writes Phone 1's wrapped masterKey into secure storage
/// while the vault is still uninitialized. If restore happened after setup,
/// a new random masterKey would already exist and importAuthBundle would skip,
/// causing every decryption to fail on Phone 2.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.auth});
  final VaultAuthService auth;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  // ── Setup form ──────────────────────────────────────────────────────────────
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  // ── Restore flow ────────────────────────────────────────────────────────────
  bool _showRestore = false;
  bool _backupDownloaded = false;
  Map<String, dynamic>? _pendingBackup;
  final _restorePassword = TextEditingController();
  GoogleDriveBackupService? _driveService;

  // ── Shared ──────────────────────────────────────────────────────────────────
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _restorePassword.dispose();
    super.dispose();
  }

  // ── Setup ────────────────────────────────────────────────────────────────────

  Future<void> _setup() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_password.text.length < 12 || _password.text != _confirm.text) {
      setState(() {
        _busy = false;
        _error = 'Use a matching password with at least 12 characters.';
      });
      return;
    }
    await widget.auth.setup(password: _password.text);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
    );
  }

  // ── Restore — Step 1: sign in and download ───────────────────────────────────

  /// Signs into Google Drive and downloads the backup.
  ///
  /// Because the vault is not yet initialized at this point, downloadBackup()
  /// calls importAuthBundle() which writes Phone 1's wrapped masterKey and
  /// salts into secure storage. After this call isInitialized() returns true,
  /// so unlockWithPassword() in step 2 can correctly derive Phone 1's masterKey.
  Future<void> _signInAndDownload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _driveService = GoogleDriveBackupService(authService: widget.auth);

      final signedIn = await _driveService!.signIn();
      if (!mounted) return;
      if (!signedIn) {
        setState(() {
          _busy = false;
          _error = 'Google sign-in was cancelled.';
        });
        return;
      }

      debugPrint('SETUP RESTORE: downloading backup from Drive...');
      final backup = await _driveService!.downloadBackup();
      if (!mounted) return;
      if (backup == null) {
        debugPrint('SETUP RESTORE FAILED: no backup found on Drive');
        setState(() {
          _busy = false;
          _error = 'No VaultX backup found in your Google Drive.';
        });
        return;
      }

      debugPrint('SETUP RESTORE: backup downloaded, keys=${backup.keys.join(", ")}');
      debugPrint('SETUP RESTORE: has authBundle=${backup.containsKey("authBundle")}, has manifest=${backup.containsKey("manifest")}');
      debugPrint('SETUP RESTORE: mainVault records=${(backup["mainVault"] as List?)?.length ?? 0}');
      debugPrint('SETUP RESTORE: hiddenVault records=${(backup["hiddenVault"] as List?)?.length ?? 0}');

      if (!mounted) return;
      setState(() {
        _busy = false;
        _backupDownloaded = true;
        _pendingBackup = backup;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Drive error: $e';
      });
    }
  }

  // ── Restore — Step 2: unlock and decrypt ─────────────────────────────────────

  /// Unlocks with the user's original password (which now unwraps Phone 1's
  /// masterKey from the imported auth bundle) and restores all records.
  Future<void> _restoreWithPassword() async {
    if (_restorePassword.text.isEmpty) {
      setState(
        () => _error = 'Enter your vault password to decrypt the backup.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      debugPrint('SETUP RESTORE: unlocking with password...');
      final result = await widget.auth.unlockWithPassword(
        _restorePassword.text,
      );
      debugPrint('SETUP RESTORE: unlock result ok=${result.ok}, kind=${result.kind}, hasKey=${result.masterKey != null}');
      final verified = await widget.auth.verify(result);
      debugPrint('SETUP RESTORE: verify result ok=${verified.ok}, kind=${verified.kind}, hasKey=${verified.masterKey != null}');
      if (!mounted) return;

      if (!verified.ok || verified.masterKey == null) {
        debugPrint('SETUP RESTORE FAILED: wrong password or masterKey is null');
        setState(() {
          _busy = false;
          _error =
              'Wrong password — this must be the password from your original vault.';
        });
        return;
      }

      debugPrint('SETUP RESTORE: password verified, masterKey length=${verified.masterKey!.length}');
      debugPrint('SETUP RESTORE: starting full restore...');
      final backupService = BackupService(
        masterKey: verified.masterKey!,
        kind: VaultKind.main,
        authService: widget.auth,
      );
      final restoreResult = await backupService.restoreBackup(
        _pendingBackup!,
        mode: RestoreMode.replace,
        mainMasterKey: verified.masterKey!,
      );
      debugPrint('SETUP RESTORE: restoreBackup returned success=${restoreResult.success}, error=${restoreResult.error}');

      if (!mounted) return;

      if (restoreResult.success) {
        FloatingNotificationService.instance.show('Vault restored successfully.');
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
        );
      } else {
        final errMsg = restoreResult.error ?? 'Unknown restore error';
        debugPrint('SETUP RESTORE FAILED: $errMsg');
        FloatingNotificationService.instance.show('Restore failed: $errMsg', error: true);
        setState(() {
          _busy = false;
          _error = errMsg;
        });
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('SETUP RESTORE EXCEPTION: $e');
      FloatingNotificationService.instance.show('Restore failed: $e', error: true);
      setState(() {
        _busy = false;
        _error = 'Restore failed: $e';
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final strength = _passwordStrength(_password.text);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: PremiumSurface(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: ListView(
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  const Icon(Icons.security, size: 56),
                  const SizedBox(height: 16),
                  Text(
                    'VaultX',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Local-first encrypted notes. No cloud account. No plaintext vault records.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SecurityPill(icon: Icons.lock, label: 'AES-256'),
                      SecurityPill(icon: Icons.storage, label: 'Local only'),
                      SecurityPill(
                        icon: Icons.visibility_off,
                        label: 'Zero knowledge',
                      ),
                    ],
                  ),

                  // ── Restore section (shown when tapped) ─────────────────────
                  if (_showRestore) ...[
                    const SizedBox(height: 28),
                    _buildRestoreSection(context),
                  ],

                  // ── Setup form (hidden while restoring) ─────────────────────
                  if (!_showRestore) ...[
                    const SizedBox(height: 24),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Master password',
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: strength.score / 4,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      strength.label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm master password',
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy ? null : _setup,
                      icon: const Icon(Icons.lock),
                      label: const Text('Create encrypted vault'),
                    ),
                    const SizedBox(height: 20),
                    _buildOrDivider(context),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _showRestore = true;
                              _error = null;
                            }),
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('Restore from Google Drive'),
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

  Widget _buildOrDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Divider(color: cs.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(child: Divider(color: cs.outlineVariant)),
      ],
    );
  }

  Widget _buildRestoreSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_download_outlined, color: cs.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Restore from Google Drive',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: cs.primary),
              ),
              const Spacer(),
              // Cancel button
              IconButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _showRestore = false;
                        _backupDownloaded = false;
                        _pendingBackup = null;
                        _error = null;
                        _restorePassword.clear();
                      }),
                icon: Icon(Icons.close, size: 18, color: cs.onSurfaceVariant),
                visualDensity: VisualDensity.compact,
                tooltip: 'Cancel',
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (!_backupDownloaded) ...[
            // Step 1 ─ sign in
            Text(
              'Sign in with Google to download your encrypted backup.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _signInAndDownload,
                icon: _busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Icon(Icons.login),
                label: Text(_busy ? 'Connecting\u2026' : 'Sign in with Google'),
              ),
            ),
          ] else ...[
            // Step 2 ─ enter password to decrypt
            Row(
              children: [
                Icon(Icons.check_circle, color: cs.primary, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Backup found. Enter your vault password.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _restorePassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Original vault password',
                helperText: 'The password you used on your previous device.',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _restoreWithPassword,
                icon: _busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Icon(Icons.lock_open),
                label: Text(_busy ? 'Restoring\u2026' : 'Decrypt & Restore'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  ({int score, String label}) _passwordStrength(String value) {
    var score = 0;
    if (value.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(value) && RegExp(r'[a-z]').hasMatch(value)) {
      score++;
    }
    if (RegExp(r'\d').hasMatch(value)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(value) || value.length >= 18) score++;
    final label = switch (score) {
      4 => 'Excellent: suitable for a zero-knowledge vault',
      3 => 'Strong: add length or symbols for maximum security',
      2 => 'Moderate: use a longer passphrase',
      _ =>
        'Weak: use at least 12 characters; forgotten passwords cannot be recovered',
    };
    return (score: score, label: label);
  }
}

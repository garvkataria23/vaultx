import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../services/cloud_storage_provider.dart';
import '../widgets/widgets.dart';
import '../widgets/cloud_restore_selector.dart';
import 'login_screen.dart';

/// Initial vault setup screen — creates master password, optional PIN, and decoy PIN.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.auth});
  final VaultAuthService auth;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _showRestore = false;
  bool _backupDownloaded = false;
  Map<String, dynamic>? _pendingBackup;
  final _restorePassword = TextEditingController();
  CloudProvider _selectedProvider = CloudProvider.googleDrive;
  CloudStorageProvider? _activeCloudService;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _restorePassword.dispose();
    super.dispose();
  }

  Future<void> _setup() async {
    if (_password.text.length < 12 || _password.text != _confirm.text) {
      setState(() {
        _busy = false;
        _error = 'Use a matching password with at least 12 characters.';
      });
      return;
    }
    setState(() => _busy = true);
    await widget.auth.setup(password: _password.text);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
    );
  }

  Future<void> _handleCloudRestore() async {
    await AuditLog.write('CLOUD_RESTORE_CLICKED');
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CloudRestoreSelector(
        onSelected: (provider) async {
          await AuditLog.write('PROVIDER_SELECTED: ${provider.name}');
          setState(() {
            _selectedProvider = provider;
            _showRestore = true;
            _error = null;
          });
          _signInAndDownload();
        },
      ),
    );
  }

  Future<void> _signInAndDownload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_selectedProvider == CloudProvider.googleDrive) {
        await AuditLog.write('GOOGLE_RESTORE_START');
        _activeCloudService = GoogleDriveBackupService(authService: widget.auth);
        final signedIn = await _activeCloudService!.signIn();
        if (!mounted) return;
        if (!signedIn) {
          setState(() {
            _busy = false;
            _error = 'Google sign-in was cancelled.';
          });
          return;
        }
      } else {
        await AuditLog.write('MEGA_RESTORE_START');
        _activeCloudService = MEGABackupService(authService: widget.auth);
        final success = await _showMegaLoginDialog();
        if (!mounted) return;
        if (success != true) {
          setState(() {
            _busy = false;
            _error = 'MEGA connection was cancelled or failed.';
          });
          return;
        }
      }

      final backup = await _activeCloudService!.downloadBackup();
      if (!mounted) return;
      if (backup == null) {
        await AuditLog.write('RESTORE_FAILED: No backup found');
        setState(() {
          _busy = false;
          _error = 'No VaultX backup found in your ${_selectedProvider.displayName}.';
        });
        return;
      }

      setState(() {
        _busy = false;
        _backupDownloaded = true;
        _pendingBackup = backup;
      });
    } catch (e) {
      await AuditLog.write('RESTORE_FAILED: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '${_selectedProvider.displayName} error: $e';
      });
    }
  }

  final _megaEmailCtrl = TextEditingController();
  final _megaPasswordCtrl = TextEditingController();
  bool _megaPasswordVisible = false;
  bool _megaLoggingIn = false;
  String? _megaError;

  Future<bool?> _showMegaLoginDialog() {
    _megaEmailCtrl.clear();
    _megaPasswordCtrl.clear();
    _megaError = null;
    _megaLoggingIn = false;

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Connect to MEGA'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _megaEmailCtrl,
                decoration: const InputDecoration(labelText: 'MEGA Email', prefixIcon: Icon(Icons.email)),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _megaPasswordCtrl,
                obscureText: !_megaPasswordVisible,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_megaPasswordVisible ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setDialogState(() => _megaPasswordVisible = !_megaPasswordVisible),
                  ),
                ),
              ),
              if (_megaError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_megaError!, style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontSize: 12)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: _megaLoggingIn ? null : () async {
                final email = _megaEmailCtrl.text.trim().toLowerCase();
                final password = _megaPasswordCtrl.text;
                if (email.isEmpty || password.isEmpty) {
                  setDialogState(() => _megaError = 'Enter credentials');
                  return;
                }
                setDialogState(() => _megaLoggingIn = true);
                try {
                  final ok = await (_activeCloudService as MEGABackupService).loginWithCredentials(email, password);
                  if (ctx.mounted) Navigator.pop(ctx, ok);
                } catch (e) {
                  setDialogState(() {
                    _megaLoggingIn = false;
                    _megaError = e.toString();
                  });
                }
              },
              child: Text(_megaLoggingIn ? 'Connecting...' : 'Connect'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restoreWithPassword() async {
    if (_restorePassword.text.isEmpty) {
      setState(() => _error = 'Enter your vault password to decrypt the backup.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.auth.unlockWithPassword(_restorePassword.text);
      if (!mounted) return;
      final verified = await widget.auth.verify(result);
      if (!mounted) return;

      if (!verified.ok || verified.masterKey == null) {
        setState(() {
          _busy = false;
          _error = 'Wrong password — this must be the password from your original vault.';
        });
        return;
      }

      final backupService = BackupService(masterKey: verified.masterKey!, kind: VaultKind.main, authService: widget.auth);
      final restoreResult = await backupService.restoreBackup(_pendingBackup!, mode: RestoreMode.replace, mainMasterKey: verified.masterKey!);
      if (!mounted) return;

      if (restoreResult.success) {
        await AuditLog.write('RESTORE_SUCCESS');
        FloatingNotificationService.instance.show('Vault restored successfully.');
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)));
      } else {
        final errMsg = restoreResult.error ?? 'Unknown restore error';
        await AuditLog.write('RESTORE_FAILED: $errMsg');
        FloatingNotificationService.instance.show('Restore failed: $errMsg', error: true);
        setState(() {
          _busy = false;
          _error = errMsg;
        });
      }
    } catch (e) {
      if (!mounted) return;
      FloatingNotificationService.instance.show('Restore failed: $e', error: true);
      setState(() {
        _busy = false;
        _error = 'Restore failed: $e';
      });
    }
  }

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
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
                children: [
                  const Icon(Icons.security, size: 56),
                  const SizedBox(height: 16),
                  Text('VaultX', style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 8),
                  Text('Local-first encrypted notes. No cloud account. No plaintext vault records.', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 14),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SecurityPill(icon: Icons.lock, label: 'AES-256'),
                      SecurityPill(icon: Icons.storage, label: 'Local only'),
                      SecurityPill(icon: Icons.visibility_off, label: 'Zero knowledge'),
                    ],
                  ),

                  if (_showRestore) ...[
                    const SizedBox(height: 28),
                    _buildRestoreSection(context),
                  ],

                  if (!_showRestore) ...[
                    const SizedBox(height: 24),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Master password'),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: strength.score / 4, minHeight: 6, borderRadius: BorderRadius.circular(99)),
                    const SizedBox(height: 6),
                    Text(strength.label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 12),
                    TextField(controller: _confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm master password')),
                    if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 20),
                    FilledButton.icon(onPressed: _busy ? null : _setup, icon: const Icon(Icons.lock), label: const Text('Create encrypted vault')),
                    const SizedBox(height: 20),
                    _buildOrDivider(context),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(onPressed: _busy ? null : _handleCloudRestore, icon: const Icon(Icons.cloud_download_outlined), label: const Text('Restore from Cloud')),
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
          child: Text('OR', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
        Expanded(child: Divider(color: cs.outlineVariant)),
      ],
    );
  }

  Widget _buildRestoreSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final providerName = _selectedProvider.displayName;
    
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
              Text('Restore from $providerName', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.primary)),
              const Spacer(),
              IconButton(
                onPressed: _busy ? null : () => setState(() {
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
            Text('Sign in to $providerName to download your encrypted backup.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _signInAndDownload,
                icon: _busy ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary)) : const Icon(Icons.login),
                label: Text(_busy ? 'Connecting\u2026' : 'Sign in to $providerName'),
              ),
            ),
          ] else ...[
            Row(
              children: [
                Icon(Icons.check_circle, color: cs.primary, size: 16),
                const SizedBox(width: 6),
                Text('Backup found. Enter your vault password.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _restorePassword,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Original vault password', helperText: 'The password you used on your previous device.'),
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
                icon: _busy ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary)) : const Icon(Icons.lock_open),
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
    if (RegExp(r'[A-Z]').hasMatch(value) && RegExp(r'[a-z]').hasMatch(value)) score++;
    if (RegExp(r'\d').hasMatch(value)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(value) || value.length >= 18) score++;
    final label = switch (score) {
      4 => 'Excellent: suitable for a zero-knowledge vault',
      3 => 'Strong: add length or symbols for maximum security',
      2 => 'Moderate: use a longer passphrase',
      _ => 'Weak: use at least 12 characters; forgotten passwords cannot be recovered',
    };
    return (score: score, label: label);
  }
}

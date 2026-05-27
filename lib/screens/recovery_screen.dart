import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';
import '../services/auth_session_manager.dart';

class RecoveryScreen extends StatefulWidget {
  final VaultAuthService auth;
  final Uint8List? preVerifiedMasterKey;

  const RecoveryScreen({
    super.key,
    required this.auth,
    this.preVerifiedMasterKey,
  });

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  final _recovery = RecoveryService();
  final _codeCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _codeVisible = false;
  bool _newPasswordVisible = false;
  bool _confirmVisible = false;
  bool _busy = false;
  String? _error;
  Uint8List? _masterKey;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.preVerifiedMasterKey != null) {
      _masterKey = widget.preVerifiedMasterKey;
    }
  }

  bool get _hasMasterKey => _masterKey != null;

  Future<void> _verifyCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty || !_isValidFormat(code)) {
      setState(() => _error = 'Enter a valid recovery code (XXXX-XXXX).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await _recovery.verifyCode(code);

    if (!mounted) return;

    if (result.success && result.masterKey != null) {
      setState(() {
        _masterKey = result.masterKey;
        _busy = false;
      });
      return;
    }

    setState(() {
      _busy = false;
      _error = result.error ?? 'Invalid recovery code.';
    });
  }

  Future<void> _resetPassword() async {
    final newPw = _newPasswordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (newPw.length < 12) {
      setState(() => _error = 'Use at least 12 characters.');
      return;
    }
    if (newPw != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final ok = await widget.auth.changeMasterPasswordWithKey(
      masterKey: _masterKey!,
      newPassword: newPw,
    );

    if (!mounted) return;

    if (ok) {
      final pending = AuthResult.pending(
        _masterKey!,
        'masterVerifier',
        VaultKind.main,
      );
      final verified = await widget.auth.verify(pending);
      DeadMansService.resetTimer();
      AuthSessionManager.instance.authenticate(verified);
    } else {
      setState(() {
        _busy = false;
        _error = 'Failed to reset password. Try again.';
      });
    }
  }

  bool _isValidFormat(String code) {
    final parts = code.split('-');
    return parts.length == 2 &&
        parts[0].length == 4 &&
        parts[1].length == 4;
  }

  ({int score, String label}) _passwordStrength(String value) {
    var score = 0;
    if (value.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(value) &&
        RegExp(r'[a-z]').hasMatch(value)) {
      score++;
    }
    if (RegExp(r'\d').hasMatch(value)) {
      score++;
    }
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(value) ||
        value.length >= 18) {
      score++;
    }
    final label = switch (score) {
      4 => 'Excellent',
      3 => 'Strong',
      2 => 'Moderate',
      _ => 'Weak',
    };
    return (score: score, label: label);
  }

  void _backToLogin() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

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
                  Icon(
                    _hasMasterKey
                        ? Icons.lock_reset
                        : Icons.password_rounded,
                    size: 56,
                    color: cs.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _hasMasterKey ? 'Reset Password' : 'Recover Vault',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _hasMasterKey
                        ? 'Choose a new master password for your vault.'
                        : 'Enter one of your recovery codes to regain access.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),

                  if (!_hasMasterKey) ...[
                    TextField(
                      controller: _codeCtrl,
                      obscureText: !_codeVisible,
                      maxLength: 9,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: InputDecoration(
                        labelText: 'Recovery code',
                        hintText: 'XXXX-XXXX',
                        prefixIcon: const Icon(Icons.vpn_key_outlined),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _codeVisible
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                          onPressed: () =>
                              setState(() => _codeVisible = !_codeVisible),
                        ),
                      ),
                      onSubmitted: (_) => _verifyCode(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _verifyCode,
                        icon: _busy
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: cs.onPrimary),
                              )
                            : const Icon(Icons.verified_outlined),
                        label:
                            Text(_busy ? 'Verifying\u2026' : 'Verify Code'),
                      ),
                    ),
                  ],

                  if (_hasMasterKey) ...[
                    TextField(
                      controller: _newPasswordCtrl,
                      obscureText: !_newPasswordVisible,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'New master password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_newPasswordVisible
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () => setState(
                              () => _newPasswordVisible = !_newPasswordVisible),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    (() {
                      final strength = _passwordStrength(_newPasswordCtrl.text);
                      return Column(
                        children: [
                          LinearProgressIndicator(
                            value: strength.score / 4,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              strength.label,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      );
                    })(),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirmCtrl,
                      obscureText: !_confirmVisible,
                      decoration: InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(_confirmVisible
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () => setState(
                              () => _confirmVisible = !_confirmVisible),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _resetPassword,
                        icon: _busy
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: cs.onPrimary),
                              )
                            : const Icon(Icons.lock_reset),
                        label: Text(
                            _busy ? 'Resetting\u2026' : 'Reset Password'),
                      ),
                    ),
                  ],

                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                size: 18, color: cs.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                    color: cs.error,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 24),
                  TextButton.icon(
                    onPressed: _busy ? null : _backToLogin,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('Back to login'),
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

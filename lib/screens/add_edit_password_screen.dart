import 'dart:math';

import 'package:flutter/material.dart';

import '../models/password_entry.dart';
import '../services/password_vault_service.dart';

class AddEditPasswordScreen extends StatefulWidget {
  const AddEditPasswordScreen({
    super.key,
    required this.entry,
    required this.service,
  });

  final PasswordEntry entry;
  final PasswordVaultService service;

  @override
  State<AddEditPasswordScreen> createState() => _AddEditPasswordScreenState();
}

class _AddEditPasswordScreenState extends State<AddEditPasswordScreen> {
  late final TextEditingController _serviceCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _confirmCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tagsCtrl;

  bool _passwordVisible = false;
  bool _confirmVisible = false;
  String? _error;
  final _chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*()-_=+';

  @override
  void initState() {
    super.initState();
    _serviceCtrl = TextEditingController(text: widget.entry.serviceName);
    _usernameCtrl = TextEditingController(text: widget.entry.username);
    _passwordCtrl = TextEditingController(text: widget.entry.password);
    _confirmCtrl = TextEditingController(text: widget.entry.password);
    _notesCtrl = TextEditingController(text: widget.entry.notes);
    _urlCtrl = TextEditingController(text: widget.entry.url);
    _tagsCtrl = TextEditingController(text: widget.entry.tags.join(', '));
  }

  @override
  void dispose() {
    _serviceCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _notesCtrl.dispose();
    _urlCtrl.dispose();
    _tagsCtrl.dispose();
    super.dispose();
  }

  double get _strength {
    final p = _passwordCtrl.text;
    if (p.isEmpty) return 0;
    var score = 0;
    if (p.length >= 8) score += 20;
    if (p.length >= 12) score += 15;
    if (p.length >= 16) score += 10;
    if (RegExp(r'[a-z]').hasMatch(p)) score += 10;
    if (RegExp(r'[A-Z]').hasMatch(p)) score += 10;
    if (RegExp(r'[0-9]').hasMatch(p)) score += 10;
    if (RegExp(r'[!@#%^&*()\-_=+\[\]{}|;:,.<>?/~`]').hasMatch(p)) score += 15;
    if (RegExp(r'^.{16,}$').hasMatch(p) &&
        RegExp(r'[a-z]').hasMatch(p) &&
        RegExp(r'[A-Z]').hasMatch(p) &&
        RegExp(r'[0-9]').hasMatch(p) &&
        RegExp(r'[!@#%^&*()\-_=+\[\]{}|;:,.<>?/~`]').hasMatch(p)) {
      score += 10;
    }
    return (score / 100).clamp(0, 1);
  }

  Color _strengthColor(double s) {
    if (s < 0.3) return Colors.red;
    if (s < 0.6) return Colors.orange;
    if (s < 0.8) return Colors.yellow.shade700;
    return Colors.green;
  }

  String _strengthLabel(double s) {
    if (s < 0.3) return 'Weak';
    if (s < 0.6) return 'Fair';
    if (s < 0.8) return 'Strong';
    return 'Very Strong';
  }

  void _generatePassword() {
    final rng = Random.secure();
    final length = 20 + rng.nextInt(12);
    final password = List.generate(length, (_) => _chars[rng.nextInt(_chars.length)]).join();
    // Ensure at least one of each type
    final guaranteed = [
      'a', 'Z', '5', '!',
    ];
    final mixed = [password.substring(0, password.length - guaranteed.length), ...guaranteed].join();
    final shuffled = String.fromCharCodes(mixed.runes.toList()..shuffle(rng));
    _passwordCtrl.text = shuffled;
    _confirmCtrl.text = shuffled;
    setState(() {});
  }

  void _save() {
    final name = _serviceCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Service/App name is required');
      return;
    }
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Password is required');
      return;
    }
    if (_passwordCtrl.text != _confirmCtrl.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    final tags = _tagsCtrl.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    final now = DateTime.now();
    final entry = widget.entry.copyWith(
      serviceName: name,
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      notes: _notesCtrl.text.trim(),
      url: _urlCtrl.text.trim(),
      tags: tags,
      updatedAt: now,
      lastUsedAt: now,
    );

    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNew = widget.entry.serviceName.isEmpty;
    final strength = _strength;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(isNew ? 'Add Password' : 'Edit Password'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Error banner ─────────────────────────────────────────────
            if (_error != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
                  ],
                ),
              ),

            // ── Service / App Name ───────────────────────────────────────
            TextField(
              controller: _serviceCtrl,
              decoration: const InputDecoration(
                labelText: 'Service / App Name *',
                hintText: 'e.g. Google, GitHub, Netflix',
                prefixIcon: Icon(Icons.web),
              ),
              textCapitalization: TextCapitalization.words,
              autofocus: isNew,
            ),
            const SizedBox(height: 12),

            // ── Username or Email ────────────────────────────────────────
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: 'Username or Email',
                hintText: 'user@example.com',
                prefixIcon: Icon(Icons.person),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),

            // ── Password ─────────────────────────────────────────────────
            TextField(
              controller: _passwordCtrl,
              obscureText: !_passwordVisible,
              decoration: InputDecoration(
                labelText: 'Password *',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(_passwordVisible ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
                      tooltip: _passwordVisible ? 'Hide' : 'Reveal',
                    ),
                    IconButton(
                      icon: const Icon(Icons.shuffle, color: Colors.blue),
                      onPressed: _generatePassword,
                      tooltip: 'Generate strong password',
                    ),
                  ],
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),

            // ── Password strength meter ──────────────────────────────────
            if (_passwordCtrl.text.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: strength,
                      backgroundColor: cs.surfaceContainerHighest,
                      color: _strengthColor(strength),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _strengthLabel(strength),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _strengthColor(strength),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),

            // ── Confirm Password ─────────────────────────────────────────
            TextField(
              controller: _confirmCtrl,
              obscureText: !_confirmVisible,
              decoration: InputDecoration(
                labelText: 'Confirm Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_confirmVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _confirmVisible = !_confirmVisible),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── URL ──────────────────────────────────────────────────────
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'URL (optional)',
                hintText: 'https://example.com',
                prefixIcon: Icon(Icons.link),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),

            // ── Tags ─────────────────────────────────────────────────────
            TextField(
              controller: _tagsCtrl,
              decoration: const InputDecoration(
                labelText: 'Tags (optional, comma-separated)',
                hintText: 'e.g. work, social, banking',
                prefixIcon: Icon(Icons.label),
              ),
            ),
            const SizedBox(height: 12),

            // ── Secure Notes / Diary ─────────────────────────────────────
            TextField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Secure Notes / Diary',
                hintText: 'Any additional notes, recovery codes, or diary entries\u2026',
                prefixIcon: Icon(Icons.edit_note),
                alignLabelWithHint: true,
              ),
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 24),

            // ── Save button ──────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.lock),
                label: const Text('Save Password'),
              ),
            ),
            const SizedBox(height: 16),

            // ── Security note ────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield, size: 16, color: cs.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Encrypted with AES-256-GCM before storage. Password auto-clears from clipboard after 30s.',
                      style: TextStyle(fontSize: 12, color: cs.onTertiaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

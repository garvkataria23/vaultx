import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import '../services/format_utils.dart';
import '../services/services.dart';
import 'restore_screen.dart';
import 'storage_insights_screen.dart';
import '../widgets/provider_card.dart';

/// Centralized "Backup & Restore" management screen.
///
/// Features:
/// - Dedicated cards for Google Drive and MEGA
/// - Independent status tracking and controls
/// - Local export/import fallback
/// - Deferred authentication
class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    required this.masterKey,
    required this.kind,
    required this.authService,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService authService;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final BackupManager _manager;
  BackupService? _backupService;
  List<BackupVersion> _versions = [];
  String? _error;
  bool _optimizeMedia = true;
  bool _useArchiveBackup = true;

  // MEGA login state
  final _megaEmailCtrl = TextEditingController();
  final _megaPasswordCtrl = TextEditingController();
  bool _megaPasswordVisible = false;
  bool _megaLoggingIn = false;
  String? _megaError;

  @override
  void initState() {
    super.initState();
    _manager = BackupManager(
      masterKey: widget.masterKey,
      kind: widget.kind,
      authService: widget.authService,
    );
    _backupService = BackupService(
      masterKey: widget.masterKey,
      kind: widget.kind,
      authService: widget.authService,
    );
    _optimizeMedia = Hive.box('vaultx_settings').get('optimizeMedia', defaultValue: true) as bool;
    _useArchiveBackup = Hive.box('vaultx_settings').get('useArchiveBackup', defaultValue: true) as bool;
    _init();
  }

  Future<void> _init() async {
    await _manager.init();
    await _manager.refreshAllStorageInfo();
    if (mounted) {
      _recoverStaleLock();
      setState(() {});
      _refreshVersions();
    }
  }

  Future<void> _recoverStaleLock() async {
    final state = BackupState.load();
    if (state.isInProgress) {
      final bool isStale;
      if (state.lastBackupAt != null) {
        isStale = DateTime.now().toUtc().difference(state.lastBackupAt!) > const Duration(hours: 2);
      } else {
        isStale = true;
      }
      if (isStale) {
        debugPrint('BACKUP SCREEN: STALE LOCK RECOVERED on startup');
        await BackupState.save(const BackupState());
      }
    }
  }

  @override
  void dispose() {
    _megaEmailCtrl.dispose();
    _megaPasswordCtrl.dispose();
    _manager.dispose();
    super.dispose();
  }

  Future<void> _refreshVersions() async {
    final allVersions = <BackupVersion>[];
    for (final type in [CloudProvider.googleDrive, CloudProvider.mega]) {
      final provider = _manager.getProvider(type);
      if (provider != null && _manager.isProviderConnected(type)) {
        try {
          final versions = await provider.listBackups();
          allVersions.addAll(versions);
        } catch (_) {}
      }
    }
    allVersions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (mounted) setState(() => _versions = allVersions);
  }

  // ── Action Handlers ──────────────────────────────────────────────────

  Future<bool> _authenticateProvider(CloudProvider type) async {
    if (type == CloudProvider.mega) {
      return await _showMegaLoginDialog() ?? false;
    }

    setState(() => _error = null);
    try {
      final ok = await _manager.signIn(type);
      if (!ok && mounted) {
        setState(() => _error = 'Failed to connect to ${type.displayName}');
      }
      return ok;
    } catch (e) {
      if (mounted) setState(() => _error = 'Connection failed: $e');
      return false;
    }
  }

  Future<void> _doBackup(CloudProvider type) async {
    if (mounted) setState(() { _error = null; });

    final ok = await _manager.backupToProvider(
      type,
      verificationService: _backupService,
      compressMedia: _optimizeMedia,
      useArchive: _useArchiveBackup,
    );

    if (mounted) {
      if (ok) {
        FloatingNotificationService.instance.show(
          'Backup to ${type.displayName} completed',
          type: AppNotificationType.success,
        );
      } else {
        final providerError = _manager.getState(type).error;
        FloatingNotificationService.instance.show(
          providerError?.isNotEmpty == true ? providerError! : 'UPLOAD FAILED',
          type: AppNotificationType.error,
        );
      }
      await _refreshVersions();
      await _manager.refreshAllStorageInfo();
    }
  }

  Future<void> _handleRestoreTapForProvider(CloudProvider type) async {
    // 1. Authenticate if needed
    if (!_manager.isProviderConnected(type)) {
      final ok = await _authenticateProvider(type);
      if (!ok) return;
    }

    // 2. Open Restore Screen
    final provider = _manager.getProvider(type);
    if (provider == null) return;

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RestoreScreen(
          authService: widget.authService,
          driveService: provider,
          masterKey: widget.masterKey,
          kind: widget.kind,
        ),
      ),
    );
    
    await _refreshVersions();
    await _manager.refreshAllStorageInfo();
  }

  // ── UI Components ────────────────────────────────────────────────────

  Future<bool?> _showMegaLoginDialog() {
    _megaEmailCtrl.clear();
    _megaPasswordCtrl.clear();
    _megaError = null;

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
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                      final ok = await _manager.megaLoginWithCredentials(email, password);
                      if (ctx.mounted) Navigator.pop(ctx, ok);
                    } catch (e) {
                      setDialogState(() => _megaError = e.toString());
                    } finally {
                      setDialogState(() => _megaLoggingIn = false);
                    }
                  },
                  child: Text(_megaLoggingIn ? 'Connecting...' : 'Connect with Password'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Overview Section ──────────────────────────────────────────
          Text(
            'Cloud Providers',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: cs.primary,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Encrypted backups are stored in your private cloud storage. VaultX never has access to your plaintext data.',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),

          // ── Provider Cards ────────────────────────────────────────────
          ProviderCard(
            manager: _manager,
            provider: CloudProvider.googleDrive,
            onSignIn: () => _authenticateProvider(CloudProvider.googleDrive),
            onBackup: () => _doBackup(CloudProvider.googleDrive),
            onRestore: () => _handleRestoreTapForProvider(CloudProvider.googleDrive),
          ),
          const SizedBox(height: 16),
          ProviderCard(
            manager: _manager,
            provider: CloudProvider.mega,
            onSignIn: () => _authenticateProvider(CloudProvider.mega),
            onBackup: () => _doBackup(CloudProvider.mega),
            onRestore: () => _handleRestoreTapForProvider(CloudProvider.mega),
          ),

          const SizedBox(height: 32),

          // ── Global Actions ────────────────────────────────────────────
          Text(
            'Tools & Optimization',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                _SettingsTile(
                  icon: Icons.auto_fix_high,
                  title: 'Smart Optimization',
                  subtitle: 'Compress media before backup',
                  value: _optimizeMedia,
                  onChanged: (v) {
                    setState(() => _optimizeMedia = v);
                    Hive.box('vaultx_settings').put('optimizeMedia', v);
                  },
                ),
                const Divider(height: 1),
                _SettingsTile(
                  icon: Icons.folder_zip_outlined,
                  title: 'Compressed Backup',
                  subtitle: 'Faster uploads and restores',
                  value: _useArchiveBackup,
                  onChanged: (v) {
                    setState(() => _useArchiveBackup = v);
                    Hive.box('vaultx_settings').put('useArchiveBackup', v);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.insights, size: 20),
                  title: const Text('Storage Insights', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Analyze and optimize vault size', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StorageInsightsScreen(
                    masterKey: widget.masterKey,
                    kind: widget.kind,
                    authService: widget.authService,
                  ))),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
            ),

          const SizedBox(height: 20),

          // ── Backup History ───────────────────────────────────────────
          if (_versions.isNotEmpty) ...[
            Text('Backup History', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _versions.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final v = _versions[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.restore_page, size: 20),
                    title: Text(v.label, style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${v.provider.displayName} · ${formatBytes(v.totalSizeBytes)}', style: const TextStyle(fontSize: 11)),
                  );
                },
              ),
            ),
          ],
          
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }
}



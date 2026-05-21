import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import '../services/format_utils.dart';
import '../services/services.dart';
import 'restore_screen.dart';
import 'storage_insights_screen.dart';
import '../widgets/provider_card.dart';
import '../widgets/import_widgets.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({
    super.key,
    required this.masterKey,
    required this.kind,
    required this.authService,
    required this.repo,
    this.onDataChanged,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService authService;
  final VaultRepository? repo;
  final Future<void> Function()? onDataChanged;

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  late final BackupManager _manager;
  BackupService? _backupService;
  List<BackupVersion> _versions = [];
  
  // Settings
  bool _autoBackup = false;
  bool _optimizeMedia = true;
  bool _useArchiveBackup = true;
  bool _wifiOnly = false;
  String _backupInterval = 'weekly';
  
  // Include options
  bool _includeNotes = true;
  bool _includeHidden = true;
  bool _includeDrive = true;
  bool _includeMedia = true;

  // MEGA login state
  final _megaEmailCtrl = TextEditingController();
  final _megaPasswordCtrl = TextEditingController();
  bool _megaPasswordVisible = false;
  bool _megaLoggingIn = false;
  String? _megaError;

  bool _importingZip = false;

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
    _loadSettings();
    _init();
  }

  void _loadSettings() {
    final box = Hive.box('vaultx_settings');
    setState(() {
      _autoBackup = box.get('autoBackup', defaultValue: false) as bool;
      _optimizeMedia = box.get('optimizeMedia', defaultValue: true) as bool;
      _useArchiveBackup = box.get('useArchiveBackup', defaultValue: true) as bool;
      _wifiOnly = box.get('backupWifiOnly', defaultValue: false) as bool;
      _backupInterval = box.get('backupInterval', defaultValue: 'weekly') as String;
      
      _includeNotes = box.get('backupIncludeNotes', defaultValue: true) as bool;
      _includeHidden = box.get('backupIncludeHidden', defaultValue: true) as bool;
      _includeDrive = box.get('backupIncludeDrive', defaultValue: true) as bool;
      _includeMedia = box.get('backupIncludeMedia', defaultValue: true) as bool;
    });
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

    try {
      final ok = await _manager.signIn(type);
      if (!ok && mounted) {
        FloatingNotificationService.instance.show('Failed to connect to ${type.displayName}', error: true);
      }
      return ok;
    } catch (e) {
      if (mounted) FloatingNotificationService.instance.show('Connection failed: $e', error: true);
      return false;
    }
  }

  Future<void> _disconnectProvider(CloudProvider type) async {
    try {
      await _manager.signOut(type);
      if (mounted) {
        FloatingNotificationService.instance.show('${type.displayName} disconnected');
      }
      await _refreshVersions();
      await _manager.refreshAllStorageInfo();
    } catch (e) {
      if (mounted) {
        FloatingNotificationService.instance.show('Disconnect failed: $e', error: true);
      }
    }
  }

  Future<void> _doBackup(CloudProvider type) async {
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
    final restored = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (_) => RestoreScreen(
          authService: widget.authService,
          driveService: provider,
          masterKey: widget.masterKey,
          kind: widget.kind,
        ),
      ),
    );
    
    if (restored != null) {
      debugPrint('BACKUP_SCREEN: Cloud restore successful, triggering UI refresh');
      if (widget.onDataChanged != null) await widget.onDataChanged!();
    }
    
    await _refreshVersions();
    await _manager.refreshAllStorageInfo();
  }

  // ── ZIP Export/Import ───────────────────────────────────────────────

  Future<void> _importBulkNotesZip() async {
    if (_importingZip) return;

    // Authentication is handled by parent screen or we can add it here if needed
    // But since we are already inside Backup & Restore which required auth to enter, it's safer.
    
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (picked == null || picked.files.isEmpty) {
      SecurityPlatform.setSensitiveOperationActive(false);
      return;
    }

    SecurityPlatform.setSensitiveOperationActive(true);
    if (!mounted) return;

    setState(() => _importingZip = true);
    
    final importService = NoteImportService(
      widget.repo, 
      isDecoy: widget.kind == VaultKind.decoy,
    );

    final progressValue = ValueNotifier<(ImportStage, double, String, int?, int?)>(
      (ImportStage.preparing, 0.0, 'Starting...', null, null),
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<(ImportStage, double, String, int?, int?)>(
        valueListenable: progressValue,
        builder: (ctx, val, _) => NoteImportProgressDialog(
          stage: val.$1,
          progress: val.$2,
          message: val.$3,
          current: val.$4,
          total: val.$5,
        ),
      ),
    );

    try {
      final stats = await importService.importZip(
        picked: picked,
        onProgress: (stage, progress, message, {current, total}) {
          progressValue.value = (stage, progress, message, current, total);
        },
      );

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // Close progress dialog
        
        if (stats.totalNotes > 0) {
          if (widget.onDataChanged != null) await widget.onDataChanged!();
          
          if (!mounted) return;
          await showDialog<String>(
            context: context,
            builder: (_) => ImportSuccessDialog(stats: stats),
          );
        } else {
          FloatingNotificationService.instance.show('No notes imported. Check if ZIP contains supported files.', error: true);
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        FloatingNotificationService.instance.show('Import failed: $e', error: true);
      }
    } finally {
      SecurityPlatform.setSensitiveOperationActive(false);
      progressValue.dispose();
      if (mounted) {
        setState(() => _importingZip = false);
      }
    }
  }

  Future<void> _exportVaultZip() async {
    if (widget.repo == null) return;

    // 1. Require Biometric or Password
    final authenticated = await _authenticateForExport();
    if (!authenticated) return;

    // 2. Show security warning (Required for decrypted export)
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 10),
            Text('Security Warning'),
          ],
        ),
        content: const Text(
          'This export will contain FULLY DECRYPTED and READABLE data (including images and videos) to allow for easy phone transfer.\n\n'
          'Anyone with access to this ZIP file will be able to see your private notes and files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I Understand, Export'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    SecurityPlatform.setSensitiveOperationActive(true);
    FloatingNotificationService.instance.show('Preparing decrypted export ZIP...');

    try {
      final result = await NoteExportService.instance.exportVaultZip(
        masterKey: widget.masterKey,
        kind: widget.kind,
        authService: widget.authService,
      );

      if (result.success) {
        await NoteExportService.instance.shareExport(result.path);
        FloatingNotificationService.instance.show('Vault exported');
      } else {
        FloatingNotificationService.instance.show('Export failed: ${result.error}', error: true);
      }
    } catch (e) {
      FloatingNotificationService.instance.show('Export error: $e', error: true);
    } finally {
      SecurityPlatform.setSensitiveOperationActive(false);
    }
  }

  Future<bool> _authenticateForExport() async {
    // Attempt Biometric first
    final bioAvailable = await widget.authService.isBiometricUnlockAvailable();
    if (bioAvailable) {
      final ok = await widget.authService.authenticateBiometric();
      if (ok) return true;
    }

    if (!mounted) return false;

    // Fallback to password dialog
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Vault Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter your vault password to authorize this export.', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Vault Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (password == null || password.isEmpty) return false;

    final result = await widget.authService.unlockWithPassword(password);
    final verified = await widget.authService.verify(result);

    if (!verified.ok && mounted) {
      FloatingNotificationService.instance.show('Invalid password', error: true);
    }
    
    return verified.ok;
  }

  // ── UI Components ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final backupState = BackupState.load();
    final backupInProgress = backupState.isInProgress;
    
    final inProgress = backupInProgress || 
        _manager.getState(CloudProvider.googleDrive).uploading ||
        _manager.getState(CloudProvider.mega).uploading ||
        _importingZip ||
        _megaLoggingIn;

    return PopScope(
      canPop: !inProgress,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (inProgress) {
          FloatingNotificationService.instance.show('Please wait for the operation to complete.');
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Backup & Restore')),
        body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Backup Status Card ─────────────────────────────────────────
          _buildStatusCard(cs, backupState, backupInProgress),
          const SizedBox(height: 24),

          // ── Cloud Providers ────────────────────────────────────────────
          _buildSectionHeader(cs, 'Cloud Storage'),
          const SizedBox(height: 12),
          ProviderCard(
            manager: _manager,
            provider: CloudProvider.googleDrive,
            onSignIn: () => _authenticateProvider(CloudProvider.googleDrive),
            onBackup: () => _doBackup(CloudProvider.googleDrive),
            onRestore: () => _handleRestoreTapForProvider(CloudProvider.googleDrive),
            onDisconnect: () => _disconnectProvider(CloudProvider.googleDrive),
          ),
          const SizedBox(height: 12),
          ProviderCard(
            manager: _manager,
            provider: CloudProvider.mega,
            onSignIn: () => _authenticateProvider(CloudProvider.mega),
            onBackup: () => _doBackup(CloudProvider.mega),
            onRestore: () => _handleRestoreTapForProvider(CloudProvider.mega),
            onDisconnect: () => _disconnectProvider(CloudProvider.mega),
          ),
          const SizedBox(height: 24),

          // ── ZIP Management ─────────────────────────────────────────────
          _buildSectionHeader(cs, 'Local Import / Export'),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('Export Vault to ZIP'),
                  subtitle: const Text('Fully decrypted for easy phone transfer'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _exportVaultZip,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.unarchive_outlined),
                  title: const Text('Import Notes from ZIP'),
                  subtitle: const Text('Restore from a previously exported ZIP'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _importBulkNotesZip,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Backup Settings ────────────────────────────────────────────
          _buildSectionHeader(cs, 'Backup Settings'),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  value: _autoBackup,
                  onChanged: (v) async {
                    setState(() => _autoBackup = v);
                    await Hive.box('vaultx_settings').put('autoBackup', v);
                  },
                  secondary: const Icon(Icons.sync),
                  title: const Text('Automatic Backups'),
                  subtitle: const Text('Periodically sync to connected clouds'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Backup Interval'),
                  subtitle: Text(_backupInterval.toUpperCase()),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showIntervalPicker,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _wifiOnly,
                  onChanged: (v) async {
                    setState(() => _wifiOnly = v);
                    await Hive.box('vaultx_settings').put('backupWifiOnly', v);
                  },
                  secondary: const Icon(Icons.wifi),
                  title: const Text('WiFi Only'),
                  subtitle: const Text('Only backup when connected to WiFi'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _optimizeMedia,
                  onChanged: (v) {
                    setState(() => _optimizeMedia = v);
                    Hive.box('vaultx_settings').put('optimizeMedia', v);
                  },
                  secondary: const Icon(Icons.auto_fix_high),
                  title: const Text('Smart Optimization'),
                  subtitle: const Text('Compress media before backup'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Include Options ─────────────────────────────────────────────
          _buildSectionHeader(cs, 'Include in Backup'),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                _buildIncludeTile(Icons.description_outlined, 'Notes', _includeNotes, (v) {
                  setState(() => _includeNotes = v);
                  Hive.box('vaultx_settings').put('backupIncludeNotes', v);
                }),
                _buildIncludeTile(Icons.visibility_off_outlined, 'Hidden Vault', _includeHidden, (v) {
                  setState(() => _includeHidden = v);
                  Hive.box('vaultx_settings').put('backupIncludeHidden', v);
                }),
                _buildIncludeTile(Icons.folder_outlined, 'Drive Files', _includeDrive, (v) {
                  setState(() => _includeDrive = v);
                  Hive.box('vaultx_settings').put('backupIncludeDrive', v);
                }),
                _buildIncludeTile(Icons.image_outlined, 'Media (Images/Videos)', _includeMedia, (v) {
                  setState(() => _includeMedia = v);
                  Hive.box('vaultx_settings').put('backupIncludeMedia', v);
                }),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Storage Insights ───────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.insights),
            title: const Text('Storage Insights'),
            subtitle: const Text('Analyze and optimize vault size'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StorageInsightsScreen(
              masterKey: widget.masterKey,
              kind: widget.kind,
              authService: widget.authService,
            ))),
          ),
          const SizedBox(height: 24),

          // ── History ───────────────────────────────────────────────────
          if (_versions.isNotEmpty) ...[
            _buildSectionHeader(cs, 'Backup History'),
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
                    leading: const Icon(Icons.restore_page_outlined, size: 20),
                    title: Text(v.label, style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${v.provider.displayName} · ${formatBytes(v.totalSizeBytes)}', style: const TextStyle(fontSize: 11)),
                  );
                },
              ),
            ),
          ],

          const SizedBox(height: 120),
        ],
      ),
    ));
  }

  Widget _buildSectionHeader(ColorScheme cs, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: cs.primary,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildIncludeTile(IconData icon, String title, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      value: value,
      onChanged: (v) => onChanged(v ?? true),
      secondary: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      dense: true,
    );
  }

  String _relativeTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min${diff.inMinutes == 1 ? '' : 's'} ago';
    if (diff.inHours < 24) return '${diff.inHours} hr${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays < 2) return 'Yesterday';
    if (diff.inDays < 30) return '${diff.inDays} days ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()} months ago';
    return '${(diff.inDays / 365).floor()} years ago';
  }

  Widget _buildStatusCard(ColorScheme cs, BackupState state, bool inProgress) {
    final status = state.lastBackupStatus;
    final statusColor = inProgress
        ? cs.tertiary
        : status == 'synced'
            ? Colors.green
            : status == 'failed'
                ? Colors.red
                : cs.onSurfaceVariant;
    final statusIcon = inProgress
        ? Icons.sync
        : status == 'synced'
            ? Icons.cloud_done
            : status == 'failed'
                ? Icons.cloud_off
                : Icons.cloud_outlined;
    final statusLabel = inProgress
        ? 'Syncing'
        : status == 'synced'
            ? 'Synced'
            : status == 'failed'
                ? 'Failed'
                : 'Never Backed Up';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: inProgress
              ? cs.primary.withValues(alpha: 0.3)
              : cs.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: inProgress
          ? cs.primaryContainer.withValues(alpha: 0.2)
          : cs.surfaceContainerHighest.withValues(alpha: 0.2),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status row
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        state.lastBackupAt == null
                            ? 'No backups found yet'
                            : 'Last: ${_relativeTime(state.lastBackupAt)}',
                        style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Details
            if (state.lastBackupAt != null) ...[
              const SizedBox(height: 20),
              Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
              const SizedBox(height: 16),
              _statusRow(cs, 'Last Backup', _relativeTime(state.lastBackupAt)),
              const SizedBox(height: 8),
              _statusRow(cs, 'Last Sync', _relativeTime(state.lastSyncAt)),
              const SizedBox(height: 8),
              _statusRow(cs, 'Backup Size', formatBytes(state.lastBackupSizeBytes)),
              const SizedBox(height: 8),
              _statusRow(cs, 'Files Backed Up', '${state.lastBackupFileCount} items'),
              const SizedBox(height: 8),
              _statusRow(cs, 'Provider', state.lastBackupProvider ?? '—'),
              const SizedBox(height: 8),
              _statusRow(cs, 'Auto Backup', _autoBackup ? 'ON' : 'OFF'),
              const SizedBox(height: 8),
              _statusRow(cs, 'Backup Folder', 'VaultX_Backups'),
            ],
            if (inProgress) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(
                backgroundColor: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
            ],
            // View Details button
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _showBackupDetails(state),
                icon: const Icon(Icons.info_outline, size: 18),
                label: const Text('View Backup Details'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(ColorScheme cs, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  void _showBackupDetails(BackupState state) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Backup Details', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.onSurface)),
                const SizedBox(height: 24),
                _detailRow(cs, 'Last Backup Provider', state.lastBackupProvider ?? '—'),
                const SizedBox(height: 12),
                _detailRow(cs, 'Last Backup', state.lastBackupAt != null
                    ? DateFormat('MMM d, yyyy • h:mm a').format(state.lastBackupAt!.toLocal())
                    : 'Never'),
                const SizedBox(height: 12),
                _detailRow(cs, 'Last Sync', state.lastSyncAt != null
                    ? DateFormat('MMM d, yyyy • h:mm a').format(state.lastSyncAt!.toLocal())
                    : 'Never'),
                const SizedBox(height: 12),
                _detailRow(cs, 'Backup Size', formatBytes(state.lastBackupSizeBytes)),
                const SizedBox(height: 12),
                _detailRow(cs, 'Items Backed Up', '${state.lastBackupFileCount} items'),
                const SizedBox(height: 12),
                _detailRow(cs, 'Verification Status', state.lastSyncAt != null ? 'Verified' : 'Not verified'),
                const SizedBox(height: 12),
                _detailRow(cs, 'Cloud Folder', 'VaultX_Backups'),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(ColorScheme cs, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Future<void> _showIntervalPicker() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Backup Interval', style: TextStyle(fontWeight: FontWeight.bold))),
            ListTile(
              title: const Text('Daily'),
              leading: Radio<String>(value: 'daily', groupValue: _backupInterval, onChanged: (v) => Navigator.pop(ctx, v)),
              onTap: () => Navigator.pop(ctx, 'daily'),
            ),
            ListTile(
              title: const Text('Weekly'),
              leading: Radio<String>(value: 'weekly', groupValue: _backupInterval, onChanged: (v) => Navigator.pop(ctx, v)),
              onTap: () => Navigator.pop(ctx, 'weekly'),
            ),
            ListTile(
              title: const Text('Manual Only'),
              leading: Radio<String>(value: 'manual', groupValue: _backupInterval, onChanged: (v) => Navigator.pop(ctx, v)),
              onTap: () => Navigator.pop(ctx, 'manual'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      setState(() => _backupInterval = result);
      await Hive.box('vaultx_settings').put('backupInterval', result);
    }
  }

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
}

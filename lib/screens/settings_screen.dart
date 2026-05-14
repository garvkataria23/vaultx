import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../services/secure_delete_service.dart';
import '../theme/custom_theme_creator_screen.dart';
import '../theme/theme_picker.dart';
import '../widgets/widgets.dart';
import 'backup_screen.dart';
import 'privacy_policy_screen.dart';
import 'restore_screen.dart';
import 'security_logs_screen.dart';
import 'setup_screen.dart';

// Import your floating notification service

// ─────────────────────────────────────────────────────────────────────────────
// Dead Man Switch guard
// ─────────────────────────────────────────────────────────────────────────────
class DeadManSwitchGuard {
  static Future<bool> checkOnLaunch({
    required VaultAuthService auth,
    bool isAuthenticated = false,
    VaultRepository? repo,
  }) async {
    final result = await DeadMansService.checkOnLaunch(
      auth: auth,
      isAuthenticated: isAuthenticated,
      repo: repo,
    );
    await Hive.box(
      'vaultx_settings',
    ).put('lastOpenedAt', DateTime.now().toIso8601String());
    return result == DmsCheckResult.wiped;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Time-based access guard
// ─────────────────────────────────────────────────────────────────────────────
class TimeAccessGuard {
  static bool canOpenNow() {
    final box = Hive.box('vaultx_settings');
    final enabled = box.get('timeAccess', defaultValue: false) as bool;
    if (!enabled) return true;
    final startH = box.get('timeAccessStartHour', defaultValue: 8) as int;
    final startM = box.get('timeAccessStartMin', defaultValue: 0) as int;
    final endH = box.get('timeAccessEndHour', defaultValue: 22) as int;
    final endM = box.get('timeAccessEndMin', defaultValue: 0) as int;
    final now = TimeOfDay.now();
    final nowMins = now.hour * 60 + now.minute;
    final startMins = startH * 60 + startM;
    final endMins = endH * 60 + endM;
    if (startMins <= endMins) {
      return nowMins >= startMins && nowMins <= endMins;
    } else {
      return nowMins >= startMins || nowMins <= endMins;
    }
  }

  static String windowLabel() {
    final box = Hive.box('vaultx_settings');
    final sh = box.get('timeAccessStartHour', defaultValue: 8) as int;
    final sm = box.get('timeAccessStartMin', defaultValue: 0) as int;
    final eh = box.get('timeAccessEndHour', defaultValue: 22) as int;
    final em = box.get('timeAccessEndMin', defaultValue: 0) as int;
    String p(int h, int m) =>
        '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    return '${p(sh, sm)} – ${p(eh, em)}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings / Security Center screen
// ─────────────────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.repo,
    required this.posture,
    required this.onDataChanged,
    this.vaultKind,
    this.onSwitchVault,
  });
  final VaultAuthService auth;
  final VaultRepository? repo;
  final Map<String, dynamic> posture;
  final Future<void> Function() onDataChanged;
  final VaultKind? vaultKind;
  final void Function(VaultKind)? onSwitchVault;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with AutomaticKeepAliveClientMixin {
  // Hidden vault password controllers
  final _hiddenPasswordCtrl = TextEditingController();
  final _hiddenPasswordConfirmCtrl = TextEditingController();
  bool _hiddenPasswordVisible = false;
  bool _hiddenPasswordConfirmVisible = false;

  // Decoy password controllers
  final _decoyPasswordCtrl = TextEditingController();
  final _decoyPasswordConfirmCtrl = TextEditingController();
  bool _decoyPasswordVisible = false;
  bool _decoyPasswordConfirmVisible = false;

  // Biometric state
  bool _biometricEnabled = false;
  bool _biometricHardwareAvailable = false;
  bool _biometricEnrolled = false;
  String _biometricTypeLabel = 'Device Biometrics';

  // Settings state
  bool _deadMansSwitch = false;
  int _deadMansDays = 7;
  String _deadMansAction = 'wipe';
  final _deadMansEmailCtrl = TextEditingController();
  final _deadMansMessageCtrl = TextEditingController();
  bool _timeAccess = false;
  TimeOfDay _timeStart = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _timeEnd = const TimeOfDay(hour: 22, minute: 0);
  bool _intruderCaptureEnabled = false;
  int _intruderCaptureThreshold = 3;
  bool _autoBackup = false;
  bool _autoRestore = false;
  bool _backupNewNotesByDefault = true;
  bool _backupNewDriveFilesByDefault = true;
  String _failedAttemptNotifications = 'persistent';
  bool _decoyCalculatorEnabled = false;
  bool _decoyCalculatorHistory = true;
  String _decoyCalculatorTrigger = 'pin';
  final _decoyCalculatorSecretCtrl = TextEditingController();
  int _lockMinutes =
      Hive.box('vaultx_settings').get('lockMinutes', defaultValue: 1) as int;

  // Google Drive
  GoogleDriveBackupService? _gdriveBackup;
  bool _gdriveSigningIn = false;
  String? _googleEmail;

  // Enriched posture
  late final Map<String, String> _enrichedPosture;

  // ── Notification helper ──────────────────────────────────────────────────
  void _notify(String msg, {bool error = false}) {
    FloatingNotificationService.instance.show(
      msg,
      error: error,
      type: error ? AppNotificationType.error : AppNotificationType.success,
    );
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _enrichedPosture = _buildEnrichedPosture(widget.posture);
    _restoreGoogleSession();
    _loadSavedSettings();
    _loadBiometricStatus();
  }

  @override
  void dispose() {
    _hiddenPasswordCtrl.clear();
    _hiddenPasswordConfirmCtrl.clear();
    _decoyPasswordCtrl.clear();
    _decoyPasswordConfirmCtrl.clear();
    _hiddenPasswordCtrl.dispose();
    _hiddenPasswordConfirmCtrl.dispose();
    _decoyPasswordCtrl.dispose();
    _decoyPasswordConfirmCtrl.dispose();
    _deadMansEmailCtrl.dispose();
    _deadMansMessageCtrl.dispose();
    _decoyCalculatorSecretCtrl.dispose();
    super.dispose();
  }

  // ── Loaders ───────────────────────────────────────────────────────────────
  Future<void> _restoreGoogleSession() async {
    final service = _getGDriveService();
    if (service == null) return;
    final success = await service.signInSilently();
    if (success && mounted) {
      setState(() => _googleEmail = service.signedInEmail);
    }
  }

  void _loadSavedSettings() {
    final box = Hive.box('vaultx_settings');
    setState(() {
      _biometricEnabled =
          box.get('biometricEnabled', defaultValue: false) as bool;
      _deadMansSwitch = box.get('deadMansSwitch', defaultValue: false) as bool;
      _deadMansDays = box.get('deadMansDays', defaultValue: 7) as int;
      _deadMansAction =
          box.get('deadMansAction', defaultValue: 'wipe') as String;
      _deadMansEmailCtrl.text =
          box.get('deadMansEmail', defaultValue: '') as String;
      _deadMansMessageCtrl.text =
          box.get('deadMansMessage', defaultValue: '') as String;
      _timeAccess = box.get('timeAccess', defaultValue: false) as bool;
      _timeStart = TimeOfDay(
        hour: box.get('timeAccessStartHour', defaultValue: 8) as int,
        minute: box.get('timeAccessStartMin', defaultValue: 0) as int,
      );
      _timeEnd = TimeOfDay(
        hour: box.get('timeAccessEndHour', defaultValue: 22) as int,
        minute: box.get('timeAccessEndMin', defaultValue: 0) as int,
      );
      _intruderCaptureEnabled =
          box.get('intruderCaptureEnabled', defaultValue: false) as bool;
      _intruderCaptureThreshold =
          box.get('intruderCaptureThreshold', defaultValue: 3) as int;
      _autoBackup = box.get('autoBackup', defaultValue: false) as bool;
      _autoRestore = box.get('autoRestore', defaultValue: false) as bool;
      _failedAttemptNotifications =
          box.get('failedAttemptNotifications', defaultValue: 'persistent')
              as String;
      if (_failedAttemptNotifications == 'auto_disappear') {
        _failedAttemptNotifications = 'floating';
      }
      _decoyCalculatorEnabled =
          box.get('decoyCalculatorEnabled', defaultValue: false) as bool;
      _decoyCalculatorHistory =
          box.get('decoyCalculatorHistory', defaultValue: true) as bool;
      _decoyCalculatorTrigger =
          box.get('decoyCalculatorTrigger', defaultValue: 'pin') as String;
      _decoyCalculatorSecretCtrl.text =
          box.get('decoyCalculatorSecret', defaultValue: '0000') as String;
    });
  }

  // ── Posture enrichment ────────────────────────────────────────────────────
  static Map<String, String> _buildEnrichedPosture(Map<String, dynamic> raw) {
    final enriched = <String, String>{};
    if (raw.containsKey('platform')) {
      final platform = raw['platform'].toString();
      final match = RegExp(r'android-(\d+)').firstMatch(platform);
      if (match != null) {
        final sdk = int.tryParse(match.group(1) ?? '') ?? 0;
        enriched['Platform'] = 'Android ${_androidVersionName(sdk)} (API $sdk)';
      } else {
        enriched['Platform'] = platform;
      }
    }
    if (raw.containsKey('rooted')) {
      final v = raw['rooted'] == true || raw['rooted'] == 'true';
      enriched['Root access'] = v
          ? '⚠️ Detected — vault is at higher risk'
          : '✅ Not detected';
    }
    if (raw.containsKey('debuggable') && kDebugMode) {
      final v = raw['debuggable'] == true || raw['debuggable'] == 'true';
      enriched['Debug build'] = v ? '⚠️ Yes — debug build' : '✅ No';
    }
    const known = {'platform', 'rooted', 'debuggable'};
    for (final e in raw.entries) {
      if (known.contains(e.key)) continue;
      final label = e.key
          .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
          .trim();
      final title = label[0].toUpperCase() + label.substring(1);
      final val = e.value?.toString() ?? 'Unknown';
      enriched[title] = val == 'true'
          ? '✅ Yes'
          : val == 'false'
          ? '✅ No'
          : val;
    }
    return enriched;
  }

  static String _androidVersionName(int sdk) {
    const names = {
      35: '15',
      34: '14',
      33: '13',
      32: '12L',
      31: '12',
      30: '11',
      29: '10',
      28: '9 Pie',
      27: '8.1',
      26: '8.0',
    };
    return names[sdk] ?? 'Unknown';
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String? _validatePassword(String pass, String confirm, String fieldName) {
    if (pass.isEmpty) return '$fieldName cannot be empty';
    if (pass.length < 12) return '$fieldName must be at least 12 characters';
    if (pass != confirm) return 'Passwords do not match';
    return null;
  }

  String _formatTOD(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _deadMansDayLabel(int days) {
    switch (days) {
      case 30:
        return '1 month';
      case 180:
        return '6 months';
      case 365:
        return '1 year';
      case 730:
        return '2 years';
      case 1095:
        return '3 years';
      default:
        return '$days days';
    }
  }

  String get _deadMansActionLabel {
    switch (_deadMansAction) {
      case 'email_and_wipe':
        return 'Email & Wipe';
      default:
        return 'Wipe Only';
    }
  }

  // ── Google Drive service ──────────────────────────────────────────────────
  GoogleDriveBackupService? _getGDriveService() {
    if (widget.repo == null) return null;
    final currentKey = widget.repo!.masterKey;
    if (_gdriveBackup == null ||
        !_masterKeysEqual(_gdriveBackup!.masterKey, currentKey)) {
      _gdriveBackup = GoogleDriveBackupService(
        masterKey: currentKey,
        authService: widget.auth,
      );
    }
    return _gdriveBackup;
  }

  bool _masterKeysEqual(Uint8List? a, Uint8List b) {
    if (a == null || a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ── Google Drive actions ──────────────────────────────────────────────────
  Future<void> _autoBackupNow() async {
    if (widget.repo == null) return;
    final service = GoogleDriveBackupService(authService: widget.auth);
    final email = await service.restoreSession();
    if (email == null) return;
    final backupService = BackupService(
      masterKey: widget.repo!.masterKey,
      kind: widget.repo!.kind,
      authService: widget.auth,
    );
    try {
      final ok = await service.uploadBackup(({bool compressMedia = false}) async {
        final result = await backupService.createBackup(compressMedia: compressMedia);
        return result.data;
      }, verificationService: backupService);
      debugPrint(ok ? 'AUTO BACKUP: completed' : 'AUTO BACKUP: failed');
    } catch (e, st) {
      debugPrint('AUTO BACKUP ERROR: $e\n$st');
    }
  }

  Future<void> _signInGoogleDrive() async {
    setState(() => _gdriveSigningIn = true);
    final service = _getGDriveService();
    if (service == null) {
      setState(() => _gdriveSigningIn = false);
      _notify('Google Drive backup unavailable in decoy mode', error: true);
      return;
    }
    var success = await service.signInSilently();
    if (!success) success = await service.signIn();
    setState(() {
      _gdriveSigningIn = false;
      if (success) _googleEmail = service.signedInEmail;
    });
    _notify(
      success
          ? 'Signed in as ${service.signedInEmail}'
          : 'Google Sign-In failed. Check network and try again.',
      error: !success,
    );
  }

  Future<void> _signOutGoogleDrive() async {
    await _gdriveBackup?.signOut();
    setState(() {
      _gdriveBackup = null;
      _googleEmail = null;
    });
    _notify('Signed out from Google Drive');
  }

  void _openBackupScreen() {
    if (widget.repo == null) {
      _notify('Backup unavailable in decoy mode', error: true);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BackupScreen(
          masterKey: widget.repo!.masterKey,
          kind: widget.repo!.kind,
          authService: widget.auth,
        ),
      ),
    );
  }

  void _openRestoreScreen() {
    if (widget.repo == null) {
      _notify('Restore unavailable in decoy mode', error: true);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RestoreScreen(
          authService: widget.auth,
          driveService: GoogleDriveBackupService(
            masterKey: widget.repo!.masterKey,
            authService: widget.auth,
          ),
          masterKey: widget.repo!.masterKey,
          kind: widget.repo!.kind,
        ),
      ),
    );
  }

  // ── Local backup actions ──────────────────────────────────────────────────
  Future<void> _exportLocalBackup() async {
    final path = await widget.repo?.exportEncryptedBackup();
    await Hive.box(
      'vaultx_settings',
    ).put('lastBackupAt', DateTime.now().toIso8601String());
    _notify(
      path == null
          ? 'Backup unavailable in decoy mode'
          : 'Encrypted backup exported to $path',
    );
  }

  Future<void> _restoreLocalBackup() async {
    if (widget.repo == null) {
      _notify('Restore unavailable in this mode', error: true);
      return;
    }
    final credentialOk = await _confirmRestoreCredential();
    if (!credentialOk) {
      _notify('Restore cancelled or credential rejected', error: true);
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['vxbak', 'json'],
      withData: false,
    );
    final path = picked?.files.single.path;
    if (path == null) {
      _notify('Restore cancelled');
      return;
    }
    try {
      final count = await widget.repo!.restoreEncryptedBackup(path);
      await widget.onDataChanged();
      _notify('Restored $count encrypted records');
    } catch (e) {
      _notify(
        'Restore failed: backup password/key did not match this vault',
        error: true,
      );
    }
  }

  Future<bool> _confirmRestoreCredential() async {
    final ctrl = TextEditingController();
    final secret = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Authenticate restore'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: InputDecoration(
            labelText: widget.repo!.kind == VaultKind.hidden
                ? 'Hidden vault password'
                : 'Master password',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    ctrl.clear();
    ctrl.dispose();
    if (secret == null || secret.isEmpty) return false;
    if (!mounted) return false;
    var result = widget.repo!.kind == VaultKind.hidden
        ? await widget.auth.unlockHidden(secret)
        : await widget.auth.unlockWithPassword(secret);
    if (!mounted) return false;
    result = await widget.auth.verify(result);
    if (!mounted) return false;
    return result.ok && result.kind == widget.repo!.kind;
  }

  // ── Biometric ─────────────────────────────────────────────────────────────
  Future<void> _loadBiometricStatus() async {
    if (!mounted) return;
    final hardwareAvailable = await widget.auth.biometricAvailable();
    final enrolled = (await widget.auth.getAvailableBiometrics()).isNotEmpty;
    final typeLabel = await widget.auth.biometricTypeLabel();
    if (!mounted) return;
    setState(() {
      _biometricHardwareAvailable = hardwareAvailable;
      _biometricEnrolled = enrolled;
      _biometricTypeLabel = typeLabel;
    });
  }

  bool _biometricBusy = false;

  Future<void> _toggleBiometric(bool enable) async {
    if (_biometricBusy) return;
    _biometricBusy = true;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BiometricPasswordDialog(enable: enable),
    );
    if (result == null || result.isEmpty) {
      _biometricBusy = false;
      return;
    }
    if (!mounted) {
      _biometricBusy = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        await _doToggleBiometric(enable, result);
      } finally {
        _biometricBusy = false;
      }
    });
  }

  Future<void> _doToggleBiometric(bool enable, String password) async {
    if (!mounted) return;
    try {
      var authResult = await widget.auth.unlockWithPassword(password);
      if (!mounted) return;
      authResult = await widget.auth.verify(authResult);
      if (!mounted) return;
      if (!authResult.ok || authResult.kind == VaultKind.decoy) {
        _notify(
          authResult.error ?? 'Authentication failed — wrong password',
          error: true,
        );
        return;
      }
      if (authResult.masterKey == null) {
        _notify('Failed to retrieve master key', error: true);
        return;
      }
      if (enable) {
        final ok = await widget.auth.setupBiometric(authResult.masterKey!);
        if (!mounted) return;
        if (ok) {
          setState(() => _biometricEnabled = true);
          _notify(
            'Biometric unlock enabled — use $_biometricTypeLabel to unlock',
          );
        } else {
          _notify(
            'Failed to enable biometrics — your device may not support Android Keystore',
            error: true,
          );
        }
      } else {
        await widget.auth.removeBiometric();
        if (!mounted) return;
        setState(() => _biometricEnabled = false);
        _notify('Biometric unlock disabled — password-only unlock');
      }
    } catch (e) {
      if (!mounted) return;
      _notify(
        'An error occurred: ${e.toString().substring(0, 100)}',
        error: true,
      );
    }
  }

  // ── Dead Man Switch ───────────────────────────────────────────────────────
  Future<void> _toggleDeadMansSwitch(bool enable) async {
    if (enable) {
      final authed = await DeadMansService.requireAuth(context, widget.auth);
      if (!authed) return;
      if (!mounted) return;
      final days = await _pickDeadMansPeriod();
      if (days == null) return;
      if (!mounted) return;
      final action = await _pickDeadMansAction();
      String? email;
      String? message;
      if (action == 'email_and_wipe') {
        final result = await _pickDeadMansEmailAndMessage();
        if (result == null) return;
        email = result.$1;
        message = result.$2;
      }
      await DeadMansService.saveSettings(
        enabled: true,
        action: action ?? 'wipe',
        email: email,
        message: message,
        days: days,
      );
      if (!mounted) return;
      setState(() {
        _deadMansSwitch = true;
        _deadMansDays = days;
        _deadMansAction = action ?? 'wipe';
        _deadMansEmailCtrl.text = email ?? '';
        _deadMansMessageCtrl.text = message ?? '';
      });
      _notify(
        action == 'email_and_wipe'
            ? 'Dead man switch ON — export & wipe after ${_deadMansDayLabel(days)} of inactivity'
            : 'Dead man switch ON — vault wipes after ${_deadMansDayLabel(days)} of inactivity. Make sure you have a backup!',
      );
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Disable dead man switch?'),
          content: const Text(
            'The vault will no longer auto-wipe on inactivity.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Disable'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      await DeadMansService.disable();
      if (!mounted) return;
      setState(() {
        _deadMansSwitch = false;
        _deadMansAction = 'wipe';
        _deadMansEmailCtrl.clear();
        _deadMansMessageCtrl.clear();
      });
      _notify('Dead man switch disabled');
    }
  }

  Future<int?> _pickDeadMansPeriod() async {
    int? chosen;
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('⚠️ Enable Dead Man Switch'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'If you do not open VaultX within the chosen period, '
                'the configured action will be executed.\n\n'
                'Make sure you understand the consequences before enabling.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in [30, 180, 365, 730, 1095])
                    ChoiceChip(
                      label: Text(_deadMansDayLabel(d)),
                      selected: chosen == d,
                      onSelected: (_) => setInner(() => chosen = d),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: chosen == null
                  ? null
                  : () => Navigator.pop(ctx, chosen),
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _pickDeadMansAction() async {
    String chosen = 'wipe';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Choose Action'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'What should happen after the inactivity period ends?',
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'wipe',
                    label: Text('Wipe Only'),
                    icon: Icon(Icons.delete_forever),
                  ),
                  ButtonSegment(
                    value: 'email_and_wipe',
                    label: Text('Email & Wipe'),
                    icon: Icon(Icons.email),
                  ),
                ],
                selected: {chosen},
                onSelectionChanged: (s) => setInner(() => chosen = s.first),
              ),
              const SizedBox(height: 12),
              if (chosen == 'email_and_wipe')
                const Text(
                  'An encrypted backup will be shared before wiping all data.',
                  style: TextStyle(fontSize: 13),
                )
              else
                const Text(
                  'All vault data will be permanently deleted with no export.',
                  style: TextStyle(fontSize: 13),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, chosen),
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<(String, String)?> _pickDeadMansEmailAndMessage() async {
    return showDialog<(String, String)>(
      context: context,
      builder: (_) => const _DeadMansEmailDialog(),
    );
  }

  // ── Time-based access ─────────────────────────────────────────────────────
  Future<void> _pickTimeWindow() async {
    final start = await showTimePicker(
      context: context,
      initialTime: _timeStart,
      helpText: 'Access allowed FROM',
    );
    if (start == null) return;
    if (!mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: _timeEnd,
      helpText: 'Access allowed UNTIL',
    );
    if (end == null) return;
    setState(() {
      _timeStart = start;
      _timeEnd = end;
    });
    final box = Hive.box('vaultx_settings');
    await box.put('timeAccessStartHour', start.hour);
    await box.put('timeAccessStartMin', start.minute);
    await box.put('timeAccessEndHour', end.hour);
    await box.put('timeAccessEndMin', end.minute);
    _notify(
      'Notes accessible between ${_formatTOD(start)} and ${_formatTOD(end)}',
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.read<VaultAppState>();
    final gdriveService = _getGDriveService();
    final gdriveSignedIn =
        _googleEmail != null || (gdriveService?.isAuthenticated ?? false);
    final gdriveEmail = _googleEmail ?? gdriveService?.signedInEmail;
    final lastBackupAt =
        Hive.box('vaultx_settings').get('lastBackupAt') as String?;
    final lastGoogleBackupAt =
        Hive.box('vaultx_settings').get('lastGoogleBackupAt') as String?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Security center',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),

        // ── Security dashboard ────────────────────────────────────────────
        SecurityDashboard(
          posture: widget.posture,
          failedPinAttempts: appState.failedPinAttempts,
          lockMinutes: _lockMinutes,
          lastBackupAt: lastBackupAt,
        ),
        const SizedBox(height: 16),

        // ── Hidden Vault Quick Access ─────────────────────────────────────
        if (widget.onSwitchVault != null && widget.vaultKind != VaultKind.hidden)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              elevation: 0,
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.2),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => widget.onSwitchVault!(VaultKind.hidden),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.visibility_off,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Open Hidden Vault',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            Text(
                              'Access your secondary secure space',
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // ── Auto-lock timeout ─────────────────────────────────────────────
        Text(
          'Auto-lock timeout',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in [1, 2, 5, 15, 30])
              ChoiceChip(
                label: Text(m == 1 ? '1 min' : '$m min'),
                selected: _lockMinutes == m,
                onSelected: (_) async {
                  setState(() => _lockMinutes = m);
                  await Hive.box('vaultx_settings').put('lockMinutes', m);
                },
              ),
          ],
        ),
        const SizedBox(height: 16),

        // ── Appearance ────────────────────────────────────────────────────
        Divider(
          height: 32,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        ThemePickerTile(),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CustomThemeCreatorScreen(),
              ),
            ),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Create custom theme'),
          ),
        ),
        const SizedBox(height: 12),

        // ── Biometric ─────────────────────────────────────────────────────
        _BiometricSection(
          auth: widget.auth,
          enabled: _biometricEnabled,
          hardwareAvailable: _biometricHardwareAvailable,
          enrolled: _biometricEnrolled,
          biometricType: _biometricTypeLabel,
          onToggle: _toggleBiometric,
        ),
        const Divider(height: 32),

        // ── Encryption info ───────────────────────────────────────────────
        ListTile(
          leading: Icon(
            Icons.lock,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: const Text('AES-256-GCM encryption'),
          subtitle: const Text('All notes encrypted on-device before storage'),
          contentPadding: EdgeInsets.zero,
        ),
        ListTile(
          leading: Icon(
            Icons.phonelink_lock,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: const Text('Key stored in Android Keystore'),
          subtitle: const Text(
            'Biometric key is hardware-backed and never leaves the device',
          ),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 32),

        // ── Google Drive Backup ───────────────────────────────────────────
        const Text(
          'Google Drive Backup',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Zero-knowledge: all data is encrypted before upload. '
          'Google never sees your notes.',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 12),
        if (!gdriveSignedIn)
          FilledButton.icon(
            onPressed: _gdriveSigningIn ? null : _signInGoogleDrive,
            icon: _gdriveSigningIn
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(
              _gdriveSigningIn ? 'Signing in…' : 'Sign in with Google',
            ),
          )
        else ...[
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.account_circle)),
              title: Text(gdriveEmail ?? ''),
              subtitle: const Text('Connected to Google Drive'),
              trailing: TextButton(
                onPressed: _signOutGoogleDrive,
                child: const Text('Sign out'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _autoBackup,
            onChanged: (v) async {
              setState(() => _autoBackup = v);
              await Hive.box('vaultx_settings').put('autoBackup', v);
              if (v) _autoBackupNow();
            },
            title: const Text('Auto-backup on changes'),
            subtitle: const Text('Upload encrypted backup after each save'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _backupNewNotesByDefault,
            onChanged: (v) async {
              setState(() => _backupNewNotesByDefault = v);
              await Hive.box('vaultx_settings').put('backupNewNotesByDefault', v);
            },
            title: const Text('Backup new notes by default'),
            subtitle: const Text(
              'New notes will be included in backups unless manually excluded',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _backupNewDriveFilesByDefault,
            onChanged: (v) async {
              setState(() => _backupNewDriveFilesByDefault = v);
              await Hive.box('vaultx_settings').put('backupNewDriveFilesByDefault', v);
            },
            title: const Text('Backup new files by default'),
            subtitle: const Text(
              'Newly imported files will be included in backups unless manually excluded',
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _openBackupScreen,
              icon: const Icon(Icons.backup),
              label: const Text('Manage Backups'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openRestoreScreen,
              icon: const Icon(Icons.restore),
              label: const Text('Restore Backup'),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _autoRestore,
            onChanged: (v) async {
              setState(() => _autoRestore = v);
              await Hive.box('vaultx_settings').put('autoRestore', v);
              _notify(
                v
                    ? 'Auto-restore enabled — backup will restore on new device login'
                    : 'Auto-restore disabled',
              );
            },
            title: const Text('Auto-restore on new device'),
            subtitle: const Text(
              'Automatically restore latest backup after login on a new device',
            ),
          ),
          if (lastGoogleBackupAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Last cloud backup: '
                '${DateTime.tryParse(lastGoogleBackupAt)?.toLocal() ?? lastGoogleBackupAt}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
        ],
        const Divider(height: 32),

        // ── Local Backup ──────────────────────────────────────────────────
        const Text(
          'Local Backup',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _exportLocalBackup,
                icon: const Icon(Icons.file_download),
                label: const Text('Export encrypted backup'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _restoreLocalBackup,
                icon: const Icon(Icons.restore),
                label: const Text('Restore backup'),
              ),
            ),
          ],
        ),
        if (lastBackupAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Last local backup: ${DateTime.tryParse(lastBackupAt)?.toLocal() ?? lastBackupAt}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        const Divider(height: 32),

        // ── Hidden Vault ──────────────────────────────────────────────────
        ExpansionTile(
          leading: const Icon(Icons.visibility_off),
          title: const Text('Hidden vault'),
          subtitle: const Text(
            'Set a separate password to open a secret second vault',
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                'When you enter this password on the lock screen, '
                'a completely separate encrypted vault opens — '
                'different notes, invisible to the main vault.',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: TextField(
                controller: _hiddenPasswordCtrl,
                obscureText: !_hiddenPasswordVisible,
                decoration: InputDecoration(
                  labelText: 'Hidden vault password',
                  helperText: 'Minimum 12 characters',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _hiddenPasswordVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(
                      () => _hiddenPasswordVisible = !_hiddenPasswordVisible,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _hiddenPasswordConfirmCtrl,
                obscureText: !_hiddenPasswordConfirmVisible,
                decoration: InputDecoration(
                  labelText: 'Confirm hidden vault password',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _hiddenPasswordConfirmVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(
                      () => _hiddenPasswordConfirmVisible =
                          !_hiddenPasswordConfirmVisible,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: () async {
                  final err = _validatePassword(
                    _hiddenPasswordCtrl.text,
                    _hiddenPasswordConfirmCtrl.text,
                    'Hidden vault password',
                  );
                  if (err != null) {
                    _notify(err, error: true);
                    return;
                  }
                  await widget.auth.configureHiddenVault(
                    _hiddenPasswordCtrl.text,
                  );
                  _hiddenPasswordCtrl.clear();
                  _hiddenPasswordConfirmCtrl.clear();
                  _notify(
                    'Hidden vault password set. '
                    'You can now switch vaults from the app bar or use "Open hidden vault" on the lock screen.',
                  );
                },
                icon: const Icon(Icons.lock),
                label: const Text('Save hidden vault password'),
              ),
            ),
          ],
        ),
        const Divider(height: 32),

        // ── Decoy Mode ────────────────────────────────────────────────────
        ExpansionTile(
          leading: const Icon(Icons.theater_comedy),
          title: const Text('Decoy mode'),
          subtitle: const Text(
            'Calculator launch cover and emergency dummy vault',
          ),
          children: [
            SwitchListTile(
              value: _decoyCalculatorEnabled,
              onChanged: (value) async {
                await Hive.box(
                  'vaultx_settings',
                ).put('decoyCalculatorEnabled', value);
                await SecurityPlatform.setDecoyLauncherEnabled(value);
                if (!mounted) return;
                setState(() => _decoyCalculatorEnabled = value);
                _notify(
                  value
                      ? 'Decoy calculator enabled. Restart opens Calculator first.'
                      : 'Decoy calculator disabled.',
                );
              },
              title: const Text('Launch as Calculator'),
              subtitle: const Text(
                'Shows a working calculator before vault authentication',
              ),
            ),
            SwitchListTile(
              value: _decoyCalculatorHistory,
              onChanged: (value) async {
                await Hive.box(
                  'vaultx_settings',
                ).put('decoyCalculatorHistory', value);
                if (!mounted) return;
                setState(() => _decoyCalculatorHistory = value);
              },
              title: const Text('Calculator history'),
              subtitle: const Text('Keep recent calculations in decoy mode'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: DropdownButtonFormField<String>(
                initialValue: _decoyCalculatorTrigger,
                decoration: const InputDecoration(labelText: 'Secret trigger'),
                items: const [
                  DropdownMenuItem(
                    value: 'pin',
                    child: Text('Secret PIN sequence'),
                  ),
                  DropdownMenuItem(
                    value: 'long_press',
                    child: Text('Hidden long press'),
                  ),
                  DropdownMenuItem(
                    value: 'invisible_area',
                    child: Text('Invisible corner area'),
                  ),
                  DropdownMenuItem(
                    value: 'double_tap_logo',
                    child: Text('Double tap calculator logo'),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  await Hive.box(
                    'vaultx_settings',
                  ).put('decoyCalculatorTrigger', value);
                  if (!mounted) return;
                  setState(() => _decoyCalculatorTrigger = value);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _decoyCalculatorSecretCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Secret PIN sequence',
                  helperText: 'Typed into the calculator display',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                onPressed: () async {
                  final pin = _decoyCalculatorSecretCtrl.text.trim();
                  if (pin.length < 4 || int.tryParse(pin) == null) {
                    _notify(
                      'Use a numeric trigger of at least 4 digits.',
                      error: true,
                    );
                    return;
                  }
                  await Hive.box(
                    'vaultx_settings',
                  ).put('decoyCalculatorSecret', pin);
                  _notify('Calculator trigger saved.');
                },
                icon: const Icon(Icons.calculate),
                label: const Text('Save calculator trigger'),
              ),
            ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                'When you enter this password on the lock screen instead of '
                'your real password, the app opens a convincing but completely '
                'empty vault — no real notes are ever shown.',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: TextField(
                controller: _decoyPasswordCtrl,
                obscureText: !_decoyPasswordVisible,
                decoration: InputDecoration(
                  labelText: 'Decoy password',
                  helperText:
                      'Minimum 12 characters — must differ from real password',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _decoyPasswordVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(
                      () => _decoyPasswordVisible = !_decoyPasswordVisible,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _decoyPasswordConfirmCtrl,
                obscureText: !_decoyPasswordConfirmVisible,
                decoration: InputDecoration(
                  labelText: 'Confirm decoy password',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _decoyPasswordConfirmVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(
                      () => _decoyPasswordConfirmVisible =
                          !_decoyPasswordConfirmVisible,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                onPressed: () async {
                  final err = _validatePassword(
                    _decoyPasswordCtrl.text,
                    _decoyPasswordConfirmCtrl.text,
                    'Decoy password',
                  );
                  if (err != null) {
                    _notify(err, error: true);
                    return;
                  }
                  await widget.auth.setFakePin(_decoyPasswordCtrl.text);
                  _decoyPasswordCtrl.clear();
                  _decoyPasswordConfirmCtrl.clear();
                  _notify(
                    'Decoy password set. '
                    'Entering it on the lock screen will open an empty vault.',
                  );
                },
                icon: const Icon(Icons.theater_comedy),
                label: const Text('Save decoy password'),
              ),
            ),
          ],
        ),

        // ── Time-based note access ────────────────────────────────────────
        SwitchListTile(
          value: _timeAccess,
          onChanged: (v) async {
            setState(() => _timeAccess = v);
            await Hive.box('vaultx_settings').put('timeAccess', v);
            if (v) {
              _notify(
                'Notes can only be opened between '
                '${_formatTOD(_timeStart)} and ${_formatTOD(_timeEnd)}. '
                'Tap "Set time window" to change.',
              );
            } else {
              _notify('Time-based access disabled — notes always accessible');
            }
          },
          title: const Text('Time-based note access'),
          subtitle: Text(
            _timeAccess
                ? 'Notes locked outside ${_formatTOD(_timeStart)} – ${_formatTOD(_timeEnd)}'
                : 'Notes accessible at any time',
          ),
        ),
        if (_timeAccess)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: OutlinedButton.icon(
              onPressed: _pickTimeWindow,
              icon: const Icon(Icons.access_time),
              label: Text(
                'Set time window  '
                '(${_formatTOD(_timeStart)} – ${_formatTOD(_timeEnd)})',
              ),
            ),
          ),

        // ── Dead Man Switch ───────────────────────────────────────────────
        SwitchListTile(
          value: _deadMansSwitch,
          onChanged: _toggleDeadMansSwitch,
          title: const Text('Dead man switch'),
          subtitle: Text(
            _deadMansSwitch
                ? '⚠️ Active — $_deadMansActionLabel after ${_deadMansDayLabel(_deadMansDays)}'
                : 'Disabled — vault is never auto-wiped',
          ),
        ),
        if (_deadMansSwitch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _deadMansAction == 'email_and_wipe'
                          ? Icons.email
                          : Icons.delete_forever,
                      size: 16,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Action: $_deadMansActionLabel',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_deadMansAction == 'email_and_wipe') ...[
                  if (_deadMansEmailCtrl.text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.email_outlined,
                            size: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _deadMansEmailCtrl.text,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_deadMansMessageCtrl.text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        _deadMansMessageCtrl.text,
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Inactivity period: ${_deadMansDayLabel(_deadMansDays)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in [30, 180, 365, 730, 1095])
                      ChoiceChip(
                        label: Text(_deadMansDayLabel(d)),
                        selected: _deadMansDays == d,
                        onSelected: (_) async {
                          await DeadMansService.saveSettings(
                            enabled: true,
                            action: _deadMansAction,
                            email: _deadMansEmailCtrl.text,
                            message: _deadMansMessageCtrl.text,
                            days: d,
                          );
                          if (!mounted) return;
                          setState(() => _deadMansDays = d);
                          _notify(
                            'Inactivity period set to ${_deadMansDayLabel(d)}',
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Open the app at least once every ${_deadMansDayLabel(_deadMansDays)} to prevent the action.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),

        // ── Intruder selfie capture ───────────────────────────────────────
        const Divider(height: 32),
        SwitchListTile(
          value: _intruderCaptureEnabled,
          onChanged: (val) async {
            await Hive.box(
              'vaultx_settings',
            ).put('intruderCaptureEnabled', val);
            if (!mounted) return;
            setState(() => _intruderCaptureEnabled = val);
          },
          title: const Text('Intruder selfie capture'),
          subtitle: Text(
            _intruderCaptureEnabled
                ? 'On — captures selfie after $_intruderCaptureThreshold failed attempts'
                : 'Off — no capture on failed PIN attempts',
          ),
        ),
        if (_intruderCaptureEnabled) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Capture threshold: $_intruderCaptureThreshold attempts',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [3, 5, 10].map((n) {
                    return ChoiceChip(
                      label: Text('$n'),
                      selected: _intruderCaptureThreshold == n,
                      onSelected: (_) async {
                        await Hive.box(
                          'vaultx_settings',
                        ).put('intruderCaptureThreshold', n);
                        if (!mounted) return;
                        setState(() => _intruderCaptureThreshold = n);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Text(
                  'A front-camera photo is taken after $_intruderCaptureThreshold '
                  'failed PIN attempts and stored encrypted.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ],

        // ── Failed Attempt Notifications ──────────────────────────────────
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Failed Attempt Notifications'),
          subtitle: Text(
            _failedAttemptNotifications == 'off'
                ? 'Hidden'
                : _failedAttemptNotifications == 'floating'
                ? 'Floating popup'
                : 'Persistent',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'off', label: Text('Off')),
              ButtonSegment(value: 'floating', label: Text('Floating')),
              ButtonSegment(value: 'persistent', label: Text('Persistent')),
            ],
            selected: {_failedAttemptNotifications},
            onSelectionChanged: (selected) {
              final val = selected.first;
              Hive.box(
                'vaultx_settings',
              ).put('failedAttemptNotifications', val);
              setState(() => _failedAttemptNotifications = val);
            },
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _failedAttemptNotifications == 'off'
                ? 'Failed attempt popups are hidden. Security logging and intruder capture still work normally.'
                : _failedAttemptNotifications == 'floating'
                ? 'Failed attempt popup auto-removes after a few seconds.'
                : 'Failed attempt popup remains available for 15 minutes or until dismissed.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.camera_alt_outlined),
          title: const Text('View Intruder Logs'),
          subtitle: const Text('Review captured intruder selfies'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  SecurityLogsScreen(auth: widget.auth, isDecoy: false),
            ),
          ),
        ),

        // ── Device posture ────────────────────────────────────────────────
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.health_and_safety),
          title: const Text('Device security posture'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              ..._enrichedPosture.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(
                          '${e.key}:',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          e.value,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          isThreeLine: true,
        ),

        // ── Privacy policy ────────────────────────────────────────────────
        ListTile(
          leading: const Icon(Icons.policy),
          title: const Text('Privacy policy'),
          subtitle: const Text('Local-first data handling and permissions'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
          ),
        ),
        const Divider(height: 32),

        // ── Activity logs ─────────────────────────────────────────────────
        ExpansionTile(
          leading: const Icon(Icons.receipt_long),
          title: const Text('Activity logs'),
          subtitle: const Text('Last 20 security events'),
          children: AuditLog.all()
              .take(20)
              .map(
                (e) => ListTile(
                  dense: true,
                  title: Text(e['event'].toString()),
                  subtitle: Text(e['ts'].toString()),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 16),

        // ── Full data wipe ────────────────────────────────────────────────
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _showDeleteEverythingFlow,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete Everything'),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Future<void> _showDeleteEverythingFlow() async {
    final navigator = Navigator.of(context);
    final cs = Theme.of(context).colorScheme;

    // 1. Initial Warning and Typed Confirmation
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: cs.error),
                const SizedBox(width: 8),
                const Text('Irreversible Action'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You are about to permanently delete ALL VaultX data. '
                  'This includes:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text('• All local notes and files\n'
                           '• Hidden vault contents\n'
                           '• Encrypted cloud backups (Google Drive)\n'
                           '• Temporary files and cached data\n'
                           '• Application settings and credentials'),
                const SizedBox(height: 16),
                const Text(
                  'This action CANNOT be undone.',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text('Type "DELETE EVERYTHING" to confirm:'),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'DELETE EVERYTHING',
                  ),
                  onChanged: (_) => setState(() {}), // Trigger rebuild to update button state
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: cs.error),
                onPressed: ctrl.text == 'DELETE EVERYTHING'
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('Proceed'),
              ),
            ],
          ),
        );
      },
    );

    if (confirmed != true) return;
    if (!mounted) return;

    // 2. Mandatory Password Confirmation
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('Verify Identity'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your master password to authorize deletion.'),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Master password',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cs.error),
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (password == null || password.isEmpty) return;
    if (!mounted) return;

    // 3. Execution with Progress Overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _DeleteProgressOverlay(),
    );

    // Give the UI a moment to render the overlay
    await Future.delayed(const Duration(milliseconds: 300));

    final success = await SecureDeleteService.wipeEverything(
      password: password,
      authService: widget.auth,
      onProgress: (phase) {
        // We broadcast progress via a ValueNotifier in the overlay
        _deleteProgressNotifier.value = phase;
      },
    );

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // Close overlay

    if (success) {
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SetupScreen(auth: widget.auth)),
        (_) => false,
      );
    } else {
      _notify('Deletion failed. Incorrect password or unexpected error.', error: true);
    }
  }
}

// Global notifier for the progress overlay
final _deleteProgressNotifier = ValueNotifier<String>('Starting deletion...');

class _DeleteProgressOverlay extends StatelessWidget {
  const _DeleteProgressOverlay();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.red),
            const SizedBox(height: 24),
            const Text(
              'Deleting Everything',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: _deleteProgressNotifier,
              builder: (context, phase, _) {
                return Text(
                  phase,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Biometric section card

// ─────────────────────────────────────────────────────────────────────────────
class _BiometricSection extends StatelessWidget {
  const _BiometricSection({
    required this.auth,
    required this.enabled,
    required this.hardwareAvailable,
    required this.enrolled,
    required this.biometricType,
    required this.onToggle,
  });

  final VaultAuthService auth;
  final bool enabled;
  final bool hardwareAvailable;
  final bool enrolled;
  final String biometricType;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final available = hardwareAvailable && enrolled;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.fingerprint, color: cs.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Biometric Authentication',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  available ? Icons.check_circle : Icons.cancel,
                  size: 16,
                  color: available ? cs.primary : cs.error,
                ),
                const SizedBox(width: 6),
                Text(
                  available ? 'Available' : 'Unavailable',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: available ? cs.primary : cs.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  biometricType.contains('Face')
                      ? Icons.face
                      : Icons.fingerprint,
                  size: 14,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 6),
                Text(
                  biometricType,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            if (available && !enabled) ...[
              const SizedBox(height: 4),
              Text(
                'Use your $biometricType to unlock the vault quickly.',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
            if (!available && !hardwareAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'This device does not support biometric authentication.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            if (!available && hardwareAvailable && !enrolled)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'No biometrics enrolled. Add fingerprints or face data in system settings.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            if (enabled && !available)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Biometric unlock enabled but unavailable. Check device biometric settings.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.error.withValues(alpha: 0.8),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: enabled,
              onChanged: available ? onToggle : null,
              title: const Text('Enable biometric unlock'),
              subtitle: Text(
                enabled
                    ? 'Use $biometricType to unlock the vault'
                    : 'Password-only unlock',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dead man's email dialog
// ─────────────────────────────────────────────────────────────────────────────
class _DeadMansEmailDialog extends StatefulWidget {
  const _DeadMansEmailDialog();

  @override
  State<_DeadMansEmailDialog> createState() => _DeadMansEmailDialogState();
}

class _DeadMansEmailDialogState extends State<_DeadMansEmailDialog> {
  final _emailCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    Navigator.pop(context, (email, _messageCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Recovery Email'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the email address where the encrypted backup should be sent.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailCtrl,
              decoration: InputDecoration(
                labelText: 'Recovery email',
                hintText: 'trusted@example.com',
                prefixIcon: const Icon(Icons.email_outlined),
                errorText: _error,
              ),
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageCtrl,
              decoration: const InputDecoration(
                labelText: 'Custom message (optional)',
                prefixIcon: Icon(Icons.message_outlined),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Biometric password dialog
// ─────────────────────────────────────────────────────────────────────────────
class _BiometricPasswordDialog extends StatefulWidget {
  const _BiometricPasswordDialog({required this.enable});
  final bool enable;

  @override
  State<_BiometricPasswordDialog> createState() =>
      _BiometricPasswordDialogState();
}

class _BiometricPasswordDialogState extends State<_BiometricPasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.enable ? 'Enable Biometrics' : 'Disable Biometrics'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.enable
                ? 'Enter your master password to enable biometric unlock.'
                : 'Enter your master password to disable biometric unlock.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Master password'),
            onSubmitted: (_) => Navigator.pop(context, _controller.text),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}


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
import 'backup_restore_screen.dart';
import 'privacy_policy_screen.dart';
import 'security_logs_screen.dart';
import 'setup_screen.dart';
import 'trash_screen.dart';

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
    this.trashService,
  });
  final VaultAuthService auth;
  final VaultRepository? repo;
  final Map<String, dynamic> posture;
  final Future<void> Function() onDataChanged;
  final VaultKind? vaultKind;
  final void Function(VaultKind)? onSwitchVault;
  final TrashService? trashService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with AutomaticKeepAliveClientMixin {
  final _hiddenPasswordCtrl = TextEditingController();
  final _hiddenPasswordConfirmCtrl = TextEditingController();
  bool _hiddenPasswordVisible = false;
  bool _hiddenPasswordConfirmVisible = false;

  final _decoyPasswordCtrl = TextEditingController();
  final _decoyPasswordConfirmCtrl = TextEditingController();
  bool _decoyPasswordVisible = false;
  bool _decoyPasswordConfirmVisible = false;

  bool _biometricEnabled = false;
  bool _biometricHardwareAvailable = false;
  bool _biometricEnrolled = false;
  String _biometricTypeLabel = 'Device Biometrics';

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
  String _failedAttemptNotifications = 'persistent';
  bool _decoyCalculatorEnabled = false;
  bool _decoyCalculatorHistory = true;
  String _decoyCalculatorTrigger = 'pin';
  final _decoyCalculatorSecretCtrl = TextEditingController();
  int _lockMinutes =
      Hive.box('vaultx_settings').get('lockMinutes', defaultValue: 1) as int;

  late final Map<String, String> _enrichedPosture;

  void _notify(String msg, {bool error = false}) {
    FloatingNotificationService.instance.show(
      msg,
      error: error,
      type: error ? AppNotificationType.error : AppNotificationType.success,
    );
  }

  @override
  void initState() {
    super.initState();
    _enrichedPosture = _buildEnrichedPosture(widget.posture);
    _loadSavedSettings();
    _loadBiometricStatus();
  }

  @override
  void dispose() {
    _hiddenPasswordCtrl.dispose();
    _hiddenPasswordConfirmCtrl.dispose();
    _decoyPasswordCtrl.dispose();
    _decoyPasswordConfirmCtrl.dispose();
    _deadMansEmailCtrl.dispose();
    _deadMansMessageCtrl.dispose();
    _decoyCalculatorSecretCtrl.dispose();
    super.dispose();
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
      35: '15', 34: '14', 33: '13', 32: '12L', 31: '12', 30: '11', 29: '10', 28: '9 Pie', 27: '8.1', 26: '8.0',
    };
    return names[sdk] ?? 'Unknown';
  }

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
      case 30: return '1 month';
      case 180: return '6 months';
      case 365: return '1 year';
      case 730: return '2 years';
      case 1095: return '3 years';
      default: return '$days days';
    }
  }

  String get _deadMansActionLabel {
    switch (_deadMansAction) {
      case 'email_and_wipe': return 'Email & Wipe';
      default: return 'Wipe Only';
    }
  }

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
        _notify(authResult.error ?? 'Authentication failed — wrong password', error: true);
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
          _notify('Biometric unlock enabled — use $_biometricTypeLabel to unlock');
        } else {
          _notify('Failed to enable biometrics — your device may not support Android Keystore', error: true);
        }
      } else {
        await widget.auth.removeBiometric();
        if (!mounted) return;
        setState(() => _biometricEnabled = false);
        _notify('Biometric unlock disabled — password-only unlock');
      }
    } catch (e) {
      if (!mounted) return;
      _notify('An error occurred: ${e.toString().substring(0, 100)}', error: true);
    }
  }

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
      await DeadMansService.saveSettings(enabled: true, action: action ?? 'wipe', email: email, message: message, days: days);
      if (!mounted) return;
      setState(() {
        _deadMansSwitch = true;
        _deadMansDays = days;
        _deadMansAction = action ?? 'wipe';
        _deadMansEmailCtrl.text = email ?? '';
        _deadMansMessageCtrl.text = message ?? '';
      });
      _notify(action == 'email_and_wipe'
            ? 'Dead man switch ON — export & wipe after ${_deadMansDayLabel(days)} of inactivity'
            : 'Dead man switch ON — vault wipes after ${_deadMansDayLabel(days)} of inactivity.');
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Disable dead man switch?'),
          content: const Text('The vault will no longer auto-wipe on inactivity.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disable')),
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
              const Text('If you do not open VaultX within the chosen period, the configured action will be executed.'),
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
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: chosen == null ? null : () => Navigator.pop(ctx, chosen),
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _pickDeadMansAction() async {
    String chosen = 'wipe';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Choose Action'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('What should happen after the inactivity period ends?'),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'wipe', label: Text('Wipe Only'), icon: Icon(Icons.delete_forever)),
                  ButtonSegment(value: 'email_and_wipe', label: Text('Email & Wipe'), icon: Icon(Icons.email)),
                ],
                selected: {chosen},
                onSelectionChanged: (s) => setInner(() => chosen = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, chosen), child: const Text('Next')),
          ],
        ),
      ),
    );
  }

  Future<(String, String)?> _pickDeadMansEmailAndMessage() async {
    return showDialog<(String, String)>(context: context, builder: (_) => const _DeadMansEmailDialog());
  }

  Future<void> _pickTimeWindow() async {
    final start = await showTimePicker(context: context, initialTime: _timeStart, helpText: 'Access allowed FROM');
    if (start == null) return;
    if (!mounted) return;
    final end = await showTimePicker(context: context, initialTime: _timeEnd, helpText: 'Access allowed UNTIL');
    if (end == null) return;
    setState(() { _timeStart = start; _timeEnd = end; });
    final box = Hive.box('vaultx_settings');
    await box.put('timeAccessStartHour', start.hour);
    await box.put('timeAccessStartMin', start.minute);
    await box.put('timeAccessEndHour', end.hour);
    await box.put('timeAccessEndMin', end.minute);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.read<VaultAppState>();
    final lastBackup = _getLatestBackup();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Security center', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        SecurityDashboard(posture: widget.posture, failedPinAttempts: appState.failedPinAttempts, lockMinutes: _lockMinutes, lastBackupAt: lastBackup),
        const SizedBox(height: 16),

        if (widget.onSwitchVault != null && widget.vaultKind != VaultKind.hidden)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2))),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => widget.onSwitchVault!(VaultKind.hidden),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle), child: const Icon(Icons.visibility_off, color: Colors.white, size: 20)),
                      const SizedBox(width: 16),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Open Hidden Vault', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('Access your secondary secure space', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ])),
                      Icon(Icons.arrow_forward_ios, size: 14, color: Theme.of(context).colorScheme.primary),
                    ],
                  ),
                ),
              ),
            ),
          ),

        Text('Auto-lock timeout', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in [1, 2, 5, 15, 30])
            ChoiceChip(label: Text(m == 1 ? '1 min' : '$m min'), selected: _lockMinutes == m, onSelected: (_) async {
              setState(() => _lockMinutes = m);
              await Hive.box('vaultx_settings').put('lockMinutes', m);
            }),
        ]),
        const SizedBox(height: 16),

        Divider(height: 32, color: Theme.of(context).colorScheme.outlineVariant),
        Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        ThemePickerTile(),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: OutlinedButton.icon(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CustomThemeCreatorScreen())), icon: const Icon(Icons.auto_awesome), label: const Text('Create custom theme'))),
        const SizedBox(height: 12),

        _BiometricSection(auth: widget.auth, enabled: _biometricEnabled, hardwareAvailable: _biometricHardwareAvailable, enrolled: _biometricEnrolled, biometricType: _biometricTypeLabel, onToggle: _toggleBiometric),
        const Divider(height: 32),

        // ── Backup & Restore (CONSOLIDATED) ──────────────────────────────────
        ListTile(
          leading: Icon(Icons.backup_outlined, color: Theme.of(context).colorScheme.primary),
          title: const Text('Backup & Restore'),
          subtitle: const Text('Cloud sync, ZIP export/import, and settings'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            if (widget.repo == null) {
              _notify('Backup unavailable in decoy mode', error: true);
              return;
            }
            final authenticated = await _authenticateForAction('Authenticate Backup & Restore');
            if (!authenticated || !mounted) return;
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => BackupRestoreScreen(masterKey: widget.repo!.masterKey, kind: widget.repo!.kind, authService: widget.auth, repo: widget.repo, onDataChanged: widget.onDataChanged)));
          },
        ),
        const Divider(height: 32),

        ListTile(
          leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.primary),
          title: const Text('View Trash'),
          subtitle: const Text('Recently deleted items'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (widget.trashService != null) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TrashScreen(
                  trashService: widget.trashService!,
                  auth: widget.auth,
                  repo: widget.repo,
                ),
              ));
            }
          },
        ),
        const Divider(height: 32),

        ExpansionTile(
          leading: const Icon(Icons.visibility_off),
          title: const Text('Hidden vault'),
          subtitle: const Text('Set a separate password to open a secret second vault'),
          children: [
            Padding(padding: const EdgeInsets.all(12), child: TextField(controller: _hiddenPasswordCtrl, obscureText: !_hiddenPasswordVisible, decoration: InputDecoration(labelText: 'Hidden vault password', suffixIcon: IconButton(icon: Icon(_hiddenPasswordVisible ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _hiddenPasswordVisible = !_hiddenPasswordVisible))))),
            Padding(padding: const EdgeInsets.all(12), child: TextField(controller: _hiddenPasswordConfirmCtrl, obscureText: !_hiddenPasswordConfirmVisible, decoration: InputDecoration(labelText: 'Confirm hidden vault password', suffixIcon: IconButton(icon: Icon(_hiddenPasswordConfirmVisible ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _hiddenPasswordConfirmVisible = !_hiddenPasswordConfirmVisible))))),
            Padding(padding: const EdgeInsets.all(12), child: FilledButton.icon(onPressed: () async {
              final err = _validatePassword(_hiddenPasswordCtrl.text, _hiddenPasswordConfirmCtrl.text, 'Hidden vault password');
              if (err != null) { _notify(err, error: true); return; }
              await widget.auth.configureHiddenVault(_hiddenPasswordCtrl.text);
              _hiddenPasswordCtrl.clear(); _hiddenPasswordConfirmCtrl.clear();
              _notify('Hidden vault password set.');
            }, icon: const Icon(Icons.lock), label: const Text('Save hidden vault password'))),
          ],
        ),
        const Divider(height: 32),

        ExpansionTile(
          leading: const Icon(Icons.theater_comedy),
          title: const Text('Decoy mode'),
          subtitle: const Text('Calculator launch cover and emergency dummy vault'),
          children: [
            SwitchListTile(value: _decoyCalculatorEnabled, onChanged: (value) async { await Hive.box('vaultx_settings').put('decoyCalculatorEnabled', value); await SecurityPlatform.setDecoyLauncherEnabled(value); if (mounted) setState(() => _decoyCalculatorEnabled = value); }, title: const Text('Launch as Calculator')),
            SwitchListTile(value: _decoyCalculatorHistory, onChanged: (value) async { await Hive.box('vaultx_settings').put('decoyCalculatorHistory', value); if (mounted) setState(() => _decoyCalculatorHistory = value); }, title: const Text('Calculator history')),
            Padding(padding: const EdgeInsets.all(12), child: TextField(controller: _decoyCalculatorSecretCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Secret PIN sequence'))),
            Padding(padding: const EdgeInsets.all(12), child: OutlinedButton.icon(onPressed: () async {
              final pin = _decoyCalculatorSecretCtrl.text.trim();
              if (pin.length < 4 || int.tryParse(pin) == null) { _notify('Use a numeric trigger of at least 4 digits.', error: true); return; }
              await Hive.box('vaultx_settings').put('decoyCalculatorSecret', pin); _notify('Calculator trigger saved.');
            }, icon: const Icon(Icons.calculate), label: const Text('Save calculator trigger'))),
          ],
        ),

        SwitchListTile(value: _timeAccess, onChanged: (v) async { setState(() => _timeAccess = v); await Hive.box('vaultx_settings').put('timeAccess', v); }, title: const Text('Time-based note access')),
        if (_timeAccess) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: OutlinedButton.icon(onPressed: _pickTimeWindow, icon: const Icon(Icons.access_time), label: Text('Set time window (${_formatTOD(_timeStart)} – ${_formatTOD(_timeEnd)})'))),

        SwitchListTile(value: _deadMansSwitch, onChanged: _toggleDeadMansSwitch, title: const Text('Dead man switch')),
        const Divider(height: 32),

        SwitchListTile(value: _intruderCaptureEnabled, onChanged: (val) async { await Hive.box('vaultx_settings').put('intruderCaptureEnabled', val); if (mounted) setState(() => _intruderCaptureEnabled = val); }, title: const Text('Intruder selfie capture')),
        const Divider(height: 32),

        ListTile(leading: const Icon(Icons.notifications_outlined), title: const Text('Failed Attempt Notifications')),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: SegmentedButton<String>(segments: const [ButtonSegment(value: 'off', label: Text('Off')), ButtonSegment(value: 'floating', label: Text('Floating')), ButtonSegment(value: 'persistent', label: Text('Persistent'))], selected: {_failedAttemptNotifications}, onSelectionChanged: (s) { Hive.box('vaultx_settings').put('failedAttemptNotifications', s.first); setState(() => _failedAttemptNotifications = s.first); })),

        const Divider(height: 32),
        ListTile(leading: const Icon(Icons.health_and_safety), title: const Text('Device security posture'), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _enrichedPosture.entries.map((e) => Text('${e.key}: ${e.value}', style: const TextStyle(fontSize: 12))).toList())),

        ListTile(leading: const Icon(Icons.policy), title: const Text('Privacy policy'), onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()))),
        const Divider(height: 32),

        ExpansionTile(leading: const Icon(Icons.receipt_long), title: const Text('Activity logs'), children: AuditLog.all().take(20).map((e) => ListTile(dense: true, title: Text(e['event'].toString()), subtitle: Text(e['ts'].toString()))).toList()),
        const SizedBox(height: 16),

        FilledButton.tonalIcon(style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer, foregroundColor: Theme.of(context).colorScheme.error), onPressed: _showDeleteEverythingFlow, icon: const Icon(Icons.delete_forever), label: const Text('Delete Everything')),
        const SizedBox(height: 120),
      ],
    );
  }

  String? _getLatestBackup() {
    final lastGoogleBackupAt = Hive.box('vaultx_settings').get('lastGoogleBackupAt') as String?;
    final lastMegaBackupAt = Hive.box('vaultx_settings').get('lastMegaBackupAt') as String?;
    final gDt = DateTime.tryParse(lastGoogleBackupAt ?? '');
    final mDt = DateTime.tryParse(lastMegaBackupAt ?? '');
    if (gDt != null && mDt != null) return gDt.isAfter(mDt) ? lastGoogleBackupAt : lastMegaBackupAt;
    return lastGoogleBackupAt ?? lastMegaBackupAt;
  }

  Future<void> _showDeleteEverythingFlow() async {
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) { final ctrl = TextEditingController(); return AlertDialog(title: const Text('Irreversible Action'), content: Column(mainAxisSize: MainAxisSize.min, children: [const Text('Type "DELETE EVERYTHING" to confirm:'), TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'DELETE EVERYTHING'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(backgroundColor: cs.error), onPressed: () => Navigator.pop(ctx, ctrl.text == 'DELETE EVERYTHING'), child: const Text('Proceed'))]); });
    if (confirmed != true || !mounted) return;
    final password = await showDialog<String>(context: context, builder: (ctx) { final ctrl = TextEditingController(); return AlertDialog(title: const Text('Verify Identity'), content: TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(labelText: 'Master password')), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(backgroundColor: cs.error), onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Delete'))]); });
    if (password == null || password.isEmpty || !mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (ctx) => const _DeleteProgressOverlay());
    final success = await SecureDeleteService.wipeEverything(
      password: password,
      authService: widget.auth,
      onProgress: (_) {}, // Added required onProgress
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (success) { Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => SetupScreen(auth: widget.auth)), (_) => false); }
    else { _notify('Deletion failed.', error: true); }
  }

  Future<bool> _authenticateForAction(String title) async {
    await SecurityPlatform.enableScreenProtection();
    final bioEnabled = await widget.auth.isBiometricUnlockAvailable();
    if (bioEnabled) { if (await widget.auth.authenticateBiometric()) return true; }
    if (!mounted) return false;
    final ctrl = TextEditingController();
    final secret = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: Text(title), content: TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password')), actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Verify'))]));
    if (secret == null || secret.isEmpty) return false;
    var result = widget.repo!.kind == VaultKind.hidden ? await widget.auth.unlockHidden(secret) : await widget.auth.unlockWithPassword(secret);
    result = await widget.auth.verify(result);
    return result.ok && result.kind == widget.repo!.kind;
  }
}

class _DeleteProgressOverlay extends StatelessWidget {
  const _DeleteProgressOverlay();
  @override
  Widget build(BuildContext context) { return const Dialog(backgroundColor: Colors.transparent, child: Center(child: CircularProgressIndicator(color: Colors.red))); }
}

class _BiometricSection extends StatelessWidget {
  const _BiometricSection({required this.auth, required this.enabled, required this.hardwareAvailable, required this.enrolled, required this.biometricType, required this.onToggle});
  final VaultAuthService auth; final bool enabled; final bool hardwareAvailable; final bool enrolled; final String biometricType; final ValueChanged<bool> onToggle;
  @override
  Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme; final available = hardwareAvailable && enrolled; return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Biometric Authentication', style: const TextStyle(fontWeight: FontWeight.bold)), SwitchListTile(value: enabled, onChanged: available ? onToggle : null, title: Text('Enable $biometricType'))]))); }
}

class _DeadMansEmailDialog extends StatefulWidget {
  const _DeadMansEmailDialog();
  @override
  State<_DeadMansEmailDialog> createState() => _DeadMansEmailDialogState();
}

class _DeadMansEmailDialogState extends State<_DeadMansEmailDialog> {
  final _emailCtrl = TextEditingController(); final _messageCtrl = TextEditingController();
  @override
  Widget build(BuildContext context) { return AlertDialog(title: const Text('Recovery Email'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: _emailCtrl, decoration: const InputDecoration(labelText: 'Email')), TextField(controller: _messageCtrl, decoration: const InputDecoration(labelText: 'Message'))]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, (_emailCtrl.text, _messageCtrl.text)), child: const Text('Save'))]); }
}

class _BiometricPasswordDialog extends StatefulWidget {
  const _BiometricPasswordDialog({required this.enable});
  final bool enable;
  @override
  State<_BiometricPasswordDialog> createState() => _BiometricPasswordDialogState();
}

class _BiometricPasswordDialogState extends State<_BiometricPasswordDialog> {
  final _controller = TextEditingController();
  @override
  Widget build(BuildContext context) { return AlertDialog(title: Text(widget.enable ? 'Enable Biometrics' : 'Disable Biometrics'), content: TextField(controller: _controller, obscureText: true, decoration: const InputDecoration(labelText: 'Password')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Confirm'))]); }
}

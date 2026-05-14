import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../services/services.dart';
import '../theme/theme_provider.dart';
import '../widgets/widgets.dart';
import 'screens.dart';

/// App entry point — initializes Hive, enables screen protection, and runs the app.
Future<void> runVaultX() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FLUTTER ERROR: ${details.exceptionAsString()}');
    if (details.stack != null) debugPrint('${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PLATFORM ERROR: $error');
    debugPrint('$stack');
    return true;
  };
  await Hive.initFlutter();
  await Hive.openBox('vaultx_records');
  await Hive.openBox('vaultx_audit');
  await Hive.openBox('vaultx_settings');
  await Hive.openBox('vaultx_drive');
  await Hive.openBox('vaultx_intruder');
  await Hive.openBox('vaultx_passwords');
  await Hive.openBox('vaultx_decoy_notes');
  await Hive.openBox('vaultx_decoy_drive');
  await SecurityPlatform.enableScreenProtection();
  final appState = VaultAppState();
  await appState.init();
  final themeProvider = ThemeProvider();
  await themeProvider.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => appState),
        ChangeNotifierProvider(create: (_) => themeProvider),
      ],
      child: const VaultXApp(),
    ),
  );
}

/// Global app state managed via Provider.
/// Tracks onboarding, PIN lockout, and strict offline mode.
///
/// All Hive reads are deferred to an async init so the app starts instantly
/// without blocking the main thread during construction.
class VaultAppState extends ChangeNotifier {
  bool _onboardingComplete = false;
  bool _strictOffline = true;
  int _failedPinAttempts = 0;
  int _failedBiometricAttempts = 0;
  DateTime? _pinLockedUntil;
  bool _initialized = false;
  bool _disposed = false;

  bool get onboardingComplete => _onboardingComplete;
  bool get strictOffline => _strictOffline;
  int get failedPinAttempts => _failedPinAttempts;
  int get failedBiometricAttempts => _failedBiometricAttempts;
  bool get isBiometricEscalated => _failedBiometricAttempts >= 5;
  DateTime? get pinLockedUntil => _pinLockedUntil;
  bool get isPinLocked =>
      _pinLockedUntil != null && DateTime.now().isBefore(_pinLockedUntil!);
  bool get isInitialized => _initialized;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Loads persisted state from Hive asynchronously.
  /// Must be called once after Hive boxes are open.
  Future<void> init() async {
    if (_initialized) return;
    final box = Hive.box('vaultx_settings');
    _onboardingComplete =
        box.get('onboardingComplete', defaultValue: false) as bool;
    _strictOffline = box.get('strictOffline', defaultValue: true) as bool;
    _failedPinAttempts = box.get('failedPinAttempts', defaultValue: 0) as int;
    _failedBiometricAttempts =
        box.get('failedBiometricAttempts', defaultValue: 0) as int;
    final lockRaw = box.get('pinLockedUntil') as String?;
    _pinLockedUntil = lockRaw == null ? null : DateTime.tryParse(lockRaw);
    _initialized = true;
    _safeNotify();
  }

  Future<void> completeOnboarding() async {
    _onboardingComplete = true;
    await Hive.box('vaultx_settings').put('onboardingComplete', true);
    _safeNotify();
  }

  Future<void> setStrictOffline(bool value) async {
    _strictOffline = value;
    await Hive.box('vaultx_settings').put('strictOffline', value);
    _safeNotify();
  }

  Future<void> recordFailedPinAttempt() async {
    _failedPinAttempts++;
    await AuditLog.write('Failed password unlock attempt (PIN/Pass #$_failedPinAttempts)');
    if (_failedPinAttempts >= 5) {
      _pinLockedUntil = DateTime.now().add(const Duration(minutes: 15));
      await Hive.box(
        'vaultx_settings',
      ).put('pinLockedUntil', _pinLockedUntil!.toIso8601String());
      await AuditLog.write('Security escalation: PIN lockout active for 15 minutes');
    }
    await Hive.box(
      'vaultx_settings',
    ).put('failedPinAttempts', _failedPinAttempts);
    _safeNotify();
  }

  Future<void> recordFailedBiometricAttempt() async {
    _failedBiometricAttempts++;
    await AuditLog.write('Failed biometric unlock attempt (#$_failedBiometricAttempts)');
    if (_failedBiometricAttempts >= 5) {
      await AuditLog.write('Security escalation: Biometric mandatory password required');
    }
    await Hive.box('vaultx_settings')
        .put('failedBiometricAttempts', _failedBiometricAttempts);
    _safeNotify();
  }

  Future<void> resetPinAttempts() async {
    _failedPinAttempts = 0;
    _pinLockedUntil = null;
    await Hive.box('vaultx_settings').put('failedPinAttempts', 0);
    await Hive.box('vaultx_settings').delete('pinLockedUntil');
    _safeNotify();
  }

  Future<void> resetBiometricAttempts() async {
    _failedBiometricAttempts = 0;
    await Hive.box('vaultx_settings').put('failedBiometricAttempts', 0);
    _safeNotify();
  }
}

/// Root MaterialApp with theme driven by [ThemeProvider].
class VaultXApp extends StatelessWidget {
  const VaultXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:
          Hive.box(
                'vaultx_settings',
              ).get('decoyCalculatorEnabled', defaultValue: false)
              as bool
          ? 'Calculator'
          : 'VaultX',
      debugShowCheckedModeBanner: false,
      theme: context.watch<ThemeProvider>().themeData,
      builder: (context, child) =>
          FloatingNotificationHost(child: child ?? const SizedBox.shrink()),
      home: const VaultBootstrap(),
    );
  }
}

/// Bootstrapper that decides which screen to show: Onboarding, Setup, or Login.
class VaultBootstrap extends StatefulWidget {
  const VaultBootstrap({super.key});

  @override
  State<VaultBootstrap> createState() => _VaultBootstrapState();
}

class _VaultBootstrapState extends State<VaultBootstrap> {
  final _auth = VaultAuthService();
  bool? _ready;
  bool _appStateReady = false;

  @override
  void initState() {
    super.initState();
    _initAppState();
  }

  Future<void> _initAppState() async {
    final appState = context.read<VaultAppState>();
    await appState.init();
    if (mounted) {
      setState(() => _appStateReady = true);
      _load();
    }
  }

  Future<void> _load() async {
    // Check Dead Man Switch before deciding which screen to show.
    // Wipe-only action will make isInitialized() return false -> SetupScreen.
    await DeadMansService.checkOnLaunch(auth: _auth);

    final initialized = await _auth.isInitialized();
    if (mounted) setState(() => _ready = initialized);
  }

  @override
  Widget build(BuildContext context) {
    if (!_appStateReady || _ready == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!context.watch<VaultAppState>().onboardingComplete) {
      return const OnboardingScreen();
    }
    final decoyCalculator =
        Hive.box(
              'vaultx_settings',
            ).get('decoyCalculatorEnabled', defaultValue: false)
            as bool;
    final isReady = _ready ?? false;
    if (isReady && decoyCalculator) {
      return DecoyCalculatorScreen(auth: _auth);
    }
    return isReady ? LoginScreen(auth: _auth) : SetupScreen(auth: _auth);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../models/auth.dart';
import '../models/app_state.dart';
import '../services/services.dart';
import '../services/auth_session_manager.dart';
import '../theme/themes.dart';
import '../widgets/widgets.dart';
import '../widgets/vault_auth_guard.dart';
import 'screens.dart';

import 'package:vaultx/l10n/app_localizations.dart';

/// App entry point — called after Hive is initialized in main().
Future<void> runVaultX() async {
  debugPrint('STARTUP: runVaultX entered');

  debugPrint('STARTUP: opening Hive boxes');
  const boxNames = [
    'vaultx_records',
    'vaultx_audit',
    'vaultx_settings',
    'vaultx_drive',
    'vaultx_intruder',
    'vaultx_passwords',
    'vaultx_decoy_notes',
    'vaultx_decoy_drive',
  ];
  for (final name in boxNames) {
    try {
      await Hive.openBox(name).timeout(const Duration(seconds: 15));
      debugPrint('STARTUP: box $name opened');
    } catch (e) {
      debugPrint('STARTUP_ERROR: Hive.openBox($name) failed: $e');
    }
  }
  debugPrint('STARTUP: Hive boxes opened');
  StartupDiagnostics.instance.markHiveBoxesOpen();

  Future.microtask(() => SearchIndexService.instance.init());
  Future.microtask(() => SecurityPlatform.enableScreenProtection());

  debugPrint('STARTUP: initializing VaultAppState');
  final appState = VaultAppState();
  try {
    await appState.init().timeout(const Duration(seconds: 10));
    debugPrint('STARTUP: VaultAppState initialized');
  } catch (e) {
    debugPrint('STARTUP_ERROR: VaultAppState.init failed: $e');
  }

  debugPrint('STARTUP: initializing ThemeProvider');
  final themeProvider = ThemeProvider();
  try {
    await themeProvider.init().timeout(const Duration(seconds: 10));
    debugPrint('STARTUP: ThemeProvider initialized');
  } catch (e) {
    debugPrint('STARTUP_ERROR: ThemeProvider.init failed: $e');
  }
  StartupDiagnostics.instance.markAppStateReady();

  debugPrint('STARTUP: calling runApp()');
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => appState),
        ChangeNotifierProvider(create: (_) => themeProvider),
        ChangeNotifierProvider(create: (_) => PasswordManagerProvider()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
      ],
      child: const VaultXApp(),
    ),
  );
  debugPrint('STARTUP: runApp() returned');
}

/// Global app state managed via Provider.
/// Tracks onboarding, PIN lockout, and strict offline mode.
///
/// All Hive reads are deferred to an async init so the app starts instantly
/// without blocking the main thread during construction.

/// Root MaterialApp with theme driven by [ThemeProvider].
class VaultXApp extends StatelessWidget {
  const VaultXApp({super.key});

  @override
  Widget build(BuildContext context) {
    String title;
    try {
      title =
          Hive.box('vaultx_settings').get('decoyCalculatorEnabled', defaultValue: false) as bool
              ? 'Calculator'
              : 'Notex';
    } catch (_) {
      title = 'Notex';
    }
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: context.watch<ThemeProvider>().themeData,
      locale: context.watch<LocaleProvider>().locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          FloatingNotificationHost(
            child: VaultAuthGuard(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
      home: const VaultBootstrap(),
      onGenerateRoute: (settings) {
        final args = settings.arguments as Map<String, dynamic>? ?? {};
        
        switch (settings.name) {
          case NavigationService.routeHome:
            return MaterialPageRoute(builder: (_) => const VaultBootstrap());
          case NavigationService.routeDrive:
            return MaterialPageRoute(
              builder: (_) => DriveScreen(
                auth: args['auth'] as VaultAuthService,
                drive: args['drive'] as DriveService?,
                passwordVault: args['passwordVault'] as PasswordVaultService?,
                itemActions: args['itemActions'] as ItemActionService?,
                isDecoy: args['isDecoy'] as bool? ?? false,
              ),
            );
          case NavigationService.routeSecurity:
            return MaterialPageRoute(
              builder: (_) => SecurityLogsScreen(
                auth: args['auth'] as VaultAuthService,
                isDecoy: args['isDecoy'] as bool? ?? false,
              ),
            );
          case NavigationService.routePasswords:
            return MaterialPageRoute(
              builder: (_) => PasswordManagerScreen(
                service: args['service'] as PasswordVaultService,
              ),
            );
          case NavigationService.routeSettings:
            return MaterialPageRoute(
              builder: (_) => Material(
                child: SettingsScreen(
                  auth: args['auth'] as VaultAuthService,
                  repo: args['repo'] as VaultRepository?,
                  posture: args['posture'] as Map<String, dynamic>? ?? {},
                  onDataChanged: args['onDataChanged'] as Future<void> Function()? ?? () async {},
                  vaultKind: args['vaultKind'] as VaultKind? ?? VaultKind.main,
                  trashService: args['trashService'] as TrashService?,
                  onGoHome: args['onGoHome'] as VoidCallback?,
                ),
              ),
            );
          case NavigationService.routeGame:
            return MaterialPageRoute(builder: (_) => const VaultXGameScreen());
          default:
            return null;
        }
      },
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
    debugPrint('STARTUP: _initAppState entered');
    try {
      final appState = context.read<VaultAppState>();
      debugPrint('STARTUP: about to call appState.init()');
      await appState.init().timeout(const Duration(seconds: 10));
      debugPrint('STARTUP: appState.init() completed');
      if (mounted) {
        setState(() => _appStateReady = true);
        debugPrint('STARTUP: _appStateReady set to true, calling _load()');
        await _load();
      }
    } catch (e, st) {
      debugPrint('STARTUP_ERROR: _initAppState failed: $e');
      debugPrint('$st');
      if (mounted) {
        setState(() {
          _appStateReady = true;
          _ready = false;
        });
      }
    }
  }

  void _initSessionManager() {
    try {
      final minutes = Hive.box('vaultx_settings').get('lockMinutes', defaultValue: 1) as int;
      AuthSessionManager.instance.updateLockMinutes(minutes);
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      debugPrint('STARTUP: _load entered');
      await DeadMansService.checkOnLaunch(auth: _auth).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('STARTUP_TIMEOUT: DeadMansService.checkOnLaunch timed out');
          return DmsCheckResult.none;
        },
      );
      debugPrint('STARTUP: DeadMansService.checkOnLaunch completed');

      _initSessionManager();

      final initialized = await _auth.isInitialized().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('STARTUP_TIMEOUT: _auth.isInitialized() timed out');
          return false;
        },
      );
      debugPrint('STARTUP: _auth.isInitialized() = $initialized');
      if (mounted) setState(() => _ready = initialized);
    } catch (e, st) {
      debugPrint('STARTUP_ERROR: _load failed: $e');
      debugPrint('$st');
      if (mounted) setState(() => _ready = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_appStateReady || _ready == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!context.watch<VaultAppState>().onboardingComplete) {
      return const OnboardingScreen();
    }
    bool decoyCalculator;
    try {
      decoyCalculator =
          Hive.box('vaultx_settings').get('decoyCalculatorEnabled', defaultValue: false) as bool;
    } catch (_) {
      decoyCalculator = false;
    }
    final isReady = _ready ?? false;
    if (isReady && decoyCalculator) {
      return DecoyCalculatorScreen(auth: _auth);
    }
    // Note: VaultAuthGuard handles showing LoginScreen if not authenticated.
    // But we still need to know if the vault is ready/initialized.
    return isReady ? const VaultHomeWrapper() : SetupScreen(auth: _auth);
  }
}

class VaultHomeWrapper extends StatelessWidget {
  const VaultHomeWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthSessionManager.instance,
      builder: (context, _) {
        final session = AuthSessionManager.instance;
        if (session.isAuthenticated) {
          return VaultHome(
            auth: VaultAuthService(),
            authResult: session.sessionAuth!,
          );
        }
        return LoginScreen(auth: VaultAuthService());
      },
    );
  }
}

import 'dart:io' show Directory;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:vaultx/screens/vaultx_app.dart';

Future<void> main() async {
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

  await _initHive();
  await runVaultX();
}

Future<void> _initHive() async {
  debugPrint('STARTUP: initializing Hive');
  try {
    await Hive.initFlutter().timeout(const Duration(seconds: 15));
    debugPrint('STARTUP: Hive initialized via initFlutter');
    return;
  } catch (e) {
    debugPrint('STARTUP_WARN: Hive.initFlutter failed: $e');
  }

  try {
    final dir = await getApplicationDocumentsDirectory();
    Hive.init(dir.path);
    debugPrint('STARTUP: Hive initialized via path_provider: ${dir.path}');
    return;
  } catch (e) {
    debugPrint('STARTUP_WARN: path_provider fallback failed: $e');
  }

  final fallbackDir = Directory.systemTemp.path;
  Hive.init(p.join(fallbackDir, 'vaultx_hive'));
  debugPrint('STARTUP: Hive initialized via system temp: $fallbackDir');
}

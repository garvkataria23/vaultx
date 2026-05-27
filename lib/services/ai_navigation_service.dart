import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../screens/archive_screen.dart';
import '../screens/backup_restore_screen.dart';
import '../screens/drive_tools_screen.dart';
import '../screens/password_manager_screen.dart';
import '../screens/security_logs_screen.dart';
import '../screens/smart_categories_screen.dart';
import '../screens/smart_view_screen.dart';
import '../screens/storage_insights_screen.dart';
import '../screens/trash_screen.dart';
import '../models/models.dart';
import 'services.dart';

enum AIIntent {
  openHome,
  goDrive,
  openSecurity,
  openSettings,
  openGame,
  openBackup,
  openTrash,
  openArchive,
  openPasswords,
  openSecurityLogs,
  openStorageInsights,
  openSmartView,
  openSmartCategories,
  openDriveTools,
  unknown,
}

class IntentParser {
  static AIIntent parse(String query) {
    final lower = query.toLowerCase();

    if (lower.contains('home')) return AIIntent.openHome;
    if (lower.contains('drive') && (lower.contains('tool') || lower.contains('compress') || lower.contains('optimize') || lower.contains('convert'))) return AIIntent.openDriveTools;
    if (lower.contains('drive')) return AIIntent.goDrive;
    if (lower.contains('security')) return AIIntent.openSecurity;
    if (lower.contains('settings')) return AIIntent.openSettings;
    if (lower.contains('game') || lower.contains('play')) return AIIntent.openGame;
    if (lower.contains('backup') || lower.contains('restore')) return AIIntent.openBackup;
    if (lower.contains('trash') || lower.contains('deleted') || lower.contains('bin')) return AIIntent.openTrash;
    if (lower.contains('archive') || lower.contains('archived')) return AIIntent.openArchive;
    if (lower.contains('password') || lower.contains('passwords') || lower.contains('credential')) return AIIntent.openPasswords;
    if (lower.contains('security log') || lower.contains('intruder') || lower.contains('audit')) return AIIntent.openSecurityLogs;
    if (lower.contains('storage') && (lower.contains('insight') || lower.contains('usage') || lower.contains('space'))) return AIIntent.openStorageInsights;
    if (lower.contains('smart view') || lower.contains('smart organized')) return AIIntent.openSmartView;
    if (lower.contains('smart categor') || lower.contains('category')) return AIIntent.openSmartCategories;

    return AIIntent.unknown;
  }
}

class ActionExecutor {
  static Future<bool> execute(BuildContext context, AIIntent intent, {Map<String, dynamic>? arguments}) async {
    final masterKey = arguments?['masterKey'] as Uint8List?;
    final kind = arguments?['vaultKind'] as VaultKind?;
    final authService = arguments?['auth'] as VaultAuthService?;
    final repo = arguments?['repo'] as VaultRepository?;
    final passwordVault = arguments?['passwordVault'] as PasswordVaultService?;
    final isDecoy = arguments?['isDecoy'] as bool? ?? false;
    final drive = arguments?['drive'] as DriveService?;
    final trashService = arguments?['trashService'] as TrashService?;
    final notes = arguments?['notes'] as List<SecureNote>?;
    final blobs = arguments?['blobs'] as EncryptedBlobService?;

    switch (intent) {
      case AIIntent.openHome:
        await NavigationService.navigateTo(context, NavigationService.routeHome, arguments: arguments);
        return true;
      case AIIntent.goDrive:
        await NavigationService.navigateTo(context, NavigationService.routeDrive, arguments: arguments);
        return true;
      case AIIntent.openSecurity:
        await NavigationService.navigateTo(context, NavigationService.routeSecurity, arguments: arguments);
        return true;
      case AIIntent.openSettings:
        await NavigationService.navigateTo(context, NavigationService.routeSettings, arguments: arguments);
        return true;
      case AIIntent.openGame:
        await NavigationService.navigateTo(context, NavigationService.routeGame, arguments: arguments);
        return true;
      case AIIntent.openBackup:
        if (masterKey == null || kind == null || authService == null || repo == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BackupRestoreScreen(
              masterKey: masterKey,
              kind: kind,
              authService: authService,
              repo: repo,
            ),
          ),
        );
        return true;
      case AIIntent.openTrash:
        if (trashService == null || authService == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TrashScreen(
              trashService: trashService,
              auth: authService,
              repo: repo,
            ),
          ),
        );
        return true;
      case AIIntent.openArchive:
        if (repo == null || passwordVault == null || authService == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArchiveScreen(
              repo: repo,
              passwordVault: passwordVault,
              auth: authService,
            ),
          ),
        );
        return true;
      case AIIntent.openPasswords:
        if (passwordVault == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PasswordManagerScreen(
              service: passwordVault,
            ),
          ),
        );
        return true;
      case AIIntent.openSecurityLogs:
        if (authService == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SecurityLogsScreen(
              auth: authService,
              isDecoy: isDecoy,
            ),
          ),
        );
        return true;
      case AIIntent.openStorageInsights:
        if (masterKey == null || kind == null || authService == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StorageInsightsScreen(
              masterKey: masterKey,
              kind: kind,
              authService: authService,
            ),
          ),
        );
        return true;
      case AIIntent.openSmartView:
        if (notes == null || repo == null || blobs == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SmartViewScreen(
              notes: notes,
              repo: repo,
              blobs: blobs,
              vaultKind: kind ?? VaultKind.main,
            ),
          ),
        );
        return true;
      case AIIntent.openSmartCategories:
        if (notes == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SmartCategoriesScreen(
              notes: notes,
            ),
          ),
        );
        return true;
      case AIIntent.openDriveTools:
        if (drive == null) return false;
        if (!context.mounted) return false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DriveToolsScreen(
              drive: drive,
            ),
          ),
        );
        return true;
      case AIIntent.unknown:
        return false;
    }
  }
}

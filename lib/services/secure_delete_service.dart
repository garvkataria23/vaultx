import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'auth_service.dart';
import 'cloud_storage_provider.dart';
import 'google_drive_backup.dart';
import 'mega_backup_service.dart';
import 'temp_file_manager.dart';

/// Orchestrates the irreversible "Delete Everything" process.
class SecureDeleteService {
  /// Completely wipes all local and cloud data.
  /// Requires the user's [password] and the [authService] to validate it.
  /// Updates [onProgress] with the current phase.
  static Future<bool> wipeEverything({
    required String password,
    required VaultAuthService authService,
    required Function(String phase) onProgress,
  }) async {
    try {
      onProgress('Authenticating request...');
      
      // 1. Mandatory Password Confirmation
      final authResult = await authService.unlockWithPassword(password);
      final verified = await authService.verify(authResult);
      if (!verified.ok) {
        return false; // Authentication failed
      }

      // 2. Cloud/Drive Cleanup
      onProgress('Cleaning up cloud backups...');

      Future<void> _wipeProvider(CloudStorageProvider provider) async {
        final signedIn = await provider.signInSilently();
        if (signedIn) {
          await provider.deleteAllBackups();
          await provider.signOut();
        }
      }

      await _wipeProvider(GoogleDriveBackupService(
        authService: authService,
        masterKey: verified.masterKey,
      ));
      await _wipeProvider(MEGABackupService(
        authService: authService,
        masterKey: verified.masterKey,
      ));

      // 3. Local Data Wipe - Directories & Files
      onProgress('Deleting secure media and files...');
      await _deleteDriveBlobs();
      await TempFileManager.instance.clearAll();

      // 4. Local Data Wipe - Hive Databases
      onProgress('Erasing databases...');
      await _wipeHiveBoxes();

      // 5. Auth and Keystore Reset
      onProgress('Clearing secure credentials...');
      await authService.wipeAll();
      await SecurityPlatform.resetAndroidKeystore();

      onProgress('Wipe complete.');
      return true;
    } catch (e, st) {
      debugPrint('SECURE DELETE ERROR: $e\n$st');
      return false; // Wipe partially failed
    }
  }

  static Future<void> _deleteDriveBlobs() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      
      final mainDriveDir = Directory('${docDir.path}/vaultx_drive_main');
      if (await mainDriveDir.exists()) {
        await mainDriveDir.delete(recursive: true);
      }

      final hiddenDriveDir = Directory('${docDir.path}/vaultx_drive_hidden');
      if (await hiddenDriveDir.exists()) {
        await hiddenDriveDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Error deleting drive blobs: $e');
    }
  }

  static Future<void> _wipeHiveBoxes() async {
    final boxesToClear = [
      'vaultx_records',
      'vaultx_drive',
      'vaultx_audit',
      'vaultx_settings',
    ];

    for (final boxName in boxesToClear) {
      try {
        if (Hive.isBoxOpen(boxName)) {
          await Hive.box(boxName).clear();
        } else {
          final box = await Hive.openBox(boxName);
          await box.clear();
        }
      } catch (e) {
        debugPrint('Error clearing Hive box $boxName: $e');
      }
    }
  }
}

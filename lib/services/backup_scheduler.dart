import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import 'auth_service.dart';
import 'backup_change_tracker.dart';
import 'backup_service.dart';
import 'google_drive_backup.dart';
import 'floating_notification_service.dart';

/// Interval options for automatic backups.
enum BackupInterval { daily, weekly, manual }

/// Periodic backup scheduler with retry logic and health tracking.
///
/// Runs a periodic timer (every 15 minutes in check mode) and evaluates whether
/// a backup should be triggered based on:
/// 1. The configured interval (daily/weekly/manual)
/// 2. Whether any tracked data has changed since the last successful backup
/// 3. Retry backoff for consecutive failures
///
/// Tracks backup health via [BackupState] persisted in Hive. Avoids concurrent
/// backups and provides progress reporting.
class BackupScheduler {
  BackupScheduler({
    required this.masterKey,
    required this.kind,
    required this.authService,
    this.onProgress,
  });

  final Uint8List masterKey;
  final VaultKind kind;
  final VaultAuthService authService;
  final BackupProgressCallback? onProgress;

  Timer? _timer;
  bool _running = false;

  /// Whether the scheduler is currently running.
  bool get isRunning => _running;

  /// Current backup health state from Hive.
  BackupState get currentState => BackupState.load();

  /// Start the periodic check timer. Checks every 15 minutes.
  void start() {
    if (_running) return;
    _running = true;
    debugPrint('BACKUP SCHEDULER: started');

    _checkAndBackup();
    _timer = Timer.periodic(const Duration(minutes: 15), (_) {
      _checkAndBackup();
    });
  }

  /// Stop the periodic check timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    debugPrint('BACKUP SCHEDULER: stopped');
  }

  /// Get the configured backup interval from Hive settings.
  static BackupInterval getInterval() {
    final raw = Hive.box('vaultx_settings')
        .get('backupInterval', defaultValue: 'weekly') as String;
    return BackupInterval.values.firstWhere(
      (i) => i.name == raw,
      orElse: () => BackupInterval.weekly,
    );
  }

  /// Set the backup interval in Hive.
  static Future<void> setInterval(BackupInterval interval) async {
    await Hive.box('vaultx_settings').put('backupInterval', interval.name);
  }

  /// Return the interval duration for comparison.
  static Duration intervalDuration(BackupInterval interval) {
    switch (interval) {
      case BackupInterval.daily:
        return const Duration(hours: 24);
      case BackupInterval.weekly:
        return const Duration(days: 7);
      case BackupInterval.manual:
        return Duration.zero;
    }
  }

  /// Check whether auto-backup is enabled.
  static bool isAutoBackupEnabled() {
    final interval = getInterval();
    if (interval == BackupInterval.manual) return false;
    final enabled = Hive.box('vaultx_settings')
        .get('autoBackup', defaultValue: false) as bool;
    return enabled;
  }

  /// Enable or disable auto-backup.
  static Future<void> setAutoBackupEnabled(bool enabled) async {
    await Hive.box('vaultx_settings').put('autoBackup', enabled);
  }

  /// Returns the timestamp of the last successful backup, or null.
  static DateTime? get lastBackupAt {
    final raw = Hive.box('vaultx_settings')
        .get('lastGoogleBackupAt') as String?;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  /// Returns backoff duration based on consecutive failure count.
  static Duration _backoffDuration(int failures) {
    return switch (failures) {
      0 => Duration.zero,
      1 => const Duration(minutes: 30),
      2 => const Duration(hours: 1),
      3 => const Duration(hours: 4),
      4 => const Duration(hours: 8),
      _ => const Duration(days: 1),
    };
  }

  /// Internal check: evaluates all conditions and triggers backup if needed.
  Future<void> _checkAndBackup() async {
    if (!isAutoBackupEnabled()) return;

    // Load current backup state
    var state = BackupState.load();

    // Check if a backup is already in progress
    if (state.isInProgress) {
      // Check if the in-progress flag is stale (> 2 hours old)
      if (state.lastBackupAt != null) {
        final staleSince = DateTime.now().toUtc().difference(state.lastBackupAt!);
        if (staleSince > const Duration(hours: 2)) {
          debugPrint('BACKUP SCHEDULER: clearing stale in-progress flag');
          state = state.copyWith(clearInProgress: true);
          await BackupState.save(state);
        } else {
          debugPrint('BACKUP SCHEDULER: backup already in progress, skipping');
          return;
        }
      } else {
        debugPrint('BACKUP SCHEDULER: backup already in progress, skipping');
        return;
      }
    }

    // Check retry backoff
    if (state.nextRetryAt != null && DateTime.now().toUtc().isBefore(state.nextRetryAt!)) {
      debugPrint('BACKUP SCHEDULER: in retry backoff until ${state.nextRetryAt}');
      return;
    }

    final interval = getInterval();
    final duration = intervalDuration(interval);
    final lastBackup = lastBackupAt;

    if (lastBackup != null) {
      final elapsed = DateTime.now().toUtc().difference(lastBackup);

      // If we have consecutive failures, use a shorter interval for retries
      if (state.consecutiveFailures == 0 && elapsed < duration) {
        debugPrint(
          'BACKUP SCHEDULER: skipping — last backup $elapsed ago, '
          'interval $duration',
        );
        return;
      }
    }

    // Check if any data has changed since last backup
    if (lastBackup != null && !BackupChangeTracker.instance.hasChangesSince(lastBackup)) {
      debugPrint('BACKUP SCHEDULER: skipping — no changes since last backup');
      return;
    }

    debugPrint('BACKUP SCHEDULER: changes detected, starting backup...');

    // Mark backup as in progress
    state = state.copyWith(isInProgress: true);
    await BackupState.save(state);

    try {
      final driveService = GoogleDriveBackupService(
        authService: authService,
        masterKey: masterKey,
      );
      final email = await driveService.restoreSession();
      if (email == null) {
        debugPrint('BACKUP SCHEDULER: not authenticated to Drive, skipping');
        state = state.copyWith(
          clearInProgress: true,
          lastError: 'Not authenticated',
        );
        await BackupState.save(state);
        return;
      }

      final backupService = BackupService(
        masterKey: masterKey,
        kind: kind,
        authService: authService,
      );

      var uploadOk = false;
      var backupSize = 0;

      await driveService.uploadBackup(({bool compressMedia = false}) async {
        final result = await backupService.createBackup(compressMedia: compressMedia);
        backupSize = result.manifest.totalSizeBytes;
        return result.data;
      });

      uploadOk = true;

      if (uploadOk) {
        BackupChangeTracker.instance.clearAll();
        state = state.copyWith(
          lastBackupAt: DateTime.now().toUtc(),
          lastBackupSizeBytes: backupSize,
          consecutiveFailures: 0,
          clearInProgress: true,
          clearError: true,
          nextRetryAt: null,
          totalBackupsCreated: state.totalBackupsCreated + 1,
        );
        await BackupState.save(state);
        FloatingNotificationService.instance.show(
          'Auto-backup completed successfully',
          type: AppNotificationType.success,
        );
        debugPrint('BACKUP SCHEDULER: auto-backup completed successfully (${backupSize}B)');
      }
    } catch (e, st) {
      debugPrint('BACKUP SCHEDULER: auto-backup error: $e\n$st');
      final newFailures = state.consecutiveFailures + 1;
      state = state.copyWith(
        clearInProgress: true,
        consecutiveFailures: newFailures,
        lastError: e.toString(),
        nextRetryAt: DateTime.now().toUtc().add(_backoffDuration(newFailures)),
      );
      await BackupState.save(state);
    }
  }
}

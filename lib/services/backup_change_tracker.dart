import 'package:hive_flutter/hive_flutter.dart';

/// Tracks data changes across VaultX domains for change-based auto-backup.
///
/// Each domain records its last modification timestamp and an estimated
/// change magnitude (byte count). The backup scheduler compares these
/// against the last successful backup time and avoids re-uploading
/// components that have not changed.
///
/// All timestamps are stored in Hive and survive app restarts.
class BackupChangeTracker {
  BackupChangeTracker._();

  static final BackupChangeTracker _instance = BackupChangeTracker._();
  static BackupChangeTracker get instance => _instance;

  static const String _hiveKey = 'backupChangeTimestamps';
  static const String _sizeKey = 'backupChangeSizes';

  /// Mark a domain as changed at the current time.
  void notifyChanged(String domain, {int estimatedBytes = 0}) {
    final timestamps = _load();
    timestamps[domain] = DateTime.now().toUtc().toIso8601String();
    Hive.box('vaultx_settings').put(_hiveKey, timestamps);

    if (estimatedBytes > 0) {
      final sizes = _loadSizes();
      sizes[domain] = (sizes[domain] ?? 0) + estimatedBytes;
      Hive.box('vaultx_settings').put(_sizeKey, sizes);
    }
  }

  void notifyNotesChanged({int estimatedBytes = 0}) =>
    notifyChanged('notes', estimatedBytes: estimatedBytes);

  void notifyDriveChanged({int estimatedBytes = 0}) =>
    notifyChanged('drive', estimatedBytes: estimatedBytes);

  void notifyOcrChanged({int estimatedBytes = 0}) =>
    notifyChanged('ocr', estimatedBytes: estimatedBytes);

  void notifySettingsChanged({int estimatedBytes = 0}) =>
    notifyChanged('settings', estimatedBytes: estimatedBytes);

  void notifyThemeChanged({int estimatedBytes = 0}) =>
    notifyChanged('theme', estimatedBytes: estimatedBytes);

  void notifyHiddenVaultChanged({int estimatedBytes = 0}) =>
    notifyChanged('hiddenVault', estimatedBytes: estimatedBytes);

  void notifyMetadataChanged({int estimatedBytes = 0}) =>
    notifyChanged('metadata', estimatedBytes: estimatedBytes);

  void notifyPasswordManagerChanged({int estimatedBytes = 0}) =>
    notifyChanged('passwordManager', estimatedBytes: estimatedBytes);

  /// Returns the most recent change timestamp across all domains, or null.
  DateTime? get lastChangeAt {
    final timestamps = _load();
    DateTime? latest;
    for (final ts in timestamps.values) {
      final dt = DateTime.tryParse(ts);
      if (dt != null && (latest == null || dt.isAfter(latest))) {
        latest = dt;
      }
    }
    return latest;
  }

  /// Returns true if any domain has changed since [since].
  bool hasChangesSince(DateTime since) {
    final last = lastChangeAt;
    return last != null && last.isAfter(since);
  }

  /// Returns a map of domain → ISO timestamp for all tracked changes.
  Map<String, String> allTimestamps() => Map<String, String>.from(_load());

  /// Returns the estimated total change size in bytes across all domains.
  int get estimatedChangeBytes {
    final sizes = _loadSizes();
    return sizes.values.fold<int>(0, (sum, v) => sum + v);
  }

  /// Returns the set of domains that have changed since [since].
  Set<String> changedDomainsSince(DateTime since) {
    final timestamps = _load();
    final changed = <String>{};
    for (final entry in timestamps.entries) {
      final dt = DateTime.tryParse(entry.value);
      if (dt != null && dt.isAfter(since)) {
        changed.add(entry.key);
      }
    }
    return changed;
  }

  /// Clear all tracked changes (called after successful backup).
  void clearAll() {
    Hive.box('vaultx_settings').put(_hiveKey, <String, String>{});
    Hive.box('vaultx_settings').put(_sizeKey, <String, int>{});
  }

  /// Clear changes for a specific domain.
  void clear(String domain) {
    final timestamps = _load();
    timestamps.remove(domain);
    Hive.box('vaultx_settings').put(_hiveKey, timestamps);
    final sizes = _loadSizes();
    sizes.remove(domain);
    Hive.box('vaultx_settings').put(_sizeKey, sizes);
  }

  Map<String, String> _load() {
    final raw = Hive.box('vaultx_settings').get(_hiveKey);
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return {};
  }

  Map<String, int> _loadSizes() {
    final raw = Hive.box('vaultx_settings').get(_sizeKey);
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), _toInt(v)));
    }
    return {};
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

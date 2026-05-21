import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/auth.dart';
import '../models/password_entry.dart';
import 'audit_log.dart';
import 'backup_change_tracker.dart';
import 'crypto_service.dart';

/// CRUD operations for encrypted password manager entries in Hive storage.
///
/// Uses the same AES-256-GCM encryption pattern as [VaultRepository] but
/// stores entries in a dedicated `vaultx_passwords` box.
class PasswordVaultService {
  PasswordVaultService(Uint8List masterKey, this.kind)
    : masterKey = Uint8List.fromList(masterKey) {
    _instances.add(this);
  }

  final Uint8List masterKey;
  final VaultKind kind;
  final _crypto = CryptoService();
  final _uuid = const Uuid();

  Box get _box => Hive.box('vaultx_passwords');

  String get _prefix => kind == VaultKind.hidden ? 'hidden_pw' : 'main_pw';

  final _decryptCache = <String, PasswordEntry>{};

  static final List<PasswordVaultService> _instances = [];

  /// Invalidates ALL decryption caches for all active password services.
  static void clearAllCaches() {
    for (final instance in _instances) {
      instance.clearCache();
    }
    debugPrint('PW_VAULT: cleared caches for ${_instances.length} instances');
  }

  void clearCache() {
    _decryptCache.clear();
  }

  static Map<String, dynamic> _deepConvert(Map raw) {
    return raw.map((k, v) {
      final key = k.toString();
      if (v is Map) return MapEntry(key, _deepConvert(v));
      if (v is List) return MapEntry(key, _deepConvertList(v));
      return MapEntry(key, v);
    });
  }

  static List<dynamic> _deepConvertList(List raw) {
    return raw.map((v) {
      if (v is Map) return _deepConvert(v);
      if (v is List) return _deepConvertList(v);
      return v;
    }).toList();
  }

  Future<List<PasswordEntry>> loadEntries() async {
    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final k in _box.keys.where(
      (k) => k.toString().startsWith('$_prefix:'),
    )) {
      entries.add(MapEntry(k as String, _deepConvert(_box.get(k) as Map)));
    }

    final toDecryptIndices = <int>[];
    final cachedResults = <int, PasswordEntry>{};
    for (var i = 0; i < entries.length; i++) {
      final raw = entries[i].value;
      final entryId = raw['id'] as String;
      if (_decryptCache.containsKey(entryId)) {
        cachedResults[i] = _decryptCache[entryId]!;
      } else {
        toDecryptIndices.add(i);
      }
    }

    if (toDecryptIndices.isNotEmpty) {
      final batchItems = <BatchItem>[];
      for (final i in toDecryptIndices) {
        final raw = entries[i].value;
        batchItems.add(
          BatchItem(
            noteId: raw['id'] as String,
            salt: raw['salt'] as String,
            payload: Map<String, dynamic>.from(raw['payload'] as Map),
          ),
        );
      }

      final decrypted = await _crypto.decryptJsonBatch(batchItems, masterKey);

      for (var j = 0; j < batchItems.length; j++) {
        final item = batchItems[j];
        final clear = decrypted[j];
        if (clear == null) {
          await AuditLog.write(
            'Skipped unreadable password entry ${item.noteId}',
          );
          continue;
        }
        try {
          final entry = PasswordEntry.fromJson(clear);
          _decryptCache[entry.id] = entry;
          cachedResults[toDecryptIndices[j]] = entry;
        } catch (_) {
          await AuditLog.write(
            'Skipped corrupt password entry ${item.noteId}',
          );
        }
      }
    }

    final result = <PasswordEntry>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = cachedResults[i];
      if (entry != null) result.add(entry);
    }

    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  Future<PasswordEntry> createBlank() async {
    final now = DateTime.now();
    return PasswordEntry(
      id: _uuid.v4(),
      serviceName: '',
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> save(PasswordEntry entry) async {
    final salt = base64Encode(_crypto.randomBytes(16));
    final recordKey = _crypto.deriveRecordKey(masterKey, entry.id, salt);
    final payload = _crypto.encryptJson(entry.toJson(), recordKey);
    await _box.put('$_prefix:${entry.id}', {
      'id': entry.id,
      'salt': salt,
      'payload': payload,
      'backupExcluded': entry.backupExcluded,
    });
    _decryptCache[entry.id] = entry;
    await AuditLog.write('Password entry saved');
    final size = utf8.encode(jsonEncode(entry.toJson())).length;
    BackupChangeTracker.instance.notifyPasswordManagerChanged(
      estimatedBytes: size,
    );
  }

  Future<void> delete(String id) async {
    _decryptCache.remove(id);
    await _box.delete('$_prefix:$id');
    await AuditLog.write('Password entry deleted');
    BackupChangeTracker.instance.notifyPasswordManagerChanged();
  }

  Future<List<PasswordEntry>> loadTrashEntries() async {
    final all = await loadEntries();
    return all.where((e) => e.deleted).toList();
  }

  Future<void> moveToTrash(PasswordEntry entry) async {
    final settingsBox = Hive.box('vaultx_settings');
    final retentionDays = settingsBox.get('trashRetentionDays', defaultValue: 30) as int;
    
    if (retentionDays == 0) {
      await permanentlyDeleteEntry(entry);
      return;
    }

    DateTime? autoDeleteAt = DateTime.now().add(Duration(days: retentionDays));

    final trashedEntry = entry.copyWith(
      deleted: true,
      deletedAt: DateTime.now(),
      autoDeleteAt: autoDeleteAt,
      favorite: false,
      archived: false,
    );
    await save(trashedEntry);
    await AuditLog.write('PASSWORD ENTRY MOVED TO TRASH: ${entry.serviceName}');
  }

  Future<void> restoreEntry(PasswordEntry entry) async {
    final restoredEntry = entry.copyWith(
      deleted: false,
      deletedAt: null,
      autoDeleteAt: null,
    );
    await save(restoredEntry);
    await AuditLog.write('PASSWORD ENTRY RESTORED: ${entry.serviceName}');
  }

  Future<void> permanentlyDeleteEntry(PasswordEntry entry) async {
    await delete(entry.id);
    await AuditLog.write('PASSWORD ENTRY PERMANENTLY DELETED: ${entry.serviceName}');
  }

  Future<void> emptyTrash() async {
    final trash = await loadTrashEntries();
    for (final entry in trash) {
      await permanentlyDeleteEntry(entry);
    }
    await AuditLog.write('PASSWORD TRASH CLEANED');
  }

  PasswordEntry? fromCachedData(String id, String salt, Map<String, dynamic> payload) {
    try {
      final recordKey = _crypto.deriveRecordKey(masterKey, id, salt);
      final clear = _crypto.decryptJson(payload, recordKey);
      return PasswordEntry.fromJson(clear);
    } catch (_) {
      return null;
    }
  }

  /// Exports all encrypted records for backup (deep-converted).
  Map<String, Map<String, dynamic>> exportEncryptedRecords() {
    final records = <String, Map<String, dynamic>>{};
    for (final k in _box.keys.where(
      (k) => k.toString().startsWith('$_prefix:'),
    )) {
      records[k as String] = _deepConvert(_box.get(k) as Map);
    }
    return records;
  }

  /// Count of entries in this vault.
  int get entryCount {
    var count = 0;
    for (final k in _box.keys) {
      if (k.toString().startsWith('$_prefix:')) count++;
    }
    return count;
  }

  /// Load only non-archived (active) password entries.
  Future<List<PasswordEntry>> loadActiveEntries() async {
    final all = await loadEntries();
    return all.where((e) => !e.archived && !e.deleted).toList();
  }

  /// Load only archived password entries.
  Future<List<PasswordEntry>> loadArchivedEntries() async {
    final all = await loadEntries();
    return all.where((e) => e.archived && !e.deleted).toList();
  }

  /// Toggle archive status: archive if not archived, unarchive if archived.
  Future<void> toggleArchive(String id) async {
    final all = await loadEntries();
    final entry = all.where((e) => e.id == id).firstOrNull;
    if (entry == null) return;
    final updated = entry.copyWith(archived: !entry.archived);
    await save(updated);
    final action = updated.archived ? 'ARCHIVED' : 'RESTORED';
    await AuditLog.write('PASSWORD ENTRY $action ${entry.id}');
  }

  /// Count of archived entries.
  Future<int> archivedCount() async {
    final all = await loadEntries();
    return all.where((e) => e.archived).length;
  }
}

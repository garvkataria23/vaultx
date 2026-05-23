import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/auth.dart';
import '../models/drive_file.dart';
import '../models/note.dart';
import 'crypto_service.dart';
import 'package:flutter/foundation.dart';

import 'audit_log.dart';
import 'backup_change_tracker.dart';
import 'search_index_service.dart';

/// CRUD operations for encrypted notes in Hive storage.
///
/// Notes are decrypted in batch via an isolate to avoid blocking the UI.
/// Results are cached by (noteId, salt) so repeated loads are instant.
class VaultRepository {
  /// FIX: Copy masterKey into a new Uint8List owned by this repo.
  /// VaultHome calls _wipeSessionKey() which zeroes the AuthResult's masterKey
  /// bytes on lock. Since Uint8List is passed by reference, this was also
  /// zeroing _repo.masterKey — making every subsequent crypto operation use
  /// an all-zeros key. Copying gives this repo its own bytes, unaffected by
  /// external wipes.
  VaultRepository(Uint8List masterKey, this.kind)
    : masterKey = Uint8List.fromList(masterKey) {
    _instances.add(this);
  }
  final Uint8List masterKey;
  final VaultKind kind;
  final _crypto = CryptoService();
  final _uuid = const Uuid();
  Box get _box => Hive.box('vaultx_records');
  String get _prefix => kind == VaultKind.hidden ? 'hidden' : 'main';

  /// Caches decrypted note JSON by composite key "noteId:salt" to avoid
  /// re-decrypting notes that haven't changed.
  final _decryptCache = <String, Map<String, dynamic>>{};

  static final List<VaultRepository> _instances = [];

  /// Invalidates ALL decryption caches for all active repositories.
  /// Must be called after a restore or bulk external modification.
  static void clearAllCaches() {
    for (final instance in _instances) {
      instance.clearCache();
    }
  }

  /// Clears the internal decryption cache for this repository instance.
  void clearCache() {
    _decryptCache.clear();
  }

  /// FIX: Deep-converts any nested Map (including Hive's LinkedMap&lt;dynamic,dynamic&gt;)
  /// to Map&lt;String, dynamic&gt; recursively. This is critical for the backup
  /// round-trip: Hive stores maps with dynamic keys, and when serialized to
  /// JSON and back, nested maps must be fully typed or decryption will fail
  /// because payload fields like 'nonce' and 'ct' cannot be cast correctly.
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

  Future<List<SecureNote>> loadNotes() async {
    final allKeys = _box.keys.map((k) => k.toString()).toList();
    final prefix = '$_prefix:';
    final matchedKeys = allKeys.where((k) => k.startsWith(prefix) && !k.startsWith('${prefix}folder_metadata:')).toList();

    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final k in matchedKeys) {
      final val = _box.get(k);
      if (val is Map) {
        entries.add(MapEntry(k, _deepConvert(val)));
      }
    }

    // Build cache keys and collect indices that need decryption.
    final toDecryptIndices = <int>[];
    final cachedResults = <int, Map<String, dynamic>>{};
    for (var i = 0; i < entries.length; i++) {
      final raw = entries[i].value;
      final noteId = raw['id'] as String?;
      final salt = raw['salt'] as String?;
      
      if (noteId == null || salt == null) {
        continue;
      }

      final cacheKey = '$noteId:$salt';
      if (_decryptCache.containsKey(cacheKey)) {
        cachedResults[i] = _decryptCache[cacheKey]!;
      } else {
        toDecryptIndices.add(i);
      }
    }

    // Batch-decrypt only the entries not already cached.
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
            'Skipped unreadable encrypted record ${item.noteId}',
          );
          continue;
        }
        final cacheKey = '${item.noteId}:${item.salt}';
        _decryptCache[cacheKey] = clear;
        cachedResults[toDecryptIndices[j]] = clear;
      }
    }

    final expiredKeys = <String>[];
    final notes = <SecureNote>[];
    for (var i = 0; i < entries.length; i++) {
      final clear = cachedResults[i];
      if (clear == null) continue;
      try {
        final note = SecureNote.fromJson(clear);
        if (note.deleted) continue; // Skip deleted notes in normal load
        if (note.expiresAt != null && DateTime.now().isAfter(note.expiresAt!)) {
          expiredKeys.add(entries[i].key);
          continue;
        }
        notes.add(note);
      } catch (_) {
        final raw = entries[i].value;
        await AuditLog.write(
          'Skipped unreadable encrypted record ${raw['id']}',
        );
      }
    }

    if (expiredKeys.isNotEmpty) {
      _box.deleteAll(expiredKeys);
      for (final k in expiredKeys) {
        final noteId = k.split(':').last;
        _decryptCache.removeWhere((key, _) => key.startsWith('$noteId:'));
      }
      await AuditLog.write('Deleted ${expiredKeys.length} expired note(s)');
    }

    notes.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return notes;
  }

  Future<List<SecureNote>> loadTrashNotes() async {
    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    final folderPrefix = '$_prefix:folder_metadata:';
    for (final k in _box.keys.where(
      (k) => k.toString().startsWith('$_prefix:') && !k.toString().startsWith(folderPrefix),
    )) {
      final val = _box.get(k);
      if (val is Map) {
        entries.add(MapEntry(k as String, _deepConvert(val)));
      }
    }

    final trash = <SecureNote>[];
    for (final entry in entries) {
      final raw = entry.value;
      final noteId = raw['id'] as String?;
      final salt = raw['salt'] as String?;
      
      if (noteId == null || salt == null) continue;

      final cacheKey = '$noteId:$salt';
      
      Map<String, dynamic>? clear;
      if (_decryptCache.containsKey(cacheKey)) {
        clear = _decryptCache[cacheKey];
      } else {
        final recordKey = _crypto.deriveRecordKey(masterKey, noteId, salt);
        try {
          clear = _crypto.decryptJson(Map<String, dynamic>.from(raw['payload'] as Map), recordKey);
          _decryptCache[cacheKey] = clear;
        } catch (_) {}
      }

      if (clear != null) {
        try {
          final note = SecureNote.fromJson(clear);
          if (note.deleted) trash.add(note);
        } catch (_) {}
      }
    }
    trash.sort((a, b) => b.deletedAt?.compareTo(a.deletedAt ?? DateTime.now()) ?? 0);
    return trash;
  }

  /// Loads metadata for logical folders used by notes.
  Future<List<SecureDriveFolder>> loadFolderMetadata() async {
    final folders = <SecureDriveFolder>[];
    final prefix = '$_prefix:folder_metadata:';
    for (final k in _box.keys.where((k) => k.toString().startsWith(prefix))) {
      final raw = _box.get(k);
      if (raw is Map) {
        folders.add(SecureDriveFolder.fromJson(_deepConvert(raw)));
      }
    }
    return folders;
  }

  /// Saves metadata for a logical folder.
  Future<void> saveFolderMetadata(SecureDriveFolder folder) async {
    final key = '$_prefix:folder_metadata:${folder.name}';
    await _box.put(key, folder.toJson());
    await AuditLog.write('Folder metadata saved: ${folder.name}');
  }

  Future<SecureNote> createBlank(NoteType type) async {
    final now = DateTime.now();
    final box = Hive.box('vaultx_settings');
    final backupDefault = box.get('backupNewNotesByDefault', defaultValue: true) as bool;
    
    return SecureNote(
      id: _uuid.v4(),
      title: 'Untitled',
      body: '',
      type: type,
      createdAt: now,
      updatedAt: now,
      backupExcluded: !backupDefault,
    );
  }

  Future<void> save(SecureNote note) async {
    final salt = base64Encode(_crypto.randomBytes(16));

    final recordKey = _crypto.deriveRecordKey(masterKey, note.id, salt);
    final payload = _crypto.encryptJson(note.toJson(), recordKey);
    await _box.put('$_prefix:${note.id}', {
      'id': note.id,
      'salt': salt,
      'payload': payload,
      'backupExcluded': note.backupExcluded,
      'folder': note.folder,
      'updatedAt': note.updatedAt.toIso8601String(), // For efficient merging
    });
    // Invalidate ALL cache entries for this note (new salt = new cache key)
    _decryptCache.removeWhere((key, _) => key.startsWith('${note.id}:'));
    await SearchIndexService.instance.indexNote(note);
    await AuditLog.write('Encrypted note saved');
    final size = utf8.encode(jsonEncode(note.toJson())).length;
    BackupChangeTracker.instance.notifyNotesChanged(estimatedBytes: size);
  }

  Future<void> saveAll(List<SecureNote> notes) async {
    final Map<String, dynamic> batch = {};
    int totalSize = 0;

    for (final note in notes) {
      final salt = base64Encode(_crypto.randomBytes(16));
      final recordKey = _crypto.deriveRecordKey(masterKey, note.id, salt);
      final payload = _crypto.encryptJson(note.toJson(), recordKey);
      
      batch['$_prefix:${note.id}'] = {
        'id': note.id,
        'salt': salt,
        'payload': payload,
        'backupExcluded': note.backupExcluded,
        'folder': note.folder,
        'updatedAt': note.updatedAt.toIso8601String(), // For efficient merging
      };
      
      _decryptCache.removeWhere((key, _) => key.startsWith('${note.id}:'));
      await SearchIndexService.instance.indexNote(note);
      totalSize += utf8.encode(jsonEncode(note.toJson())).length;
    }

    await _box.putAll(batch);
    await AuditLog.write('Batch of ${notes.length} notes saved');
    BackupChangeTracker.instance.notifyNotesChanged(estimatedBytes: totalSize);
  }

  Future<void> moveToTrash(SecureNote note) async {
    final settingsBox = Hive.box('vaultx_settings');
    final retentionDays = settingsBox.get('trashRetentionDays', defaultValue: 30) as int;
    
    if (retentionDays == 0) {
      await permanentlyDeleteNote(note);
      return;
    }

    DateTime? autoDeleteAt = DateTime.now().add(Duration(days: retentionDays));

    final trashedNote = note.markDeleted(autoDeleteAt: autoDeleteAt);
    await save(trashedNote);
    await AuditLog.write('ITEM MOVED TO TRASH: ${note.title} (${note.id})');
  }

  Future<void> restoreNote(SecureNote note) async {
    final restoredNote = note.copyWith(
      deleted: false,
      deletedAt: null,
      autoDeleteAt: null,
    );
    await save(restoredNote);
    await AuditLog.write('ITEM RESTORED: ${note.title} (${note.id})');
  }

  Future<void> permanentlyDeleteNote(SecureNote note) async {
    for (final attachment in note.attachments) {
      await EncryptedBlobService.secureDeletePath(attachment.encryptedPath);
    }
    await _deletePermanently(note.id);
    await AuditLog.write('ITEM PERMANENTLY DELETED: ${note.title} (${note.id})');
  }

  Future<void> emptyTrash() async {
    final trash = await loadTrashNotes();
    for (final note in trash) {
      await permanentlyDeleteNote(note);
    }
    await AuditLog.write('Trash emptied');
  }

  Future<void> _deletePermanently(String id) async {
    // Remove all cache entries for this note
    _decryptCache.removeWhere((key, _) => key.startsWith('$id:'));
    await SearchIndexService.instance.removeNote(id);
    await _box.delete('$_prefix:$id');
    BackupChangeTracker.instance.notifyNotesChanged();
  }

  Future<void> delete(String id) async {
    // We search for the note first to move it to trash.
    // If we can't find it or it's already in trash, we might do nothing or perm delete.
    // For simplicity, let's assume UI calls moveToTrash for existing notes.
    // This 'delete' might be called from places expecting permanent deletion (like sync).
    // Let's keep 'delete' as permanent for now but maybe rename it to _deletePermanently internally.
    await _deletePermanently(id);
    await AuditLog.write('Encrypted note deleted permanently');
  }

  Future<void> secureDelete(SecureNote note) async {
    await permanentlyDeleteNote(note);
  }
}

class EncryptedBlobService {
  /// FIX: Same copy-on-construct pattern as VaultRepository.
  /// Prevents external key wipes from corrupting blob encryption.
  EncryptedBlobService(Uint8List masterKey)
    : masterKey = Uint8List.fromList(masterKey);
  final Uint8List masterKey;
  final _crypto = CryptoService();
  final _uuid = const Uuid();

  Future<SecureAttachment?> pickAndEncryptFile(String noteId) async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    return _writeEncryptedBlob(
      ownerId: noteId,
      name: file.name,
      bytes: bytes,
      kind: 'file',
    );
  }

  Future<SecureAttachment> encryptExistingFile({
    required String ownerId,
    required String name,
    required String path,
    required String kind,
    Duration? duration,
  }) async {
    return _writeEncryptedBlob(
      ownerId: ownerId,
      name: name,
      bytes: await File(path).readAsBytes(),
      kind: kind,
      duration: duration,
    );
  }

  Future<SecureAttachment> encryptMemoryBlob({
    required String ownerId,
    required String name,
    required List<int> bytes,
    required String kind,
    Duration? duration,
  }) async {
    return _writeEncryptedBlob(
      ownerId: ownerId,
      name: name,
      bytes: bytes,
      kind: kind,
      duration: duration,
    );
  }

  Future<Uint8List> decryptAttachmentToBytes(
    String noteId,
    SecureAttachment attachment,
  ) async {
    final encrypted = await File(attachment.encryptedPath).readAsBytes();
    final key = _crypto.deriveRecordKey(
      masterKey,
      '$noteId:${attachment.id}',
      attachment.salt,
    );
    final clearBytes = encrypted.length > 102400
        ? await _crypto.decryptBytesIsolate(encrypted, key)
        : _crypto.decryptBytes(encrypted, key);
    return Uint8List.fromList(clearBytes);
  }

  Future<String> decryptAttachmentToTemp(
    String noteId,
    SecureAttachment attachment,
  ) async {
    final encrypted = await File(attachment.encryptedPath).readAsBytes();
    final key = _crypto.deriveRecordKey(
      masterKey,
      '$noteId:${attachment.id}',
      attachment.salt,
    );
    final clear = encrypted.length > 102400
        ? await _crypto.decryptBytesIsolate(encrypted, key)
        : _crypto.decryptBytes(encrypted, key);
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/vaultx_exports',
    );
    await dir.create(recursive: true);
    final safeName = attachment.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final out = File('${dir.path}/$safeName');
    await out.writeAsBytes(clear, flush: true);
    _crypto.wipe(clear);
    await AuditLog.write(
      'Attachment decrypted to temporary export after authentication',
    );
    return out.path;
  }

  Future<SecureAttachment> _writeEncryptedBlob({
    required String ownerId,
    required String name,
    required List<int> bytes,
    required String kind,
    Duration? duration,
  }) async {
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/vaultx_blobs',
    );
    await dir.create(recursive: true);
    final id = _uuid.v4();
    final salt = base64Encode(_crypto.randomBytes(16));
    final key = _crypto.deriveRecordKey(masterKey, '$ownerId:$id', salt);
    final encrypted = bytes.length > 102400
        ? await _crypto.encryptBytesIsolate(bytes, key)
        : _crypto.encryptBytes(bytes, key);
    final out = File('${dir.path}/$id.vxblob');
    await out.writeAsBytes(encrypted, flush: true);
    return SecureAttachment(
      id: id,
      name: name,
      encryptedPath: out.path,
      salt: salt,
      size: bytes.length,
      createdAt: DateTime.now(),
      kind: kind,
      duration: duration,
    );
  }

  static Future<void> secureDeletePath(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final length = await file.length();
      final sink = file.openSync(mode: FileMode.write);
      sink.writeFromSync(Uint8List(length));
      sink.flushSync();
      sink.closeSync();
      await file.delete();
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<void> cleanupTempExports() async {
    try {
      final tempPath = (await getTemporaryDirectory()).path;
      for (final name in ['vaultx_exports', 'VaultX_Exports']) {
        final dir = Directory('$tempPath/$name');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}

class FileWrite {
  static Future<void> writeText(String path, String value) async {
    await File(path).writeAsString(value, flush: true);
  }
}

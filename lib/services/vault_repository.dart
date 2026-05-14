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
    : masterKey = Uint8List.fromList(masterKey);
  final Uint8List masterKey;
  final VaultKind kind;
  final _crypto = CryptoService();
  final _uuid = const Uuid();
  Box get _box => Hive.box('vaultx_records');
  String get _prefix => kind == VaultKind.hidden ? 'hidden' : 'main';

  /// Caches decrypted note JSON by composite key "noteId:salt" to avoid
  /// re-decrypting notes that haven't changed.
  final _decryptCache = <String, Map<String, dynamic>>{};

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
    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final k in _box.keys.where(
      (k) => k.toString().startsWith('$_prefix:'),
    )) {
      entries.add(MapEntry(k as String, _deepConvert(_box.get(k) as Map)));
    }

    // Build cache keys and collect indices that need decryption.
    final toDecryptIndices = <int>[];
    final cachedResults = <int, Map<String, dynamic>>{};
    for (var i = 0; i < entries.length; i++) {
      final raw = entries[i].value;
      final noteId = raw['id'] as String;
      final salt = raw['salt'] as String;
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
        if (note.expiresAt != null && DateTime.now().isAfter(note.expiresAt!)) {
          expiredKeys.add(entries[i].key);
          continue;
        }
        notes.add(note);
      } catch (_) {
        await AuditLog.write(
          'Skipped unreadable encrypted record ${entries[i].value['id']}',
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
    });
    // Invalidate ALL cache entries for this note (new salt = new cache key)
    _decryptCache.removeWhere((key, _) => key.startsWith('${note.id}:'));
    await AuditLog.write('Encrypted note saved');
    final size = utf8.encode(jsonEncode(note.toJson())).length;
    BackupChangeTracker.instance.notifyNotesChanged(estimatedBytes: size);
  }

  Future<void> delete(String id) async {
    // Remove all cache entries for this note
    _decryptCache.removeWhere((key, _) => key.startsWith('$id:'));
    await _box.delete('$_prefix:$id');
    await AuditLog.write('Encrypted note deleted');
    BackupChangeTracker.instance.notifyNotesChanged();
  }

  Future<void> secureDelete(SecureNote note) async {
    for (final attachment in note.attachments) {
      await EncryptedBlobService.secureDeletePath(attachment.encryptedPath);
    }
    await delete(note.id);
    await AuditLog.write('Encrypted note blobs shredded where supported');
  }

  Future<String> exportEncryptedBackup() async {
    final dir = await getApplicationDocumentsDirectory();
    final fileName =
        'vaultx_${kind.name}_${DateTime.now().millisecondsSinceEpoch}.vxbak';
    final file = '${dir.path}/$fileName';
    final notes = await loadNotes();
    final blobs = <String, String>{};
    for (final note in notes) {
      for (final attachment in note.attachments) {
        final blobFile = File(attachment.encryptedPath);
        if (await blobFile.exists()) {
          blobs[attachment.id] = base64Encode(await blobFile.readAsBytes());
        }
      }
    }
    final backup = {
      'format': 'VaultX encrypted backup',
      'version': 2,
      'vault': kind.name,
      'createdAt': DateTime.now().toIso8601String(),
      // FIX: Deep-convert all Hive records before serializing to JSON.
      // Hive returns LinkedMap<dynamic,dynamic>; nested payload maps (with
      // 'nonce', 'ct', 'alg' fields) must be Map<String,dynamic> or
      // jsonEncode will produce wrong output and decryption will fail on restore.
      'records': Map.fromEntries(
        _box.keys
            .where((k) => k.toString().startsWith('$_prefix:'))
            .map(
              (k) => MapEntry(k.toString(), _deepConvert(_box.get(k) as Map)),
            ),
      ),
      'blobs': blobs,
      'integrity': {'recordCount': notes.length, 'blobCount': blobs.length},
    };
    await FileWrite.writeText(file, jsonEncode(backup));
    await AuditLog.write('Encrypted local backup exported');
    return file;
  }

  Future<Map<String, dynamic>> exportEncryptedBackupMap() async {
    final notes = await loadNotes();
    final blobs = <String, String>{};
    for (final note in notes) {
      for (final attachment in note.attachments) {
        final blobFile = File(attachment.encryptedPath);
        if (await blobFile.exists()) {
          blobs[attachment.id] = base64Encode(await blobFile.readAsBytes());
        }
      }
    }
    return {
      'format': 'VaultX encrypted backup',
      'version': 2,
      'vault': kind.name,
      'createdAt': DateTime.now().toIso8601String(),
      // FIX: Deep-convert all Hive records before upload to Google Drive.
      // Without this, Hive's LinkedMap<dynamic,dynamic> gets serialized
      // incorrectly, and the nested payload (nonce/ct) cannot be decoded
      // on restore, causing InvalidCipherTextException on every record.
      'records': Map.fromEntries(
        _box.keys
            .where((k) => k.toString().startsWith('$_prefix:'))
            .map(
              (k) => MapEntry(k.toString(), _deepConvert(_box.get(k) as Map)),
            ),
      ),
      'blobs': blobs,
      'integrity': {'recordCount': notes.length, 'blobCount': blobs.length},
    };
  }

  Future<int> restoreEncryptedBackup(String filePath) async {
    final backup =
        jsonDecode(await File(filePath).readAsString()) as Map<String, dynamic>;
    return _importBackup(backup);
  }

  Future<int> restoreEncryptedBackupFromMap(Map<String, dynamic> backup) async {
    return _importBackup(backup);
  }

  Future<int> _importBackup(Map<String, dynamic> backup) async {
    debugPrint("");
    debugPrint("==========================================");
    debugPrint("========== RESTORE STARTED ===============");
    debugPrint("==========================================");

    debugPrint("BACKUP FORMAT => ${backup['format']}");
    debugPrint("BACKUP VERSION => ${backup['version']}");
    debugPrint("BACKUP VAULT => ${backup['vault']}");

    if (backup['format'] != 'VaultX encrypted backup' ||
        (backup['version'] != 1 && backup['version'] != 2)) {
      debugPrint("INVALID BACKUP FORMAT");

      throw const FormatException('Unsupported VaultX backup');
    }

    // FIX: Deep-convert the records map coming back from JSON decode.
    // jsonDecode returns Map<String, dynamic> at the top level but nested
    // maps (the payload with 'nonce', 'ct') may be Map<String, dynamic>
    // already from JSON — but we deep-convert defensively to guarantee
    // all levels are properly typed before passing to decryptJson.
    final rawRecords = backup['records'] as Map;
    final records = rawRecords.map(
      (k, v) => MapEntry(k.toString(), _deepConvert(v as Map)),
    );

    debugPrint("TOTAL RECORDS => ${records.length}");

    final blobs = Map<String, dynamic>.from(
      backup['blobs'] as Map? ?? const {},
    );

    debugPrint("TOTAL BLOBS => ${blobs.length}");

    final expectedPrefix = '$_prefix:';

    debugPrint("EXPECTED PREFIX => $expectedPrefix");

    var imported = 0;

    final docDir = await getApplicationDocumentsDirectory();

    for (final entry in records.entries) {
      debugPrint("");
      debugPrint("================================");
      debugPrint("PROCESSING ENTRY");
      debugPrint("ENTRY KEY => ${entry.key}");
      debugPrint("================================");

      if (!entry.key.startsWith(expectedPrefix)) {
        debugPrint("SKIPPED => PREFIX MISMATCH");

        continue;
      }

      try {
        // entry.value is already deep-converted above
        final raw = entry.value;

        final noteId = raw['id'] as String;

        debugPrint("NOTE ID => $noteId");

        final noteSalt = raw['salt'] as String;

        debugPrint("NOTE SALT => $noteSalt");

        debugPrint("GENERATING RECORD KEY");

        final recordKey = _crypto.deriveRecordKey(masterKey, noteId, noteSalt);

        debugPrint("RECORD KEY GENERATED");

        Map<String, dynamic> clear;

        try {
          debugPrint("STARTING DECRYPT");

          // payload is already Map<String, dynamic> from _deepConvert
          clear = _crypto.decryptJson(
            raw['payload'] as Map<String, dynamic>,
            recordKey,
          );

          debugPrint("DECRYPT SUCCESS");

          debugPrint("DECRYPTED JSON => $clear");
        } catch (e, st) {
          debugPrint("");
          debugPrint("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
          debugPrint("DECRYPT FAILED");
          debugPrint("ERROR => $e");
          debugPrint("STACK => $st");
          debugPrint("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");

          continue;
        }

        debugPrint("CREATING SECURE NOTE");

        final note = SecureNote.fromJson(clear);

        debugPrint("NOTE CREATED SUCCESSFULLY");

        debugPrint("NOTE TITLE => ${note.title}");
        debugPrint("NOTE BODY => ${note.body}");
        debugPrint("NOTE TYPE => ${note.type}");
        debugPrint("NOTE CREATED => ${note.createdAt}");
        debugPrint("NOTE UPDATED => ${note.updatedAt}");

        final restoredAttachments = <SecureAttachment>[];

        debugPrint("TOTAL ATTACHMENTS => ${note.attachments.length}");

        for (final attachment in note.attachments) {
          debugPrint("");
          debugPrint("PROCESSING ATTACHMENT");
          debugPrint("ATTACHMENT ID => ${attachment.id}");
          debugPrint("ATTACHMENT NAME => ${attachment.name}");

          final blob = blobs[attachment.id] as String?;

          if (blob == null) {
            debugPrint("ATTACHMENT BLOB MISSING => ${attachment.id}");

            restoredAttachments.add(attachment);

            continue;
          }

          final dir = Directory('${docDir.path}/vaultx_blobs');

          await dir.create(recursive: true);

          final out = File('${dir.path}/${attachment.id}.vxblob');

          await out.writeAsBytes(base64Decode(blob));

          restoredAttachments.add(attachment.copyWith(encryptedPath: out.path));

          debugPrint("ATTACHMENT RESTORED => ${attachment.id}");
        }

        debugPrint("SAVING NOTE TO HIVE");

        await save(note.copyWith(attachments: restoredAttachments));

        debugPrint("NOTE SAVED SUCCESSFULLY");

        imported++;

        debugPrint("CURRENT IMPORT COUNT => $imported");
      } catch (e, st) {
        debugPrint("");
        debugPrint("################################");
        debugPrint("IMPORT ERROR");
        debugPrint("ERROR => $e");
        debugPrint("STACK => $st");
        debugPrint("################################");
      }
    }

    debugPrint("");
    debugPrint("==========================================");
    debugPrint("TOTAL IMPORTED => $imported");
    debugPrint("========== RESTORE COMPLETE ==============");
    debugPrint("==========================================");

    await AuditLog.write('Encrypted backup restored: $imported records');

    return imported;
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
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/vaultx_exports',
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

class FileWrite {
  static Future<void> writeText(String path, String value) async {
    await File(path).writeAsString(value, flush: true);
  }
}

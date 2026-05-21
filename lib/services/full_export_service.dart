import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'audit_log.dart';

class FullExportService {
  FullExportService._();
  static final FullExportService instance = FullExportService._();

  static const String exportRoot = 'VaultX_Export';

  /// Creates a comprehensive ZIP export of the entire vault.
  /// 
  /// Structure:
  /// VaultX_Export/
  ///   notes_json/        (Decrypted main notes in JSON)
  ///   notes_txt/         (Human readable main notes in TXT)
  ///   hidden_vault/
  ///     hidden_json/     (Decrypted hidden notes in JSON)
  ///     hidden_txt/      (Human readable hidden notes in TXT)
  ///   images/            (Decrypted image files)
  ///   videos/            (Decrypted video files)
  ///   audio/             (Decrypted audio files)
  ///   pdf/               (Decrypted PDF files)
  ///   files/             (Decrypted other files)
  ///   folders/           (Folder metadata)
  ///   metadata/          (Raw Hive records for restore, settings, passwords)
  ///   vault_data.json    (Manifest)
  Future<String?> createFullExportZip({
    required Uint8List masterKey,
    required VaultAuthService authService,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final docDir = await getApplicationDocumentsDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final zipPath = '${tempDir.path}/VaultX_Full_Export_$timestamp.zip';

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    final crypto = CryptoService();
    final recordsBox = Hive.box('vaultx_records');
    final driveBox = Hive.box('vaultx_drive');
    final settingsBox = Hive.box('vaultx_settings');
    final passwordsBox = Hive.box('vaultx_passwords');

    int notesCount = 0;
    int hiddenNotesCount = 0;
    int filesCount = 0;

    try {
      // 1. Export Notes (Main)
      final mainNotesRaw = _collectRawRecords(recordsBox, 'main');
      for (final raw in mainNotesRaw) {
        try {
          final id = raw['id'] as String;
          final salt = raw['salt'] as String;
          final payload = Map<String, dynamic>.from(raw['payload'] as Map);
          final recordKey = crypto.deriveRecordKey(masterKey, id, salt);
          final clear = crypto.decryptJson(payload, recordKey);
          final note = SecureNote.fromJson(clear);
          final safeTitle = _getSafeFileName(note.title, id);
          
          // JSON Export
          final jsonBytes = utf8.encode(jsonEncode(clear));
          encoder.addArchiveFile(ArchiveFile('$exportRoot/notes_json/$safeTitle.json', jsonBytes.length, jsonBytes));
          
          // TXT Export (Human readable)
          final txtContent = _generateReadableTxt(note);
          final txtBytes = utf8.encode(txtContent);
          encoder.addArchiveFile(ArchiveFile('$exportRoot/notes_txt/$safeTitle.txt', txtBytes.length, txtBytes));
          
          // Save raw record for restore
          final rawBytes = utf8.encode(jsonEncode(raw));
          encoder.addArchiveFile(ArchiveFile('$exportRoot/metadata/raw_notes/main/$id.json', rawBytes.length, rawBytes));
          
          notesCount++;
        } catch (e) {
          debugPrint('FullExport: failed to process main note ${raw['id']}: $e');
        }
      }

      // 2. Export Notes (Hidden)
      final hiddenNotesRaw = _collectRawRecords(recordsBox, 'hidden');
      for (final raw in hiddenNotesRaw) {
        try {
          final id = raw['id'] as String;
          final salt = raw['salt'] as String;
          final payload = Map<String, dynamic>.from(raw['payload'] as Map);
          final recordKey = crypto.deriveRecordKey(masterKey, id, salt);
          final clear = crypto.decryptJson(payload, recordKey);
          final note = SecureNote.fromJson(clear);
          final safeTitle = _getSafeFileName(note.title, id);
          
          // JSON Export
          final jsonBytes = utf8.encode(jsonEncode(clear));
          encoder.addArchiveFile(ArchiveFile('$exportRoot/hidden_vault/hidden_json/$safeTitle.json', jsonBytes.length, jsonBytes));
          
          // TXT Export (Human readable)
          final txtContent = _generateReadableTxt(note);
          final txtBytes = utf8.encode(txtContent);
          encoder.addArchiveFile(ArchiveFile('$exportRoot/hidden_vault/hidden_txt/$safeTitle.txt', txtBytes.length, txtBytes));
          
          // Save raw record for restore
          final rawBytes = utf8.encode(jsonEncode(raw));
          encoder.addArchiveFile(ArchiveFile('$exportRoot/metadata/raw_notes/hidden/$id.json', rawBytes.length, rawBytes));
          
          hiddenNotesCount++;
        } catch (e) {
          debugPrint('FullExport: failed to process hidden note ${raw['id']}: $e');
        }
      }

      // 3. Export Drive Files and Blobs (Decrypted)
      final Map<String, String> blobToDir = {};
      for (final prefix in ['main', 'hidden']) {
        final driveRaw = _collectRawRecords(driveBox, prefix);
        for (final raw in driveRaw) {
          try {
            final file = SecureDriveFile.fromJson(Map<String, dynamic>.from(raw));

            // Metadata (always preserved for restore)
            final jsonBytes = utf8.encode(jsonEncode(file.toJson()));
            encoder.addArchiveFile(ArchiveFile('$exportRoot/metadata/drive/${prefix}_${file.id}.json', jsonBytes.length, jsonBytes));

            // Blob -> Decrypt and add as real file
            final blobPath = file.encryptedPath;
            if (await File(blobPath).exists()) {
              final folder = _getFolderByKind(file.kind);
              final key = crypto.deriveRecordKey(masterKey, '$prefix:${file.id}', file.salt);
              final encryptedBytes = await File(blobPath).readAsBytes();

              final clearBytes = encryptedBytes.length > 102400
                  ? await crypto.decryptBytesIsolate(encryptedBytes, key)
                  : crypto.decryptBytes(encryptedBytes, key);
              
              final safeName = _getSafeFileName(file.name, file.id, includeExtension: true);
              encoder.addArchiveFile(ArchiveFile('$exportRoot/$folder/$safeName', clearBytes.length, clearBytes));

              blobToDir[file.id] = prefix == 'hidden' ? 'vaultx_drive_hidden' : 'vaultx_drive_main';
              filesCount++;
            }
          } catch (e) {
            debugPrint('FullExport: failed to process $prefix drive file: $e');
          }
        }
      }

      // 4. Export Attachment Blobs (Decrypted)
      final allNotesRaw = [..._collectRawRecords(recordsBox, 'main'), ..._collectRawRecords(recordsBox, 'hidden')];
      final attachmentDir = Directory('${docDir.path}/vaultx_blobs');

      if (await attachmentDir.exists()) {
        final blobFiles = await attachmentDir.list().where((e) => e is File && e.path.endsWith('.vxblob')).toList();
        for (final entity in blobFiles) {
          final fileEntity = entity as File;
          final blobId = fileEntity.uri.pathSegments.last.replaceAll('.vxblob', '');

          // Find owner note and attachment metadata
          SecureNote? owner;
          SecureAttachment? attachment;
          String ownerPrefix = 'main';

          for (final rawNote in allNotesRaw) {
            try {
              final id = rawNote['id'] as String;
              final salt = rawNote['salt'] as String;
              final payload = Map<String, dynamic>.from(rawNote['payload'] as Map);
              final recordKey = crypto.deriveRecordKey(masterKey, id, salt);
              final clear = SecureNote.fromJson(crypto.decryptJson(payload, recordKey));

              final found = clear.attachments.where((a) => a.id == blobId);
              if (found.isNotEmpty) {
                owner = clear;
                attachment = found.first;
                ownerPrefix = recordsBox.get('main:$id') != null ? 'main' : 'hidden';
                break;
              }
            } catch (_) {}
          }

          if (owner != null && attachment != null) {
            try {
              final key = crypto.deriveRecordKey(masterKey, '${owner.id}:${attachment.id}', attachment.salt);
              final encryptedBytes = await fileEntity.readAsBytes();
              final clearBytes = encryptedBytes.length > 102400
                  ? await crypto.decryptBytesIsolate(encryptedBytes, key)
                  : crypto.decryptBytes(encryptedBytes, key);

              final folder = _getFolderByKind(attachment.kind);
              final safeName = _getSafeFileName(attachment.name, attachment.id, includeExtension: true);

              encoder.addArchiveFile(ArchiveFile('$exportRoot/$folder/$safeName', clearBytes.length, clearBytes));
              blobToDir[blobId] = 'vaultx_blobs';
            } catch (e) {
              debugPrint('FullExport: failed to decrypt attachment $blobId: $e');
            }
          }
        }
      }

      // 5. Folders Metadata
      for (final box in [recordsBox, driveBox]) {
        final boxName = box.name == 'vaultx_records' ? 'records' : 'drive';
        for (final key in box.keys.where((k) => k.toString().contains(':folder_metadata:'))) {
          final data = box.get(key);
          if (data is Map) {
            final jsonBytes = utf8.encode(jsonEncode(data));
            final folderName = data['name'] ?? 'unknown';
            encoder.addArchiveFile(ArchiveFile('$exportRoot/folders/${boxName}_$folderName.json', jsonBytes.length, jsonBytes));
          }
        }
      }

      // 6. Settings and Auth
      final settings = <String, dynamic>{};
      for (final k in settingsBox.keys) {
        settings[k.toString()] = settingsBox.get(k);
      }
      final settingsBytes = utf8.encode(jsonEncode(settings));
      encoder.addArchiveFile(ArchiveFile('$exportRoot/metadata/settings.json', settingsBytes.length, settingsBytes));

      try {
        final authBundle = await authService.exportAuthBundle();
        final authBytes = utf8.encode(jsonEncode(authBundle));
        encoder.addArchiveFile(ArchiveFile('$exportRoot/metadata/auth_bundle.json', authBytes.length, authBytes));
      } catch (e) {
        debugPrint('FullExport: failed to export auth bundle: $e');
      }

      // 7. Passwords
      final passwords = <String, dynamic>{};
      for (final k in passwordsBox.keys) {
        passwords[k.toString()] = passwordsBox.get(k);
      }
      final passwordsBytes = utf8.encode(jsonEncode(passwords));
      encoder.addArchiveFile(ArchiveFile('$exportRoot/metadata/passwords.json', passwordsBytes.length, passwordsBytes));

      // 8. vault_data.json (Manifest)
      final manifest = {
        'version': 4,
        'timestamp': DateTime.now().toIso8601String(),
        'notesCount': notesCount,
        'hiddenNotesCount': hiddenNotesCount,
        'filesCount': filesCount,
        'exportType': 'fully_decrypted',
        'blobMapping': blobToDir,
      };
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      encoder.addArchiveFile(ArchiveFile('$exportRoot/vault_data.json', manifestBytes.length, manifestBytes));

      encoder.close();
      await AuditLog.write('Full export ZIP created: $notesCount notes, $hiddenNotesCount hidden, $filesCount files');
      return zipPath;
    } catch (e, st) {
      debugPrint('FullExport ERROR: $e\n$st');
      encoder.close();
      return null;
    }
  }

  String _getSafeFileName(String name, String id, {bool includeExtension = false}) {
    String safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) safeName = 'untitled';
    
    // To avoid collisions and clarify which file is which, we append a short ID suffix
    final shortId = id.length > 8 ? id.substring(0, 8) : id;
    
    if (includeExtension) {
      final parts = safeName.split('.');
      if (parts.length > 1) {
        final ext = parts.last;
        final base = parts.sublist(0, parts.length - 1).join('.');
        return '${base}_$shortId.$ext';
      }
    }
    
    return '${safeName}_$shortId';
  }

  String _generateReadableTxt(SecureNote note) {
    final df = DateFormat('dd MMM yyyy HH:mm');
    final buf = StringBuffer();
    buf.writeln('Title: ${note.title}');
    buf.writeln('Created: ${df.format(note.createdAt)}');
    buf.writeln('Modified: ${df.format(note.updatedAt)}');
    buf.writeln('Folder: ${note.folder}');
    buf.writeln('Tags: ${note.tags.join(', ')}');
    buf.writeln('Pinned: ${note.pinned ? 'Yes' : 'No'}');
    buf.writeln('Favorite: ${note.favorite ? 'Yes' : 'No'}');
    buf.writeln('Archived: ${note.archived ? 'Yes' : 'No'}');
    buf.writeln('Type: ${note.type.name}');
    if (note.oneTimeView) buf.writeln('One-time view enabled');
    if (note.locked) buf.writeln('Note is locked');
    
    buf.writeln('\nContent:');
    buf.writeln('─' * 40);
    buf.writeln(note.body);
    buf.writeln('─' * 40);
    
    if (note.attachments.isNotEmpty) {
      buf.writeln('\nAttachments:');
      for (final a in note.attachments) {
        buf.writeln('- ${a.name} (${a.kind})');
      }
    }
    
    return buf.toString();
  }

  String _getFolderByKind(String kind) {
    switch (kind.toLowerCase()) {
      case 'image': return 'images';
      case 'video': return 'videos';
      case 'audio': return 'audio';
      case 'pdf': return 'pdf';
      default: return 'files';
    }
  }

  List<Map<String, dynamic>> _collectRawRecords(Box box, String prefix) {
    final records = <Map<String, dynamic>>[];
    for (final key in box.keys.where((k) => k.toString().startsWith('$prefix:') && !k.toString().contains(':folder_metadata:'))) {
      final raw = box.get(key) as Map?;
      if (raw != null) {
        records.add(Map<String, dynamic>.from(raw));
      }
    }
    return records;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as share;
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import 'audit_log.dart';
import 'crypto_service.dart';
import 'vault_repository.dart';

/// Generates and consumes encrypted share packages (.vxshare).
///
/// A share package bundles a note (decrypted JSON + attachment blobs) into
/// a single encrypted file protected by a human-readable share code.
/// The recipient opens the file and enters the same code to decrypt.
class SharePackageService {
  SharePackageService._();

  static final _crypto = CryptoService();
  static final _random = Random.secure();
  static final _uuid = const Uuid();

  static const _codeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const _codeLength = 8;

  /// Generate a random 8-character share code (no ambiguous chars).
  static String generateCode() {
    final code = List.generate(
      _codeLength,
      (_) => _codeChars[_random.nextInt(_codeChars.length)],
    ).join();
    // Add a dash in the middle for readability
    return '${code.substring(0, 4)}-${code.substring(4)}';
  }

  /// Export a note + its attachment blobs into an encrypted .vxshare file.
  ///
  /// Returns the generated file path and the share code, or null on failure.
  static Future<({String filePath, String shareCode})?> exportNote(
    SecureNote note,
    EncryptedBlobService blobs,
    Uint8List masterKey,
  ) async {
    try {
      final shareCode = generateCode();
      final saltB64 = base64Encode(_crypto.randomBytes(16));
      final shareKey = await _crypto.deriveCredentialKey(shareCode, saltB64);

      // Encrypt the note JSON
      final notePayload = _crypto.encryptJson(note.toJson(), shareKey);

      // Encrypt all attachment blobs
      final blobsMap = <String, Map<String, dynamic>>{};
      for (final attachment in note.attachments) {
        final encrypted = await File(attachment.encryptedPath).readAsBytes();
        final key = _crypto.deriveRecordKey(
          masterKey,
          '${note.id}:${attachment.id}',
          attachment.salt,
        );
        final decrypted = encrypted.length > 102400
            ? await _crypto.decryptBytesIsolate(encrypted, key)
            : _crypto.decryptBytes(encrypted, key);

        final blobSalt = base64Encode(_crypto.randomBytes(16));
        final blobKey = await _crypto.deriveCredentialKey(
          '$shareCode:${attachment.id}',
          blobSalt,
        );
        final reEncrypted = _crypto.encryptBytes(decrypted, blobKey);
        _crypto.wipe(decrypted);

        blobsMap[attachment.id] = {
          'name': attachment.name,
          'kind': attachment.kind,
          'ct': base64Encode(reEncrypted),
          'salt': blobSalt,
        };
      }

      // Build the package manifest
      final package = {
        'format': 'VaultX Share Package',
        'version': 1,
        'salt': saltB64,
        'note': notePayload,
        'noteMetadata': {
          'title': note.title,
          'type': note.type.name,
          'createdAt': note.createdAt.toIso8601String(),
        },
        'blobs': blobsMap,
        'integrity': {
          'noteId': note.id,
          'blobCount': note.attachments.length,
        },
      };

      final dir = await getTemporaryDirectory();
      final fileName = 'VaultX_Share_${_uuid.v4().substring(0, 8)}.vxshare';
      final filePath = '${dir.path}/$fileName';
      await File(filePath).writeAsString(jsonEncode(package), flush: true);

      await AuditLog.write(
        'Share package created: ${note.title} ($fileName)',
      );

      return (filePath: filePath, shareCode: shareCode);
    } catch (e) {
      await AuditLog.write('Share package export failed: $e');
      return null;
    }
  }

  /// Import a note from a .vxshare file using the [shareCode].
  /// Returns the decrypted SecureNote, or null on failure.
  static Future<SecureNote?> importPackage(
    String filePath,
    String shareCode,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        await AuditLog.write('Share import: file not found');
        return null;
      }

      final package =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      if (package['format'] != 'VaultX Share Package') {
        await AuditLog.write('Share import: invalid format');
        return null;
      }

      final saltB64 = package['salt'] as String;
      final shareKey = await _crypto.deriveCredentialKey(shareCode, saltB64);

      // Decrypt the note
      final notePayload = Map<String, dynamic>.from(package['note'] as Map);
      final clearJson = _crypto.decryptJson(notePayload, shareKey);
      final note = SecureNote.fromJson(clearJson);

      // Decrypt and save attachment blobs
      final rawBlobs = package['blobs'] as Map<String, dynamic>? ?? {};
      final restoredAttachments = <SecureAttachment>[];

      final docDir = await getApplicationDocumentsDirectory();
      final blobDir = Directory('${docDir.path}/vaultx_blobs');
      await blobDir.create(recursive: true);

      for (final entry in rawBlobs.entries) {
        final blobData = Map<String, dynamic>.from(entry.value as Map);
        final blobSalt = blobData['salt'] as String;
        final blobKey = await _crypto.deriveCredentialKey(
          '$shareCode:${entry.key}',
          blobSalt,
        );
        final reEncrypted = base64Decode(blobData['ct'] as String);
        final decrypted = _crypto.decryptBytes(reEncrypted, blobKey);

        final newId = _uuid.v4();
        final newSalt = base64Encode(_crypto.randomBytes(16));
        final ownerId = note.id;
        final key = _crypto.deriveRecordKey(
          Uint8List.fromList(shareKey),
          '$ownerId:$newId',
          newSalt,
        );
        final encrypted = _crypto.encryptBytes(decrypted, key);
        _crypto.wipe(decrypted);

        final outPath = '${blobDir.path}/$newId.vxblob';
        await File(outPath).writeAsBytes(encrypted, flush: true);

        restoredAttachments.add(SecureAttachment(
          id: newId,
          name: blobData['name'] as String? ?? 'attachment',
          encryptedPath: outPath,
          salt: newSalt,
          size: reEncrypted.length,
          createdAt: DateTime.now(),
          kind: blobData['kind'] as String? ?? 'file',
        ));
      }

      final now = DateTime.now();
      final restoredNote = SecureNote(
        id: _uuid.v4(),
        title: note.title,
        body: note.body,
        type: note.type,
        createdAt: now,
        updatedAt: now,
        folder: note.folder,
        tags: note.tags,
        priority: note.priority,
        ocrText: note.ocrText,
        transcript: note.transcript,
        summary: note.summary,
        attachments: restoredAttachments,
      );

      await AuditLog.write(
        'Share package imported: ${restoredNote.title} '
        '(${restoredAttachments.length} blobs)',
      );

      return restoredNote;
    } catch (e) {
      await AuditLog.write('Share package import failed: $e');
      return null;
    }
  }

  /// Share a .vxshare file via the system share sheet.
  static Future<void> sharePackage(String filePath, {String? shareCode}) async {
    final text = shareCode != null
        ? 'VaultX encrypted note — share code: $shareCode'
        : 'VaultX encrypted note package';
    await share.SharePlus.instance.share(
      share.ShareParams(
        files: [share.XFile(filePath)],
        text: text,
      ),
    );
  }
}

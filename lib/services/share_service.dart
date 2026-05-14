import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import '../models/note.dart';
import '../models/drive_file.dart';
import 'crypto_service.dart';
import 'package:path_provider/path_provider.dart';

class ShareService {
  static Future<void> shareNote(SecureNote note) async {
    final text = '${note.title}\n\n${note.body}';
    // ignore: deprecated_member_use
    await Share.share(text, subject: note.title);
  }

  static Future<void> shareFile(
    SecureDriveFile file,
    Uint8List masterKey,
  ) async {
    try {
      final crypto = CryptoService();
      final encryptedFile = File(file.encryptedPath);
      if (!await encryptedFile.exists()) {
        debugPrint('ShareService: Encrypted file not found at ${file.encryptedPath}');
        return;
      }

      final encryptedBytes = await encryptedFile.readAsBytes();
      final recordKey = crypto.deriveRecordKey(masterKey, 'drive:${file.id}', file.salt);
      
      final decryptedBytes = encryptedBytes.length > 102400
          ? await crypto.decryptBytesIsolate(encryptedBytes, recordKey)
          : crypto.decryptBytes(encryptedBytes, recordKey);

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${file.name}');
      await tempFile.writeAsBytes(decryptedBytes);

      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(tempFile.path)], text: file.name);
      
      // Clean up after share - note: share sheet might still be using it, 
      // but usually Share.shareXFiles returns when the sheet is shown or dismissed depending on platform.
      // Better to cleanup after a short delay or just let it be in temp.
      Future.delayed(const Duration(minutes: 5), () async {
        if (await tempFile.exists()) await tempFile.delete();
      });
    } catch (e) {
      debugPrint('ShareService: Error sharing file: $e');
    }
  }
}

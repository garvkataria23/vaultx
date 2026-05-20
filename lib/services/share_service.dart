import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart' as share;
import '../models/note.dart';
import '../models/drive_file.dart';
import 'crypto_service.dart';
import 'package:path_provider/path_provider.dart';

class ShareService {
  static Future<void> shareNote(SecureNote note) async {
    final text = '${note.title}\n\n${note.body}';
    await share.SharePlus.instance.share(
      share.ShareParams(text: text, subject: note.title),
    );
  }

  static Future<void> shareFilePath(String filePath, {String? text}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      debugPrint('ShareService: File not found at $filePath');
      return;
    }
    await share.SharePlus.instance.share(
      share.ShareParams(
        files: [share.XFile(filePath)],
        text: text ?? filePath.split('\\').last.split('/').last,
      ),
    );
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

      await share.SharePlus.instance.share(
        share.ShareParams(
          files: [share.XFile(tempFile.path)],
          text: file.name,
        ),
      );
      
      // Clean up after share
      Future.delayed(const Duration(minutes: 5), () async {
        if (await tempFile.exists()) await tempFile.delete();
      });
    } catch (e) {
      debugPrint('ShareService: Error sharing file: $e');
    }
  }
}

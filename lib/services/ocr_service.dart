import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'audit_log.dart';
import 'backup_change_tracker.dart';

/// Privacy-first local OCR service.
///
/// All processing runs on-device via ML Kit. No data ever leaves the device.
/// Only available on Android and iOS. Returns null on other platforms.
class OcrService {
  OcrService._();

  static bool _checked = false;
  static bool _available = false;

  /// Whether OCR is supported on this platform (Android/iOS only).
  static bool isAvailable() {
    if (!_checked) {
      _available =
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;
      _checked = true;
    }
    return _available;
  }

  /// Extract text from an image file at [imagePath].
  /// Returns the recognized text, or null if OCR fails or is unavailable.
  static Future<String?> extractText(String imagePath) async {
    if (!isAvailable()) return null;
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        await AuditLog.write('OCR skipped — image file not found');
        return null;
      }
      final size = await file.length();
      if (size > 50 * 1024 * 1024) {
        await AuditLog.write('OCR skipped — file exceeds 50 MB limit');
        return null;
      }
      final recognizer = TextRecognizer();
      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await recognizer.processImage(inputImage);
      recognizer.close();
      final text = result.text.trim();
      await AuditLog.write(
        text.isNotEmpty
            ? 'OCR extracted ${text.length} characters from image'
            : 'OCR completed — no text found in image',
      );
      if (text.isNotEmpty) {
        BackupChangeTracker.instance.notifyOcrChanged(estimatedBytes: text.length);
      }
      return text.isNotEmpty ? text : null;
    } catch (e) {
      await AuditLog.write('OCR extraction failed: $e');
      return null;
    }
  }

  /// Extract text from in-memory image bytes.
  /// Saves bytes to a temporary file, runs OCR, then cleans up.
  static Future<String?> extractFromBytes(Uint8List bytes) async {
    if (!isAvailable()) return null;
    Directory? tmpDir;
    try {
      tmpDir = Directory.systemTemp.createTempSync('vaultx_ocr_');
      final tmpFile = File(
        '${tmpDir.path}/ocr_image_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await tmpFile.writeAsBytes(bytes, flush: true);
      final text = await extractText(tmpFile.path);
      return text;
    } catch (e) {
      await AuditLog.write('OCR bytes extraction failed: $e');
      return null;
    } finally {
      try {
        tmpDir?.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

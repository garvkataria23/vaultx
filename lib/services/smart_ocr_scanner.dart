import 'dart:async';
import 'package:flutter/foundation.dart';
import 'vault_repository.dart';
import 'ocr_service.dart';

class SmartOcrScanner {
  static bool _isRunning = false;
  static bool _stopRequested = false;

  /// Starts a background scanner that silently processes OCR for images
  /// in notes that haven't been processed yet.
  static Future<void> start(
    VaultRepository repo,
    EncryptedBlobService blobs,
  ) async {
    if (!OcrService.isAvailable()) return;
    if (_isRunning) return;
    _isRunning = true;
    _stopRequested = false;

    try {
      final notes = await repo.loadNotes();
      
      for (final note in notes) {
        if (_stopRequested) break;

        // Skip if it already has OCR text or has no images
        if (note.ocrText.isNotEmpty) continue;
        final images = note.attachments.where((a) => a.kind == 'image').toList();
        if (images.isEmpty) continue;

        String combinedOcr = '';
        bool updated = false;

        for (final img in images) {
          if (_stopRequested) break;
          
          final tempPath = await blobs.decryptAttachmentToTemp(note.id, img);
          
          if (tempPath.isEmpty) continue;

          final extracted = await OcrService.extractText(tempPath);
          
          if (extracted != null && extracted.isNotEmpty) {
            combinedOcr += '--- ${img.name} ---\n$extracted\n\n';
            updated = true;
          }

          // Small delay to prevent UI freezing and device heating
          await Future.delayed(const Duration(milliseconds: 500));
        }

        if (updated && !_stopRequested) {
          final updatedNote = note.copyWith(ocrText: combinedOcr.trim());
          await repo.save(updatedNote);
        }
      }
    } catch (e) {
      debugPrint('SmartOcrScanner error: $e');
    } finally {
      _isRunning = false;
    }
  }

  static void stop() {
    _stopRequested = true;
  }
}

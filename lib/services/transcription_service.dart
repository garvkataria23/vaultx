import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:vosk_flutter_service/vosk_flutter.dart';

import 'audit_log.dart';

/// Privacy-first local speech-to-text transcription service.
///
/// All processing runs on-device via Vosk. No data ever leaves the device.
/// Audio must be 16-bit PCM, 16 kHz, mono for best compatibility.
class TranscriptionService {
  TranscriptionService._();

  static bool _checked = false;
  static bool _available = false;
  static Model? _model;
  static final ModelLoader _modelLoader = ModelLoader();

  static final Set<String> _supportedFormats = {'wav', 'pcm'};

  /// Whether transcription is supported on this platform.
  static bool isAvailable() {
    if (!_checked) {
      try {
        VoskFlutterPlugin.instance();
        _available = true;
      } catch (_) {
        _available = false;
      }
      _checked = true;
    }
    return _available;
  }

  /// Load the Vosk model, downloading it first if needed.
  /// Returns true once the model is ready for transcription.
  static Future<bool> ensureModel() async {
    if (_model != null) return true;
    try {
      final vosk = VoskFlutterPlugin.instance();

      // Check if model was previously downloaded
      const modelName = 'vosk-model-small-en-us-0.15';
      if (await _modelLoader.isModelAlreadyLoaded(modelName)) {
        final path = await _modelLoader.modelPath(modelName);
        _model = await vosk.createModel(path);
        return _model != null;
      }
      return false;
    } catch (e) {
      await AuditLog.write('TranscriptionService: failed to load model: $e');
      return false;
    }
  }

  /// Download the small English Vosk model (~40 MB).
  /// Calls [onProgress] with a value 0.0–1.0 during download.
  static Future<bool> downloadModel({
    void Function(double progress)? onProgress,
  }) async {
    try {
      const modelUrl =
          'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';

      final path = await _modelLoader.loadFromNetwork(
        modelUrl,
        forceReload: false,
      );

      final vosk = VoskFlutterPlugin.instance();
      _model = await vosk.createModel(path);
      return _model != null;
    } catch (e) {
      await AuditLog.write('TranscriptionService: download failed: $e');
      return false;
    }
  }

  /// Transcribe a PCM/WAV audio file.
  /// Returns recognized text, or null on failure.
  static Future<String?> transcribeFile(String audioPath) async {
    if (!isAvailable()) {
      await AuditLog.write(
        'Transcription skipped — not available on this platform',
      );
      return null;
    }

    final file = File(audioPath);
    if (!await file.exists()) {
      await AuditLog.write('Transcription skipped — audio file not found');
      return null;
    }

    final ext = audioPath.split('.').last.toLowerCase();
    if (!_supportedFormats.contains(ext)) {
      await AuditLog.write('Transcription skipped — unsupported format: .$ext');
      return null;
    }

    if (!await ensureModel()) {
      await AuditLog.write('Transcription skipped — model not loaded');
      return null;
    }

    try {
      final plugin = VoskFlutterPlugin.instance();
      final recognizer = await plugin.createRecognizer(
        model: _model!,
        sampleRate: 16000,
      );

      final bytes = await file.readAsBytes();
      const chunkSize = 8192;

      for (var pos = 0; pos + chunkSize < bytes.length; pos += chunkSize) {
        final chunk = bytes.sublist(pos, pos + chunkSize);
        await recognizer.acceptWaveformBytes(Uint8List.fromList(chunk));
      }
      final remainingStart = (bytes.length ~/ chunkSize) * chunkSize;
      if (remainingStart < bytes.length) {
        final remaining = bytes.sublist(remainingStart);
        await recognizer.acceptWaveformBytes(Uint8List.fromList(remaining));
      }

      final resultJson = await recognizer.getFinalResult();
      recognizer.dispose();

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      final text = parsed['text'] as String? ?? '';

      await AuditLog.write(
        text.isNotEmpty
            ? 'Transcription extracted ${text.length} characters from audio'
            : 'Transcription completed — no speech detected',
      );

      return text.isNotEmpty ? text : null;
    } catch (e) {
      await AuditLog.write('Transcription failed: $e');
      return null;
    }
  }
}

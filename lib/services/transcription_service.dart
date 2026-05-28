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

  /// Vosk model for Indian English (better accuracy for Hinglish / Indian accents).
  /// Small model (36 MB) suitable for mobile. Switch to 'vosk-model-small-en-us-0.15'
  /// for US English, or 'vosk-model-en-in-0.5' for more accurate Indian English (1 GB server model).
  static const String _modelName = 'vosk-model-small-en-in-0.4';
  static const String _modelUrl =
      'https://alphacephei.com/vosk/models/$_modelName.zip';

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

      if (await _modelLoader.isModelAlreadyLoaded(_modelName)) {
        final path = await _modelLoader.modelPath(_modelName);
        _model = await vosk.createModel(path);
        return _model != null;
      }
      
      return await downloadModel();
    } catch (e) {
      await AuditLog.write('TranscriptionService: failed to load model: $e');
      return false;
    }
  }

  /// Download the Indian English Vosk model (~42 MB).
  static Future<bool> downloadModel({
    void Function(double progress)? onProgress,
  }) async {
    try {
      final path = await _modelLoader.loadFromNetwork(
        _modelUrl,
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
      final fullText = StringBuffer();

      // Skip the WAV header dynamically if present so Vosk processes pure PCM
      int startOffset = 0;
      if (bytes.length > 44 && utf8.decode(bytes.take(4).toList(), allowMalformed: true) == 'RIFF') {
        for (int i = 12; i < bytes.length - 4; i++) {
          if (bytes[i] == 0x64 && bytes[i+1] == 0x61 && bytes[i+2] == 0x74 && bytes[i+3] == 0x61) {
            startOffset = i + 8; // skip 'data' and the 4-byte size
            break;
          }
        }
        if (startOffset == 0) startOffset = 44; // fallback
      }

      for (var pos = startOffset; pos + chunkSize < bytes.length; pos += chunkSize) {
        final chunk = bytes.sublist(pos, pos + chunkSize);
        final utteranceComplete = await recognizer.acceptWaveformBytes(Uint8List.fromList(chunk));
        if (utteranceComplete) {
          final res = await recognizer.getResult();
          final parsed = jsonDecode(res) as Map<String, dynamic>;
          final t = parsed['text'] as String? ?? '';
          if (t.isNotEmpty) fullText.write('$t ');
        }
      }
      
      final remainingStart = startOffset + ((bytes.length - startOffset) ~/ chunkSize) * chunkSize;
      if (remainingStart < bytes.length) {
        final remaining = bytes.sublist(remainingStart);
        final utteranceComplete = await recognizer.acceptWaveformBytes(Uint8List.fromList(remaining));
        if (utteranceComplete) {
          final res = await recognizer.getResult();
          final parsed = jsonDecode(res) as Map<String, dynamic>;
          final t = parsed['text'] as String? ?? '';
          if (t.isNotEmpty) fullText.write('$t ');
        }
      }

      final resultJson = await recognizer.getFinalResult();
      recognizer.dispose();

      final parsedFinal = jsonDecode(resultJson) as Map<String, dynamic>;
      final tFinal = parsedFinal['text'] as String? ?? '';
      if (tFinal.isNotEmpty) fullText.write(tFinal);

      final text = fullText.toString().trim();

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

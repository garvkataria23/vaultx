import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'vault_repository.dart';
import '../models/note.dart';

/// Handles voice recording, encrypting the result as a SecureAttachment.
class VoiceNoteRecorder {
  VoiceNoteRecorder(this.blobs, this.noteId);
  final EncryptedBlobService blobs;
  final String noteId;
  final AudioRecorder _recorder = AudioRecorder();
  String? _path;
  bool _pcmMode = false;

  /// Start recording in AAC format (smaller file, for playback).
  Future<bool> start() async {
    try {
      if (!await _recorder.hasPermission()) {
        debugPrint('VoiceRecorder: Microphone permission denied');
        return false;
      }
      _pcmMode = false;
      final dir = await getTemporaryDirectory();
      _path =
          '${dir.path}/vaultx_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      debugPrint('VoiceRecorder: Starting AAC recording at $_path');
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _path!,
      );
      return true;
    } catch (e) {
      debugPrint('VoiceRecorder: Failed to start AAC recording: $e');
      return false;
    }
  }

  /// Start recording in PCM/WAV format (compatible with Vosk transcription).
  Future<bool> startPcm() async {
    try {
      if (!await _recorder.hasPermission()) {
        debugPrint('VoiceRecorder: Microphone permission denied');
        return false;
      }
      _pcmMode = true;
      final dir = await getTemporaryDirectory();
      _path =
          '${dir.path}/vaultx_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      debugPrint('VoiceRecorder: Starting WAV/PCM16 recording at $_path');
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _path!,
      );
      return true;
    } catch (e) {
      debugPrint('VoiceRecorder: Failed to start WAV recording: $e');
      return false;
    }
  }

  /// Get amplitude stream to monitor voice activity.
  Stream<Amplitude> getAmplitudeStream() {
    return _recorder.onAmplitudeChanged(const Duration(milliseconds: 100));
  }

  Future<SecureAttachment?> stopAndEncrypt() async {
    try {
      debugPrint('VoiceRecorder: Stopping recording...');
      final path = await _recorder.stop() ?? _path;
      await _recorder.dispose();
      
      if (path == null || !File(path).existsSync()) {
        debugPrint('VoiceRecorder: No audio file found at $path');
        return null;
      }
      
      final file = File(path);
      final size = await file.length();
      debugPrint('VoiceRecorder: Recording saved. Size: $size bytes');
      
      if (size < 1000) {
        debugPrint('VoiceRecorder: Audio file too small, discarding.');
        try { await file.delete(); } catch (_) {}
        return null;
      }

      final ext = _pcmMode ? 'wav' : 'm4a';
      final attachment = await blobs.encryptExistingFile(
        ownerId: noteId,
        name: 'Voice note ${DateTime.now().toIso8601String()}.$ext',
        path: path,
        kind: 'voice',
      );
      
      try {
        await file.delete();
      } catch (_) {}
      
      debugPrint('VoiceRecorder: Encrypted as attachment ${attachment.id}');
      return attachment;
    } catch (e) {
      debugPrint('VoiceRecorder: Failed to stop and encrypt: $e');
      return null;
    }
  }

  bool get isPcmMode => _pcmMode;
}

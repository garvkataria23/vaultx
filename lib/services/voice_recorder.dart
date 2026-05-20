import 'dart:io';

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
    if (!await _recorder.hasPermission()) return false;
    _pcmMode = false;
    final dir = await getTemporaryDirectory();
    _path =
        '${dir.path}/vaultx_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: _path!,
    );
    return true;
  }

  /// Start recording in PCM/WAV format (compatible with Vosk transcription).
  Future<bool> startPcm() async {
    if (!await _recorder.hasPermission()) return false;
    _pcmMode = true;
    final dir = await getTemporaryDirectory();
    _path =
        '${dir.path}/vaultx_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _path!,
    );
    return true;
  }

  Future<SecureAttachment?> stopAndEncrypt() async {
    final path = await _recorder.stop() ?? _path;
    if (path == null || !File(path).existsSync()) return null;
    final ext = _pcmMode ? 'wav' : 'm4a';
    final attachment = await blobs.encryptExistingFile(
      ownerId: noteId,
      name: 'Voice note ${DateTime.now().toIso8601String()}.$ext',
      path: path,
      kind: 'voice',
    );
    try {
      await File(path).delete();
    } catch (_) {}
    return attachment;
  }

  bool get isPcmMode => _pcmMode;
}

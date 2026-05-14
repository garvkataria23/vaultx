import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'vault_repository.dart';
import 'audit_log.dart';
import '../models/note.dart';

/// Captures a front-camera selfie on failed PIN attempts and stores it encrypted.
class IntruderSelfieService {
  /// Minimum seconds between consecutive captures to prevent spam.
  static const int cooldownSeconds = 30;

  /// Captures a front-camera selfie, encrypts it, and stores as blob.
  static Future<SecureAttachment?> capture(Uint8List masterKey) async {
    try {
      debugPrint('INTRUDER: capture start');

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        await AuditLog.write('Intruder capture skipped — no cameras available');
        debugPrint('INTRUDER: no cameras available');
        return null;
      }

      CameraDescription? front;
      try {
        front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
        );
      } catch (_) {
        front = cameras.first;
      }
      debugPrint('INTRUDER: using camera ${front.lensDirection}');

      final controller = CameraController(
        front,
        ResolutionPreset.low,
        enableAudio: false,
      );

      XFile? image;
      try {
        await controller.initialize();
        debugPrint('INTRUDER: camera initialized');
        image = await controller.takePicture();
        debugPrint('INTRUDER: photo captured at ${image.path}');
      } catch (e) {
        debugPrint('INTRUDER: camera capture failed: $e');
        await AuditLog.write('Intruder capture failed — camera error: $e');
        return null;
      } finally {
        try {
          await controller.dispose();
        } catch (_) {}
      }

      try {
        final blob = await EncryptedBlobService(masterKey).encryptExistingFile(
          ownerId: 'intruder',
          name: 'failed_unlock_${DateTime.now().millisecondsSinceEpoch}.jpg',
          path: image.path,
          kind: 'intruder_selfie',
        );
        debugPrint('INTRUDER: encrypted blob at ${blob.encryptedPath}');

        try {
          await File(image.path).delete();
          debugPrint('INTRUDER: temp file deleted');
        } catch (_) {}

        await AuditLog.write('Intruder selfie captured and encrypted');
        debugPrint('INTRUDER: capture complete');
        return blob;
      } catch (e) {
        debugPrint('INTRUDER: encryption failed: $e');
        await AuditLog.write('Intruder capture failed — encryption error: $e');
        try {
          await File(image.path).delete();
        } catch (_) {}
        return null;
      }
    } catch (e) {
      debugPrint('INTRUDER: unexpected error: $e');
      await AuditLog.write('Intruder capture unavailable: $e');
      return null;
    }
  }

  /// Checks whether enough time has passed since the last capture.
  static Future<bool> isCooldownElapsed() async {
    final box = Hive.box('vaultx_settings');
    final last = box.get('intruderLastCaptureAt') as int?;
    if (last == null) return true;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed >= cooldownSeconds * 1000;
  }

  /// Records the current timestamp as the last capture time.
  static Future<void> markCaptureTime() async {
    await Hive.box('vaultx_settings').put(
      'intruderLastCaptureAt',
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// Security log entry representing a failed unlock attempt with optional intruder selfie.
class IntruderLogEntry {
  const IntruderLogEntry({
    required this.id,
    required this.timestamp,
    required this.attemptNumber,
    required this.authMethod,
    this.attachment,
  });

  final String id;
  final DateTime timestamp;
  final int attemptNumber;
  final String authMethod;
  final SecureAttachment? attachment;

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'attemptNumber': attemptNumber,
    'authMethod': authMethod,
    if (attachment != null) 'attachment': attachment!.toJson(),
  };

  factory IntruderLogEntry.fromJson(Map<String, dynamic> json) =>
      IntruderLogEntry(
        id: json['id'] as String? ?? '',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
        attemptNumber: json['attemptNumber'] as int? ?? 0,
        authMethod: json['authMethod'] as String? ?? '',
        attachment: json['attachment'] is Map
            ? SecureAttachment.fromJson(
                Map<String, dynamic>.from(json['attachment'] as Map),
              )
            : null,
      );
}

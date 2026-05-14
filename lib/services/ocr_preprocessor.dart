import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class OcrPreprocessingResult {
  OcrPreprocessingResult({
    required this.optimizedPath,
    required this.originalWidth,
    required this.originalHeight,
    required this.originalSizeBytes,
    required this.optimizedSizeBytes,
    required this.imageType,
    required this.wasResized,
  });

  final String optimizedPath;
  final int originalWidth;
  final int originalHeight;
  final int originalSizeBytes;
  final int optimizedSizeBytes;
  final String imageType;
  final bool wasResized;

  double get sizeReductionPct {
    if (originalSizeBytes == 0) return 0;
    return (1 - optimizedSizeBytes / originalSizeBytes) * 100;
  }
}

class OcrPreprocessor {
  OcrPreprocessor._();

  static const int maxDimension = 2048;
  static const int jpegQuality = 85;
  static const int maxFileSizeBytes = 50 * 1024 * 1024;

  static Future<OcrPreprocessingResult?> preprocess(String imagePath) async {
    try {
      return await compute(_runPreprocessing, imagePath);
    } catch (e) {
      return null;
    }
  }
}

OcrPreprocessingResult? _runPreprocessing(String imagePath) {
  final file = File(imagePath);
  if (!file.existsSync()) return null;

  final originalBytes = file.readAsBytesSync();
  final originalSize = originalBytes.length;

  if (originalSize > OcrPreprocessor.maxFileSizeBytes) return null;

  final image = img.decodeImage(originalBytes);
  if (image == null) return null;

  final origW = image.width;
  final origH = image.height;
  final imageType = _detectImageType(originalBytes);

  img.Image processed = image;
  bool wasResized = false;

  if (origW > OcrPreprocessor.maxDimension ||
      origH > OcrPreprocessor.maxDimension) {
    final scale =
        OcrPreprocessor.maxDimension / (origW > origH ? origW : origH);
    processed = img.copyResize(image, width: (origW * scale).toInt());
    wasResized = true;
  }

  final optimizedBytes = img.encodeJpg(
    processed,
    quality: OcrPreprocessor.jpegQuality,
  );

  final tmpDir = Directory.systemTemp.createTempSync('vaultx_ocr_pre_');
  final optimizedPath =
      '${tmpDir.path}/ocr_opt_${DateTime.now().millisecondsSinceEpoch}.jpg';
  File(optimizedPath).writeAsBytesSync(optimizedBytes);

  return OcrPreprocessingResult(
    optimizedPath: optimizedPath,
    originalWidth: origW,
    originalHeight: origH,
    originalSizeBytes: originalSize,
    optimizedSizeBytes: optimizedBytes.length,
    imageType: imageType,
    wasResized: wasResized,
  );
}

String _detectImageType(Uint8List bytes) {
  if (bytes.length < 4) return 'unknown';
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpeg';
  if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  if (bytes[0] == 0x47 && bytes[1] == 0x49) return 'gif';
  if (bytes[0] == 0x52 && bytes[1] == 0x49) return 'webp';
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
  return 'unknown';
}

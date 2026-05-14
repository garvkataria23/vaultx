import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'temp_file_manager.dart';

class PdfToolsService {
  static final PdfToolsService instance = PdfToolsService._();
  PdfToolsService._();

  final _tempManager = TempFileManager.instance;

  /// Creates a PDF from a list of image paths.
  Future<String?> imagesToPdf(List<String> imagePaths) async {
    try {
      final pdf = pw.Document();

      for (final imagePath in imagePaths) {
        final file = File(imagePath);
        if (!await file.exists()) continue;

        final image = pw.MemoryImage(await file.readAsBytes());
        pdf.addPage(
          pw.Page(
            build: (pw.Context context) {
              return pw.Center(child: pw.Image(image));
            },
          ),
        );
      }

      final outPath = await _tempManager.createTempPath('generated.pdf');
      final outFile = File(outPath);
      await outFile.writeAsBytes(await pdf.save());

      return outPath;
    } catch (e) {
      debugPrint('Error creating PDF from images: $e');
      return null;
    }
  }

  /// Creates a PDF from plain text.
  Future<String?> textToPdf(String text, {String? title}) async {
    try {
      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) => [
            if (title != null)
              pw.Header(level: 0, child: pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
            pw.Paragraph(text: text),
          ],
        ),
      );

      final outPath = await _tempManager.createTempPath('document.pdf');
      final outFile = File(outPath);
      await outFile.writeAsBytes(await pdf.save());

      return outPath;
    } catch (e) {
      debugPrint('Error creating PDF from text: $e');
      return null;
    }
  }

  /// Extract text from a PDF (via OCR on images if necessary, or direct if possible).
  /// Note: Pure Dart PDF text extraction is limited. We'll rely on OCR for images for now.
  Future<String?> pdfToText(String pdfPath) async {
    // For now, since we don't have a pure-dart PDF-to-Image renderer,
    // we'll mention that PDF to Text is currently using OCR which works best on images.
    // Real implementation would need 'pdf_render' or similar native plugin.
    return null; 
  }
}

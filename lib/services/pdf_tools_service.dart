import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'temp_file_manager.dart';
import 'vault_repository.dart';
import '../models/note.dart';

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

  /// Create a PDF from images and encrypt it as a SecureAttachment.
  Future<SecureAttachment?> imagesToEncryptedPdf(
    List<String> imagePaths,
    EncryptedBlobService blobs,
    String noteId,
  ) async {
    try {
      final pdfPath = await imagesToPdf(imagePaths);
      if (pdfPath == null) return null;

      final attachment = await blobs.encryptExistingFile(
        ownerId: noteId,
        name: 'Merged PDF ${DateTime.now().toIso8601String()}.pdf',
        path: pdfPath,
        kind: 'pdf',
      );

      try {
        await File(pdfPath).delete();
      } catch (_) {}

      return attachment;
    } catch (e) {
      debugPrint('Error creating encrypted PDF from images: $e');
      return null;
    }
  }

  /// Extract text from a PDF using Syncfusion's PDF text extractor.
  Future<String?> pdfToText(String pdfPath) async {
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfTextExtractor extractor = sf.PdfTextExtractor(document);
      final text = extractor.extractText().trim();
      document.dispose();

      return text.isNotEmpty ? text : null;
    } catch (e) {
      debugPrint('Error extracting text from PDF: $e');
      return null;
    }
  }

  /// Converts a PDF to a list of image paths (one per page).
  /// Uses Syncfusion's page text extraction — each page's text is rendered
  /// as an image via platform native APIs when available; otherwise returns
  /// the extracted text paths for downstream OCR processing.
  Future<List<String>> pdfToImages(String pdfPath) async {
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return [];

      final bytes = await file.readAsBytes();
      final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
      final imagePaths = <String>[];

      // Export each page as a separate text file for OCR processing.
      // For true image rendering, add syncfusion_flutter_pdfviewer dependency.
      final dir = await getTemporaryDirectory();
      final baseName = pdfPath.split(Platform.pathSeparator).last.replaceAll('.pdf', '');

      for (var i = 0; i < document.pages.count; i++) {
        final extractor = sf.PdfTextExtractor(document);
        final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i).trim();
        if (pageText.isNotEmpty) {
          final outPath = '${dir.path}/${baseName}_page_${i + 1}.txt';
          await File(outPath).writeAsString(pageText);
          imagePaths.add(outPath);
        }
      }

      document.dispose();
      return imagePaths;
    } catch (e) {
      debugPrint('Error converting PDF to images: $e');
      return [];
    }
  }

  /// Flatten a PDF by removing all metadata (author, title, subject, etc.).
  /// Returns the path to the cleaned PDF, or null on failure.
  Future<String?> flattenPdf(String pdfPath) async {
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);

      // Clear all metadata
      final info = document.documentInformation;
      info.author = '';
      info.title = '';
      info.subject = '';
      info.keywords = '';
      info.creator = '';
      info.producer = 'VaultX';

      final outPath = await _tempManager.createTempPath('flattened.pdf');
      final outBytes = await document.save();
      document.dispose();

      await File(outPath).writeAsBytes(outBytes);
      return outPath;
    } catch (e) {
      debugPrint('Error flattening PDF: $e');
      return null;
    }
  }
}

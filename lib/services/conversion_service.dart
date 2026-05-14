import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart' as xml;
import 'pdf_tools_service.dart';
import 'temp_file_manager.dart';

enum ConversionFormat { pdf, docx, txt, images, pptx, doc, ppt, jpg, png, webp }

class ConversionResult {
  final String path;
  final bool success;
  final String? error;

  ConversionResult({required this.path, this.success = true, this.error});
  factory ConversionResult.failure(String error) => ConversionResult(path: '', success: false, error: error);
}

class ConversionService {
  static final ConversionService instance = ConversionService._();
  ConversionService._();

  final _pdfTools = PdfToolsService.instance;
  final _tempManager = TempFileManager.instance;
  final Set<String> _processingPaths = {};

  /// Main entry point for conversions.
  Future<ConversionResult> convert({
    required String inputPath,
    required ConversionFormat targetFormat,
  }) async {
    if (_processingPaths.contains(inputPath)) {
      return ConversionResult.failure('Conversion already in progress for this file');
    }

    _processingPaths.add(inputPath);
    final ext = inputPath.split('.').last.toLowerCase();
    
    try {
      // Image to Image
      if (['jpg', 'jpeg', 'png', 'webp'].contains(ext) && 
          [ConversionFormat.jpg, ConversionFormat.png, ConversionFormat.webp].contains(targetFormat)) {
        return await _imageToImage(inputPath, targetFormat);
      }

      // To PDF
      if (targetFormat == ConversionFormat.pdf) {
        if (ext == 'txt') return await _txtToPdf(inputPath);
        if (['jpg', 'jpeg', 'png', 'webp'].contains(ext)) return await _imagesToPdf([inputPath]);
        if (ext == 'docx') return await _docxToPdf(inputPath);
        if (ext == 'pptx') return await _pptxToPdf(inputPath);
      }

      // To Text
      if (targetFormat == ConversionFormat.txt) {
        if (ext == 'pdf') return await _pdfToTxt(inputPath);
        if (ext == 'docx') return await _docxToTxt(inputPath);
        if (ext == 'pptx') return await _pptxToTxt(inputPath);
      }

      // To DOCX
      if (targetFormat == ConversionFormat.docx) {
        if (ext == 'txt') return await _txtToDocx(inputPath);
      }
      
      if (['doc', 'ppt'].contains(ext)) {
        return ConversionResult.failure('Legacy format .$ext is not directly supported. Please use modern formats (DOCX/PPTX).');
      }
      
      return ConversionResult.failure('Unsupported conversion: $ext to ${targetFormat.name.toUpperCase()}');
    } catch (e) {
      return ConversionResult.failure(e.toString());
    } finally {
      _processingPaths.remove(inputPath);
    }
  }

  Future<ConversionResult> _imageToImage(String path, ConversionFormat target) async {
    try {
      final bytes = await File(path).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return ConversionResult.failure('Failed to decode image');

      Uint8List? outBytes;
      String outExt = '';

      switch (target) {
          case ConversionFormat.jpg:
            outBytes = img.encodeJpg(image);
            outExt = 'jpg';
            break;
          case ConversionFormat.png:
            outBytes = img.encodePng(image);
            outExt = 'png';
            break;
          case ConversionFormat.webp:
            // WebP encoding not available in image package v4; fall back to PNG
            outBytes = img.encodePng(image);
            outExt = 'png';
            break;
          default:
            return ConversionResult.failure('Unsupported image target');
        }

        final outPath = await _tempManager.createTempPath('converted.$outExt');
        await File(outPath).writeAsBytes(outBytes);
        return ConversionResult(path: outPath);
        } catch (e) {
        return ConversionResult.failure('Image conversion error: $e');
        }
        }

        Future<ConversionResult> _txtToPdf(String path) async {
        final file = File(path);
        if (!await file.exists()) return ConversionResult.failure('File not found');
        final text = await file.readAsString();
    final name = path.split(Platform.pathSeparator).last;
    final outPath = await _pdfTools.textToPdf(text, title: name);
    if (outPath != null) return ConversionResult(path: outPath);
    return ConversionResult.failure('Failed to convert text to PDF');
  }

  Future<ConversionResult> _imagesToPdf(List<String> paths) async {
    final outPath = await _pdfTools.imagesToPdf(paths);
    if (outPath != null) return ConversionResult(path: outPath);
    return ConversionResult.failure('Failed to convert images to PDF');
  }

  Future<ConversionResult> _pdfToTxt(String path) async {
    return ConversionResult.failure('Direct PDF text extraction is coming soon. Use OCR for now.');
  }

  Future<ConversionResult> _docxToTxt(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final documentFile = archive.findFile('word/document.xml');
      
      if (documentFile == null) return ConversionResult.failure('Invalid DOCX: missing document.xml');

      final content = String.fromCharCodes(documentFile.content);
      final document = xml.XmlDocument.parse(content);
      
      final textNodes = document.findAllElements('w:t');
      final text = textNodes.map((node) => node.innerText).join('\n');

      final outPath = await _tempManager.createTempPath('extracted_docx.txt');
      await File(outPath).writeAsString(text);
      
      return ConversionResult(path: outPath);
    } catch (e) {
      return ConversionResult.failure('DOCX extraction error: $e');
    }
  }

  Future<ConversionResult> _pptxToTxt(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      
      String fullText = '';
      final slides = archive.files.where((f) => f.name.startsWith('ppt/slides/slide') && f.name.endsWith('.xml')).toList();
      slides.sort((a, b) => a.name.compareTo(b.name));

      for (final file in slides) {
        final content = String.fromCharCodes(file.content);
        final document = xml.XmlDocument.parse(content);
        final textNodes = document.findAllElements('a:t');
        fullText += '${textNodes.map((node) => node.innerText).join(' ')}\n\n';
      }

      if (fullText.isEmpty) return ConversionResult.failure('No text found in PPTX slides');

      final outPath = await _tempManager.createTempPath('extracted_pptx.txt');
      await File(outPath).writeAsString(fullText);
      
      return ConversionResult(path: outPath);
    } catch (e) {
      return ConversionResult.failure('PPTX extraction error: $e');
    }
  }

  Future<ConversionResult> _docxToPdf(String path) async {
    final txtResult = await _docxToTxt(path);
    if (!txtResult.success) return txtResult;
    
    final text = await File(txtResult.path).readAsString();
    final name = path.split(Platform.pathSeparator).last;
    final outPath = await _pdfTools.textToPdf(text, title: name);
    
    if (outPath != null) return ConversionResult(path: outPath);
    return ConversionResult.failure('Failed to convert DOCX to PDF');
  }

  Future<ConversionResult> _pptxToPdf(String path) async {
    final txtResult = await _pptxToTxt(path);
    if (!txtResult.success) return txtResult;
    
    final text = await File(txtResult.path).readAsString();
    final name = path.split(Platform.pathSeparator).last;
    final outPath = await _pdfTools.textToPdf(text, title: name);
    
    if (outPath != null) return ConversionResult(path: outPath);
    return ConversionResult.failure('Failed to convert PPTX to PDF');
  }

  Future<ConversionResult> _txtToDocx(String path) async {
    try {
      final text = await File(path).readAsString();
      
      // Create a very basic DOCX structure
      final archive = Archive();
      
      // [Content_Types].xml
      final contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>';
      archive.addFile(ArchiveFile('[Content_Types].xml', contentTypes.length, contentTypes.codeUnits));
      
      // _rels/.rels
      final rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>';
      archive.addFile(ArchiveFile('_rels/.rels', rels.length, rels.codeUnits));
      
      // word/document.xml
      final escapedText = text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      final paragraphs = escapedText.split('\n').map((p) => '<w:p><w:r><w:t>$p</w:t></w:r></w:p>').join();
      final documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$paragraphs</w:body></w:document>';
      archive.addFile(ArchiveFile('word/document.xml', documentXml.length, documentXml.codeUnits));
      
      final zipData = ZipEncoder().encode(archive);

      final outPath = await _tempManager.createTempPath('converted.docx');
      await File(outPath).writeAsBytes(zipData);
      
      return ConversionResult(path: outPath);
    } catch (e) {
      return ConversionResult.failure('TXT to DOCX error: $e');
    }
  }
}

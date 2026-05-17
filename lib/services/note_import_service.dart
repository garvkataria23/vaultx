import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart';

import '../models/note.dart';
import 'vault_repository.dart';
import 'decoy_seed_service.dart';

Archive _decodeZip(List<int> bytes) {
  return ZipDecoder().decodeBytes(bytes);
}

enum ImportStage {
  preparing,
  extracting,
  reading,
  importing,
  media,
  saving,
  finalizing,
  completed,
  failed,
}

class ImportStats {
  int totalNotes = 0;
  int totalFolders = 0;
  int totalMedia = 0;
  int failedFiles = 0;
  int duplicatesSkipped = 0;
  Duration timeTaken = Duration.zero;

  ImportStats();
}

/// Detailed progress callback for bulk import.
typedef ImportProgressCallback = void Function(
  ImportStage stage, 
  double progress, 
  String message,
  {int? current, int? total}
);

class NoteImportService {
  final VaultRepository? _repo;
  final bool _isDecoy;
  final _uuid = const Uuid();

  NoteImportService(this._repo, {bool isDecoy = false}) : _isDecoy = isDecoy;

  /// Imports all .txt, .pdf, and .sdocx files from a ZIP.
  Future<ImportStats> importZip({
    FilePickerResult? picked,
    required ImportProgressCallback onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final stats = ImportStats();

    try {
      onProgress(ImportStage.preparing, 0.0, 'Selecting ZIP file...');
      picked ??= await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (picked == null || picked.files.isEmpty) {
        return stats;
      }

      onProgress(ImportStage.extracting, 0.1, 'Extracting archive...');
      final file = File(picked.files.single.path!);
      final bytes = await file.readAsBytes();
      
      // Decoding can be heavy, but archive package is sync. 
      // For very large ZIPs, this might still block UI briefly, so we use compute.
      final archive = await compute(_decodeZip, bytes);
      
      onProgress(ImportStage.reading, 0.2, 'Analyzing folder structure...');
      // Filter for supported files and images
      final supportedFiles = archive.files.where((f) {
        if (!f.isFile) return false;
        final name = f.name.toLowerCase();
        return name.endsWith('.txt') || 
               name.endsWith('.pdf') || 
               name.endsWith('.sdocx') ||
               name.endsWith('.jpg') ||
               name.endsWith('.jpeg') ||
               name.endsWith('.png');
      }).toList();
      
      if (supportedFiles.isEmpty) {
        onProgress(ImportStage.failed, 1.0, 'No supported files found in ZIP.');
        return stats;
      }

      onProgress(ImportStage.importing, 0.3, 'Processing documents...');
      
      final Map<String, List<ArchiveFile>> folderGroups = {};
      for (final f in supportedFiles) {
        final pathParts = f.name.split('/');
        final folderName = pathParts.length > 1 ? pathParts[pathParts.length - 2] : 'Imported';
        folderGroups.putIfAbsent(folderName, () => []).add(f);
      }
      stats.totalFolders = folderGroups.keys.length;

      final List<SecureNote> allNotesToSave = [];
      int processedCount = 0;
      final totalToProcess = supportedFiles.length;

      for (final entry in folderGroups.entries) {
        final folderName = entry.key;
        final files = entry.value;

        for (final archiveFile in files) {
          processedCount++;
          final progress = 0.3 + (processedCount / totalToProcess) * 0.5;
          onProgress(
            ImportStage.importing, 
            progress, 
            'Processing $folderName/${archiveFile.name.split('/').last}',
            current: processedCount,
            total: totalToProcess,
          );

          try {
            final fileName = archiveFile.name.toLowerCase();
            if (fileName.endsWith('.jpg') || fileName.endsWith('.jpeg') || fileName.endsWith('.png')) {
              // In this version, we don't handle standalone images as notes, 
              // but we could attach them to notes in the same folder.
              // For simplicity now, we just count them as media.
              stats.totalMedia++;
              continue;
            }

            String content = '';
            String title = _cleanTitle(archiveFile.name);

            if (fileName.endsWith('.txt')) {
              content = utf8.decode(archiveFile.content as List<int>, allowMalformed: true);
            } else if (fileName.endsWith('.pdf')) {
              content = await _extractTextFromPdf(archiveFile.content as List<int>);
            } else if (fileName.endsWith('.sdocx')) {
              content = await _extractTextFromSdocx(archiveFile.content as List<int>);
            }
            
            if (content.trim().isEmpty) {
              content = fileName.endsWith('.pdf') 
                ? 'PDF Import: [No text could be extracted]' 
                : '[No text content found]';
            }

            final now = DateTime.now();
            allNotesToSave.add(SecureNote(
              id: _uuid.v4(),
              title: title,
              body: content,
              type: NoteType.text,
              createdAt: now,
              updatedAt: now,
              folder: folderName,
              tags: ['imported'],
            ));
            stats.totalNotes++;
          } catch (e) {
            stats.failedFiles++;
            debugPrint('Failed to process ${archiveFile.name}: $e');
          }
        }
      }

      onProgress(ImportStage.saving, 0.85, 'Saving to secure database...');
      if (allNotesToSave.isNotEmpty) {
        // Save in chunks to avoid large memory spikes during encryption/Hive write
        const chunkSize = 50;
        for (int i = 0; i < allNotesToSave.length; i += chunkSize) {
          final end = (i + chunkSize < allNotesToSave.length) ? i + chunkSize : allNotesToSave.length;
          final chunk = allNotesToSave.sublist(i, end);
          
          if (_isDecoy) {
            await DecoySeedService.saveAllNotes(chunk);
          } else if (_repo != null) {
            await _repo.saveAll(chunk);
          }
          
          final saveProgress = 0.85 + (end / allNotesToSave.length) * 0.1;
          onProgress(ImportStage.saving, saveProgress, 'Saving notes (${i + chunk.length}/${allNotesToSave.length})...');
        }
      }

      onProgress(ImportStage.finalizing, 0.95, 'Finalizing import...');
      stopwatch.stop();
      stats.timeTaken = stopwatch.elapsed;
      onProgress(ImportStage.completed, 1.0, 'Import completed successfully!');
      
    } catch (e) {
      onProgress(ImportStage.failed, 1.0, 'Import failed: $e');
      debugPrint('Import error: $e');
    }

    return stats;
  }

  Future<String> _extractTextFromPdf(List<int> bytes) async {
    try {
      final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfTextExtractor extractor = sf.PdfTextExtractor(document);
      final String text = extractor.extractText();
      document.dispose();
      return text.trim();
    } catch (e) {
      return 'PDF Import Error: $e';
    }
  }

  Future<String> _extractTextFromSdocx(List<int> bytes) async {
    try {
      final sdocxArchive = ZipDecoder().decodeBytes(bytes);
      final contentFile = sdocxArchive.files.firstWhere(
        (f) => (f.name.contains('content.xml') || f.name.contains('note.xml')) && f.isFile,
        orElse: () => throw Exception('Content XML not found'),
      );
      final xmlContent = utf8.decode(contentFile.content as List<int>, allowMalformed: true);
      final document = XmlDocument.parse(xmlContent);
      return document.innerText.trim();
    } catch (e) {
      return 'SDOCX Import Error: $e';
    }
  }

  String _cleanTitle(String fileName) {
    final name = fileName.split('/').last.split('\\').last;
    final extensions = ['.txt', '.pdf', '.sdocx'];
    for (var ext in extensions) {
      if (name.toLowerCase().endsWith(ext)) {
        return name.substring(0, name.length - ext.length);
      }
    }
    return name;
  }
}

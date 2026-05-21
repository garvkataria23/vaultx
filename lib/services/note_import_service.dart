import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart';

import '../models/note.dart';
import '../models/backup.dart';
import 'vault_repository.dart';
import 'decoy_seed_service.dart';
import 'archive_service.dart';
import 'backup_service.dart';
import 'auth_service.dart';

import 'crypto_service.dart';

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
        debugPrint('[ZIP IMPORT] No file picked or picker cancelled');
        return stats;
      }

      final fileName = picked.files.single.name;
      final filePath = picked.files.single.path;
      debugPrint('[ZIP IMPORT] Start file=$fileName path=$filePath');

      if (filePath == null) {
        debugPrint('[ZIP IMPORT] ERROR: file path is null (content URI or picker issue)');
        onProgress(ImportStage.failed, 1.0, 'Cannot access selected file. Try a different file picker.');
        return stats;
      }

      onProgress(ImportStage.extracting, 0.1, 'Extracting archive...');
      final file = File(filePath);
      final fileExists = await file.exists();
      debugPrint('[ZIP IMPORT] File exists=$fileExists');

      if (!fileExists) {
        debugPrint('[ZIP IMPORT] ERROR: file not found at path=$filePath');
        onProgress(ImportStage.failed, 1.0, 'Selected file no longer exists.');
        return stats;
      }

      final bytes = await file.readAsBytes();
      debugPrint('[ZIP IMPORT] Read bytes success size=${bytes.length}');

      // Decoding can be heavy, but archive package is sync. 
      // For very large ZIPs, this might still block UI briefly, so we use compute.
      Archive archive;
      try {
        archive = await compute(_decodeZip, bytes);
        debugPrint('[ZIP IMPORT] ZIP opened entries=${archive.length}');
      } catch (e, st) {
        debugPrint('[ZIP IMPORT] ZIP DECODE ERROR: $e\n$st');
        onProgress(ImportStage.failed, 1.0, 'Invalid or corrupted ZIP file.');
        return stats;
      }
      
      // ── Native VaultX Backup Detection ───────────────────────────────────
      final isNativeBackup = archive.files.any((f) => f.name == 'manifest.json');
      debugPrint('[ZIP IMPORT] manifest.json found=$isNativeBackup');
      if (isNativeBackup) {
        onProgress(ImportStage.reading, 0.2, 'Native backup detected...');
        return _handleNativeRestore(filePath, onProgress, stopwatch);
      }

      // ── Full Structured Export Detection ──────────────────────────────────
      final isFullExport = archive.files.any((f) => f.name.contains('vault_data.json'));
      debugPrint('[ZIP IMPORT] Full export detected=$isFullExport');
      if (isFullExport) {
        onProgress(ImportStage.reading, 0.2, 'Full export detected...');
        return _handleFullRestore(archive, onProgress, stopwatch);
      }

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
      
      debugPrint('[NoteImportService] Found ${supportedFiles.length} supported files in archive');

      if (supportedFiles.isEmpty) {
        debugPrint('[NoteImportService] No supported files found in ZIP');
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
      debugPrint('[NoteImportService] Grouped files into ${stats.totalFolders} folders');

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
            debugPrint('[NoteImportService] Failed to process ${archiveFile.name}: $e');
          }
        }
      }

      debugPrint('[NoteImportService] Finished processing, ${allNotesToSave.length} notes ready to save');

      onProgress(ImportStage.saving, 0.85, 'Saving to secure database...');
      if (allNotesToSave.isNotEmpty) {
        // Save in chunks to avoid large memory spikes during encryption/Hive write
        const chunkSize = 50;
        for (int i = 0; i < allNotesToSave.length; i += chunkSize) {
          final end = (i + chunkSize < allNotesToSave.length) ? i + chunkSize : allNotesToSave.length;
          final chunk = allNotesToSave.sublist(i, end);
          
          debugPrint('[NoteImportService] Saving batch ${i ~/ chunkSize + 1} (${chunk.length} notes)');
          
          if (_isDecoy) {
            await DecoySeedService.saveAllNotes(chunk);
          } else if (_repo != null) {
            await _repo.saveAll(chunk);
          }
          
          final saveProgress = 0.85 + (end / allNotesToSave.length) * 0.1;
          onProgress(ImportStage.saving, saveProgress, 'Saving notes (${i + chunk.length}/${allNotesToSave.length})...');
        }
        debugPrint('[NoteImportService] Successfully saved all batches');
      }

      onProgress(ImportStage.finalizing, 0.95, 'Finalizing import...');
      stopwatch.stop();
      stats.timeTaken = stopwatch.elapsed;
      debugPrint('[NoteImportService] Import completed in ${stats.timeTaken.inSeconds}s');
      onProgress(ImportStage.completed, 1.0, 'Import completed successfully!');
      
    } catch (e, st) {
      onProgress(ImportStage.failed, 1.0, 'Import failed: $e');
      debugPrint('[ZIP IMPORT] CRITICAL ERROR: $e');
      debugPrint('[ZIP IMPORT] Stack trace: $st');
    }

    return stats;
  }

  Future<ImportStats> _handleNativeRestore(
    String path,
    ImportProgressCallback onProgress,
    Stopwatch stopwatch,
  ) async {
    final stats = ImportStats();
    try {
      if (_repo == null) throw Exception('Repository not available');

      onProgress(ImportStage.extracting, 0.3, 'Extracting native backup...');
      debugPrint('[ZIP IMPORT] _handleNativeRestore start path=$path');
      final backupData = await ArchiveService.extractArchive(path);
      debugPrint('[ZIP IMPORT] Archive extract success keys=${backupData.keys}');

      final manifestJson = backupData['manifest'];
      if (manifestJson == null) {
        throw Exception('manifest.json missing in backup archive');
      }
      debugPrint('[ZIP IMPORT] JSON parsed manifest present');

      onProgress(ImportStage.importing, 0.5, 'Restoring vault data...');
      debugPrint('[ZIP IMPORT] Creating BackupService for restore');
      final backupService = BackupService(
        masterKey: _repo.masterKey,
        kind: _repo.kind,
        authService: VaultAuthService(),
        onProgress: (p) {
          final processed = p.components.fold<int>(0, (sum, c) => sum + c.itemsProcessed);
          final total = p.components.fold<int>(0, (sum, c) => sum + c.totalItems);
          final progress = 0.5 + (total > 0 ? (processed / total) * 0.4 : 0.0);
          onProgress(ImportStage.importing, progress, 'Restoring components...', current: processed, total: total);
        },
      );

      debugPrint('[ZIP IMPORT] Starting restoreBackup');
      final result = await backupService.restoreBackup(
        backupData,
        mode: RestoreMode.merge,
        mainMasterKey: _repo.masterKey,
        targetMasterKey: _repo.masterKey,
      );
      debugPrint('[ZIP IMPORT] restoreBackup completed success=${result.success}');

      if (!result.success) {
        throw Exception(result.error ?? 'Native restore failed');
      }

      onProgress(ImportStage.finalizing, 0.95, 'Finalizing...');
      stopwatch.stop();
      stats.timeTaken = stopwatch.elapsed;
      stats.totalNotes = 1;

      onProgress(ImportStage.completed, 1.0, 'Vault restored successfully!');
      debugPrint('[ZIP IMPORT] Native restore success');
    } catch (e, st) {
      onProgress(ImportStage.failed, 1.0, 'Native restore failed: $e');
      debugPrint('[ZIP IMPORT] NATIVE RESTORE ERROR: $e');
      debugPrint('[ZIP IMPORT] Stack trace: $st');
    }
    return stats;
  }

  Future<ImportStats> _handleFullRestore(
    Archive archive,
    ImportProgressCallback onProgress,
    Stopwatch stopwatch,
  ) async {
    final stats = ImportStats();
    try {
      if (_repo == null) throw Exception('Repository not available');
      final docDir = await getApplicationDocumentsDirectory();

      onProgress(ImportStage.reading, 0.3, 'Reading manifest...');
      final manifestFile = archive.files.firstWhere((f) => f.name.contains('vault_data.json'));
      final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>)) as Map<String, dynamic>;
      final blobMapping = Map<String, String>.from(manifest['blobMapping'] ?? {});
      final isDecryptedExport = manifest['exportType'] == 'fully_decrypted';

      onProgress(ImportStage.importing, 0.4, 'Restoring vault structure...');
      
      final recordsBox = Hive.box('vaultx_records');
      final driveBox = Hive.box('vaultx_drive');
      final settingsBox = Hive.box('vaultx_settings');
      final passwordsBox = Hive.box('vaultx_passwords');
      final cryptoService = CryptoService();

      int processed = 0;
      final total = archive.files.length;

      for (final file in archive.files) {
        processed++;
        if (!file.isFile) continue;
        
        final path = file.name;
        final content = file.content as List<int>;

        // 1. Restore Raw Notes (Main/Hidden)
        if (path.contains('/metadata/raw_notes/')) {
          final isMain = path.contains('/main/');
          final prefixStr = isMain ? 'main' : 'hidden';
          final data = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
          final id = data['id'];
          if (id != null) {
            await recordsBox.put('$prefixStr:$id', data);
            stats.totalNotes++;
          }
        }
        
        // 2. Restore Drive Metadata
        else if (path.contains('/metadata/drive/')) {
          final data = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
          final id = data['id'];
          final prefixStr = data['_prefix'] ?? (path.contains('main_') ? 'main' : 'hidden');
          if (id != null) {
            await driveBox.put('$prefixStr:$id', data);
          }
        }

        // 3. Restore Blobs (Images, Videos, etc.)
        else if (path.endsWith('.vxblob') || (isDecryptedExport && !path.contains('/metadata/') && !path.contains('/folders/') && !path.endsWith('.json'))) {
          final fileName = path.split('/').last;
          String id;
          if (isDecryptedExport && !path.endsWith('.vxblob')) {
            // Decrypted export format is id_name.ext
            id = fileName.split('_').first;
          } else {
            id = fileName.replaceAll('.vxblob', '');
          }
          
          final targetDirName = blobMapping[id] ?? 'vaultx_blobs';
          final targetDir = Directory('${docDir.path}/$targetDirName');
          await targetDir.create(recursive: true);

          if (isDecryptedExport && !path.endsWith('.vxblob')) {
            // Need to re-encrypt!
            // Find metadata to get salt and owner
            Map<String, dynamic>? meta;
            String? prefixStr;
            
            // Search in drive metadata first
            final driveMetaFile = archive.files.firstWhere(
              (f) => f.name.contains('/metadata/drive/') && f.name.contains(id),
              orElse: () => archive.files.firstWhere(
                (f) => f.name.contains('/metadata/raw_notes/') && f.name.contains(id),
                orElse: () => ArchiveFile('', 0, []),
              ),
            );

            if (driveMetaFile.name.isNotEmpty) {
              if (driveMetaFile.name.contains('/drive/')) {
                meta = jsonDecode(utf8.decode(driveMetaFile.content as List<int>));
                prefixStr = driveMetaFile.name.contains('hidden_') ? 'hidden' : 'main';
              }
            }

            // If we have the masterKey (which we should in NoteImportService), we can re-encrypt.
            if (_repo != null) {
              final masterKey = _repo.masterKey;
              String? salt;
              String ownerId = '';

              if (meta?['salt'] != null) {
                salt = meta!['salt'];
                ownerId = meta['id'];
                final key = cryptoService.deriveRecordKey(masterKey, '$prefixStr:$ownerId', salt!);
                final encrypted = content.length > 102400
                    ? await cryptoService.encryptBytesIsolate(content, key)
                    : cryptoService.encryptBytes(content, key);
                await File('${targetDir.path}/$id.vxblob').writeAsBytes(encrypted);
              } else {
                // If it's an attachment, we need to find its metadata in the note.
                final noteFiles = archive.files.where((f) => f.name.contains('/metadata/raw_notes/'));
                for (final nf in noteFiles) {
                  final raw = jsonDecode(utf8.decode(nf.content as List<int>));
                  final noteId = raw['id'];
                  final noteSalt = raw['salt'];
                  final recordKey = cryptoService.deriveRecordKey(masterKey, noteId, noteSalt);
                  final clear = cryptoService.decryptJson(Map<String, dynamic>.from(raw['payload']), recordKey);
                  final note = SecureNote.fromJson(clear);
                  final atts = note.attachments.where((a) => a.id == id);
                  if (atts.isNotEmpty) {
                    final att = atts.first;
                    final key = cryptoService.deriveRecordKey(masterKey, '${note.id}:${att.id}', att.salt);
                    final encrypted = content.length > 102400
                        ? await cryptoService.encryptBytesIsolate(content, key)
                        : cryptoService.encryptBytes(content, key);
                    await File('${targetDir.path}/$id.vxblob').writeAsBytes(encrypted);
                    break;
                  }
                }
              }
            }
          } else {
            // It's already encrypted (.vxblob)
            await File('${targetDir.path}/$id.vxblob').writeAsBytes(content);
          }
          stats.totalMedia++;
        }

        // 4. Restore Folders
        else if (path.contains('/folders/')) {
          final data = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
          final name = data['name'];
          final boxName = path.contains('records_') ? 'records' : 'drive';
          final prefix = data['vaultKind'] == 'hidden' ? 'hidden' : 'main';
          if (name != null) {
            final targetBox = boxName == 'records' ? recordsBox : driveBox;
            await targetBox.put('$prefix:folder_metadata:$name', data);
          }
        }

        // 5. Settings and Passwords
        else if (path.endsWith('settings.json')) {
          final data = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
          for (final entry in data.entries) {
            await settingsBox.put(entry.key, entry.value);
          }
        }
        else if (path.endsWith('passwords.json')) {
          final data = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
          for (final entry in data.entries) {
            await passwordsBox.put(entry.key, entry.value);
          }
        }

        if (processed % 20 == 0) {
          onProgress(ImportStage.importing, 0.4 + (processed / total) * 0.5, 'Restoring: ${path.split('/').last}', current: processed, total: total);
        }
      }

      onProgress(ImportStage.finalizing, 0.95, 'Finalizing...');
      stopwatch.stop();
      stats.timeTaken = stopwatch.elapsed;
      onProgress(ImportStage.completed, 1.0, 'Full vault restored successfully!');
    } catch (e, st) {
      onProgress(ImportStage.failed, 1.0, 'Full restore failed: $e');
      debugPrint('[ZIP IMPORT] FULL RESTORE ERROR: $e\n$st');
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

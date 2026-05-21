import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/note.dart';
import '../models/auth.dart';
import 'floating_notification_service.dart';
import 'share_service.dart';
import 'archive_service.dart';
import 'auth_service.dart';

import 'full_export_service.dart';

enum ExportFormat { json, csv, txt, pdf, zip }

class ExportResult {
  final String path;
  final bool success;
  final String? error;
  final int noteCount;

  ExportResult({
    required this.path,
    required this.success,
    this.error,
    required this.noteCount,
  });
}

class NoteExportService {
  NoteExportService._();
  static final NoteExportService instance = NoteExportService._();

  /// Exports the entire vault (including hidden, attachments, drive files) as a ZIP.
  Future<ExportResult> exportVaultZip({
    required Uint8List masterKey,
    required VaultKind kind,
    required VaultAuthService authService,
  }) async {
    try {
      final zipPath = await FullExportService.instance.createFullExportZip(
        masterKey: masterKey,
        authService: authService,
      );

      if (zipPath == null) {
        throw Exception('Failed to create structured export ZIP');
      }

      final tempDir = await getTemporaryDirectory();
      final exportDir = Directory('${tempDir.path}/VaultX_Exports');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      
      final timestamp = DateFormat('yyyyMMdd').format(DateTime.now());
      final finalPath = '${exportDir.path}/VaultX_Backup_$timestamp.zip';
      
      // If destination exists, delete it first
      final destFile = File(finalPath);
      if (await destFile.exists()) await destFile.delete();
      
      final finalFile = await File(zipPath).copy(finalPath);
      
      // Cleanup the original temp archive
      try { await File(zipPath).delete(); } catch(_) {}

      return ExportResult(
        path: finalFile.path,
        success: true,
        noteCount: 0, // We'll rely on the UI or manifest for counts
      );
    } catch (e) {
      return ExportResult(
        path: '',
        success: false,
        error: e.toString(),
        noteCount: 0,
      );
    }
  }

  Future<ExportResult> exportNotes({
    required List<SecureNote> notes,
    required ExportFormat format,
    String? fileName,
  }) async {
    if (notes.isEmpty) {
      return ExportResult(path: '', success: false, error: 'No notes to export', noteCount: 0);
    }

    try {
      switch (format) {
        case ExportFormat.json:
          return _exportJson(notes, fileName);
        case ExportFormat.csv:
          return _exportCsv(notes, fileName);
        case ExportFormat.txt:
          return _exportTxt(notes, fileName);
        case ExportFormat.pdf:
          return _exportPdf(notes, fileName);
        case ExportFormat.zip:
          return _exportZip(notes, fileName);
      }
    } catch (e) {
      return ExportResult(path: '', success: false, error: e.toString(), noteCount: notes.length);
    }
  }

  Future<ExportResult> _exportZip(List<SecureNote> notes, String? fileName) async {
    final data = notes.map((n) => n.toJson()).toList();
    final zipPath = await ArchiveService.createArchive({
      'notes': data,
    });
    
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final finalPath = '${dir.path}/${fileName ?? 'vaultx_export_$timestamp'}.zip';
    final finalFile = await File(zipPath).copy(finalPath);
    await ArchiveService.cleanup(zipPath);

    return ExportResult(path: finalFile.path, success: true, noteCount: notes.length);
  }

  Future<ExportResult> _exportJson(List<SecureNote> notes, String? fileName) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${fileName ?? 'vaultx_export_${DateTime.now().millisecondsSinceEpoch}'}.json';
    final file = File(path);

    final data = notes.map((n) => {
      'id': n.id,
      'title': n.title,
      'body': n.body,
      'type': n.type.name,
      'folder': n.folder,
      'tags': n.tags,
      'priority': n.priority,
      'pinned': n.pinned,
      'favorite': n.favorite,
      'archived': n.archived,
      'createdAt': n.createdAt.toIso8601String(),
      'updatedAt': n.updatedAt.toIso8601String(),
      'locked': n.locked,
    }).toList();

    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return ExportResult(path: path, success: true, noteCount: notes.length);
  }

  Future<ExportResult> _exportCsv(List<SecureNote> notes, String? fileName) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${fileName ?? 'vaultx_export_${DateTime.now().millisecondsSinceEpoch}'}.csv';
    final file = File(path);

    final buf = StringBuffer();
    buf.writeln('Title,Type,Folder,Tags,Priority,Pinned,Favorite,Archived,Body');
    for (final n in notes) {
      final body = n.body.replaceAll('"', '""');
      final tags = n.tags.join('; ');
      buf.writeln('"${n.title}","${n.type.name}","${n.folder}","$tags",${n.priority},${n.pinned},${n.favorite},${n.archived},"$body"');
    }

    await file.writeAsString(buf.toString());
    return ExportResult(path: path, success: true, noteCount: notes.length);
  }

  Future<ExportResult> _exportTxt(List<SecureNote> notes, String? fileName) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${fileName ?? 'vaultx_export_${DateTime.now().millisecondsSinceEpoch}'}.txt';
    final file = File(path);

    final buf = StringBuffer();
    final dateFmt = DateFormat('yyyy-MM-dd HH:mm');
    for (int i = 0; i < notes.length; i++) {
      final n = notes[i];
      buf.writeln('=' * 60);
      buf.writeln('Title: ${n.title}');
      buf.writeln('Type: ${n.type.name}');
      buf.writeln('Folder: ${n.folder}');
      buf.writeln('Tags: ${n.tags.join(', ')}');
      buf.writeln('Created: ${dateFmt.format(n.createdAt)}');
      buf.writeln('Updated: ${dateFmt.format(n.updatedAt)}');
      buf.writeln('Priority: ${n.priority}');
      buf.writeln('Pinned: ${n.pinned}');
      buf.writeln('');
      buf.writeln(n.body);
      if (i < notes.length - 1) buf.writeln('');
    }

    await file.writeAsString(buf.toString());
    return ExportResult(path: path, success: true, noteCount: notes.length);
  }

  Future<ExportResult> _exportPdf(List<SecureNote> notes, String? fileName) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${fileName ?? 'vaultx_export_${DateTime.now().millisecondsSinceEpoch}'}.pdf';
    final doc = pw.Document();
    final dateFmt = DateFormat('yyyy-MM-dd HH:mm');

    for (final n in notes) {
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (ctx) => [
            pw.Header(
              level: 0,
              text: n.title,
            ),
            pw.Paragraph(
              text: 'Type: ${n.type.name}  |  Folder: ${n.folder}  |  Tags: ${n.tags.join(', ')}',
              style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.Paragraph(
              text: 'Created: ${dateFmt.format(n.createdAt)}  |  Updated: ${dateFmt.format(n.updatedAt)}',
              style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 12),
            pw.Paragraph(text: n.body),
            pw.SizedBox(height: 16),
            pw.Divider(),
          ],
        ),
      );
    }

    await File(path).writeAsBytes(await doc.save());
    return ExportResult(path: path, success: true, noteCount: notes.length);
  }

  Future<void> shareExport(String path, {ExportFormat? format}) async {
    final file = File(path);
    if (!await file.exists()) {
      FloatingNotificationService.instance.show('Export file not found');
      return;
    }
    await ShareService.shareFilePath(path);
  }
}

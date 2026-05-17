import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/note.dart';
import '../models/drive_file.dart';
import 'services.dart';
import '../widgets/move_dialog.dart';

class ItemActionService {
  ItemActionService({
    required this.repo,
    required this.drive,
    required this.masterKey,
  });

  final VaultRepository repo;
  final DriveService drive;
  final Uint8List masterKey;

  // ── Notes ──────────────────────────────────────────────────────────────

  Future<void> pinNote(BuildContext context, SecureNote note) async {
    final updated = note.copyWith(pinned: !note.pinned);
    await repo.save(updated);
    if (!context.mounted) return;
    HapticFeedback.mediumImpact();
    _showSnackBar(context, updated.pinned ? 'Note pinned to top' : 'Note unpinned');
  }

  Future<void> archiveNote(BuildContext context, SecureNote note) async {
    final updated = note.copyWith(archived: !note.archived);
    await repo.save(updated);
    if (!context.mounted) return;
    HapticFeedback.lightImpact();
    _showSnackBar(context, updated.archived ? 'Note moved to archive' : 'Note restored from archive');
  }

  Future<void> deleteNote(BuildContext context, SecureNote note) async {
    await repo.delete(note.id);
    if (!context.mounted) return;
    HapticFeedback.heavyImpact();
    _showSnackBar(context, 'Note deleted');
  }

  Future<void> shareNote(BuildContext context, SecureNote note) async {
    await ShareService.shareNote(note);
    if (!context.mounted) return;
    HapticFeedback.lightImpact();
  }

  Future<void> moveNote(BuildContext context, SecureNote note) async {
    final folders = await repo.loadFolderMetadata();
    final folderNames = folders.map((f) => f.name).toList();
    if (!folderNames.contains('Private')) folderNames.add('Private');
    if (!folderNames.contains('Work')) folderNames.add('Work');
    if (!folderNames.contains('Personal')) folderNames.add('Personal');

    if (!context.mounted) return;
    final newFolder = await showDialog<String>(
      context: context,
      builder: (ctx) => MoveDialog(
        currentFolder: note.folder,
        folders: folderNames,
        title: 'Move Note',
      ),
    );

    if (newFolder != null && newFolder != note.folder) {
      final updated = note.copyWith(folder: newFolder);
      await repo.save(updated);
      if (!context.mounted) return;
      HapticFeedback.mediumImpact();
      _showSnackBar(context, 'Note moved to $newFolder');
    }
  }

  // ── Backup Exclusion Toggle ──────────────────────────────────────────

  Future<void> toggleNoteBackup(BuildContext context, SecureNote note) async {
    final updated = note.copyWith(backupExcluded: !note.backupExcluded);
    await repo.save(updated);
    if (!context.mounted) return;
    HapticFeedback.lightImpact();
    _showSnackBar(
      context,
      updated.backupExcluded
          ? 'Note set to Local Only — excluded from backups'
          : 'Note now included in backups',
    );
  }

  Future<void> lockNote(BuildContext context, SecureNote note) async {
    final updated = note.copyWith(locked: !note.locked);
    await repo.save(updated);
    if (!context.mounted) return;
    HapticFeedback.mediumImpact();
    _showSnackBar(
      context,
      updated.locked ? 'Note locked' : 'Note unlocked',
    );
  }

  Future<void> toggleFileBackup(BuildContext context, SecureDriveFile file) async {
    final updated = file.copyWith(backupExcluded: !file.backupExcluded);
    await drive.updateFile(updated);
    if (!context.mounted) return;
    HapticFeedback.lightImpact();
    _showSnackBar(
      context,
      updated.backupExcluded
          ? 'File set to Local Only — excluded from backups'
          : 'File now included in backups',
    );
  }

  // ── Files ──────────────────────────────────────────────────────────────

  Future<void> pinFile(BuildContext context, SecureDriveFile file) async {
    final updated = file.copyWith(pinned: !file.pinned);
    await drive.updateFile(updated);
    if (!context.mounted) return;
    HapticFeedback.mediumImpact();
    _showSnackBar(context, updated.pinned ? 'File pinned to top' : 'File unpinned');
  }

  Future<void> archiveFile(BuildContext context, SecureDriveFile file) async {
    final updated = file.copyWith(
      archived: !file.archived,
      archivedAt: !file.archived ? DateTime.now() : null,
    );
    await drive.updateFile(updated);
    if (!context.mounted) return;
    HapticFeedback.lightImpact();
    _showSnackBar(context, updated.archived ? 'File moved to archive' : 'File restored from archive');
  }

  Future<void> deleteFile(BuildContext context, SecureDriveFile file) async {
    await drive.deleteFile(file);
    if (!context.mounted) return;
    HapticFeedback.heavyImpact();
    _showSnackBar(context, 'File deleted');
  }

  Future<void> shareFile(BuildContext context, SecureDriveFile file) async {
    await ShareService.shareFile(file, masterKey);
    if (!context.mounted) return;
    HapticFeedback.lightImpact();
  }

  Future<void> moveFile(BuildContext context, SecureDriveFile file) async {
    final folderNames = SecureDriveFile.folders;
    
    final newFolder = await showDialog<String>(
      context: context,
      builder: (ctx) => MoveDialog(
        currentFolder: file.folder,
        folders: folderNames,
        title: 'Move File',
      ),
    );

    if (newFolder != null && newFolder != file.folder) {
      final updated = file.copyWith(folder: newFolder);
      await drive.updateFile(updated);
      if (!context.mounted) return;
      HapticFeedback.mediumImpact();
      _showSnackBar(context, 'File moved to $newFolder');
    }
  }

  void _showSnackBar(BuildContext context, String message) {
    FloatingNotificationService.instance.show(
      message,
      type: AppNotificationType.success,
    );
  }
}

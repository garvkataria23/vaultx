import 'dart:async';
import '../models/auth.dart';
import '../models/drive_file.dart';
import '../models/note.dart';
import 'drive_service.dart';
import 'vault_repository.dart';
import 'audit_log.dart';

class TrashItem {
  final dynamic originalItem;
  final String id;
  final String title;
  final DateTime deletedAt;
  final String type; // 'note', 'file', 'folder'
  final VaultKind vaultKind;

  TrashItem({
    required this.originalItem,
    required this.id,
    required this.title,
    required this.deletedAt,
    required this.type,
    required this.vaultKind,
  });

  int get daysRemaining {
    final diff = DateTime.now().difference(deletedAt).inDays;
    return 30 - diff;
  }
}

class TrashService {
  final VaultRepository repo;
  final DriveService drive;
  final VaultKind vaultKind;

  TrashService({
    required this.repo,
    required this.drive,
    required this.vaultKind,
  });

  Future<List<TrashItem>> loadAllTrash() async {
    final items = <TrashItem>[];

    // Load Notes
    final notes = await repo.loadTrashNotes();
    items.addAll(notes.map((n) => TrashItem(
      originalItem: n,
      id: n.id,
      title: n.title,
      deletedAt: n.deletedAt ?? DateTime.now(),
      type: 'note',
      vaultKind: vaultKind,
    )));

    // Load Drive Files
    final files = await drive.loadTrashFiles();
    items.addAll(files.map((f) => TrashItem(
      originalItem: f,
      id: f.id,
      title: f.name,
      deletedAt: f.deletedAt ?? DateTime.now(),
      type: 'file',
      vaultKind: vaultKind,
    )));

    // Load Drive Folders
    final folders = await drive.loadTrashFolders();
    items.addAll(folders.map((f) => TrashItem(
      originalItem: f,
      id: f.name,
      title: f.name,
      deletedAt: f.deletedAt ?? DateTime.now(),
      type: 'folder',
      vaultKind: vaultKind,
    )));

    items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return items;
  }

  Future<void> restore(TrashItem item) async {
    if (item.type == 'note') {
      await repo.restoreNote(item.originalItem as SecureNote);
    } else if (item.type == 'file') {
      await drive.restoreFile(item.originalItem as SecureDriveFile);
    } else if (item.type == 'folder') {
      await drive.restoreFolder(item.originalItem as SecureDriveFolder);
    }
  }

  Future<void> deleteForever(TrashItem item) async {
    if (item.type == 'note') {
      await repo.permanentlyDeleteNote(item.originalItem as SecureNote);
    } else if (item.type == 'file') {
      await drive.permanentlyDeleteFile(item.originalItem as SecureDriveFile);
    } else if (item.type == 'folder') {
      await drive.permanentlyDeleteFolder(item.originalItem as SecureDriveFolder);
    }
  }

  Future<void> emptyTrash() async {
    await repo.emptyTrash();
    await drive.emptyTrash();
  }

  Future<void> autoCleanup() async {
    final now = DateTime.now();
    final items = await loadAllTrash();
    bool cleaned = false;
    for (final item in items) {
      if (now.difference(item.deletedAt).inDays >= 30) {
        await deleteForever(item);
        cleaned = true;
      }
    }
    if (cleaned) {
      await AuditLog.write('Auto-cleanup: Trash items older than 30 days removed');
    }
  }
}

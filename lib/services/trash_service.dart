import 'dart:async';
import '../models/models.dart';
import 'drive_service.dart';
import 'vault_repository.dart';
import 'password_vault_service.dart';
import 'audit_log.dart';

class TrashItem {
  final dynamic originalItem;
  final String id;
  final String title;
  final DateTime deletedAt;
  final DateTime? autoDeleteAt;
  final String type; // 'note', 'file', 'folder', 'password'
  final String? originalFolder;
  final String deletedBy;
  final int size;
  final VaultKind vaultKind;

  TrashItem({
    required this.originalItem,
    required this.id,
    required this.title,
    required this.deletedAt,
    this.autoDeleteAt,
    required this.type,
    this.originalFolder,
    this.deletedBy = 'user',
    this.size = 0,
    required this.vaultKind,
  });

  int get daysRemaining {
    if (autoDeleteAt == null) return -1;
    final diff = autoDeleteAt!.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }
}

class TrashService {
  final VaultRepository repo;
  final DriveService drive;
  final PasswordVaultService passwords;
  final VaultKind vaultKind;

  TrashService({
    required this.repo,
    required this.drive,
    required this.passwords,
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
      autoDeleteAt: n.autoDeleteAt,
      type: 'note',
      originalFolder: n.originalFolder,
      deletedBy: n.deletedBy,
      vaultKind: vaultKind,
    )));

    // Load Drive Files
    final files = await drive.loadTrashFiles();
    items.addAll(files.map((f) => TrashItem(
      originalItem: f,
      id: f.id,
      title: f.name,
      deletedAt: f.deletedAt ?? DateTime.now(),
      autoDeleteAt: f.autoDeleteAt,
      type: 'file',
      originalFolder: f.originalFolder ?? f.folder,
      deletedBy: f.deletedBy,
      size: f.size,
      vaultKind: vaultKind,
    )));

    // Load Drive Folders
    final folders = await drive.loadTrashFolders();
    items.addAll(folders.map((f) => TrashItem(
      originalItem: f,
      id: f.name,
      title: f.name,
      deletedAt: f.deletedAt ?? DateTime.now(),
      autoDeleteAt: f.autoDeleteAt,
      type: 'folder',
      originalFolder: f.originalFolder,
      deletedBy: f.deletedBy,
      vaultKind: vaultKind,
    )));

    // Load Passwords
    final pws = await passwords.loadTrashEntries();
    items.addAll(pws.map((p) => TrashItem(
      originalItem: p,
      id: p.id,
      title: p.serviceName,
      deletedAt: p.deletedAt ?? DateTime.now(),
      autoDeleteAt: p.autoDeleteAt,
      type: 'password',
      originalFolder: p.originalFolder,
      deletedBy: p.deletedBy,
      vaultKind: vaultKind,
    )));

    return items;
  }

  Future<void> restore(TrashItem item) async {
    if (item.type == 'note') {
      await repo.restoreNote(item.originalItem as SecureNote);
    } else if (item.type == 'file') {
      await drive.restoreFile(item.originalItem as SecureDriveFile);
    } else if (item.type == 'folder') {
      await drive.restoreFolder(item.originalItem as SecureDriveFolder);
    } else if (item.type == 'password') {
      await passwords.restoreEntry(item.originalItem as PasswordEntry);
    }
  }

  Future<void> deleteForever(TrashItem item) async {
    if (item.type == 'note') {
      await repo.permanentlyDeleteNote(item.originalItem as SecureNote);
    } else if (item.type == 'file') {
      await drive.permanentlyDeleteFile(item.originalItem as SecureDriveFile);
    } else if (item.type == 'folder') {
      await drive.permanentlyDeleteFolder(item.originalItem as SecureDriveFolder);
    } else if (item.type == 'password') {
      await passwords.permanentlyDeleteEntry(item.originalItem as PasswordEntry);
    }
  }

  Future<void> emptyTrash() async {
    await repo.emptyTrash();
    await drive.emptyTrash();
    await passwords.emptyTrash();
    await AuditLog.write('TRASH FULLY CLEANED');
  }

  Future<void> autoCleanup() async {
    final now = DateTime.now();
    final items = await loadAllTrash();
    int cleanedCount = 0;
    
    for (final item in items) {
      if (item.autoDeleteAt != null && now.isAfter(item.autoDeleteAt!)) {
        await deleteForever(item);
        cleanedCount++;
      } else if (item.autoDeleteAt == null) {
        // Fallback for items with missing autoDeleteAt (use default 30 days)
        if (now.difference(item.deletedAt).inDays >= 30) {
          await deleteForever(item);
          cleanedCount++;
        }
      }
    }
    
    if (cleanedCount > 0) {
      await AuditLog.write('AUTO DELETE RUN: $cleanedCount items removed from trash');
    }
  }

  Future<void> updateRetentionForAll(int retentionDays) async {
    final items = await loadAllTrash();
    for (final item in items) {
      final newAutoDeleteAt = retentionDays == 0
          ? DateTime.now()
          : item.deletedAt.add(Duration(days: retentionDays));

      if (item.type == 'note') {
        final note = item.originalItem as SecureNote;
        final updated = note.copyWith(autoDeleteAt: newAutoDeleteAt);
        await repo.save(updated);
      } else if (item.type == 'file') {
        final file = item.originalItem as SecureDriveFile;
        final updated = file.copyWith(autoDeleteAt: newAutoDeleteAt);
        await drive.updateFile(updated);
      } else if (item.type == 'folder') {
        final folder = item.originalItem as SecureDriveFolder;
        final updated = folder.copyWith(autoDeleteAt: newAutoDeleteAt);
        await drive.saveFolderMetadata(updated);
      } else if (item.type == 'password') {
        final entry = item.originalItem as PasswordEntry;
        final updated = entry.copyWith(autoDeleteAt: newAutoDeleteAt);
        await passwords.save(updated);
      }
    }
    final label = retentionDays == 0 ? 'Immediate' : '$retentionDays days';
    await AuditLog.write('TRASH RETENTION UPDATED TO $label - ALL ITEMS RECALCULATED');
  }

  Future<Map<String, dynamic>> getTrashStats() async {
    final items = await loadAllTrash();
    int totalSize = 0;
    DateTime? oldest;
    DateTime? nextAutoDelete;

    for (final item in items) {
      totalSize += item.size;
      if (oldest == null || item.deletedAt.isBefore(oldest)) {
        oldest = item.deletedAt;
      }
      if (item.autoDeleteAt != null) {
        if (nextAutoDelete == null || item.autoDeleteAt!.isBefore(nextAutoDelete)) {
          nextAutoDelete = item.autoDeleteAt;
        }
      }
    }

    return {
      'count': items.length,
      'size': totalSize,
      'oldestItem': oldest,
      'nextRun': nextAutoDelete,
    };
  }
}

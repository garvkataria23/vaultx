import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../screens/note_editor.dart';

class NavigationService {
  static const String routeHome = '/home';
  static const String routeDrive = '/drive';
  static const String routeSecurity = '/security';
  static const String routePasswords = '/passwords';
  static const String routeSettings = '/settings';
  static const String routeGame = '/game';

  static Future<void> navigateTo(BuildContext context, String routeName, {Object? arguments}) async {
    await Navigator.of(context).pushNamed(routeName, arguments: arguments);
  }

  static Future<void> openNote({
    required BuildContext context,
    required SecureNote note,
    required VaultRepository? repo,
    required EncryptedBlobService? blobs,
    required List<SecureNote> allNotes,
    required Future<void> Function(SecureNote) onSave,
    bool isDecoy = false,
  }) async {
    final updated = note.copyWith(
      viewCount: note.viewCount + 1,
      lastViewedAt: DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );

    if (isDecoy) {
      await DecoySeedService.saveNote(updated);
    } else if (repo != null) {
      await repo.save(updated);
    }

    if (!context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditor(
          note: updated,
          blobs: blobs,
          allNotes: allNotes,
          onAutoSave: (edited) async {
            await onSave(edited);
          },
        ),
      ),
    );
  }
}

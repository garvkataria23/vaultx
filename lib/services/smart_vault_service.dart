import 'dart:math';
import 'dart:collection';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'note_analyzer.dart';
import 'summarization_service.dart';
import 'password_vault_service.dart';
import 'drive_service.dart';
import 'trash_service.dart';
import 'item_action_service.dart';
import 'auth_service.dart';
import 'vault_repository.dart';

class SmartVaultResult {
  final String type;
  final String title;
  final String? subtitle;
  final List<SecureNote> notes;
  final double relevance;
  final String? summary;

  const SmartVaultResult({
    required this.type,
    required this.title,
    this.subtitle,
    this.notes = const [],
    this.relevance = 1.0,
    this.summary,
  });
}

/// Context object passed to [SmartVaultService.processQuery] when the
/// query may need access to vault services (state queries, actions, etc.).
class SmartVaultContext {
  final VaultRepository? repo;
  final PasswordVaultService? passwords;
  final DriveService? drive;
  final TrashService? trash;
  final ItemActionService? itemActions;
  final VaultAuthService? auth;
  final VaultKind vaultKind;

  const SmartVaultContext({
    this.repo,
    this.passwords,
    this.drive,
    this.trash,
    this.itemActions,
    this.auth,
    this.vaultKind = VaultKind.main,
  });
}

class AIMemory {
  final String key;
  final String instruction;
  final DateTime createdAt;

  const AIMemory({
    required this.key,
    required this.instruction,
    required this.createdAt,
  });
}

class SmartVaultService {
  final NoteAnalyzerService _analyzer = NoteAnalyzerService();

  final List<AIMemory> _memories = [];
  late final Map<String, Set<String>> _thematicIndex = _buildThematicIndex();

  SmartVaultService();

  Map<String, Set<String>> _buildThematicIndex() {
    return {
      'cricket': {'cricket', 'match', 'batting', 'bowling', 'score', 'ipl', 't20', 'test', 'odi', 'sports', 'team', 'player', 'wicket', 'run'},
      'finance': {'finance', 'money', 'bank', 'account', 'payment', 'transaction', 'budget', 'expense', 'income', 'investment', 'stock', 'tax', 'salary', 'loan', 'credit', 'debit', 'invoice', 'receipt'},
      'password': {'password', 'login', 'credential', 'account', 'username', 'secret', 'auth', 'authentication', 'key', 'token', 'access'},
      'backup': {'backup', 'restore', 'mega', 'drive', 'google', 'cloud', 'sync', 'storage', 'export', 'import'},
      'flutter': {'flutter', 'dart', 'widget', 'app', 'mobile', 'code', 'snippet', 'framework', 'development'},
      'internship': {'internship', 'intern', 'job', 'work', 'career', 'experience', 'learning', 'training', 'placement', 'opportunity'},
      'health': {'health', 'doctor', 'medical', 'medicine', 'fitness', 'exercise', 'workout', 'diet', 'nutrition', 'symptom'},
      'travel': {'travel', 'trip', 'flight', 'hotel', 'booking', 'vacation', 'holiday', 'destination', 'tour'},
      'tech': {'tech', 'code', 'programming', 'software', 'hardware', 'computer', 'app', 'api', 'server', 'database'},
      'education': {'education', 'study', 'course', 'lecture', 'exam', 'assignment', 'class', 'learning', 'research'},
      'work': {'work', 'meeting', 'project', 'office', 'task', 'deadline', 'colleague', 'client', 'presentation'},
      'personal': {'personal', 'diary', 'journal', 'thought', 'idea', 'note', 'reminder', 'goal', 'habit'},
      'car': {'car', 'vehicle', 'auto', 'red', 'blue', 'black', 'white', 'drive', 'fuel', 'service', 'maintenance'},
      'screenshot': {'screenshot', 'image', 'photo', 'picture', 'capture', 'screen', 'attachment', 'media'},
    };
  }

  final String appVersion = '2.0.0';

  // ── Knowledge Base ─────────────────────────────────────────────────────
  static const List<Map<String, dynamic>> _knowledgeBase = [
    {
      'triggers': ['what is vaultx', 'about vaultx', 'tell me about vaultx', 'what does vaultx do', 'what is this app'],
      'answer': 'VaultX is a fully encrypted, offline-first vault app for storing notes, passwords, and files. Everything is encrypted with AES-256-GCM before it ever touches disk, and all AI processing happens on-device — your data never leaves this device.',
    },
    {
      'triggers': ['who made vaultx', 'who created vaultx', 'who built vaultx', 'developer', 'creator'],
      'answer': 'VaultX was created by a team focused on privacy-first digital security. The app is built with Flutter and Dart.',
    },
    {
      'triggers': ['what version', 'app version', 'current version', 'which version', 'version number'],
      'answer': 'You\'re running VaultX version {{version}}. All features run fully offline with no external dependencies.',
    },
    {
      'triggers': ['how to backup', 'how do i backup', 'backup my data', 'how to restore', 'how do i restore'],
      'answer': 'You can back up your vault from Settings > Backup & Restore. VaultX supports Google Drive and MEGA cloud backups, as well as ZIP archive export (.vxbackup format). To restore, go to the same section and choose a backup source.',
    },
    {
      'triggers': ['what is dead man', 'dead man switch', 'what is dead man switch', 'how does dead man work'],
      'answer': 'The Dead Man\'s Switch is a security feature that automatically wipes your vault if you don\'t check in within a set time. Configure it in Settings > Security Center. If enabled, you must enter your password periodically to reset the timer — failure to do so triggers an automatic vault wipe.',
    },
    {
      'triggers': ['how to change password', 'change master password', 'change my password', 'how do i change password'],
      'answer': 'Go to Settings > Security Center > Change Master Password. You\'ll need your current password to authorize the change. After changing, all future unlocks will use the new password.',
    },
    {
      'triggers': ['what is hidden vault', 'hidden vault', 'decoy mode', 'decoy calculator', 'what is decoy mode'],
      'answer': 'Hidden Vault (Decoy Mode) lets you create a separate, plausible-looking vault that opens with a different PIN. In Settings you can configure a fake calculator app as the entry point — entering your secret PIN reveals the real vault, while a wrong PIN shows the decoy vault with fake data.',
    },
    {
      'triggers': ['what is biometric', 'fingerprint unlock', 'face unlock', 'biometric unlock', 'how to enable biometric'],
      'answer': 'Biometric unlock lets you use your device\'s fingerprint or face recognition to unlock the vault. Enable it in Settings > Security Center > Biometric Unlock. VaultX uses platform-native biometric APIs (Android Keystore / iOS Secure Enclave).',
    },
    {
      'triggers': ['how to export', 'export notes', 'export data', 'how do i export'],
      'answer': 'You can export your vault data as a ZIP archive from Settings > Backup & Restore > Export as ZIP. This creates a .vxbackup file that can be transferred and imported on another device.',
    },
    {
      'triggers': ['what is capture', 'intruder selfie', 'intruder capture', 'failed attempt photo', 'what is intruder selfie'],
      'answer': 'The Intruder Selfie feature captures a photo using the front camera whenever someone enters the wrong password. You can view captured images in Security Logs. Enable it in Settings > Security Center > Intruder Selfie Capture.',
    },
    {
      'triggers': ['what features', 'feature list', 'what can vaultx do', 'all features', 'capabilities'],
      'answer': 'VaultX has many features:\n• Encrypted notes (text, checklist, voice, drawing)\n• Password manager with strong password generator\n• Encrypted file manager (Drive) with compression tools\n• Cloud backup (Google Drive, MEGA)\n• Smart AI assistant for offline note querying\n• Smart View & Categories for auto-organized notes\n• Security features: biometric unlock, hidden vault, dead man\'s switch, intruder selfie capture, time-based access\n• Trash with auto-cleanup\n• OCR text extraction from images\n• Voice transcription (Vosk, on-device)\n• Browser extension pairing for password autofill',
    },
    {
      'triggers': ['how to use ai', 'what can ai do', 'what can you do', 'help', 'what can i ask'],
      'answer': 'You can ask me about your notes (find, summarize, related notes), navigate to any screen (settings, drive, trash, etc.), check vault statistics (note count, storage, backup status), create notes, manage passwords, and learn about VaultX features. Try: "find my cricket notes", "how many notes do I have", "show me my recent notes", "create a note called Groceries", "open settings", "what is dead man switch".',
    },
    {
      'triggers': ['is my data safe', 'is vaultx secure', 'encryption', 'how secure', 'privacy'],
      'answer': 'Yes, your data is protected with AES-256-GCM encryption. Your master key never leaves your device. All AI processing is done on-device — no data is sent to cloud servers. The app uses platform security features (Android Keystore, iOS Secure Enclave) for biometric authentication.',
    },
    {
      'triggers': ['time access', 'time based access', 'schedule access', 'restrict access time'],
      'answer': 'Time-Based Access lets you restrict when the vault can be unlocked. Configure it in Settings > Security Center > Time-Based Access. You can set allowed unlock windows (e.g., 8 AM - 10 PM) — the vault cannot be unlocked outside these hours.',
    },
    {
      'triggers': ['auto lock', 'auto lock timeout', 'lock after', 'session timeout', 'auto lock timer'],
      'answer': 'You can configure auto-lock timeout in Settings. The vault will automatically lock after a period of inactivity. You can also manually lock at any time from the home screen.',
    },
  ];

  // ── Intent Patterns (ordered by priority) ──────────────────────────────
  final List<Map<String, String>> _intentPatterns = [
    // Knowledge & help queries (high priority)
    {'pattern': r'^(what is|what are|what does|who|how do|how to|tell me about|explain|about |help|feature|capa)', 'intent': 'knowledge'},
    // App state queries
    {'pattern': r'(how many|count|total|number of|note count|password count)', 'intent': 'stats'},
    {'pattern': r'(backup.*(status|when|date|last|history)|when.*(backup|last)|last.*backup)', 'intent': 'backup_status'},
    {'pattern': r'(storage|drive.*(usage|space|size|used|free))', 'intent': 'storage_status'},
    {'pattern': r'(trash.*(count|items|size)|how many.*trash)', 'intent': 'trash_status'},
    {'pattern': r'(security.*(status|enabled|on|off)|is.*(biometric|dead|intruder|time)|status.*(security|lock))', 'intent': 'security_status'},
    // Note CRUD
    {'pattern': r'^(create|make|write|new)\s+(a\s+)?note', 'intent': 'create_note'},
    {'pattern': r'(delete|remove|trash)\s+.*(note|notes)', 'intent': 'delete_note'},
    {'pattern': r'archive\s+.*(note|notes)', 'intent': 'archive_note'},
    {'pattern': r'pin\s+.*(note|notes)', 'intent': 'pin_note'},
    // Password queries
    {'pattern': r'(password|passwords|credential).*(for|of|show|find|get|search)', 'intent': 'password_query'},
    {'pattern': r'(generate|create|make|new)\s+(a\s+)?(strong\s+)?(password|pass|key)', 'intent': 'generate_password'},
    // App actions
    {'pattern': r'(empty|clear)\s+(the\s+)?trash', 'intent': 'empty_trash'},
    {'pattern': r'(lock|secure|close)\s+(the\s+)?(vault|app)', 'intent': 'lock_vault'},
    {'pattern': r'^(trigger|run|start)\s+(a\s+)?(backup|export)', 'intent': 'trigger_backup'},
    // Existing patterns
    {'pattern': r'^(summarize|summary|summarise|gist|tl;dr|tl dr)\s+', 'intent': 'summarize'},
    {'pattern': r'(duplicate|duplicates|duplicated|find\s+(same|similar|copy))', 'intent': 'duplicates'},
    {'pattern': r'(related|similar|like|same\s+as)', 'intent': 'related'},
    {'pattern': r'(pin|memory|remember|prioritize|prioritise)', 'intent': 'memory'},
    {'pattern': r'(tag|label|categorize|categorise|suggest\s+tags)', 'intent': 'tags'},
    {'pattern': r'(hidden\s+connection|find\s+connection|relate|link\s+note)', 'intent': 'connections'},
    {'pattern': r'(image|screenshot|picture|photo|media)', 'intent': 'media'},
    {'pattern': r'(voice|audio|recording|recorded)', 'intent': 'voice'},
    {'pattern': r'(insight|insights|most\s+worked|trending|popular)', 'intent': 'insights'},
    {'pattern': r'(folder|group|organize|organise|auto\s*folder|smart\s*folder)', 'intent': 'folders'},
    {'pattern': r'(today|what\s+did\s+I\s+work|recent|latest|what\s+worked)', 'intent': 'recent'},
    {'pattern': r'(from|since|last|past|this|previous)\s+(week|month|year|day|today|yesterday)', 'intent': 'timeline'},
    {'pattern': r'(ask|tell|what|who|when|where|why|how|did|does|is|are)\s+', 'intent': 'ask'},
    {'pattern': r'(find|show|get|search|display|list)\s+.*(note|notes)', 'intent': 'search'},
    {'pattern': r'(open|go\s+to|navigate\s+to|take\s+me\s+to|show\s+me)\s+(the\s+)?(home|drive|security|settings|game|backup|trash|archive|password)', 'intent': 'navigate'},
    {'pattern': r'(backup|restore)\s+(my\s+)?(data|notes|vault|settings)', 'intent': 'navigate'},
  ];

  String _detectIntent(String query) {
    for (final entry in _intentPatterns) {
      if (RegExp(entry['pattern']!, caseSensitive: false).hasMatch(query)) {
        return entry['intent']!;
      }
    }
    return 'search';
  }

  // ── Knowledge Base Lookup ─────────────────────────────────────────────
  String? _answerKnowledgeQuery(String query) {
    final lower = query.toLowerCase().trim();
    for (final entry in _knowledgeBase) {
      for (final trigger in entry['triggers'] as List<String>) {
        if (lower.contains(trigger)) {
          var answer = entry['answer'] as String;
          answer = answer.replaceAll('{{version}}', appVersion);
          return answer;
        }
      }
    }
    return null;
  }

  String _extractTitleFromCreateQuery(String query) {
    final patterns = [
      RegExp(r'(?:called|named|title[:\s]+|titled)\s+(.+?)(?:\s+with\s+content|\.|$)', caseSensitive: false),
      RegExp(r'create\s+(?:a\s+)?note\s+(?:called|named|titled\s+)?(.+?)(?:\s+with\s+|\s+about\s+|\.|$)', caseSensitive: false),
      RegExp(r'write\s+(?:a\s+)?note\s+(?:about|on|called|named|titled\s+)?(.+?)(?:\s+with\s+|\s+about\s+|\.|$)', caseSensitive: false),
      RegExp(r'new\s+note\s+(?:called|named|titled\s+)?(.+?)(?:\s+with\s+|\s+about\s+|\.|$)', caseSensitive: false),
    ];
    for (final p in patterns) {
      final match = p.firstMatch(query);
      if (match != null) {
        final title = match.group(1)!.trim();
        if (title.isNotEmpty && title.length < 100) return title;
      }
    }
    final words = query.split(RegExp(r'\s+'));
    final known = {'create', 'make', 'write', 'new', 'a', 'note', 'called', 'named', 'titled', 'with', 'content', 'about', 'for'};
    final titleWords = words.where((w) => !known.contains(w.toLowerCase())).toList();
    return titleWords.take(5).join(' ');
  }

  String _extractBodyFromCreateQuery(String query) {
    final patterns = [
      RegExp(r'(?:with\s+content|content[:\s]+|body[:\s]+)(.+?)$', caseSensitive: false),
      RegExp(r'(?:about|saying)[:\s]+(.+?)$', caseSensitive: false),
    ];
    for (final p in patterns) {
      final match = p.firstMatch(query);
      if (match != null) {
        final body = match.group(1)!.trim();
        if (body.isNotEmpty) return body;
      }
    }
    return '';
  }

  String _extractFolderFromQuery(String query) {
    final lower = query.toLowerCase();
    final folderKeywords = <String, String>{
      'finance': 'Finance', 'work': 'Work', 'personal': 'Personal',
      'tech': 'Tech', 'health': 'Health', 'education': 'Education',
      'shopping': 'Shopping', 'travel': 'Travel',
    };
    for (final entry in folderKeywords.entries) {
      final regex = RegExp(r'\b' + entry.key + r'\b', caseSensitive: false);
      if (regex.hasMatch(lower)) return entry.value;
    }
    final match = RegExp(r'folder\s+(.+?)(?:\s|$)', caseSensitive: false).firstMatch(lower);
    if (match != null) {
      final folderName = match.group(1)!.trim();
      if (folderName.isNotEmpty) return folderName[0].toUpperCase() + folderName.substring(1);
    }
    return 'General';
  }

  // ── New Intent Handlers ──────────────────────────────────────────────

  Future<SmartVaultResult> _handleKnowledge(String query) async {
    final answer = _answerKnowledgeQuery(query);
    if (answer != null) {
      return SmartVaultResult(
        type: 'knowledge',
        title: 'Knowledge',
        subtitle: answer,
      );
    }
    // Fallback: check if it's asking about app features
    if (query.toLowerCase().contains('feature') || query.toLowerCase().contains('what can')) {
      final features = _knowledgeBase.firstWhere(
        (e) => (e['triggers'] as List).contains('what features'),
        orElse: () => _knowledgeBase[0],
      );
      return SmartVaultResult(
        type: 'knowledge',
        title: 'VaultX Features',
        subtitle: (features['answer'] as String).replaceAll('{{version}}', appVersion),
      );
    }
    return const SmartVaultResult(
      type: 'empty',
      title: 'I don\'t have an answer for that',
      subtitle: 'Try asking about features, security, backup, or how-to topics. Say "help" or "what can you do" for inspiration.',
    );
  }

  Future<SmartVaultResult> _handleStats(String query, List<SecureNote> notes, SmartVaultContext? ctx) async {
    final activeNotes = notes.where((n) => !n.archived && !n.deleted).toList();
    final lower = query.toLowerCase();

    // Count specific types
    if (lower.contains('image') || lower.contains('picture') || lower.contains('screenshot') || lower.contains('media')) {
      final count = activeNotes.where((n) => n.attachments.any((a) => a.kind == 'image')).length;
      return SmartVaultResult(type: 'stats', title: '📸 Image Notes', subtitle: 'You have $count notes with images');
    }
    if (lower.contains('voice') || lower.contains('audio') || lower.contains('recording')) {
      final count = activeNotes.where((n) => n.type == NoteType.voice || n.transcript.isNotEmpty).length;
      return SmartVaultResult(type: 'stats', title: '🎤 Voice Notes', subtitle: 'You have $count voice recordings');
    }
    if (lower.contains('checklist') || lower.contains('todo') || lower.contains('task')) {
      final count = activeNotes.where((n) => n.type == NoteType.checklist).length;
      return SmartVaultResult(type: 'stats', title: '✅ Checklists', subtitle: 'You have $count checklist notes');
    }
    if (lower.contains('drawing') || lower.contains('sketch') || lower.contains('doodle')) {
      final count = activeNotes.where((n) => n.type == NoteType.drawing).length;
      return SmartVaultResult(type: 'stats', title: '🎨 Drawings', subtitle: 'You have $count drawing notes');
    }
    if (lower.contains('folder') || lower.contains('folders')) {
      final folders = activeNotes.map((n) => n.folder).toSet().toList()..sort();
      final counts = <String, int>{};
      for (final n in activeNotes) {
        counts[n.folder] = (counts[n.folder] ?? 0) + 1;
      }
      final detail = folders.map((f) => '$f (${counts[f]})').join(', ');
      return SmartVaultResult(type: 'stats', title: '📁 Folder Breakdown', subtitle: '${folders.length} folders: $detail');
    }

    // Count by specific folder
    const folderKeywords = <String>{'finance', 'work', 'personal', 'tech', 'health', 'education', 'shopping', 'travel'};
    for (final kw in folderKeywords) {
      if (lower.contains(kw) && (lower.contains('note') || lower.contains('count') || lower.contains('many') || lower.contains('total'))) {
        final folderName = kw[0].toUpperCase() + kw.substring(1);
        final count = activeNotes.where((n) => n.folder.toLowerCase() == folderName.toLowerCase()).length;
        return SmartVaultResult(type: 'stats', title: '📁 $folderName Notes', subtitle: 'You have $count notes in $folderName');
      }
    }

    // Total counts
    final noteCount = activeNotes.length;
    final archivedCount = notes.where((n) => n.archived).length;
    final deletedCount = notes.where((n) => n.deleted).length;

    final parts = <String>['$noteCount active notes'];
    if (archivedCount > 0) parts.add('$archivedCount archived');
    if (deletedCount > 0) parts.add('$deletedCount in trash');

    // Password count if available
    String? pwInfo;
    if (ctx?.passwords != null) {
      try {
        final pwEntries = await ctx!.passwords!.loadActiveEntries();
        pwInfo = ' • ${pwEntries.length} password entries';
      } catch (_) {}
    }

    return SmartVaultResult(
      type: 'stats',
      title: '📊 Vault Statistics',
      subtitle: parts.join(', ') + (pwInfo ?? ''),
    );
  }

  Future<SmartVaultResult> _handleBackupStatus(SmartVaultContext? ctx) async {
    // We can't access Hive boxes directly from here, but we can check backup metadata
    try {
      final box = await Hive.openBox('vaultx_backup_meta');
      final lastBackup = box.get('last_backup_timestamp');
      final lastProvider = box.get('last_backup_provider') ?? 'Unknown';
      final autoBackup = box.get('auto_backup_enabled') ?? false;

      String subtitle;
      if (lastBackup != null) {
        final date = DateTime.fromMillisecondsSinceEpoch(lastBackup as int);
        final diff = DateTime.now().difference(date);
        String ago;
        if (diff.inMinutes < 60) {
          ago = '${diff.inMinutes} minutes ago';
        } else if (diff.inHours < 24) {
          ago = '${diff.inHours} hours ago';
        } else if (diff.inDays < 7) {
          ago = '${diff.inDays} days ago';
        } else {
          ago = '${date.month}/${date.year}';
        }
        subtitle = 'Last backup: $ago via $lastProvider';
      } else {
        subtitle = 'No backup has been performed yet. Go to Settings > Backup & Restore to create one.';
      }
      if (autoBackup == true) subtitle += ' • Auto-backup is enabled';

      await box.close();
      return SmartVaultResult(type: 'backup_status', title: '💾 Backup Status', subtitle: subtitle);
    } catch (_) {
      return const SmartVaultResult(
        type: 'backup_status',
        title: '💾 Backup Status',
        subtitle: 'Backup info not available. Go to Settings > Backup & Restore to configure.',
      );
    }
  }

  Future<SmartVaultResult> _handleStorageStatus(SmartVaultContext? ctx) async {
    try {
      // Get drive file stats
      String? driveInfo;
      if (ctx?.drive != null) {
        final files = await ctx!.drive!.loadFiles();
        final totalSize = files.fold<int>(0, (s, f) => s + f.size);
        final fileTypes = <String, int>{};
        for (final f in files) {
          final ext = f.name.contains('.') ? f.name.split('.').last.toUpperCase() : 'FILE';
          fileTypes[ext] = (fileTypes[ext] ?? 0) + 1;
        }
        final sizeStr = totalSize > 1048576
            ? '${(totalSize / 1048576).toStringAsFixed(1)} MB'
            : totalSize > 1024
                ? '${(totalSize / 1024).toStringAsFixed(1)} KB'
                : '$totalSize B';
        driveInfo = '$sizeStr across ${files.length} files (${fileTypes.length} types)';
      }

      // Note storage
      if (ctx?.repo != null) {
        final notes = await ctx!.repo!.loadNotes();
        final active = notes.where((n) => !n.deleted);
        final totalChars = active.fold<int>(0, (s, n) => s + n.title.length + n.body.length);
        final noteStorage = totalChars > 1048576
            ? '${(totalChars / 1048576).toStringAsFixed(1)} MB'
            : totalChars > 1024
                ? '${(totalChars / 1024).toStringAsFixed(1)} KB'
                : '$totalChars B';

        final parts = <String>['Notes: ~$noteStorage'];
        if (driveInfo != null) parts.add('Drive: $driveInfo');

        return SmartVaultResult(
          type: 'storage_status',
          title: '💿 Storage Overview',
          subtitle: parts.join('\n'),
        );
      }

      if (driveInfo != null) {
        return SmartVaultResult(
          type: 'storage_status',
          title: '💿 Drive Storage',
          subtitle: driveInfo,
        );
      }

      return const SmartVaultResult(
        type: 'storage_status',
        title: '💿 Storage',
        subtitle: 'Storage details are not available right now.',
      );
    } catch (_) {
      return const SmartVaultResult(
        type: 'storage_status',
        title: '💿 Storage',
        subtitle: 'Could not retrieve storage information.',
      );
    }
  }

  Future<SmartVaultResult> _handleTrashStatus(SmartVaultContext? ctx) async {
    if (ctx?.trash == null) {
      return const SmartVaultResult(
        type: 'trash_status',
        title: '🗑️ Trash',
        subtitle: 'Trash service not available.',
      );
    }
    try {
      final items = await ctx!.trash!.loadAllTrash();
      if (items.isEmpty) {
        return const SmartVaultResult(
          type: 'trash_status',
          title: '🗑️ Trash is Empty',
          subtitle: 'No deleted items.',
        );
      }
      final typeCounts = <String, int>{};
      int totalSize = 0;
      for (final item in items) {
        typeCounts[item.type] = (typeCounts[item.type] ?? 0) + 1;
        totalSize += item.size;
      }
      final detail = typeCounts.entries.map((e) => '${e.value} ${e.key}${e.value > 1 ? 's' : ''}').join(', ');
      final oldest = items.map((i) => i.deletedAt).reduce((a, b) => a.isBefore(b) ? a : b);
      String subtitle = '$detail in trash';
      if (totalSize > 0) {
        subtitle += ' (${totalSize > 1048576 ? '${(totalSize / 1048576).toStringAsFixed(1)} MB' : '${(totalSize / 1024).toStringAsFixed(1)} KB'})';
      }
      subtitle += ' • Oldest item: ${oldest.month}/${oldest.day}';
      return SmartVaultResult(type: 'trash_status', title: '🗑️ ${items.length} Items in Trash', subtitle: subtitle);
    } catch (_) {
      return const SmartVaultResult(
        type: 'trash_status',
        title: '🗑️ Trash',
        subtitle: 'Could not load trash information.',
      );
    }
  }

  Future<SmartVaultResult> _handleSecurityStatus(SmartVaultContext? ctx) async {
    final parts = <String>[];

    if (ctx?.auth != null) {
      final bioAvail = await ctx!.auth!.biometricAvailable();
      final bioEnabled = await ctx.auth!.isBiometricUnlockAvailable();
      parts.add('🔓 Biometric: ${bioEnabled ? 'Enabled' : bioAvail ? 'Available (not set up)' : 'Not available on this device'}');
    }

    // Check for dead man's switch
    try {
      final dmBox = await Hive.openBox('vaultx_deadman');
      final dmEnabled = dmBox.get('enabled') ?? false;
      if (dmEnabled == true) {
        final gracePeriod = dmBox.get('grace_days') ?? 7;
        parts.add('💀 Dead Man\'s Switch: Active ($gracePeriod day grace period)');
      } else {
        parts.add('💀 Dead Man\'s Switch: Disabled');
      }
      await dmBox.close();
    } catch (_) {}

    // Intruder capture
    try {
      final intruderBox = await Hive.openBox('vaultx_intruder');
      final captureEnabled = intruderBox.get('capture_enabled') ?? false;
      parts.add('📸 Intruder Capture: ${captureEnabled == true ? 'On' : 'Off'}');
      await intruderBox.close();
    } catch (_) {}

    return SmartVaultResult(
      type: 'security_status',
      title: '🔒 Security Status',
      subtitle: parts.join('\n'),
    );
  }

  Future<SmartVaultResult> _handleCreateNote(String query, SmartVaultContext? ctx) async {
    if (ctx?.repo == null) {
      return const SmartVaultResult(
        type: 'error',
        title: 'Cannot create note',
        subtitle: 'Repository not available.',
      );
    }
    final title = _extractTitleFromCreateQuery(query);
    if (title.isEmpty) {
      return const SmartVaultResult(
        type: 'error',
        title: 'What should I name the note?',
        subtitle: 'Try: "create a note called Groceries with content milk, eggs, bread"',
      );
    }
    final body = _extractBodyFromCreateQuery(query);
    final folder = _extractFolderFromQuery(query);

    try {
      final note = SecureNote(
        id: const Uuid().v4(),
        title: title,
        body: body,
        folder: folder,
        type: NoteType.text,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await ctx!.repo!.save(note);

      return SmartVaultResult(
        type: 'create_note',
        title: '✅ Note Created',
        subtitle: '"$title" saved in $folder folder${body.isNotEmpty ? '\n\n$body' : ''}',
        notes: [note],
      );
    } catch (e) {
      return SmartVaultResult(
        type: 'error',
        title: 'Failed to create note',
        subtitle: e.toString(),
      );
    }
  }

  Future<SmartVaultResult> _handleDeleteNote(String query, List<SecureNote> notes, SmartVaultContext? ctx) async {
    if (ctx?.repo == null) {
      return const SmartVaultResult(type: 'error', title: 'Cannot delete notes', subtitle: 'Repository not available.');
    }
    final matchedNote = _findBestMention(notes, query);
    if (matchedNote == null) {
      return SmartVaultResult(
        type: 'error',
        title: 'Which note should I delete?',
        subtitle: 'Try: "delete my cricket notes" or "remove notes about finance"',
      );
    }

    try {
      await ctx!.repo!.moveToTrash(matchedNote);
      return SmartVaultResult(
        type: 'action_done',
        title: '🗑️ Note Deleted',
        subtitle: '"${matchedNote.title}" has been moved to trash.',
        notes: [matchedNote],
      );
    } catch (e) {
      return SmartVaultResult(type: 'error', title: 'Failed to delete note', subtitle: e.toString());
    }
  }

  Future<SmartVaultResult> _handleArchiveNote(String query, List<SecureNote> notes, SmartVaultContext? ctx) async {
    if (ctx?.itemActions == null && ctx?.repo == null) {
      return const SmartVaultResult(type: 'error', title: 'Cannot archive notes', subtitle: 'Services not available.');
    }
    final matchedNote = _findBestMention(notes, query);
    if (matchedNote == null) {
      return SmartVaultResult(
        type: 'error',
        title: 'Which note should I archive?',
        subtitle: 'Try: "archive my finance notes" or "archive last week notes"',
      );
    }

    try {
      final updated = matchedNote.copyWith(archived: !matchedNote.archived);
      await ctx!.repo!.save(updated);
      return SmartVaultResult(
        type: 'action_done',
        title: matchedNote.archived ? '📦 Note Unarchived' : '📦 Note Archived',
        subtitle: '"${matchedNote.title}" has been ${matchedNote.archived ? 'restored from' : 'moved to'} archive.',
        notes: [updated],
      );
    } catch (e) {
      return SmartVaultResult(type: 'error', title: 'Failed to archive note', subtitle: e.toString());
    }
  }

  Future<SmartVaultResult> _handlePinNote(String query, List<SecureNote> notes, SmartVaultContext? ctx) async {
    if (ctx?.repo == null) {
      return const SmartVaultResult(type: 'error', title: 'Cannot pin notes', subtitle: 'Repository not available.');
    }
    final matchedNote = _findBestMention(notes, query);
    if (matchedNote == null) {
      return SmartVaultResult(
        type: 'error',
        title: 'Which note should I pin?',
        subtitle: 'Try: "pin my finance notes" or "pin the cricket notes"',
      );
    }

    try {
      final updated = matchedNote.copyWith(pinned: !matchedNote.pinned);
      await ctx!.repo!.save(updated);
      return SmartVaultResult(
        type: 'action_done',
        title: updated.pinned ? '📌 Note Pinned' : '📌 Note Unpinned',
        subtitle: '"${matchedNote.title}" is ${updated.pinned ? 'now pinned to top' : 'no longer pinned'}',
        notes: [updated],
      );
    } catch (e) {
      return SmartVaultResult(type: 'error', title: 'Failed to pin note', subtitle: e.toString());
    }
  }

  Future<SmartVaultResult> _handlePasswordQuery(String query, SmartVaultContext? ctx) async {
    if (ctx?.passwords == null) {
      return const SmartVaultResult(
        type: 'error',
        title: 'Password manager not available',
        subtitle: 'The password service is not initialized.',
      );
    }
    try {
      final entries = await ctx!.passwords!.loadActiveEntries();
      if (entries.isEmpty) {
        return const SmartVaultResult(
          type: 'password_query',
          title: '🔑 No Passwords Stored',
          subtitle: 'You haven\'t saved any passwords yet. Go to Password Manager to add some.',
        );
      }

      final lower = query.toLowerCase();
      final searchTerms = lower
          .replaceAll(RegExp(r'(show|me|find|get|search|my|password|passwords|credential|for|of|the|a|an)'), '')
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 1)
          .toList();

      if (searchTerms.isNotEmpty) {
        final matched = entries.where((e) =>
          e.serviceName.toLowerCase().contains(searchTerms.first) ||
          e.username.toLowerCase().contains(searchTerms.first) ||
          e.tags.any((t) => t.toLowerCase().contains(searchTerms.first))).toList();

        if (matched.isNotEmpty) {
          final entry = matched.first;
          return SmartVaultResult(
            type: 'password_query',
            title: '🔑 ${entry.serviceName}',
            subtitle: 'Username: ${entry.username}\nPassword: •••••••• (view in Password Manager)\nTags: ${entry.tags.isEmpty ? "none" : entry.tags.join(", ")}',
          );
        }
      }

      return SmartVaultResult(
        type: 'password_query',
        title: '🔑 ${entries.length} Password Entries',
        subtitle: entries.map((e) => '• ${e.serviceName} (${e.username})').take(10).join('\n'),
      );
    } catch (e) {
      return SmartVaultResult(type: 'error', title: 'Could not load passwords', subtitle: e.toString());
    }
  }

  Future<SmartVaultResult> _handleGeneratePassword() async {
    // Generate a cryptographically-strong random password
    final length = 24;
    final upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final lower = 'abcdefghijklmnopqrstuvwxyz';
    final digits = '0123456789';
    final special = '!@#\$%^&*()-_=+[]{}|;:,.<>?';
    final all = upper + lower + digits + special;

    final random = Random.secure();

    // Ensure at least one of each type
    final pw = StringBuffer();
    pw.write(upper[random.nextInt(upper.length)]);
    pw.write(lower[random.nextInt(lower.length)]);
    pw.write(digits[random.nextInt(digits.length)]);
    pw.write(special[random.nextInt(special.length)]);
    for (var i = 4; i < length; i++) {
      pw.write(all[random.nextInt(all.length)]);
    }

    // Shuffle
    final chars = pw.toString().split('');
    chars.shuffle(random);
    final finalPw = chars.join();

    return SmartVaultResult(
      type: 'generate_password',
      title: '🔐 Generated Password',
      subtitle: '$finalPw\n\nLength: $length characters • Mixed case + numbers + symbols\nCopy it from Password Manager.',
    );
  }

  Future<SmartVaultResult> _handleEmptyTrash(SmartVaultContext? ctx) async {
    if (ctx?.trash == null) {
      return const SmartVaultResult(type: 'error', title: 'Cannot empty trash', subtitle: 'Trash service not available.');
    }
    try {
      await ctx!.trash!.emptyTrash();
      return const SmartVaultResult(
        type: 'action_done',
        title: '🗑️ Trash Emptied',
        subtitle: 'All deleted items have been permanently removed.',
      );
    } catch (e) {
      return SmartVaultResult(type: 'error', title: 'Failed to empty trash', subtitle: e.toString());
    }
  }

  Future<SmartVaultResult> _handleLockVault() async {
    return const SmartVaultResult(
      type: 'lock_vault',
      title: '🔒 Locking Vault',
      subtitle: 'The vault will be locked...',
    );
  }

  Future<SmartVaultResult> _handleTriggerBackup(SmartVaultContext? ctx) async {
    return const SmartVaultResult(
      type: 'trigger_backup',
      title: '📤 Starting Backup',
      subtitle: 'Opening backup screen...',
    );
  }

  List<String> _expandQuery(String query) {
    final expanded = <String>{};
    final lower = query.toLowerCase();
    final words = lower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();

    for (final word in words) {
      expanded.add(word);
      for (final entry in _thematicIndex.entries) {
        if (entry.value.contains(word)) {
          expanded.addAll(entry.value);
        }
      }
    }
    return expanded.toList();
  }

  List<SecureNote> _filterByTime(List<SecureNote> notes, String query) {
    final now = DateTime.now();
    final lower = query.toLowerCase();

    Duration? range;
    if (lower.contains('today') || lower.contains('this day')) {
      range = const Duration(days: 1);
    } else if (lower.contains('yesterday')) {
      final yesterday = now.subtract(const Duration(days: 1));
      return notes.where((n) =>
        n.createdAt.year == yesterday.year &&
        n.createdAt.month == yesterday.month &&
        n.createdAt.day == yesterday.day).toList();
    } else if (lower.contains('this week')) {
      range = const Duration(days: 7);
    } else if (lower.contains('last week')) {
      final start = now.subtract(const Duration(days: 14));
      final end = now.subtract(const Duration(days: 7));
      return notes.where((n) =>
        n.createdAt.isAfter(start) && n.createdAt.isBefore(end)).toList();
    } else if (lower.contains('this month')) {
      range = const Duration(days: 30);
    } else if (lower.contains('last month')) {
      final start = now.subtract(const Duration(days: 60));
      final end = now.subtract(const Duration(days: 30));
      return notes.where((n) =>
        n.createdAt.isAfter(start) && n.createdAt.isBefore(end)).toList();
    } else if (lower.contains('this year')) {
      range = const Duration(days: 365);
    } else if (lower.contains('last year')) {
      final start = now.subtract(const Duration(days: 730));
      final end = now.subtract(const Duration(days: 365));
      return notes.where((n) =>
        n.createdAt.isAfter(start) && n.createdAt.isBefore(end)).toList();
    } else if (lower.contains('past 7') || lower.contains('7 days') || lower.contains('one week')) {
      range = const Duration(days: 7);
    } else if (lower.contains('past 30') || lower.contains('30 days') || lower.contains('one month')) {
      range = const Duration(days: 30);
    } else if (lower.contains('past 90') || lower.contains('90 days') || lower.contains('three month')) {
      range = const Duration(days: 90);
    }

    if (range != null) {
      final cutoff = now.subtract(range);
      return notes.where((n) => n.createdAt.isAfter(cutoff)).toList();
    }

    return notes;
  }

  List<SecureNote> _filterByFolder(List<SecureNote> notes, String query) {
    final lower = query.toLowerCase();
    final folderKeywords = <String, String>{
      'finance': 'Finance', 'bank': 'Finance', 'money': 'Finance',
      'work': 'Work', 'office': 'Work', 'project': 'Work',
      'personal': 'Personal', 'diary': 'Personal',
      'tech': 'Tech', 'code': 'Tech', 'programming': 'Tech',
      'health': 'Health', 'medical': 'Health', 'fitness': 'Health',
      'education': 'Education', 'study': 'Education', 'college': 'Education',
      'shopping': 'Shopping', 'receipt': 'Receipts',
      'travel': 'Travel', 'trip': 'Travel',
      'password': 'Passwords', 'login': 'Passwords',
    };

    for (final entry in folderKeywords.entries) {
      if (lower.contains(entry.key)) {
        return notes.where((n) =>
          n.folder.toLowerCase() == entry.value.toLowerCase()).toList();
      }
    }
    return notes;
  }

  double _tfIdfSimilarity(String text, List<String> queryTerms) {
    if (queryTerms.isEmpty || text.isEmpty) return 0.0;

    final lower = text.toLowerCase();
    final tokens = lower.split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return 0.0;

    final tf = HashMap<String, double>();
    final totalTerms = tokens.length;
    for (final token in tokens) {
      tf[token] = (tf[token] ?? 0.0) + 1.0 / totalTerms;
    }

    double score = 0.0;
    for (final term in queryTerms) {
      final termLower = term.toLowerCase();
      double termScore = 0.0;

      for (final entry in tf.entries) {
        if (entry.key == termLower) {
          termScore += entry.value * 1.0;
        } else if (entry.key.startsWith(termLower) || termLower.startsWith(entry.key)) {
          termScore += entry.value * 0.7;
        } else if (_levenshteinSimilarity(entry.key, termLower) > 0.7) {
          termScore += entry.value * 0.5;
        }
      }

      if (termScore > 0) {
        final idf = 1.0 + log(1.0 / (1.0 + termScore));
        score += termScore * idf;
      }
    }

    return score;
  }

  double _levenshteinSimilarity(String a, String b) {
    if (a.length < b.length) {
      final tmp = a; a = b; b = tmp;
    }
    if (b.isEmpty) return a.isEmpty ? 1.0 : 0.0;

    var prev = List.generate(b.length + 1, (i) => i);
    var curr = List.generate(b.length + 1, (i) => 0);

    for (var i = 0; i < a.length; i++) {
      curr[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        curr[j + 1] = min(min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }

    final maxLen = max(a.length, b.length);
    return 1.0 - (prev[b.length] / maxLen);
  }

  SecureNote? _findBestMention(List<SecureNote> notes, String query) {
    final lower = query.toLowerCase();
    final stopWords = {'the', 'a', 'an', 'is', 'are', 'was', 'were', 'my', 'our', 'your', 'his', 'her', 'its', 'their', 'about', 'from', 'where', 'what', 'when', 'how', 'show', 'find', 'get', 'list', 'display', 'search', 'note', 'notes', 'all', 'with', 'that', 'this', 'these', 'those'};

    final words = lower
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2 && !stopWords.contains(w))
        .toList();

    if (words.isEmpty) return null;

    final expandedTerms = _expandQuery(query);
    final queryTerms = [...words, ...expandedTerms];

    SecureNote? best;
    double bestScore = 0.0;

    for (final note in notes) {
      final text = '${note.title} ${note.body} ${note.summary} ${note.ocrText} ${note.transcript}';
      double score = _tfIdfSimilarity(text, queryTerms);

      if (note.title.isNotEmpty) {
        final titleScore = _tfIdfSimilarity(note.title, words) * 2.0;
        score += titleScore;
      }

      for (final tag in note.tags) {
        if (words.any((w) => tag.toLowerCase().contains(w))) {
          score += 1.5;
        }
      }

      final noteWords = note.body.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
      for (final qWord in words) {
        if (noteWords.contains(qWord)) {
          score += 1.0;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        best = note;
      }
    }

    return bestScore > 0.5 ? best : null;
  }

  List<SecureNote> _findRelatedNotesByContent(SecureNote note, List<SecureNote> allNotes) {
    final results = <_ScoredNote>[];
    final noteTokens = _tokenSet('${note.title} ${note.body} ${note.summary}');

    for (final other in allNotes) {
      if (other.id == note.id) continue;
      final otherTokens = _tokenSet('${other.title} ${other.body} ${other.summary}');
      if (noteTokens.isEmpty || otherTokens.isEmpty) continue;

      final intersection = noteTokens.intersection(otherTokens).length;
      final union = noteTokens.union(otherTokens).length;
      final jaccard = union > 0 ? intersection / union : 0.0;

      final sharedTags = note.tags.toSet().intersection(other.tags.toSet()).length;
      final tagScore = sharedTags * 0.2;

      final totalScore = jaccard * 0.8 + tagScore * 0.2;
      if (totalScore > 0.15) {
        results.add(_ScoredNote(other, totalScore));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(5).map((r) => r.note).toList();
  }

  Set<String> _tokenSet(String text) {
    return text.toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length > 2)
        .toSet();
  }

  String? _extractDateQuery(String query) {
    final lower = query.toLowerCase();
    if (lower.contains('today')) return 'today';
    if (lower.contains('yesterday')) return 'yesterday';
    if (lower.contains('this week')) return 'this week';
    if (lower.contains('last week')) return 'last week';
    if (lower.contains('this month')) return 'this month';
    if (lower.contains('last month')) return 'last month';
    if (lower.contains('this year')) return 'this year';
    if (lower.contains('last year')) return 'last year';
    if (lower.contains('last 7') || lower.contains('past 7') || lower.contains('7 days')) return '7 days';
    if (lower.contains('last 30') || lower.contains('past 30') || lower.contains('30 days')) return '30 days';
    return null;
  }

  String? _extractTopic(String query) {
    final lower = query.toLowerCase();
    final stopWords = {'the', 'a', 'an', 'is', 'are', 'was', 'were', 'my', 'our', 'your', 'his', 'her', 'its', 'their', 'about', 'from', 'where', 'what', 'when', 'how', 'show', 'find', 'get', 'list', 'display', 'search', 'note', 'notes', 'all', 'with', 'that', 'this', 'these', 'those', 'me', 'i', 'wrote', 'write', 'written', 'containing', 'for', 'in', 'on', 'at', 'by', 'to', 'of', 'and', 'or', 'if', 'then', 'else'};

    final words = lower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
    final contentWords = words.where((w) => w.length > 2 && !stopWords.contains(w)).toList();

    if (contentWords.length <= 3) {
      return contentWords.join(' ');
    }

    final dateWords = {'today', 'yesterday', 'week', 'month', 'year', 'day', 'last', 'this', 'past', 'previous'};
    final filtered = contentWords.where((w) => !dateWords.contains(w)).toList();
    return filtered.take(3).join(' ');
  }

  List<String> _generateSmartSuggestions(List<SecureNote> notes) {
    final suggestions = <String>[
      'How many notes do I have',
      'Show notes from today',
      'What is dead man switch',
      'Create a note called Ideas',
      'Open settings',
      'Find my passwords',
      'Generate a strong password',
      'Summarize my notes',
      'Show related notes',
      'Check backup status',
      'Check security status',
      'Show trash status',
      'Show storage usage',
      'Find duplicate notes',
      'Show notes with images',
      'Find voice recordings',
      'Show note insights',
      'Organize my folders',
      'Archive my notes',
      'Pin important notes',
      'Lock the vault',
      'Empty the trash',
      'Start a backup',
      'Show recent notes',
      'Show notes from last week',
      'Notes from this month',
      'Open password manager',
      'Go to drive',
      'Take me to trash',
      'Open security center',
      'What can VaultX do',
      'Tell me about this app',
      'How to backup my data',
      'What is hidden vault',
      'How to change password',
      'What is intruder selfie',
      'How to enable biometrics',
      'What is auto-lock timer',
      'Is my data safe',
    ];

    if (notes.any((n) => n.attachments.isNotEmpty && n.attachments.any((a) => a.kind == 'image'))) {
      suggestions.add('Show notes containing screenshots');
    }

    if (notes.any((n) => n.type == NoteType.voice)) {
      suggestions.add('Find voice recordings');
    }

    if (notes.any((n) => n.tags.contains('work') || n.folder.toLowerCase() == 'work')) {
      suggestions.add('What did I work on today');
    }

    if (notes.any((n) => n.folder.toLowerCase() == 'finance')) {
      suggestions.add('Summarize my finance notes');
    }

    if (notes.length > 5) {
      suggestions.add('Show me my recent notes');
      suggestions.add('Find related notes');
    }

    return suggestions;
  }

  String _generateSummary(List<SecureNote> notes, String topic) {
    if (notes.isEmpty) return '';
    if (notes.length == 1) {
      final s = SummarizationService.summarize(notes[0].body, maxSentences: 3);
      return s.isNotEmpty ? s : notes[0].body.length > 200 ? '${notes[0].body.substring(0, 200)}...' : notes[0].body;
    }

    final combined = notes.map((n) => '${n.title}: ${n.body}').join('\n');
    final s = SummarizationService.summarize(combined, maxSentences: 4);
    return s.isNotEmpty ? s : 'Found ${notes.length} notes about "$topic"';
  }

  String _generateInsight(List<SecureNote> notes) {
    if (notes.isEmpty) return 'Start creating notes to see insights';

    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    const monthAgo = Duration(days: 30);

    final thisWeek = notes.where((n) => n.createdAt.isAfter(weekAgo)).toList();
    final thisMonth = notes.where((n) => n.createdAt.isAfter(now.subtract(monthAgo))).toList();

    final folderCounts = <String, int>{};
    for (final n in notes) {
      folderCounts[n.folder] = (folderCounts[n.folder] ?? 0) + 1;
    }
    final topFolder = folderCounts.entries.fold<MapEntry<String, int>?>(
      null,
      (best, curr) => best == null || curr.value > best.value ? curr : best,
    );

    final tagCounts = <String, int>{};
    for (final n in notes) {
      for (final tag in n.tags) {
        tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      }
    }
    final topTag = tagCounts.entries.fold<MapEntry<String, int>?>(
      null,
      (best, curr) => best == null || curr.value > best.value ? curr : best,
    );

    final parts = <String>[];
    parts.add('You have ${notes.length} total notes');

    if (thisWeek.isNotEmpty) {
      parts.add('${thisWeek.length} created this week');
    }

    if (thisMonth.isNotEmpty) {
      parts.add('${thisMonth.length} this month');
    }

    if (topFolder != null) {
      parts.add('Most used folder: ${topFolder.key} (${topFolder.value} notes)');
    }

    if (topTag != null) {
      parts.add('Most used tag: #${topTag.key} (${topTag.value} notes)');
    }

    return parts.join(' • ');
  }

  String? _findHiddenConnection(List<SecureNote> allNotes) {
    if (allNotes.length < 2) return 'Add more notes to discover hidden connections';

    for (var i = 0; i < allNotes.length; i++) {
      for (var j = i + 1; j < allNotes.length; j++) {
        final a = allNotes[i];
        final b = allNotes[j];
        final aTokens = _tokenSet('${a.title} ${a.body}');
        final bTokens = _tokenSet('${b.title} ${b.body}');
        final shared = aTokens.intersection(bTokens);

        if (shared.length >= 3) {
          final sharedWords = shared.take(3).join(', ');
          return '"${a.title}" relates to "${b.title}" via shared terms: $sharedWords';
        }
      }
    }

    for (var i = 0; i < allNotes.length; i++) {
      for (var j = i + 1; j < allNotes.length; j++) {
        final a = allNotes[i];
        final b = allNotes[j];
        final sharedTags = a.tags.toSet().intersection(b.tags.toSet());
        if (sharedTags.isNotEmpty && a.folder != b.folder) {
          return '"${a.title}" and "${b.title}" share tags #${sharedTags.first} across different folders';
        }
      }
    }

    return null;
  }

  Future<SmartVaultResult> _handleConnections(List<SecureNote> notes) async {
    final connection = _findHiddenConnection(notes);
    if (connection == null) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No hidden connections found',
        subtitle: 'Connections appear when notes share topics across different contexts',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'connections',
      title: '🔗 Hidden Connection Found',
      subtitle: connection,
      notes: notes,
    );
  }

  String? _getPinnedMemoryResponse(String query) {
    final lower = query.toLowerCase();

    for (final memory in _memories) {
      if (lower.contains(memory.key.toLowerCase())) {
        return memory.instruction;
      }
    }

    if (lower.contains('pin') || lower.contains('remember') || lower.contains('prioritize') || lower.contains('prioritise')) {
      final words = lower.split(RegExp(r'[^a-z0-9]+'));
      final idx = words.indexWhere((w) => w == 'pin' || w == 'remember' || w == 'prioritize' || w == 'prioritise');
      if (idx >= 0 && idx + 1 < words.length) {
        final subject = words.sublist(idx + 1).where((w) => w.length > 2).join(' ');
        if (subject.isNotEmpty) {
          final key = subject.split(' ').first;
          _memories.add(AIMemory(
            key: key,
            instruction: 'Always prioritize notes about $subject',
            createdAt: DateTime.now(),
          ));
          return '🧠 I\'ll remember to prioritize "$subject" in future searches';
        }
      }
    }

    return null;
  }

  Future<SmartVaultResult> processQuery(String query, List<SecureNote> allNotes, {SmartVaultContext? context}) async {
    final lower = query.trim().toLowerCase();
    if (lower.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'Ask me anything about your notes',
        subtitle: 'Try: "find my cricket notes" or "summarize finance notes"',
      );
    }

    final intent = _detectIntent(query);
    final activeNotes = allNotes.where((n) => !n.archived && !n.deleted).toList();

    final memoryResponse = _getPinnedMemoryResponse(query);
    if (memoryResponse != null) {
      return SmartVaultResult(
        type: 'memory',
        title: memoryResponse,
        notes: [],
      );
    }

    switch (intent) {
      // New intents (high priority)
      case 'knowledge':
        return _handleKnowledge(query);
      case 'stats':
        return _handleStats(query, activeNotes, context);
      case 'backup_status':
        return _handleBackupStatus(context);
      case 'storage_status':
        return _handleStorageStatus(context);
      case 'trash_status':
        return _handleTrashStatus(context);
      case 'security_status':
        return _handleSecurityStatus(context);
      case 'create_note':
        return _handleCreateNote(query, context);
      case 'delete_note':
        return _handleDeleteNote(query, activeNotes, context);
      case 'archive_note':
        return _handleArchiveNote(query, activeNotes, context);
      case 'pin_note':
        return _handlePinNote(query, activeNotes, context);
      case 'password_query':
        return _handlePasswordQuery(query, context);
      case 'generate_password':
        return _handleGeneratePassword();
      case 'empty_trash':
        return _handleEmptyTrash(context);
      case 'lock_vault':
        return _handleLockVault();
      case 'trigger_backup':
        return _handleTriggerBackup(context);
      // Existing intents
      case 'summarize':
        return _handleSummarize(query, activeNotes);
      case 'timeline':
        return _handleTimeline(query, activeNotes);
      case 'related':
        return _handleRelated(query, activeNotes);
      case 'tags':
        return _handleTags(query, activeNotes);
      case 'ask':
        return _handleAsk(query, activeNotes);
      case 'duplicates':
        return _handleDuplicates(activeNotes);
      case 'media':
        return _handleMedia(activeNotes);
      case 'insights':
        return _handleInsights(activeNotes);
      case 'voice':
        return _handleVoice(activeNotes);
      case 'connections':
        return _handleConnections(activeNotes);
      case 'navigate':
        return _handleNavigate(query);
      case 'memory':
        return SmartVaultResult(type: 'memory', title: 'Say "pin [topic]" or "remember [topic]" to set AI memory', notes: []);
      case 'recent':
        return _handleRecent(query, activeNotes);
      case 'folders':
        return _handleFolders(activeNotes);
      default:
        return _handleSearch(query, activeNotes);
    }
  }

  Future<SmartVaultResult> _handleSearch(String query, List<SecureNote> notes) async {
    final dateFiltered = _filterByTime(notes, query);
    final folderFiltered = _filterByFolder(dateFiltered, query);
    final hasTimeFilter = dateFiltered.length < notes.length;
    final hasFolderFilter = folderFiltered.length < dateFiltered.length;

    final matchedNote = _findBestMention(folderFiltered, query);

    if (matchedNote != null) {
      final snippet = _extractSnippet(matchedNote, query);
      return SmartVaultResult(
        type: 'note',
        title: matchedNote.title,
        subtitle: snippet,
        notes: [matchedNote],
        relevance: 1.0,
      );
    }

    if (hasTimeFilter || hasFolderFilter) {
      return SmartVaultResult(
        type: 'search',
        title: 'Found ${folderFiltered.length} notes',
        subtitle: _extractDateQuery(query) != null ? 'From ${_extractDateQuery(query)}' : null,
        notes: folderFiltered,
        relevance: 0.8,
      );
    }

    final expandedTerms = _expandQuery(query);
    final scored = <_ScoredNote>[];
    for (final note in notes) {
      final text = '${note.title} ${note.body} ${note.summary} ${note.ocrText} ${note.transcript}';
      double score = _tfIdfSimilarity(text, expandedTerms);
      if (note.title.isNotEmpty) {
        score += _tfIdfSimilarity(note.title, query.split(' ')) * 2.0;
      }
      if (score > 0.1) {
        scored.add(_ScoredNote(note, score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final results = scored.take(20).toList();

    if (results.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: 'No relevant notes found',
        subtitle: 'Try rephrasing your query or check different folders',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'search',
      title: 'Found ${results.length} relevant notes',
      subtitle: 'Best match: ${results.first.note.title}',
      notes: results.map((r) => r.note).toList(),
      relevance: results.first.score,
    );
  }

  Future<SmartVaultResult> _handleSummarize(String query, List<SecureNote> notes) async {
    final topic = _extractTopic(query);
    if (topic == null || topic.isEmpty) {
      return const SmartVaultResult(type: 'error', title: 'What would you like me to summarize?');
    }

    final matchedNote = _findBestMention(notes, query);
    if (matchedNote != null) {
      final summary = SummarizationService.summarize(matchedNote.body, maxSentences: 3);
      return SmartVaultResult(
        type: 'summary',
        title: 'Summary: ${matchedNote.title}',
        subtitle: summary.isNotEmpty ? summary : matchedNote.body.length > 200
            ? '${matchedNote.body.substring(0, 200)}...' : matchedNote.body,
        notes: [matchedNote],
      );
    }

    final topicNotes = <_ScoredNote>[];
    final expandedTerms = _expandQuery(query);
    for (final note in notes) {
      final text = '${note.title} ${note.body} ${note.summary}'.toLowerCase();
      final score = _tfIdfSimilarity(text, expandedTerms);
      if (score > 0.2) {
        topicNotes.add(_ScoredNote(note, score));
      }
    }
    topicNotes.sort((a, b) => b.score.compareTo(a.score));
    final relevant = topicNotes.take(5).map((r) => r.note).toList();

    if (relevant.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: 'No notes found about "$topic"',
        notes: [],
      );
    }

    final summary = _generateSummary(relevant, topic);
    return SmartVaultResult(
      type: 'summary',
      title: 'Summary of ${relevant.length} notes about "$topic"',
      subtitle: summary,
      notes: relevant,
    );
  }

  Future<SmartVaultResult> _handleTimeline(String query, List<SecureNote> notes) async {
    final timeRange = _extractDateQuery(query);
    final filtered = timeRange != null ? _filterByTime(notes, query) : notes;

    if (filtered.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: timeRange != null ? 'No notes from $timeRange' : 'No notes found',
        notes: [],
      );
    }

    filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return SmartVaultResult(
      type: 'timeline',
      title: '${filtered.length} notes ${timeRange ?? 'over time'}',
      subtitle: 'From ${filtered.last.createdAt.toString().substring(0, 10)} to ${filtered.first.createdAt.toString().substring(0, 10)}',
      notes: filtered,
    );
  }

  Future<SmartVaultResult> _handleRelated(String query, List<SecureNote> notes) async {
    final matchedNote = _findBestMention(notes, query);
    if (matchedNote == null) {
      return const SmartVaultResult(type: 'empty', title: 'Which note do you want related notes for?');
    }

    final related = _findRelatedNotesByContent(matchedNote, notes);
    if (related.isEmpty) {
      return SmartVaultResult(
        type: 'empty',
        title: 'No related notes found for "${matchedNote.title}"',
        notes: [matchedNote],
      );
    }

    return SmartVaultResult(
      type: 'related',
      title: 'Related to "${matchedNote.title}"',
      subtitle: 'Found ${related.length} related notes',
      notes: related,
    );
  }

  Future<SmartVaultResult> _handleTags(String query, List<SecureNote> notes) async {
    final matchedNote = _findBestMention(notes, query);
    final target = matchedNote ?? (notes.isNotEmpty ? notes.first : null);

    if (target == null) {
      return const SmartVaultResult(type: 'empty', title: 'No notes to generate tags for');
    }

    final analysis = _analyzer.analyze(target);
    final suggestedTags = analysis.suggestedTags;

    if (suggestedTags.isEmpty) {
      return SmartVaultResult(
        type: 'tags',
        title: 'Suggested tags for "${target.title}"',
        subtitle: 'No new tags suggested (existing: ${target.tags.join(", ")})',
        notes: [target],
      );
    }

    return SmartVaultResult(
      type: 'tags',
      title: 'Suggested tags for "${target.title}"',
      subtitle: 'Try adding: ${suggestedTags.take(5).join(", ")}',
      notes: [target],
    );
  }

  Future<SmartVaultResult> _handleAsk(String query, List<SecureNote> notes) async {
    final answerNote = _findBestMention(notes, query);
    if (answerNote == null) {
      final expandedTerms = _expandQuery(query);
      final scored = <_ScoredNote>[];
      for (final note in notes) {
        final text = '${note.title} ${note.body} ${note.summary}';
        final score = _tfIdfSimilarity(text, expandedTerms);
        if (score > 0.15) scored.add(_ScoredNote(note, score));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));

      if (scored.isEmpty) {
        return SmartVaultResult(
          type: 'empty',
          title: 'I couldn\'t find an answer in your notes',
          subtitle: 'Try a different question or check your note content',
          notes: [],
        );
      }

      final best = scored.first.note;
      final snippet = _extractSnippet(best, query);
      return SmartVaultResult(
        type: 'answer',
        title: 'Based on "${best.title}"',
        subtitle: snippet,
        notes: [best],
      );
    }

    final snippet = _extractSnippet(answerNote, query);
    return SmartVaultResult(
      type: 'answer',
      title: 'Found in "${answerNote.title}"',
      subtitle: snippet,
      notes: [answerNote],
    );
  }

  String _extractSnippet(SecureNote note, String query) {
    final lower = note.body.toLowerCase();
    final qLower = query.toLowerCase();
    final words = qLower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 2).toList();

    int bestIdx = -1;
    String bestWord = '';

    for (final word in words) {
      final idx = lower.indexOf(word);
      if (idx >= 0 && (bestIdx == -1 || idx < bestIdx)) {
        bestIdx = idx;
        bestWord = word;
      }
    }

    if (bestIdx >= 0) {
      final start = max(0, bestIdx - 50);
      final end = min(note.body.length, bestIdx + bestWord.length + 50);
      return '${start > 0 ? "..." : ""}${note.body.substring(start, end)}${end < note.body.length ? "..." : ""}';
    }

    return note.body.length > 150 ? '${note.body.substring(0, 150)}...' : note.body;
  }

  Future<SmartVaultResult> _handleDuplicates(List<SecureNote> notes) async {
    final duplicates = <List<SecureNote>>[];
    final checked = <String>{};

    for (var i = 0; i < notes.length; i++) {
      if (checked.contains(notes[i].id)) continue;
      final group = <SecureNote>[notes[i]];
      for (var j = i + 1; j < notes.length; j++) {
        if (checked.contains(notes[j].id)) continue;
        final sim = _contentSimilarity(notes[i], notes[j]);
        if (sim > 0.75) {
          group.add(notes[j]);
          checked.add(notes[j].id);
        }
      }
      if (group.length > 1) duplicates.add(group);
      checked.add(notes[i].id);
    }

    if (duplicates.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No duplicate notes detected',
        subtitle: 'All your notes appear to be unique',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'duplicates',
      title: 'Found ${duplicates.length} duplicate groups',
      subtitle: '${duplicates.fold(0, (sum, g) => sum + g.length)} notes involved',
      notes: duplicates.expand((g) => g).toList(),
    );
  }

  Future<SmartVaultResult> _handleMedia(List<SecureNote> notes) async {
    final withImages = notes.where((n) =>
      n.attachments.any((a) => a.kind == 'image')).toList();

    if (withImages.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No image notes found',
        subtitle: 'Notes with image attachments will appear here',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'media',
      title: '${withImages.length} notes contain images',
      notes: withImages,
    );
  }

  Future<SmartVaultResult> _handleInsights(List<SecureNote> notes) async {
    if (notes.isEmpty) {
      return const SmartVaultResult(
        type: 'insights',
        title: 'No data yet',
        subtitle: 'Start creating notes to see insights',
        notes: [],
      );
    }

    final insight = _generateInsight(notes);
    return SmartVaultResult(
      type: 'insights',
      title: '📊 Smart Insights',
      subtitle: insight,
      notes: notes,
    );
  }

  Future<SmartVaultResult> _handleVoice(List<SecureNote> notes) async {
    final voiceNotes = notes.where((n) =>
      n.type == NoteType.voice || n.transcript.isNotEmpty).toList();

    if (voiceNotes.isEmpty) {
      return const SmartVaultResult(
        type: 'empty',
        title: 'No voice recordings found',
        subtitle: 'Record voice notes to see them here',
        notes: [],
      );
    }

    return SmartVaultResult(
      type: 'voice',
      title: '${voiceNotes.length} voice recordings',
      notes: voiceNotes,
    );
  }

  Future<SmartVaultResult> _handleRecent(String query, List<SecureNote> notes) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayNotes = notes.where((n) =>
      n.updatedAt.isAfter(todayStart) || n.createdAt.isAfter(todayStart)).toList();

    if (todayNotes.isEmpty) {
      final recentWeek = notes.where((n) =>
        n.updatedAt.isAfter(now.subtract(const Duration(days: 7)))).toList();
      if (recentWeek.isEmpty) {
        return const SmartVaultResult(
          type: 'empty',
          title: 'No recent activity found',
          subtitle: 'Your recent notes will appear here',
          notes: [],
        );
      }
      recentWeek.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return SmartVaultResult(
        type: 'recent',
        title: 'This week\'s activity',
        subtitle: '${recentWeek.length} notes updated this week',
        notes: recentWeek,
      );
    }

    todayNotes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return SmartVaultResult(
      type: 'recent',
      title: 'Today\'s activity',
      subtitle: 'You worked on ${todayNotes.length} notes today',
      notes: todayNotes,
    );
  }

  Future<SmartVaultResult> _handleNavigate(String query) async {
    final lower = query.toLowerCase();
    String target = 'Unknown';

    if (lower.contains('home')) target = 'Home';
    if (lower.contains('password') || lower.contains('credential') || lower.contains('login')) target = 'Password Manager';
    if (lower.contains('trash') || lower.contains('bin') || lower.contains('deleted')) target = 'Trash';
    if (lower.contains('archive') || lower.contains('archived')) target = 'Archive';
    if (lower.contains('drive') && (lower.contains('tool') || lower.contains('compress') || lower.contains('optimize') || lower.contains('convert'))) target = 'Drive Tools';
    if (lower.contains('drive')) target = 'Drive';
    if (lower.contains('security log') || lower.contains('intruder') || lower.contains('audit')) target = 'Security Logs';
    if (lower.contains('storage') && (lower.contains('insight') || lower.contains('usage'))) target = 'Storage Insights';
    if (lower.contains('smart view')) target = 'Smart View';
    if (lower.contains('smart categor') || lower.contains('category')) target = 'Smart Categories';
    if (lower.contains('security')) target = 'Security';
    if (lower.contains('settings')) target = 'Settings';
    if (lower.contains('game') || lower.contains('play')) target = 'VaultX Game';
    if (lower.contains('backup') || lower.contains('restore')) target = 'Backup';

    return SmartVaultResult(
      type: 'navigate',
      title: 'Navigating to $target',
      subtitle: 'Executing navigation intent...',
    );
  }

  Future<SmartVaultResult> _handleFolders(List<SecureNote> notes) async {
    final folderGroups = <String, List<SecureNote>>{};
    for (final note in notes) {
      folderGroups.putIfAbsent(note.folder, () => []).add(note);
    }

    final suggestions = <String>[];
    final analyzerGroups = _analyzer.groupByCategory(notes);
    for (final entry in analyzerGroups.entries) {
      if (entry.value.length >= 2) {
        final suggestedFolder = _getFolderFromCategory(entry.key);
        if (suggestedFolder != null && !folderGroups.containsKey(suggestedFolder)) {
          suggestions.add('Create "$suggestedFolder" folder for ${entry.value.length} ${entry.key.name} notes');
        }
      }
    }

    if (suggestions.isEmpty) {
      return SmartVaultResult(
        type: 'folders',
        title: '${folderGroups.length} active folders',
        subtitle: 'No new folder suggestions',
        notes: notes,
      );
    }

    return SmartVaultResult(
      type: 'folders',
      title: '${folderGroups.length} folders • ${suggestions.length} suggestions',
      subtitle: suggestions.join('\n'),
      notes: notes,
    );
  }

  double _contentSimilarity(SecureNote a, SecureNote b) {
    final tokensA = _tokenSet('${a.title} ${a.body} ${a.ocrText}');
    final tokensB = _tokenSet('${b.title} ${b.body} ${b.ocrText}');
    if (tokensA.isEmpty && tokensB.isEmpty) return 1.0;
    final intersection = tokensA.intersection(tokensB).length;
    final union = tokensA.union(tokensB).length;
    if (union == 0) return 0.0;
    return intersection / union;
  }

  String? _getFolderFromCategory(NoteCategory category) {
    switch (category) {
      case NoteCategory.finance: return 'Finance';
      case NoteCategory.work: return 'Work';
      case NoteCategory.personal: return 'Personal';
      case NoteCategory.tech: return 'Tech';
      case NoteCategory.health: return 'Health';
      case NoteCategory.education: return 'Education';
      case NoteCategory.shopping: return 'Shopping';
      case NoteCategory.travel: return 'Travel';
      case NoteCategory.passwords: return 'Passwords';
      default: return null;
    }
  }

  Future<List<SmartVaultResult>> processBatch(List<String> queries, List<SecureNote> allNotes) async {
    final results = <SmartVaultResult>[];
    for (final query in queries) {
      results.add(await processQuery(query, allNotes));
    }
    return results;
  }

  Map<String, int> getTopicFrequency(List<SecureNote> notes) {
    final freq = <String, int>{};
    for (final note in notes) {
      final topic = _analyzer.analyze(note).category.name;
      freq[topic] = (freq[topic] ?? 0) + 1;
    }
    return freq;
  }

  SecureNote? getMostWorkedTopic(List<SecureNote> notes) {
    if (notes.isEmpty) return null;
    final sorted = List<SecureNote>.from(notes)
      ..sort((a, b) => (b.viewCount + (b.versions.length)).compareTo(a.viewCount + (a.versions.length)));
    return sorted.first;
  }

  Map<String, int> getActivityByDay(List<SecureNote> notes, {int days = 7}) {
    final now = DateTime.now();
    final result = <String, int>{};
    for (var i = 0; i < days; i++) {
      final day = now.subtract(Duration(days: i));
      final key = '${day.month}/${day.day}';
      result[key] = 0;
    }
    for (final note in notes) {
      final key = '${note.updatedAt.month}/${note.updatedAt.day}';
      if (result.containsKey(key)) {
        result[key] = (result[key] ?? 0) + 1;
      }
    }
    return result;
  }

  List<String> getSuggestions(List<SecureNote> notes) {
    return _generateSmartSuggestions(notes);
  }
}

class _ScoredNote {
  final SecureNote note;
  final double score;
  const _ScoredNote(this.note, this.score);
}

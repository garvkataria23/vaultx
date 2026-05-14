/// Represents the type of note content.
enum NoteType { text, checklist, voice, drawing }

/// A single checklist item within a note.
class ChecklistItem {
  const ChecklistItem(this.text, this.done);
  final String text;
  final bool done;
  Map<String, dynamic> toJson() => {'text': text, 'done': done};
  factory ChecklistItem.fromJson(Map<String, dynamic> json) =>
      ChecklistItem(json['text'] as String? ?? '', json['done'] as bool? ?? false);
}

/// Metadata for an encrypted file attachment.
class SecureAttachment {
  const SecureAttachment({
    required this.id,
    required this.name,
    required this.encryptedPath,
    required this.salt,
    required this.size,
    required this.createdAt,
    required this.kind,
    this.duration,
    this.backupExcluded = false,
  });

  final String id;
  final String name;
  final String encryptedPath;
  final String salt;
  final int size;
  final DateTime createdAt;
  final String kind;
  final Duration? duration;
  final bool backupExcluded;

  SecureAttachment copyWith({
    String? id,
    String? name,
    String? encryptedPath,
    String? salt,
    int? size,
    DateTime? createdAt,
    String? kind,
    Duration? duration,
    bool? backupExcluded,
  }) {
    return SecureAttachment(
      id: id ?? this.id,
      name: name ?? this.name,
      encryptedPath: encryptedPath ?? this.encryptedPath,
      salt: salt ?? this.salt,
      size: size ?? this.size,
      createdAt: createdAt ?? this.createdAt,
      kind: kind ?? this.kind,
      duration: duration ?? this.duration,
      backupExcluded: backupExcluded ?? this.backupExcluded,
    );
  }

  bool get isLocalOnly => backupExcluded;
  bool shouldIncludeInBackup() => !backupExcluded;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'encryptedPath': encryptedPath,
    'salt': salt,
    'size': size,
    'createdAt': createdAt.toIso8601String(),
    'kind': kind,
    if (duration != null) 'duration': duration!.inMilliseconds,
    'backupExcluded': backupExcluded,
  };

  factory SecureAttachment.fromJson(Map<String, dynamic> json) =>
      SecureAttachment(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        encryptedPath: json['encryptedPath'] as String? ?? '',
        salt: json['salt'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        kind: json['kind'] as String? ?? 'file',
        duration: json['duration'] != null
            ? Duration(milliseconds: json['duration'] as int? ?? 0)
            : null,
        backupExcluded: json['backupExcluded'] as bool? ?? false,
      );
}

/// An encrypted note stored in the vault.
class SecureNote {
  SecureNote({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
    this.folder = 'Private',
    this.tags = const [],
    this.priority = 2,
    this.pinned = false,
    this.favorite = false,
    this.archived = false,
    this.archivedAt,
    this.locked = false,
    this.oneTimeView = false,
    this.expiresAt,
    this.checklist = const [],
    this.attachments = const [],
    this.versions = const [],
    this.ocrText = '',
    this.backupExcluded = false,
  });

  final String id;
  final String title;
  final String body;
  final NoteType type;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String folder;
  final List<String> tags;
  final int priority;
  final bool pinned;
  final bool favorite;
  final bool archived;
  final DateTime? archivedAt;
  final bool locked;
  final bool oneTimeView;
  final DateTime? expiresAt;
  final List<ChecklistItem> checklist;
  final List<SecureAttachment> attachments;
  final List<Map<String, dynamic>> versions;
  final String ocrText;
  final bool backupExcluded;

  bool get isLocalOnly => backupExcluded;

  /// Returns true if this note should be included in a backup.
  /// If [folderExcluded] is provided, it can be used to implement inheritance.
  bool shouldIncludeInBackup({bool folderExcluded = false}) {
    if (backupExcluded) return false;
    if (folderExcluded) return false;
    return true;
  }

  SecureNote copyWith({
    String? title,
    String? body,
    NoteType? type,
    String? folder,
    List<String>? tags,
    int? priority,
    bool? pinned,
    bool? favorite,
    bool? archived,
    DateTime? archivedAt,
    bool? locked,
    bool? oneTimeView,
    DateTime? expiresAt,
    List<ChecklistItem>? checklist,
    List<SecureAttachment>? attachments,
    List<Map<String, dynamic>>? versions,
    String? ocrText,
    bool? backupExcluded,
  }) {
    return SecureNote(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      type: type ?? this.type,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      folder: folder ?? this.folder,
      tags: tags ?? this.tags,
      priority: priority ?? this.priority,
      pinned: pinned ?? this.pinned,
      favorite: favorite ?? this.favorite,
      archived: archived ?? this.archived,
      archivedAt: archived == true
          ? (archivedAt ?? this.archivedAt ?? DateTime.now())
          : archived == false
              ? null
              : (archivedAt ?? this.archivedAt),
      locked: locked ?? this.locked,
      oneTimeView: oneTimeView ?? this.oneTimeView,
      expiresAt: expiresAt ?? this.expiresAt,
      checklist: checklist ?? this.checklist,
      attachments: attachments ?? this.attachments,
      versions: versions ?? this.versions,
      ocrText: ocrText ?? this.ocrText,
      backupExcluded: backupExcluded ?? this.backupExcluded,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'type': type.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'folder': folder,
    'tags': tags,
    'priority': priority,
    'pinned': pinned,
    'favorite': favorite,
    'archived': archived,
    'archivedAt': archivedAt?.toIso8601String(),
    'locked': locked,
    'oneTimeView': oneTimeView,
    'expiresAt': expiresAt?.toIso8601String(),
    'checklist': checklist.map((e) => e.toJson()).toList(),
    'attachments': attachments.map((e) => e.toJson()).toList(),
    'versions': versions,
    'ocrText': ocrText,
    'backupExcluded': backupExcluded,
  };

  factory SecureNote.fromJson(Map<String, dynamic> json) => SecureNote(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    type: NoteType.values.byName(json['type'] as String? ?? 'text'),
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    folder: json['folder'] as String? ?? 'Private',
    tags: List<String>.from(json['tags'] as List? ?? const []),
    priority: json['priority'] as int? ?? 2,
    pinned: json['pinned'] as bool? ?? false,
    favorite: json['favorite'] as bool? ?? false,
    archived: json['archived'] as bool? ?? false,
    archivedAt: json['archivedAt'] != null
        ? DateTime.tryParse(json['archivedAt'] as String? ?? '')
        : null,
    locked: json['locked'] as bool? ?? false,
    oneTimeView: json['oneTimeView'] as bool? ?? false,
    expiresAt: json['expiresAt'] == null
        ? null
        : DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    checklist: (json['checklist'] as List? ?? const [])
        .map((e) => e is Map ? ChecklistItem.fromJson(Map<String, dynamic>.from(e)) : const ChecklistItem('', false))
        .toList(),
    attachments: (json['attachments'] as List? ?? const []).map((e) {
      if (e is String) {
        return SecureAttachment(
          id: e,
          name: e,
          encryptedPath: e,
          salt: '',
          size: 0,
          createdAt: DateTime.now(),
          kind: 'legacy',
        );
      }
      if (e is Map) {
        return SecureAttachment.fromJson(Map<String, dynamic>.from(e));
      }
      return SecureAttachment(
        id: '', name: '', encryptedPath: '', salt: '',
        size: 0, createdAt: DateTime.now(), kind: 'file',
      );
    }).toList(),
    versions: (json['versions'] as List? ?? const [])
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
        .toList(),
    ocrText: json['ocrText'] as String? ?? '',
    backupExcluded: json['backupExcluded'] as bool? ?? false,
  );
}

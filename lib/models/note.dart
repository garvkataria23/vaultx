/// Represents the type of note content.
enum NoteType { text, checklist, voice, drawing, todo }

enum TodoPriority { low, medium, high }

/// A single checklist item within a note.
class ChecklistItem {
  const ChecklistItem(this.text, this.done);
  final String text;
  final bool done;
  Map<String, dynamic> toJson() => {'text': text, 'done': done};
  factory ChecklistItem.fromJson(Map<String, dynamic> json) =>
      ChecklistItem(json['text'] as String? ?? '', json['done'] as bool? ?? false);
}

/// A single task within a Todo note.
class TodoTask {
  const TodoTask({
    required this.id,
    required this.text,
    this.done = false,
    this.priority = TodoPriority.medium,
    this.dueDate,
    this.reminderAt,
    this.colorTag,
    this.progress = 0,
  });

  final String id;
  final String text;
  final bool done;
  final TodoPriority priority;
  final DateTime? dueDate;
  final DateTime? reminderAt;
  final String? colorTag;
  final int progress; // 0-100

  TodoTask copyWith({
    String? id,
    String? text,
    bool? done,
    TodoPriority? priority,
    DateTime? dueDate,
    DateTime? reminderAt,
    String? colorTag,
    int? progress,
  }) {
    return TodoTask(
      id: id ?? this.id,
      text: text ?? this.text,
      done: done ?? this.done,
      priority: priority ?? this.priority,
      dueDate: dueDate ?? this.dueDate,
      reminderAt: reminderAt ?? this.reminderAt,
      colorTag: colorTag ?? this.colorTag,
      progress: progress ?? this.progress,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'done': done,
    'priority': priority.name,
    'dueDate': dueDate?.toIso8601String(),
    'reminderAt': reminderAt?.toIso8601String(),
    'colorTag': colorTag,
    'progress': progress,
  };

  factory TodoTask.fromJson(Map<String, dynamic> json) => TodoTask(
    id: json['id'] as String? ?? '',
    text: json['text'] as String? ?? '',
    done: json['done'] as bool? ?? false,
    priority: TodoPriority.values.byName(json['priority'] as String? ?? 'medium'),
    dueDate: json['dueDate'] != null ? DateTime.tryParse(json['dueDate'] as String) : null,
    reminderAt: json['reminderAt'] != null ? DateTime.tryParse(json['reminderAt'] as String) : null,
    colorTag: json['colorTag'] as String?,
    progress: json['progress'] as int? ?? 0,
  );
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
    this.todoList = const [],
    this.attachments = const [],
    this.versions = const [],
    this.ocrText = '',
    this.transcript = '',
    this.summary = '',
    this.links = const [],
    this.backupExcluded = false,
    this.deleted = false,
    this.deletedAt,
    this.autoDeleteAt,
    this.originalFolder,
    this.deletedBy = 'user',
    this.viewCount = 0,
    this.lastViewedAt,
    this.lastOpenedAt,
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
  final List<TodoTask> todoList;
  final List<SecureAttachment> attachments;
  final List<Map<String, dynamic>> versions;
  final String ocrText;
  final String transcript;
  final String summary;
  final List<String> links;
  final bool backupExcluded;
  final bool deleted;
  final DateTime? deletedAt;
  final DateTime? autoDeleteAt;
  final String? originalFolder;
  final String deletedBy;
  final int viewCount;
  final DateTime? lastViewedAt;
  final DateTime? lastOpenedAt;

  bool get isLocalOnly => backupExcluded;

  /// Returns true if this note should be included in a backup.
  /// If [folderExcluded] is provided, it can be used to implement inheritance.
  bool shouldIncludeInBackup({bool folderExcluded = false}) {
    if (deleted) return false;
    if (backupExcluded) return false;
    if (folderExcluded) return false;
    return true;
  }

  SecureNote markDeleted({DateTime? autoDeleteAt}) => SecureNote(
    id: id,
    title: title,
    body: body,
    type: type,
    createdAt: createdAt,
    updatedAt: updatedAt,
    folder: folder,
    tags: tags,
    priority: priority,
    pinned: false,
    favorite: false,
    archived: false,
    archivedAt: null,
    locked: locked,
    oneTimeView: oneTimeView,
    expiresAt: expiresAt,
    checklist: checklist,
    todoList: todoList,
    attachments: attachments,
    versions: versions,
    ocrText: ocrText,
    transcript: transcript,
    summary: summary,
    links: links,
    backupExcluded: backupExcluded,
    deleted: true,
    deletedAt: DateTime.now(),
    autoDeleteAt: autoDeleteAt,
    originalFolder: folder,
    deletedBy: 'user',
    viewCount: viewCount,
    lastViewedAt: lastViewedAt,
  );

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
    List<TodoTask>? todoList,
    List<SecureAttachment>? attachments,
    List<Map<String, dynamic>>? versions,
    String? ocrText,
    String? transcript,
    String? summary,
    List<String>? links,
    bool? backupExcluded,
    bool? deleted,
    DateTime? deletedAt,
    DateTime? autoDeleteAt,
    String? originalFolder,
    String? deletedBy,
    int? viewCount,
    DateTime? lastViewedAt,
    DateTime? lastOpenedAt,
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
      todoList: todoList ?? this.todoList,
      attachments: attachments ?? this.attachments,
      versions: versions ?? this.versions,
      ocrText: ocrText ?? this.ocrText,
      transcript: transcript ?? this.transcript,
      summary: summary ?? this.summary,
      links: links ?? this.links,
      backupExcluded: backupExcluded ?? this.backupExcluded,
      deleted: deleted ?? this.deleted,
      deletedAt: deletedAt ?? this.deletedAt,
      autoDeleteAt: autoDeleteAt ?? this.autoDeleteAt,
      originalFolder: originalFolder ?? this.originalFolder,
      deletedBy: deletedBy ?? this.deletedBy,
      viewCount: viewCount ?? this.viewCount,
      lastViewedAt: lastViewedAt ?? this.lastViewedAt,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
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
    'todoList': todoList.map((e) => e.toJson()).toList(),
    'attachments': attachments.map((e) => e.toJson()).toList(),
    'versions': versions,
    'ocrText': ocrText,
    'transcript': transcript,
    'summary': summary,
    'links': links,
    'backupExcluded': backupExcluded,
    'deleted': deleted,
    'deletedAt': deletedAt?.toIso8601String(),
    'autoDeleteAt': autoDeleteAt?.toIso8601String(),
    'originalFolder': originalFolder,
    'deletedBy': deletedBy,
    'viewCount': viewCount,
    'lastViewedAt': lastViewedAt?.toIso8601String(),
    'lastOpenedAt': lastOpenedAt?.toIso8601String(),
  };

  static NoteType _parseNoteType(String? raw) {
    try {
      return NoteType.values.byName(raw ?? 'text');
    } catch (_) {
      return NoteType.text;
    }
  }

  factory SecureNote.fromJson(Map<String, dynamic> json) => SecureNote(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    type: _parseNoteType(json['type'] as String?),
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
    todoList: (json['todoList'] as List? ?? const [])
        .map<TodoTask>((e) => e is Map ? TodoTask.fromJson(Map<String, dynamic>.from(e)) : const TodoTask(id: '', text: ''))
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
    transcript: json['transcript'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    links: json['links'] != null
        ? List<String>.from(json['links'] as List)
        : const [],
    backupExcluded: json['backupExcluded'] as bool? ?? false,
    deleted: json['deleted'] as bool? ?? false,
    deletedAt: json['deletedAt'] != null
        ? DateTime.tryParse(json['deletedAt'] as String? ?? '')
        : null,
    autoDeleteAt: json['autoDeleteAt'] != null
        ? DateTime.tryParse(json['autoDeleteAt'] as String? ?? '')
        : null,
    originalFolder: json['originalFolder'] as String?,
    deletedBy: json['deletedBy'] as String? ?? 'user',
    viewCount: json['viewCount'] as int? ?? 0,
    lastViewedAt: json['lastViewedAt'] != null
        ? DateTime.tryParse(json['lastViewedAt'] as String? ?? '')
        : null,
    lastOpenedAt: json['lastOpenedAt'] != null
        ? DateTime.tryParse(json['lastOpenedAt'] as String? ?? '')
        : null,
  );
}

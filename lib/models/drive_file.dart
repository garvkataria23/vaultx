class SecureDriveFolder {
  SecureDriveFolder({
    required this.name,
    this.fileCount = 0,
    this.pinned = false,
    this.archived = false,
    this.archivedAt,
    this.backupExcluded = false,
    this.isLocked = false,
    this.deleted = false,
    this.deletedAt,
    this.autoDeleteAt,
    this.originalFolder,
    this.deletedBy = 'user',
  });

  final String name;
  int fileCount;
  bool pinned;
  bool archived;
  DateTime? archivedAt;
  bool backupExcluded;
  bool isLocked;
  bool deleted;
  DateTime? deletedAt;
  DateTime? autoDeleteAt;
  String? originalFolder;
  String deletedBy;

  SecureDriveFolder copyWith({
    String? name,
    int? fileCount,
    bool? pinned,
    bool? archived,
    DateTime? archivedAt,
    bool? backupExcluded,
    bool? isLocked,
    bool? deleted,
    DateTime? deletedAt,
    DateTime? autoDeleteAt,
    String? originalFolder,
    String? deletedBy,
  }) {
    return SecureDriveFolder(
      name: name ?? this.name,
      fileCount: fileCount ?? this.fileCount,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      archivedAt: archivedAt ?? this.archivedAt,
      backupExcluded: backupExcluded ?? this.backupExcluded,
      isLocked: isLocked ?? this.isLocked,
      deleted: deleted ?? this.deleted,
      deletedAt: deletedAt ?? this.deletedAt,
      autoDeleteAt: autoDeleteAt ?? this.autoDeleteAt,
      originalFolder: originalFolder ?? this.originalFolder,
      deletedBy: deletedBy ?? this.deletedBy,
    );
  }

  bool get isLocalOnly => backupExcluded;

  /// Returns true if this folder should be included in a backup.
  bool shouldIncludeInBackup() {
    if (deleted) return false;
    return !backupExcluded;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'fileCount': fileCount,
    'pinned': pinned,
    'archived': archived,
    'archivedAt': archivedAt?.toIso8601String(),
    'backupExcluded': backupExcluded,
    'isLocked': isLocked,
    'deleted': deleted,
    'deletedAt': deletedAt?.toIso8601String(),
    'autoDeleteAt': autoDeleteAt?.toIso8601String(),
    'originalFolder': originalFolder,
    'deletedBy': deletedBy,
  };

  static SecureDriveFolder fromJson(Map<String, dynamic> json) =>
      SecureDriveFolder(
        name: json['name'] as String? ?? '',
        fileCount: json['fileCount'] as int? ?? 0,
        pinned: json['pinned'] as bool? ?? false,
        archived: json['archived'] as bool? ?? false,
        archivedAt: json['archivedAt'] != null
            ? DateTime.tryParse(json['archivedAt'] as String? ?? '')
            : null,
        backupExcluded: json['backupExcluded'] as bool? ?? false,
        isLocked: json['isLocked'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        deletedAt: json['deletedAt'] != null
            ? DateTime.tryParse(json['deletedAt'] as String? ?? '')
            : null,
        autoDeleteAt: json['autoDeleteAt'] != null
            ? DateTime.tryParse(json['autoDeleteAt'] as String? ?? '')
            : null,
        originalFolder: json['originalFolder'] as String?,
        deletedBy: json['deletedBy'] as String? ?? 'user',
      );
}

class SecureDriveFile {
  SecureDriveFile({
    required this.id,
    required this.name,
    required this.kind,
    required this.mimeType,
    required this.size,
    this.originalSize,
    required this.encryptedPath,
    required this.salt,
    this.folder = '',
    this.tags = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    this.favorite = false,
    this.pinned = false,
    this.archived = false,
    this.archivedAt,
    this.backupExcluded = false,
    this.deleted = false,
    this.deletedAt,
    this.autoDeleteAt,
    this.originalFolder,
    this.deletedBy = 'user',
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  final String kind;
  final String mimeType;
  final int size;
  final int? originalSize;
  final String encryptedPath;
  final String salt;
  String folder;
  List<String> tags;
  final DateTime createdAt;
  DateTime updatedAt;
  bool favorite;
  bool pinned;
  bool archived;
  DateTime? archivedAt;
  bool backupExcluded;
  bool deleted;
  DateTime? deletedAt;
  DateTime? autoDeleteAt;
  String? originalFolder;
  String deletedBy;

  SecureDriveFile copyWith({
    String? name,
    String? kind,
    String? mimeType,
    int? size,
    int? originalSize,
    String? encryptedPath,
    String? salt,
    String? folder,
    List<String>? tags,
    bool? favorite,
    bool? pinned,
    bool? archived,
    DateTime? archivedAt,
    bool? backupExcluded,
    DateTime? updatedAt,
    bool? deleted,
    DateTime? deletedAt,
    DateTime? autoDeleteAt,
    String? originalFolder,
    String? deletedBy,
  }) {
    return SecureDriveFile(
      id: id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      mimeType: mimeType ?? this.mimeType,
      size: size ?? this.size,
      originalSize: originalSize ?? this.originalSize,
      encryptedPath: encryptedPath ?? this.encryptedPath,
      salt: salt ?? this.salt,
      folder: folder ?? this.folder,
      tags: tags ?? this.tags,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      favorite: favorite ?? this.favorite,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      archivedAt: archivedAt ?? this.archivedAt,
      backupExcluded: backupExcluded ?? this.backupExcluded,
      deleted: deleted ?? this.deleted,
      deletedAt: deletedAt ?? this.deletedAt,
      autoDeleteAt: autoDeleteAt ?? this.autoDeleteAt,
      originalFolder: originalFolder ?? this.originalFolder,
      deletedBy: deletedBy ?? this.deletedBy,
    );
  }

  bool get isLocalOnly => backupExcluded;

  /// Returns true if this file should be included in a backup.
  /// If [folderExcluded] is provided, it can be used to implement inheritance.
  bool shouldIncludeInBackup({bool folderExcluded = false}) {
    if (deleted) return false;
    if (backupExcluded) return false;
    if (folderExcluded) return false;
    return true;
  }

  static const folders = [
    'Photos',
    'Videos',
    'Audio',
    'Documents',
    'PDFs',
    'IDs',
    'Passwords',
    'Other',
  ];

  static const _kindExtensions = {
    'image': ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'],
    'video': ['mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm'],
    'audio': ['mp3', 'wav', 'flac', 'ogg', 'aac', 'wma', 'm4a', 'opus'],
    'pdf': ['pdf'],
    'document': [
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'txt',
      'rtf',
      'odt',
      'csv',
    ],
    'id': ['jpg', 'jpeg', 'png', 'pdf'],
    'password': ['txt', 'csv', 'json'],
  };

  static String detectKind(String name, String mimeType) {
    final ext = name.split('.').last.toLowerCase();
    for (final entry in _kindExtensions.entries) {
      if (entry.value.contains(ext)) return entry.key;
    }
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('video/')) return 'video';
    if (mimeType.startsWith('audio/')) return 'audio';
    if (mimeType == 'application/pdf') return 'pdf';
    return 'other';
  }

  static String detectFolder(String kind) {
    switch (kind) {
      case 'image':
        return 'Photos';
      case 'video':
        return 'Videos';
      case 'audio':
        return 'Audio';
      case 'pdf':
        return 'PDFs';
      case 'document':
        return 'Documents';
      case 'id':
        return 'IDs';
      case 'password':
        return 'Passwords';
      default:
        return 'Other';
    }
  }

  String get extension => name.split('.').last.toLowerCase();

  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'mimeType': mimeType,
    'size': size,
    'originalSize': originalSize,
    'encryptedPath': encryptedPath,
    'salt': salt,
    'folder': folder,
    'tags': tags,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'favorite': favorite,
    'pinned': pinned,
    'archived': archived,
    'archivedAt': archivedAt?.toIso8601String(),
    'backupExcluded': backupExcluded,
    'deleted': deleted,
    'deletedAt': deletedAt?.toIso8601String(),
    'autoDeleteAt': autoDeleteAt?.toIso8601String(),
    'originalFolder': originalFolder,
    'deletedBy': deletedBy,
  };

  factory SecureDriveFile.fromJson(Map<String, dynamic> json) {
    String? safeCreatedAt;
    String? safeUpdatedAt;
    try {
      if (json['createdAt'] != null) safeCreatedAt = json['createdAt'] as String;
    } catch (_) {}
    try {
      if (json['updatedAt'] != null) safeUpdatedAt = json['updatedAt'] as String;
    } catch (_) {}

    return SecureDriveFile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'unknown',
      kind: json['kind'] as String? ?? 'other',
      mimeType: json['mimeType'] as String? ?? '',
      size: json['size'] is int ? json['size'] as int : (json['size'] as num?)?.toInt() ?? 0,
      originalSize: json['originalSize'] is int ? json['originalSize'] as int : (json['originalSize'] as num?)?.toInt(),
      encryptedPath: json['encryptedPath'] as String? ?? '',
      salt: json['salt'] as String? ?? '',
      folder: json['folder'] as String? ?? '',
      tags: json['tags'] is List ? List<String>.from((json['tags'] as List).whereType<String>()) : [],
      createdAt: safeCreatedAt != null ? DateTime.tryParse(safeCreatedAt) ?? DateTime.now() : DateTime.now(),
      updatedAt: safeUpdatedAt != null ? DateTime.tryParse(safeUpdatedAt) ?? DateTime.now() : DateTime.now(),
      favorite: json['favorite'] is bool ? json['favorite'] as bool : false,
      pinned: json['pinned'] is bool ? json['pinned'] as bool : false,
      archived: json['archived'] is bool ? json['archived'] as bool : false,
      archivedAt: json['archivedAt'] != null
          ? DateTime.tryParse(json['archivedAt'] as String)
          : null,
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
    );
  }
}

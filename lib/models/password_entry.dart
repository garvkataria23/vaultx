class PasswordEntry {
  PasswordEntry({
    required this.id,
    required this.serviceName,
    this.username = '',
    this.password = '',
    this.notes = '',
    this.url = '',
    this.tags = const [],
    this.favorite = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastUsedAt,
    this.archived = false,
    this.archivedAt,
    this.backupExcluded = false,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String serviceName;
  String username;
  String password;
  String notes;
  String url;
  List<String> tags;
  bool favorite;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? lastUsedAt;
  bool archived;
  DateTime? archivedAt;
  bool backupExcluded;

  PasswordEntry copyWith({
    String? id,
    String? serviceName,
    String? username,
    String? password,
    String? notes,
    String? url,
    List<String>? tags,
    bool? favorite,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
    bool? archived,
    DateTime? archivedAt,
    bool? backupExcluded,
  }) =>
      PasswordEntry(
        id: id ?? this.id,
        serviceName: serviceName ?? this.serviceName,
        username: username ?? this.username,
        password: password ?? this.password,
        notes: notes ?? this.notes,
        url: url ?? this.url,
        tags: tags ?? this.tags,
        favorite: favorite ?? this.favorite,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        archived: archived ?? this.archived,
        archivedAt: archived == true
            ? (archivedAt ?? this.archivedAt ?? DateTime.now())
            : archived == false
                ? null
                : (archivedAt ?? this.archivedAt),
        backupExcluded: backupExcluded ?? this.backupExcluded,
      );

  bool get isLocalOnly => backupExcluded;
  bool shouldIncludeInBackup() => !backupExcluded;

  Map<String, dynamic> toJson() => {
    'id': id,
    'serviceName': serviceName,
    'username': username,
    'password': password,
    'notes': notes,
    'url': url,
    'tags': tags,
    'favorite': favorite,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastUsedAt': lastUsedAt?.toIso8601String(),
    'archived': archived,
    'archivedAt': archivedAt?.toIso8601String(),
    'backupExcluded': backupExcluded,
  };

  factory PasswordEntry.fromJson(Map<String, dynamic> json) {
    String? safeCreatedAt;
    String? safeUpdatedAt;
    try {
      if (json['createdAt'] != null) safeCreatedAt = json['createdAt'] as String;
    } catch (_) {}
    try {
      if (json['updatedAt'] != null) safeUpdatedAt = json['updatedAt'] as String;
    } catch (_) {}

    return PasswordEntry(
      id: json['id'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      url: json['url'] as String? ?? '',
      tags: json['tags'] is List ? List<String>.from((json['tags'] as List).whereType<String>()) : [],
      favorite: json['favorite'] as bool? ?? false,
      createdAt: safeCreatedAt != null ? DateTime.tryParse(safeCreatedAt) ?? DateTime.now() : DateTime.now(),
      updatedAt: safeUpdatedAt != null ? DateTime.tryParse(safeUpdatedAt) ?? DateTime.now() : DateTime.now(),
      lastUsedAt: json['lastUsedAt'] != null ? DateTime.tryParse(json['lastUsedAt'] as String) : null,
      archived: json['archived'] as bool? ?? false,
      archivedAt: json['archivedAt'] != null ? DateTime.tryParse(json['archivedAt'] as String) : null,
      backupExcluded: json['backupExcluded'] as bool? ?? false,
    );
  }
}

import '../models/models.dart';
import 'link_resolver.dart';
import 'note_analyzer.dart';

/// Service that provides high-level organization features by combining
/// the power of NoteAnalyzer, LinkResolver, and existing relationship engine.
class SmartOrganizationService {
  final List<SecureNote> allNotes;
  final NoteAnalyzerService _analyzer = NoteAnalyzerService();
  final LinkResolver _linkResolver = LinkResolver();

  SmartOrganizationService(this.allNotes) {
    _linkResolver.rebuild(allNotes);
  }

  /// Groups notes into expandable smart folders based on auto-detected categories.
  Map<NoteCategory, List<SecureNote>> getSmartCategories() {
    return _analyzer.groupByCategory(allNotes);
  }

  /// Surfaces semantically and structurally related notes for a given note.
  List<SecureNote> getRelatedNotes(SecureNote note) {
    return _analyzer.findRelatedNotes(note, allNotes);
  }

  /// Returns notes that link TO the given note (backlinks).
  List<SecureNote> getBacklinks(SecureNote note) {
    final backlinkIds = _linkResolver.computeBacklinks(note.id, allNotes, rebuildFirst: false);
    return allNotes.where((n) => backlinkIds.contains(n.id)).toList();
  }

  /// Extracts bidirectional links from note text and returns resolved note IDs.
  List<String> resolveWikiLinks(String text) {
    return _linkResolver.resolveAll(text);
  }

  /// Utility to get category UI metadata.
  static CategoryMetadata getCategoryMetadata(NoteCategory category) {
    return switch (category) {
      NoteCategory.finance => const CategoryMetadata(
          label: 'Finance',
          icon: '💰',
          description: 'Bank, UPI, receipts, and salary',
        ),
      NoteCategory.work => const CategoryMetadata(
          label: 'Work',
          icon: '💼',
          description: 'Meetings, projects, and tasks',
        ),
      NoteCategory.personal => const CategoryMetadata(
          label: 'Personal',
          icon: '👤',
          description: 'Diary, ideas, and home life',
        ),
      NoteCategory.tech => const CategoryMetadata(
          label: 'Tech',
          icon: '💻',
          description: 'Code, secrets, and servers',
        ),
      NoteCategory.health => const CategoryMetadata(
          label: 'Health',
          icon: '🏥',
          description: 'Medical, fitness, and diet',
        ),
      NoteCategory.education => const CategoryMetadata(
          label: 'Education',
          icon: '📚',
          description: 'Courses, exams, and research',
        ),
      NoteCategory.shopping => const CategoryMetadata(
          label: 'Shopping',
          icon: '🛒',
          description: 'Orders, deals, and wishlist',
        ),
      NoteCategory.travel => const CategoryMetadata(
          label: 'Travel',
          icon: '✈️',
          description: 'Trips, hotels, and passports',
        ),
      NoteCategory.legal => const CategoryMetadata(
          label: 'Legal',
          icon: '⚖️',
          description: 'Contracts, terms, and policies',
        ),
      NoteCategory.social => const CategoryMetadata(
          label: 'Social',
          icon: '🎉',
          description: 'Parties, friends, and events',
        ),
      NoteCategory.ideas => const CategoryMetadata(
          label: 'Ideas',
          icon: '💡',
          description: 'Innovation and concepts',
        ),
      NoteCategory.projects => const CategoryMetadata(
          label: 'Projects',
          icon: '🚀',
          description: 'Roadmaps and ongoing work',
        ),
      NoteCategory.receipts => const CategoryMetadata(
          label: 'Receipts',
          icon: '🧾',
          description: 'Invoices and payments',
        ),
      NoteCategory.media => const CategoryMetadata(
          label: 'Media',
          icon: '🎬',
          description: 'Photos, video, and audio',
        ),
      NoteCategory.passwords => const CategoryMetadata(
          label: 'Passwords',
          icon: '🔑',
          description: 'Logins and credentials',
        ),
      NoteCategory.general => const CategoryMetadata(
          label: 'General',
          icon: '📝',
          description: 'Miscellaneous notes',
        ),
    };
  }
}

class CategoryMetadata {
  final String label;
  final String icon;
  final String description;

  const CategoryMetadata({
    required this.label,
    required this.icon,
    required this.description,
  });
}

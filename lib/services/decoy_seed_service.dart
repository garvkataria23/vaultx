import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../models/drive_file.dart';

class DecoySeedService {
  DecoySeedService._();
  static final _uuid = const Uuid();

  static Box get _notesBox => Hive.box('vaultx_decoy_notes');
  static Box get _driveBox => Hive.box('vaultx_decoy_drive');

  static bool _seeded = false;

  static Future<void> ensureSeeded() async {
    if (_seeded) return;
    final flag = _notesBox.get('_decoy_seeded', defaultValue: false) as bool;
    if (flag) {
      _seeded = true;
      return;
    }
    await _seedAll();
    await _notesBox.put('_decoy_seeded', true);
    _seeded = true;
  }

  static Future<void> _seedAll() async {
    final now = DateTime.now();
    final notes = _generateNotes(now);
    for (final n in notes) {
      await _notesBox.put('decoy:${n.id}', n.toJson());
    }
    final files = _generateDriveFiles(now);
    for (final f in files) {
      await _driveBox.put('decoy:${f.id}', f.toJson());
    }
  }

  static Future<List<SecureNote>> loadNotes() async {
    await ensureSeeded();
    final list = <SecureNote>[];
    for (final k in _notesBox.keys.where(
      (k) => k.toString().startsWith('decoy:') && k.toString() != '_decoy_seeded',
    )) {
      final raw = _notesBox.get(k);
      if (raw is! Map) continue;
      try {
        list.add(SecureNote.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {}
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  static Future<SecureNote> createBlank() async {
    final now = DateTime.now();
    return SecureNote(
      id: _uuid.v4(),
      title: '',
      body: '',
      type: NoteType.text,
      createdAt: now,
      updatedAt: now,
      folder: 'Personal',
    );
  }

  static Future<void> saveNote(SecureNote note) async {
    await _notesBox.put('decoy:${note.id}', note.toJson());
  }

  static Future<void> deleteNote(String id) async {
    await _notesBox.delete('decoy:$id');
  }

  static Future<List<SecureDriveFile>> loadDriveFiles() async {
    await ensureSeeded();
    final list = <SecureDriveFile>[];
    for (final k in _driveBox.keys.where(
      (k) => k.toString().startsWith('decoy:'),
    )) {
      final raw = _driveBox.get(k);
      if (raw is! Map) continue;
      try {
        list.add(SecureDriveFile.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {}
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  static List<SecureNote> _generateNotes(DateTime now) {
    return [
      SecureNote(
        id: _uuid.v4(),
        title: 'Weekend Plans',
        body: 'Movie on Saturday with Rohan maybe around 7pm.\nNeed to book tickets before Friday.\n\nAlso check if PVR has the new Marvel movie.',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 5, hours: 3)),
        updatedAt: now.subtract(const Duration(days: 5, hours: 3)),
        folder: 'Personal',
        tags: ['social', 'weekend', 'movies'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Gym Routine',
        body: 'Monday — Chest & Triceps\nTuesday — Back & Biceps\nWednesday — Shoulders & Abs\nThursday — Legs\nFriday — Chest & Back combo\nSaturday — Arms & Cardio\nSunday — Rest\n\nTry to hit 10k steps daily too 💪',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 12, hours: 10)),
        updatedAt: now.subtract(const Duration(days: 1, hours: 7)),
        folder: 'Fitness',
        tags: ['gym', 'health', 'workout'],
        pinned: false,
        favorite: true,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'WiFi Password',
        body: 'Airtel_5G\nPassword: Sia@2025wifi\n\nSSID: Airtel_XXXX\nGuest: Airtel_Guest / guest@123',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 20, hours: 14)),
        updatedAt: now.subtract(const Duration(days: 20, hours: 14)),
        folder: 'Private',
        tags: ['wifi', 'home', 'internet'],
        pinned: true,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Monthly Expenses',
        body: 'Petrol — ₹1,500\nFood & dining — ₹4,200\nRecharge (phone+net) — ₹799\nNew headphones — ₹2,499\nSpotify — ₹179\nNetflix — ₹649\nGym — ₹2,000\nEmergency fund — ₹3,000\n\nTotal: ~₹14,826\nNeed to cut down on eating out 🥲',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 3, hours: 20)),
        updatedAt: now.subtract(const Duration(days: 1, hours: 12)),
        folder: 'Finance',
        tags: ['money', 'budget', 'bills'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'College Assignments',
        body: '☐ Submit AI assignment before 18th\n☐ Print project report tomorrow\n☐ Ask Prof. Mehta about extension for ML minor project\n☐ Buy chart paper for maths presentation\n☐ Group meeting for DBMS project on Thursday',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 7, hours: 16)),
        updatedAt: now.subtract(const Duration(days: 2, hours: 9)),
        folder: 'Academics',
        tags: ['college', 'deadlines', 'assignments'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Business Ideas 💡',
        body: '1. Sneaker reselling page on Instagram — could work with good reels\n2. Local chai review blog/reels — Bombay has so many hidden spots\n3. Print-on-demand t-shirts with desi memes\n4. Coding tutorials for beginners in Hindi\n\nNeed to start small and stay consistent.',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 2, hours: 22)),
        updatedAt: now.subtract(const Duration(days: 2, hours: 22)),
        folder: 'Ideas',
        tags: ['business', 'side hustle', 'creative'],
        pinned: false,
        favorite: true,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Shopping List 🛒',
        body: '• New running shoes (check Nike/Adidas sale)\n• Black hoodie — plain no print\n• Power bank — 20k mAh minimum\n• USB-C cable braided\n• Wireless earbuds under ₹2k\n• Notebooks for college\n• Tide detergent',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 1, hours: 18)),
        updatedAt: now.subtract(const Duration(days: 1, hours: 18)),
        folder: 'Personal',
        tags: ['shopping', 'wishlist'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Cafe Recommendations ☕',
        body: '• Blue Tokai — good cold brew, nice ambience\n• Subko — try the sea salt brownie 🤯\n• Poetry — great vibe for working/studying\n• Third Wave — decent filter coffee\n• Cafe Madras — best South Indian filter coffee\n• Kala Ghoda Cafe — aesthetic af\n\nTry the tiramisu at Subko next time!',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 10, hours: 11)),
        updatedAt: now.subtract(const Duration(days: 4, hours: 15)),
        folder: 'Food',
        tags: ['cafes', 'mumbai', 'coffee'],
        pinned: false,
        favorite: true,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Meeting Notes — 5 May',
        body: 'College placement cell meeting:\n- TCS visit expected in August\n- Infosys probably September\n- Start preparing aptitude from June\n- Resume workshop on 15th May\n- Mock interviews from June 1st week\n\nAsk HR about minimum CGPA criteria.',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 6, hours: 5)),
        updatedAt: now.subtract(const Duration(days: 6, hours: 3)),
        folder: 'Academics',
        tags: ['college', 'placement', 'meeting'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Goa Trip Plan ✈️',
        body: 'Dates: 20-25 June\n\n☐ Book flight tickets (check IndiGo/Cleartrip)\n☐ Hostel/Hotel near Baga or Anjuna\n☐ Rent scooty — ₹500/day approx\n☐ Make list of beaches to visit\n☐ Budget: ~₹15k\n\nPlaces to visit:\n- Anjuna Beach & Wednesday flea market\n- Chapora Fort\n- Dudhsagar Falls (if time permits)\n- South Goa beaches (Palolem, Butterfly)',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 14, hours: 8)),
        updatedAt: now.subtract(const Duration(days: 12, hours: 10)),
        folder: 'Travel',
        tags: ['trip', 'goa', 'vacation'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Active Subscriptions',
        body: '1. Spotify Premium — ₹179/mo (shared family plan)\n2. Netflix — ₹649/mo (sharing with friends)\n3. YouTube Premium — free trial ends 25 May\n4. Amazon Prime — yearly, expires Dec\n5. iCloud 50GB — ₹75/mo\n6. Notion Plus — college email, free\n\nTotal monthly: ~₹903\nNeed to cancel YouTube before trial ends!',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 25, hours: 2)),
        updatedAt: now.subtract(const Duration(days: 2, hours: 6)),
        folder: 'Finance',
        tags: ['subscriptions', 'finance', 'bills'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Recipe — Egg Fried Rice 🍳',
        body: 'Ingredients:\n- 2 cups leftover rice (cold)\n- 3 eggs\n- Spring onions\n- Soy sauce, pepper, salt\n- Garlic, ginger\n- Optional: veggies (carrot, beans, capsicum)\n\nSteps:\n1. Scramble eggs in hot oil, keep aside\n2. Fry garlic+ginger in same pan\n3. Add veggies, cook 2 min\n4. Add rice, soy sauce, toss well\n5. Add eggs back, mix, garnish with spring onion\n\nPro tip: use day-old rice for best texture!',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 18, hours: 19)),
        updatedAt: now.subtract(const Duration(days: 18, hours: 19)),
        folder: 'Food',
        tags: ['recipe', 'cooking', 'food'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Work Reminders',
        body: '☐ Finish PPT for Monday presentation\n☐ Send weekly report by Sunday evening\n☐ Remind Rahul about the payment\n☐ Update LinkedIn profile with new skills\n☐ Complete Flutter course module 5\n☐ Fix bug in login flow (reported on GitHub)',
        type: NoteType.checklist,
        createdAt: now.subtract(const Duration(days: 4, hours: 14)),
        updatedAt: now.subtract(const Duration(days: 1, hours: 1)),
        folder: 'Work',
        tags: ['work', 'tasks', 'reminders'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Movies & Shows to Watch 🎬',
        body: 'Movies:\n• Interstellar (rewatch?)\n• John Wick 4\n• Everything Everywhere All At Once\n• La La Land\n• Kantara\n\nShows:\n• Breaking Bad (started S3)\n• Panchayat S3 — waiting\n• Dark — need to finish S2\n\nCurrently watching: Panchayat S2',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 9, hours: 21)),
        updatedAt: now.subtract(const Duration(days: 7, hours: 16)),
        folder: 'Entertainment',
        tags: ['movies', 'shows', 'watchlist'],
        pinned: false,
        favorite: false,
      ),
      SecureNote(
        id: _uuid.v4(),
        title: 'Fitness Progress 📊',
        body: 'Weight: 72kg (started at 78kg)\nBench press: 55kg → 65kg (3 months)\nSquat: 60kg → 75kg\nDeadlift: 70kg → 85kg\nRunning: 2km → 5km (30 min)\n\nGoal by August:\n- Weight: 68kg\n- Bench: 75kg\n- Run 5km under 25 min\n\nProgress pics every 2 weeks.',
        type: NoteType.text,
        createdAt: now.subtract(const Duration(days: 60, hours: 5)),
        updatedAt: now.subtract(const Duration(days: 8, hours: 14)),
        folder: 'Fitness',
        tags: ['fitness', 'gym', 'progress'],
        pinned: false,
        favorite: true,
      ),
    ];
  }

  static List<SecureDriveFile> _generateDriveFiles(DateTime now) {
    return [
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Resume_Final_2025.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 284000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'PDFs',
        tags: ['resume', 'career'],
        createdAt: now.subtract(const Duration(days: 45, hours: 3)),
        updatedAt: now.subtract(const Duration(days: 30, hours: 12)),
        favorite: true,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Electricity_Bill_March2025.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 128000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['bill', 'electricity', 'house'],
        createdAt: now.subtract(const Duration(days: 50, hours: 10)),
        updatedAt: now.subtract(const Duration(days: 50, hours: 10)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'AI_Project_Report.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 2450000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'PDFs',
        tags: ['college', 'project', 'AI'],
        createdAt: now.subtract(const Duration(days: 35, hours: 14)),
        updatedAt: now.subtract(const Duration(days: 32, hours: 8)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Goa_Trip_Itinerary.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 412000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'PDFs',
        tags: ['trip', 'goa', 'travel'],
        createdAt: now.subtract(const Duration(days: 15, hours: 20)),
        updatedAt: now.subtract(const Duration(days: 13, hours: 6)),
        favorite: true,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Internship_Offer_Sparks.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 560000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['internship', 'offer', 'career'],
        createdAt: now.subtract(const Duration(days: 70, hours: 4)),
        updatedAt: now.subtract(const Duration(days: 70, hours: 4)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Notes_Sem5_ML.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 3200000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'PDFs',
        tags: ['college', 'notes', 'machine learning'],
        createdAt: now.subtract(const Duration(days: 100, hours: 6)),
        updatedAt: now.subtract(const Duration(days: 90, hours: 2)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Aadhaar_Update_Form.pdf',
        kind: 'pdf',
        mimeType: 'application/pdf',
        size: 195000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'IDs',
        tags: ['aadhaar', 'id', 'govt'],
        createdAt: now.subtract(const Duration(days: 55, hours: 12)),
        updatedAt: now.subtract(const Duration(days: 55, hours: 12)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Birthday_Photo_March.jpg',
        kind: 'image',
        mimeType: 'image/jpeg',
        size: 4200000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Photos',
        tags: ['birthday', 'friends', 'party'],
        createdAt: now.subtract(const Duration(days: 65, hours: 22)),
        updatedAt: now.subtract(const Duration(days: 65, hours: 22)),
        favorite: true,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Cafe_Sunset_Bandra.jpg',
        kind: 'image',
        mimeType: 'image/jpeg',
        size: 3800000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Photos',
        tags: ['cafe', 'sunset', 'bandra'],
        createdAt: now.subtract(const Duration(days: 30, hours: 17)),
        updatedAt: now.subtract(const Duration(days: 30, hours: 17)),
        favorite: true,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Beach_Wallpaper_Goa.jpg',
        kind: 'image',
        mimeType: 'image/jpeg',
        size: 5600000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Photos',
        tags: ['beach', 'goa', 'wallpaper'],
        createdAt: now.subtract(const Duration(days: 16, hours: 8)),
        updatedAt: now.subtract(const Duration(days: 16, hours: 8)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Pet_Dog_Charlie.jpg',
        kind: 'image',
        mimeType: 'image/jpeg',
        size: 3100000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Photos',
        tags: ['pet', 'dog', 'cute'],
        createdAt: now.subtract(const Duration(days: 40, hours: 9)),
        updatedAt: now.subtract(const Duration(days: 40, hours: 9)),
        favorite: true,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Class_Notes_DBMS.jpg',
        kind: 'image',
        mimeType: 'image/jpeg',
        size: 2800000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Photos',
        tags: ['college', 'notes', 'dbms'],
        createdAt: now.subtract(const Duration(days: 25, hours: 13)),
        updatedAt: now.subtract(const Duration(days: 25, hours: 13)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Meme_Programmers_v2.jpg',
        kind: 'image',
        mimeType: 'image/jpeg',
        size: 890000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Photos',
        tags: ['meme', 'funny', 'programming'],
        createdAt: now.subtract(const Duration(days: 8, hours: 23)),
        updatedAt: now.subtract(const Duration(days: 8, hours: 23)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Screenshot_2025-04-10_Login_Bug.png',
        kind: 'image',
        mimeType: 'image/png',
        size: 1200000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Screenshots',
        tags: ['screenshot', 'bug', 'work'],
        createdAt: now.subtract(const Duration(days: 31, hours: 16)),
        updatedAt: now.subtract(const Duration(days: 31, hours: 16)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Screenshot_2025-04-28_UI_Design.png',
        kind: 'image',
        mimeType: 'image/png',
        size: 980000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Screenshots',
        tags: ['screenshot', 'design', 'ui'],
        createdAt: now.subtract(const Duration(days: 13, hours: 20)),
        updatedAt: now.subtract(const Duration(days: 13, hours: 20)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'College_ID_Card.jpg',
        kind: 'id',
        mimeType: 'image/jpeg',
        size: 650000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'IDs',
        tags: ['college', 'id'],
        createdAt: now.subtract(const Duration(days: 200, hours: 5)),
        updatedAt: now.subtract(const Duration(days: 200, hours: 5)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'PAN_Card_Signed.jpg',
        kind: 'id',
        mimeType: 'image/jpeg',
        size: 520000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'IDs',
        tags: ['pan', 'id', 'govt'],
        createdAt: now.subtract(const Duration(days: 150, hours: 8)),
        updatedAt: now.subtract(const Duration(days: 150, hours: 8)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Invoice_Laptop_Repair.pdf',
        kind: 'document',
        mimeType: 'application/pdf',
        size: 185000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['invoice', 'laptop', 'repair'],
        createdAt: now.subtract(const Duration(days: 22, hours: 15)),
        updatedAt: now.subtract(const Duration(days: 22, hours: 15)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Flight_Ticket_Goa_IndiGo.pdf',
        kind: 'document',
        mimeType: 'application/pdf',
        size: 340000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Travel',
        tags: ['flight', 'ticket', 'goa'],
        createdAt: now.subtract(const Duration(days: 16, hours: 10)),
        updatedAt: now.subtract(const Duration(days: 16, hours: 10)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Hotel_Booking_Baga.pdf',
        kind: 'document',
        mimeType: 'application/pdf',
        size: 210000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Travel',
        tags: ['hotel', 'booking', 'goa'],
        createdAt: now.subtract(const Duration(days: 17, hours: 11)),
        updatedAt: now.subtract(const Duration(days: 17, hours: 11)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Internship_Offer_Letter.pdf',
        kind: 'document',
        mimeType: 'application/pdf',
        size: 780000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['internship', 'offer', 'career'],
        createdAt: now.subtract(const Duration(days: 72, hours: 3)),
        updatedAt: now.subtract(const Duration(days: 72, hours: 3)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Salary_Slip_April.pdf',
        kind: 'document',
        mimeType: 'application/pdf',
        size: 290000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['salary', 'finance'],
        createdAt: now.subtract(const Duration(days: 12, hours: 9)),
        updatedAt: now.subtract(const Duration(days: 12, hours: 9)),
        favorite: false,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'ML_Project_Report_Final.docx',
        kind: 'document',
        mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        size: 1800000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['college', 'ML', 'project'],
        createdAt: now.subtract(const Duration(days: 34, hours: 18)),
        updatedAt: now.subtract(const Duration(days: 33, hours: 20)),
        favorite: true,
      ),
      SecureDriveFile(
        id: _uuid.v4(),
        name: 'Receipt_Zomato_April.pdf',
        kind: 'document',
        mimeType: 'application/pdf',
        size: 95000,
        encryptedPath: '_decoy_',
        salt: '',
        folder: 'Documents',
        tags: ['receipt', 'food', 'zomato'],
        createdAt: now.subtract(const Duration(days: 6, hours: 21)),
        updatedAt: now.subtract(const Duration(days: 6, hours: 21)),
        favorite: false,
      ),
    ];
  }
}

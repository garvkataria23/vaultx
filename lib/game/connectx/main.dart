import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'pages/chat_page.dart';

const String kDbUrl = "https://connect4-199ee-default-rtdb.firebaseio.com";

// ConnectX Game Entry Point

// ════════════════════════════════════════════════════════════════════
//  THEME
// ════════════════════════════════════════════════════════════════════
class AT {
  static const r = Color(0xFFFF4757);
  static const y = Color(0xFFFFD700);
  static const bl = Color(0xFF4FC3F7);
  static const gr = Color(0xFF56C596);
  static const or = Color(0xFFFFB74D);
  static const pu = Color(0xFFB39DDB);

  static const rGlow = Color(0x8CFF4757);
  static const yGlow = Color(0x8CFFB800);
  static const blDim = Color(0x1A4FC3F7);
  static const blMid = Color(0x334FC3F7);
  static const orDim = Color(0x1AFFB74D);
  static const grDim = Color(0x1256C596);
  static const white06 = Color(0x0FFFFFFF);
  static const white12 = Color(0x1EFFFFFF);
  static const white45 = Color(0x73FFFFFF);
  static const black50 = Color(0x80000000);

  final bool dark;
  const AT(this.dark);

  Color get bg => dark ? const Color(0xFF060B18) : const Color(0xFFF0F4FF);
  Color get card => dark ? const Color(0xFF0D1A2E) : Colors.white;
  Color get brd => dark ? const Color(0xFF081428) : const Color(0xFF1A3A6B);
  Color get bdr => dark ? const Color(0xFF1E3A5F) : const Color(0xFFBDD0F0);
  Color get txt => dark ? Colors.white : const Color(0xFF0A1628);
  Color get sub => dark ? const Color(0xFF4A6B8A) : const Color(0xFF7A95C0);
  Color get stBg => dark ? const Color(0x0AFFFFFF) : const Color(0xFFEAF0FF);

  LinearGradient get grad => dark
      ? const LinearGradient(
          colors: [Color(0xFF060B18), Color(0xFF0D1F35)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        )
      : const LinearGradient(
          colors: [Color(0xFFEAF1FF), Color(0xFFF8FAFF)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        );

  ThemeData get td => ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: bg,
    fontFamily: 'Roboto',
    colorScheme: dark
        ? const ColorScheme.dark(primary: bl)
        : const ColorScheme.light(primary: bl),
  );
}

class TN extends InheritedWidget {
  final AT t;
  final VoidCallback tog;
  const TN({
    super.key,
    required this.t,
    required this.tog,
    required super.child,
  });
  static TN? maybeOf(BuildContext c) => c.dependOnInheritedWidgetOfExactType<TN>();
  static TN of(BuildContext c) {
    final res = maybeOf(c);
    return res ?? TN(t: const AT(true), tog: () {}, child: const SizedBox());
  }
  @override
  bool updateShouldNotify(TN o) => t.dark != o.t.dark;
}

// ════════════════════════════════════════════════════════════════════
//  AUDIO
// ════════════════════════════════════════════════════════════════════
class Snd {
  static bool on = true;
  static void drop() {
    if (!on) return;
    try {
      SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  static void click() {
    if (!on) return;
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  static void win() {
    if (!on) return;
    _tri(HapticFeedback.heavyImpact);
  }

  static void draw() {
    if (!on) return;
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  static void tick() {
    if (!on) return;
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}
  }

  static void _tri(Function f) async {
    try {
      f();
      await Future.delayed(const Duration(milliseconds: 90));
      f();
      await Future.delayed(const Duration(milliseconds: 90));
      f();
    } catch (_) {}
  }
}

// ════════════════════════════════════════════════════════════════════
//  FIREBASE SERVICE
// ════════════════════════════════════════════════════════════════════
class FB {
  static String _uid = '';
  static String get uid {
    if (_uid.isEmpty) {
      const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final r = Random();
      _uid = List.generate(12, (_) => cs[r.nextInt(cs.length)]).join();
    }
    return _uid;
  }

  static Future<http.Response> _put(String p, dynamic d) =>
      http.put(Uri.parse('$kDbUrl/$p.json'), body: jsonEncode(d));
  static Future<http.Response> _patch(String p, dynamic d) =>
      http.patch(Uri.parse('$kDbUrl/$p.json'), body: jsonEncode(d));
  static Future<http.Response> _del(String p) =>
      http.delete(Uri.parse('$kDbUrl/$p.json'));
  static Future<dynamic> _get(String p) async {
    try {
      final r = await http
          .get(Uri.parse('$kDbUrl/$p.json'))
          .timeout(const Duration(seconds: 8));
      if (r.body == 'null' || r.body.isEmpty) return null;
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> joinRandom(
    String username,
    void Function(String) onStatus,
  ) async {
    final me = uid;
    final ts = DateTime.now().millisecondsSinceEpoch;
    await _put('queue/$me', {'ts': ts, 'gameId': null, 'name': username});
    onStatus('Looking for opponent...');

    for (int attempt = 0; attempt < 120; attempt++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      final mySlot = await _get('queue/$me');
      if (mySlot == null) continue;
      final assignedId = mySlot['gameId'];
      if (assignedId != null && assignedId.toString().isNotEmpty) {
        for (int w = 0; w < 10; w++) {
          final g = await _get('games/$assignedId');
          if (g != null) {
            await _del('queue/$me');
            return {
              'gameId': assignedId,
              'playerNum': 2,
              'game': Map<String, dynamic>.from(g),
            };
          }
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
      final queue = await _get('queue');
      if (queue == null) {
        onStatus('Waiting...');
        continue;
      }
      final others = (queue as Map<String, dynamic>).entries
          .where(
            (e) =>
                e.key != me &&
                (e.value['gameId'] == null ||
                    e.value['gameId'].toString().isEmpty),
          )
          .toList();
      if (others.isEmpty) {
        onStatus('Waiting for opponent...');
        continue;
      }
      others.sort(
        (a, b) => ((a.value['ts'] ?? 0) as int).compareTo(
          (b.value['ts'] ?? 0) as int,
        ),
      );
      final other = others.first;
      final otherId = other.key;
      final otherName = other.value['name'] ?? 'Opponent';
      onStatus('Opponent found! Connecting...');
      final gid = _mkId();
      final gameData = {
        'board': List.filled(42, 0).join(','),
        'currentPlayer': 1,
        'p1id': me,
        'p2id': otherId,
        'p1name': username,
        'p2name': otherName,
        'status': 'active',
        'winner': 0,
        'created': ts,
        'emoji': '',
        'emojiFrom': 0,
        'rematch': 0,
        'p1score': 0,
        'p2score': 0,
      };
      await _put('games/$gid', gameData);
      await _patch('queue/$otherId', {'gameId': gid});
      await _patch('queue/$me', {'gameId': gid});
      await Future.delayed(const Duration(milliseconds: 300));
      await _del('queue/$me');
      return {'gameId': gid, 'playerNum': 1, 'game': gameData};
    }
    throw Exception('Timeout — no opponent found');
  }

  static Future<String> createFriendLobby(String username) async {
    final code = _mkCode();
    await _put('lobbies/$code', {
      'host': uid,
      'hname': username,
      'guest': null,
      'gname': null,
      'gameId': null,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    return code;
  }

  static Future<Map<String, dynamic>> joinFriendLobby(
    String code,
    String username,
  ) async {
    final lobby = await _get('lobbies/$code');
    if (lobby == null) throw Exception('Code not found');
    if (lobby['guest'] != null) throw Exception('Lobby is full');
    await _patch('lobbies/$code', {'guest': uid, 'gname': username});
    for (int i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 800));
      final l = await _get('lobbies/$code');
      if (l != null && l['gameId'] != null) {
        final gid = l['gameId'] as String;
        final g = await _get('games/$gid');
        if (g != null) {
          return {
            'gameId': gid,
            'playerNum': 2,
            'game': Map<String, dynamic>.from(g),
          };
        }
      }
    }
    throw Exception('Host did not start the game');
  }

  static Future<Map<String, dynamic>?> pollForGuest(
    String code,
    String username,
  ) async {
    final l = await _get('lobbies/$code');
    if (l == null) return null;
    final guestId = l['guest'];
    final guestName = l['gname'] ?? 'Guest';
    if (guestId == null) return null;
    final gid = _mkId();
    final gameData = {
      'board': List.filled(42, 0).join(','),
      'currentPlayer': 1,
      'p1id': uid,
      'p2id': guestId,
      'p1name': username,
      'p2name': guestName,
      'status': 'active',
      'winner': 0,
      'created': DateTime.now().millisecondsSinceEpoch,
      'emoji': '',
      'emojiFrom': 0,
      'rematch': 0,
      'p1score': 0,
      'p2score': 0,
    };
    await _put('games/$gid', gameData);
    await _patch('lobbies/$code', {'gameId': gid});
    return {
      'gameId': gid,
      'playerNum': 1,
      'game': gameData,
      'opponentName': guestName,
    };
  }

  static Future<void> deleteLobby(String code) async => _del('lobbies/$code');

  static Future<Map<String, dynamic>?> fetchGame(String gid) async {
    final d = await _get('games/$gid');
    return d == null ? null : Map<String, dynamic>.from(d);
  }

  static Future<void> pushMove(
    String gid,
    List<List<int>> board,
    int next,
  ) async => _patch('games/$gid', {
    'board': board.expand((r) => r).join(','),
    'currentPlayer': next,
  });

  static Future<void> pushWinner(
    String gid,
    int w, {
    int p1score = 0,
    int p2score = 0,
  }) async => _patch('games/$gid', {
    'status': 'finished',
    'winner': w,
    'p1score': p1score,
    'p2score': p2score,
  });

  static Future<void> pushEmoji(
    String gid,
    String emoji,
    int fromPlayer,
  ) async => _patch('games/$gid', {
    'emoji': emoji,
    'emojiFrom': fromPlayer,
    'emojiTs': DateTime.now().millisecondsSinceEpoch,
  });

  static Future<void> clearEmoji(String gid) async =>
      _patch('games/$gid', {'emoji': '', 'emojiFrom': 0});

  static Future<void> pushRematch(String gid, int playerNum) async =>
      _patch('games/$gid', {'rematch': playerNum});

  static Future<void> cancelRematch(String gid) async =>
      _patch('games/$gid', {'rematch': 0});

  static Future<String> createRematch(
    String gid,
    String p1name,
    String p2name,
    String p1id,
    String p2id,
    int p1score,
    int p2score,
  ) async {
    final newGid = _mkId();
    final gameData = {
      'board': List.filled(42, 0).join(','),
      'currentPlayer': 1,
      'p1id': p1id,
      'p2id': p2id,
      'p1name': p1name,
      'p2name': p2name,
      'status': 'active',
      'winner': 0,
      'created': DateTime.now().millisecondsSinceEpoch,
      'emoji': '',
      'emojiFrom': 0,
      'rematch': 0,
      'p1score': p1score,
      'p2score': p2score,
      'rematchOf': gid,
    };
    await _put('games/$newGid', gameData);
    await _patch('games/$gid', {'rematchGameId': newGid});
    return newGid;
  }

  static Future<void> deleteGame(String gid) async => _del('games/$gid');

  static List<List<int>> parseBoard(String s) {
    final flat = s.split(',').map(int.parse).toList();
    return List.generate(6, (r) => flat.sublist(r * 7, r * 7 + 7));
  }

  static String _mkId() {
    const c = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(16, (_) => c[r.nextInt(c.length)]).join();
  }

  static String _mkCode() {
    const c = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random();
    return List.generate(6, (_) => c[r.nextInt(c.length)]).join();
  }

  // ── Tournament helpers ──────────────────────────────────────────
  static Future<void> createTournament(
    String tid,
    Map<String, dynamic> data,
  ) async => _put('tournaments/$tid', data);
  static Future<Map<String, dynamic>?> fetchTournament(String tid) async {
    final d = await _get('tournaments/$tid');
    return d == null ? null : Map<String, dynamic>.from(d);
  }

  static Future<void> updateTournament(
    String tid,
    Map<String, dynamic> data,
  ) async => _patch('tournaments/$tid', data);
  static String mkTournamentId() => _mkCode();
  static Future<void> sendMessage(String gid, String text, int sender) async {
    final msgId = DateTime.now().millisecondsSinceEpoch.toString();
    await _patch('games/$gid/chats/$msgId', {
      'text': text,
      'sender': sender,
      'time': DateTime.now().millisecondsSinceEpoch,
      'seen': false,
    });
  }

  static Future<void> markSeen(String gid, String msgId) async {
    await _patch('games/$gid/chats/$msgId', {'seen': true});
  }

  static Future<Map<String, dynamic>?> fetchMessages(String gid) async {
    final data = await _get('games/$gid/chats');
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  static Future<void> setTyping(String gid, int player, bool isTyping) async {
    await _patch('games/$gid/typing', {'player': player, 'isTyping': isTyping});
  }

  static Future<Map<String, dynamic>?> getTyping(String gid) async {
    final data = await _get('games/$gid/typing');
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  static Future<int> getUnreadCount(String gid, int myPlayerNum) async {
    final data = await _get('games/$gid/chats');
    if (data == null) return 0;

    int count = 0;

    data.forEach((key, value) {
      if (value['sender'] != myPlayerNum && value['seen'] == false) {
        count++;
      }
    });

    return count;
  }
}

// ════════════════════════════════════════════════════════════════════
//  ENUMS
// ════════════════════════════════════════════════════════════════════
enum GM { bot, local, online }

enum Diff { easy, med, hard }

// ════════════════════════════════════════════════════════════════════
//  TOURNAMENT MODEL
// ════════════════════════════════════════════════════════════════════
class TournamentMatch {
  final String id;
  String p1, p2;
  String winner;
  String gameId;

  TournamentMatch({
    required this.id,
    required this.p1,
    required this.p2,
    this.winner = '',
    this.gameId = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'p1': p1,
    'p2': p2,
    'winner': winner,
    'gameId': gameId,
  };
  static TournamentMatch fromMap(Map<String, dynamic> m) => TournamentMatch(
    id: m['id'] ?? '',
    p1: m['p1'] ?? '',
    p2: m['p2'] ?? '',
    winner: m['winner'] ?? '',
    gameId: m['gameId'] ?? '',
  );
}

class TournamentBracket {
  final String id;
  final List<String> players;
  final List<TournamentMatch> qf;
  final List<TournamentMatch> sf;
  final List<TournamentMatch> final_;
  String champion;
  String createdBy;

  TournamentBracket({
    required this.id,
    required this.players,
    required this.qf,
    required this.sf,
    required this.final_,
    this.champion = '',
    required this.createdBy,
  });

  static TournamentBracket create(
    String id,
    List<String> players,
    String createdBy,
  ) {
    final shuffled = List<String>.from(players)..shuffle();
    final qf = [
      TournamentMatch(id: 'qf1', p1: shuffled[0], p2: shuffled[1]),
      TournamentMatch(id: 'qf2', p1: shuffled[2], p2: shuffled[3]),
      TournamentMatch(id: 'qf3', p1: shuffled[4], p2: shuffled[5]),
      TournamentMatch(id: 'qf4', p1: shuffled[6], p2: shuffled[7]),
    ];
    final sf = [
      TournamentMatch(id: 'sf1', p1: '', p2: ''),
      TournamentMatch(id: 'sf2', p1: '', p2: ''),
    ];
    final fin = [TournamentMatch(id: 'fin', p1: '', p2: '')];
    return TournamentBracket(
      id: id,
      players: shuffled,
      qf: qf,
      sf: sf,
      final_: fin,
      createdBy: createdBy,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'players': players,
    'qf': qf.map((m) => m.toMap()).toList(),
    'sf': sf.map((m) => m.toMap()).toList(),
    'final': final_.map((m) => m.toMap()).toList(),
    'champion': champion,
    'createdBy': createdBy,
  };

  static TournamentBracket fromMap(Map<String, dynamic> m) {
    List<TournamentMatch> parseMatches(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) {
        return raw
            .map((e) => TournamentMatch.fromMap(Map<String, dynamic>.from(e)))
            .toList();
      }
      if (raw is Map) {
        return raw.values
            .map((e) => TournamentMatch.fromMap(Map<String, dynamic>.from(e)))
            .toList();
      }
      return [];
    }

    return TournamentBracket(
      id: m['id'] ?? '',
      players: (m['players'] as List?)?.map((e) => e.toString()).toList() ?? [],
      qf: parseMatches(m['qf']),
      sf: parseMatches(m['sf']),
      final_: parseMatches(m['final']),
      champion: m['champion'] ?? '',
      createdBy: m['createdBy'] ?? '',
    );
  }

  void advanceWinner(String matchId, String winner) {
    if (matchId == 'qf1') {
      qf[0].winner = winner;
      sf[0].p1 = winner;
    }
    if (matchId == 'qf2') {
      qf[1].winner = winner;
      sf[0].p2 = winner;
    }
    if (matchId == 'qf3') {
      qf[2].winner = winner;
      sf[1].p1 = winner;
    }
    if (matchId == 'qf4') {
      qf[3].winner = winner;
      sf[1].p2 = winner;
    }
    if (matchId == 'sf1') {
      sf[0].winner = winner;
      final_[0].p1 = winner;
    }
    if (matchId == 'sf2') {
      sf[1].winner = winner;
      final_[0].p2 = winner;
    }
    if (matchId == 'fin') {
      final_[0].winner = winner;
      champion = winner;
    }
  }

  String getRound(String matchId) {
    if (matchId.startsWith('qf')) return 'Quarter Final';
    if (matchId.startsWith('sf')) return 'Semi Final';
    return 'FINAL';
  }
}

// ════════════════════════════════════════════════════════════════════
//  ROUTE HELPERS
// ════════════════════════════════════════════════════════════════════
Route<T> _slide<T>(Widget p) => PageRouteBuilder<T>(
  pageBuilder: (_, a, _) => p,
  transitionDuration: const Duration(milliseconds: 280),
  transitionsBuilder: (_, a, _, ch) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
    child: FadeTransition(opacity: a, child: ch),
  ),
);

Route<T> _fadeRoute<T>(Widget p) => PageRouteBuilder<T>(
  pageBuilder: (_, a, _) => p,
  transitionDuration: const Duration(milliseconds: 300),
  transitionsBuilder: (_, a, _, ch) => FadeTransition(opacity: a, child: ch),
);

// ════════════════════════════════════════════════════════════════════
//  APP ROOT
// ════════════════════════════════════════════════════════════════════
class ConnectXMain extends StatefulWidget {
  const ConnectXMain({super.key});
  @override
  State<ConnectXMain> createState() => _CXMainState();
}

class _CXMainState extends State<ConnectXMain> {
  bool _dark = true;

  @override
  Widget build(BuildContext context) {
    final t = AT(_dark);
    return TN(
      t: t,
      tog: () {
        if (mounted) setState(() => _dark = !_dark);
      },
      child: Theme(
        data: t.td,
        child: Navigator(
          onGenerateRoute: (settings) {
            return MaterialPageRoute(
              builder: (context) => const UsernameScreen(),
              settings: settings,
            );
          },
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  USERNAME SCREEN
// ════════════════════════════════════════════════════════════════════
class UsernameScreen extends StatefulWidget {
  const UsernameScreen({super.key});
  @override
  State<UsernameScreen> createState() => _USState();
}

class _USState extends State<UsernameScreen>
    with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  late AnimationController _ac;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  bool _err = false;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _ac, curve: Curves.easeOut);
    _slideAnim = Tween(
      begin: const Offset(0, .08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic));
    _ac.forward();
  }

  @override
  void dispose() {
    _ac.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _go() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      if (mounted) setState(() => _err = true);
      return;
    }
    Snd.click();
    if (!mounted) return;
    Navigator.pushReplacement(context, _fadeRoute(HomeScreen(username: name)));
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const _LogoDots(),
                      const SizedBox(height: 20),
                      Text(
                        'CONNECT 4',
                        style: TextStyle(
                          color: t.txt,
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 7,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Choose your username',
                        style: TextStyle(color: t.sub, fontSize: 14),
                      ),
                      const SizedBox(height: 52),
                      TextField(
                        controller: _ctrl,
                        maxLength: 16,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _go(),
                        onChanged: (_) {
                          if (_err) if (mounted) setState(() => _err = false);
                        },
                        style: TextStyle(
                          color: t.txt,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: 'Enter username...',
                          hintStyle: TextStyle(color: t.sub),
                          prefixIcon: const Icon(
                            Icons.person_rounded,
                            color: AT.bl,
                          ),
                          filled: true,
                          fillColor: AT.blDim,
                          errorText: _err ? 'Please enter a username' : null,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0x4D4FC3F7),
                              width: 1.5,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: AT.bl,
                              width: 2,
                            ),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: AT.r,
                              width: 1.5,
                            ),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: AT.r, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      _GlowBtn(label: "Let's Play →", color: AT.bl, onTap: _go),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoDots extends StatelessWidget {
  const _LogoDots();
  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [_Dot(AT.r), _Dot(AT.y), _Dot(AT.r), _Dot(AT.y)],
  );
}

class _Dot extends StatelessWidget {
  final Color c;
  const _Dot(this.c);
  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    margin: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: c,
      boxShadow: [BoxShadow(color: c.withValues(alpha: .5), blurRadius: 10)],
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  HOME SCREEN
// ════════════════════════════════════════════════════════════════════
class HomeScreen extends StatefulWidget {
  final String username;
  const HomeScreen({super.key, required this.username});
  @override
  State<HomeScreen> createState() => _HSState();
}

class _HSState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ac;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _ac, curve: Curves.easeOut);
    _ac.forward();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tn = TN.of(context);
    final t = tn.t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      StatefulBuilder(
                        builder: (ctx, ss) => _IPill(
                          icon: Snd.on
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          color: Snd.on ? AT.bl : t.sub,
                          onTap: () {
                            ss(() => Snd.on = !Snd.on);
                            Snd.click();
                          },
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AT.blDim,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0x4D4FC3F7)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.person_rounded,
                              color: AT.bl,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              widget.username,
                              style: const TextStyle(
                                color: AT.bl,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _IPill(
                        icon: t.dark
                            ? Icons.light_mode_rounded
                            : Icons.dark_mode_rounded,
                        color: t.dark ? AT.or : AT.bl,
                        onTap: () {
                          Snd.click();
                          tn.tog();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _Logo(),
                  const SizedBox(height: 12),
                  Text(
                    'CONNECT 4',
                    style: TextStyle(
                      color: t.txt,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 7,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'DROP · CONNECT · WIN',
                    style: TextStyle(
                      color: t.sub,
                      fontSize: 10,
                      letterSpacing: 5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 36),
                  _Card(
                    icon: Icons.smart_toy_rounded,
                    title: 'vs Bot',
                    sub: 'Easy · Medium · Hard AI',
                    color: AT.bl,
                    onTap: () => Navigator.push(
                      context,
                      _slide(DiffScreen(username: widget.username)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Card(
                    icon: Icons.people_rounded,
                    title: 'vs Friend',
                    sub: 'Local · Pass & Play',
                    color: AT.gr,
                    onTap: () => Navigator.push(
                      context,
                      _slide(LocalNamesScreen(username: widget.username)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Card(
                    icon: Icons.public_rounded,
                    title: 'Online',
                    sub: 'Random match · Friend Code · Real players',
                    color: AT.or,
                    onTap: () => Navigator.push(
                      context,
                      _slide(OnlineModeScreen(username: widget.username)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Card(
                    icon: Icons.emoji_events_rounded,
                    title: 'Tournament',
                    sub: '8 players · Bracket · Champion crowned',
                    color: AT.pu,
                    onTap: () => Navigator.push(
                      context,
                      _slide(TournamentScreen(username: widget.username)),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      if (!mounted) return;
                      Navigator.pushReplacement(
                        context,
                        _fadeRoute(const UsernameScreen()),
                      );
                    },
                    icon: Icon(Icons.edit_rounded, size: 13, color: t.sub),
                    label: Text(
                      'Change Username',
                      style: TextStyle(color: t.sub, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  LOCAL NAMES SCREEN
// ════════════════════════════════════════════════════════════════════
class LocalNamesScreen extends StatefulWidget {
  final String username;
  const LocalNamesScreen({super.key, required this.username});
  @override
  State<LocalNamesScreen> createState() => _LNSState();
}

class _LNSState extends State<LocalNamesScreen> {
  late final TextEditingController _p1 = TextEditingController(
    text: widget.username,
  );
  final _p2 = TextEditingController(text: 'Player 2');

  void _start() {
    Snd.click();
    final n1 = _p1.text.trim().isEmpty ? widget.username : _p1.text.trim();
    final n2 = _p2.text.trim().isEmpty ? 'Player 2' : _p2.text.trim();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        _slide(GamePage(mode: GM.local, p1: n1, p2: n2)),
      );
    }
  }

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              const _TBar(title: 'Player Names'),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      children: [
                        const SizedBox(height: 20),
                        _NField(
                          ctrl: _p1,
                          label: 'Player 1 (🔴 Red)',
                          color: AT.r,
                          theme: t,
                        ),
                        const SizedBox(height: 16),
                        _NField(
                          ctrl: _p2,
                          label: 'Player 2 (🟡 Yellow)',
                          color: AT.y,
                          theme: t,
                        ),
                        const SizedBox(height: 36),
                        _GlowBtn(
                          label: 'Start Game',
                          color: AT.gr,
                          onTap: _start,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  DIFFICULTY SCREEN
// ════════════════════════════════════════════════════════════════════
class DiffScreen extends StatelessWidget {
  final String username;
  const DiffScreen({super.key, required this.username});
  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              const _TBar(title: 'Select Difficulty'),
              const Spacer(),
              _DC(
                label: 'Easy',
                desc: 'Bot plays randomly',
                icon: Icons.sentiment_satisfied_alt_rounded,
                color: AT.gr,
                diff: Diff.easy,
                uname: username,
              ),
              const SizedBox(height: 14),
              _DC(
                label: 'Medium',
                desc: 'Blocks & attacks smartly',
                icon: Icons.psychology_rounded,
                color: AT.or,
                diff: Diff.med,
                uname: username,
              ),
              const SizedBox(height: 14),
              _DC(
                label: 'Hard',
                desc: 'Minimax AI — good luck!',
                icon: Icons.memory_rounded,
                color: AT.r,
                diff: Diff.hard,
                uname: username,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _DC extends StatefulWidget {
  final String label, desc, uname;
  final IconData icon;
  final Color color;
  final Diff diff;
  const _DC({
    required this.label,
    required this.desc,
    required this.icon,
    required this.color,
    required this.diff,
    required this.uname,
  });
  @override
  State<_DC> createState() => _DCState();
}

class _DCState extends State<_DC> {
  bool _p = false;
  @override
  Widget build(BuildContext ctx) {
    return GestureDetector(
      onTapDown: (_) {
        if (mounted) setState(() => _p = true);
        Snd.click();
      },
      onTapUp: (_) {
        if (mounted) setState(() => _p = false);
        if (mounted) {
          Navigator.pushReplacement(
            ctx,
            _slide(
              GamePage(
                mode: GM.bot,
                diff: widget.diff,
                p1: widget.uname,
                p2: 'Bot',
              ),
            ),
          );
        }
      },
      onTapCancel: () {
        if (mounted) setState(() => _p = false);
      },
      child: AnimatedScale(
        scale: _p ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: widget.color.withValues(alpha: .4), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: .1),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: .15),
                ),
                child: Icon(widget.icon, color: widget.color, size: 28),
              ),
              const SizedBox(width: 18),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: widget.color,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    widget.desc,
                    style: const TextStyle(color: AT.white45, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  ONLINE MODE SCREEN
// ════════════════════════════════════════════════════════════════════
class OnlineModeScreen extends StatelessWidget {
  final String username;
  const OnlineModeScreen({super.key, required this.username});
  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              const _TBar(title: 'Online Play'),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Text(
                      'How do you want to play?',
                      style: TextStyle(
                        color: t.txt,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choose random or invite a friend',
                      style: TextStyle(color: t.sub, fontSize: 13),
                    ),
                    const SizedBox(height: 40),
                    _Card(
                      icon: Icons.shuffle_rounded,
                      title: 'Random Match',
                      sub: 'Get matched with any online player instantly',
                      color: AT.or,
                      onTap: () => Navigator.push(
                        context,
                        _slide(RandomLobby(username: username)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _Card(
                      icon: Icons.link_rounded,
                      title: 'Friend Code',
                      sub: 'Create a room · Share code · Play together',
                      color: AT.bl,
                      onTap: () => Navigator.push(
                        context,
                        _slide(FriendCodeScreen(username: username)),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  RANDOM LOBBY
// ════════════════════════════════════════════════════════════════════
class RandomLobby extends StatefulWidget {
  final String username;
  const RandomLobby({super.key, required this.username});
  @override
  State<RandomLobby> createState() => _RLState();
}

class _RLState extends State<RandomLobby> with SingleTickerProviderStateMixin {
  bool _searching = false, _cancelled = false;
  String _status = '';
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _cancelled = true;
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    if (mounted) {
      setState(() {
        _searching = true;
        _status = 'Connecting to server...';
        _cancelled = false;
      });
    }
    try {
      final result = await FB.joinRandom(widget.username, (s) {
        if (mounted && !_cancelled) if (mounted) setState(() => _status = s);
      });
      if (_cancelled || !mounted) return;
      final gid = result['gameId'] as String;
      final pNum = result['playerNum'] as int;
      final game = result['game'] as Map<String, dynamic>;
      final oppName = pNum == 1
          ? (game['p2name'] ?? 'Opponent') as String
          : (game['p1name'] ?? 'Opponent') as String;
      if (mounted) {
        Navigator.pushReplacement(
          context,
          _slide(
            OnlineGame(
              gameId: gid,
              myNum: pNum,
              myName: widget.username,
              oppName: oppName,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _status = 'Error: ${e.toString().replaceAll('Exception: ', '')}';
        });
      }
    }
  }

  void _cancel() {
    _cancelled = true;
    if (mounted) {
      setState(() {
        _searching = false;
        _status = '';
      });
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final t = TN.of(ctx).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              const _TBar(title: 'Random Match'),
              const Spacer(),
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, _) {
                  final v = _pulse.value;
                  return Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.fromRGBO(255, 183, 77, 0.10 + 0.05 * v),
                      border: Border.all(
                        color: Color.fromRGBO(255, 183, 77, 0.30 + 0.20 * v),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Color.fromRGBO(255, 183, 77, 0.10 + 0.10 * v),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.public_rounded,
                      size: 48,
                      color: Color.fromRGBO(255, 183, 77, 0.9 + 0.1 * v),
                    ),
                  );
                },
              ),
              const SizedBox(height: 28),
              Text(
                'Finding Match',
                style: TextStyle(
                  color: t.txt,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 60),
                child: Text(
                  'Matched with real players worldwide in seconds.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.sub, fontSize: 13),
                ),
              ),
              const SizedBox(height: 40),
              if (!_searching)
                _GlowBtn(label: 'Find Match', color: AT.or, onTap: _find)
              else ...[
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    color: AT.or,
                    strokeWidth: 2.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: _cancel,
                  child: Text('Cancel', style: TextStyle(color: t.sub)),
                ),
              ],
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  'Playing as: ${widget.username}',
                  style: TextStyle(color: t.sub, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  FRIEND CODE SCREEN
// ════════════════════════════════════════════════════════════════════
class FriendCodeScreen extends StatefulWidget {
  final String username;
  const FriendCodeScreen({super.key, required this.username});
  @override
  State<FriendCodeScreen> createState() => _FCSState();
}

class _FCSState extends State<FriendCodeScreen> {
  final _codeCtrl = TextEditingController();
  bool _joining = false, _hosting = false;
  String _status = '', _myCode = '';
  Timer? _hostPoll;
  bool _cancelled = false;

  @override
  void dispose() {
    _cancelled = true;
    _hostPoll?.cancel();
    _codeCtrl.dispose();
    if (_myCode.isNotEmpty) FB.deleteLobby(_myCode);
    super.dispose();
  }

  Future<void> _createRoom() async {
    if (mounted) {
      setState(() {
        _hosting = true;
        _status = 'Creating room...';
      });
    }
    try {
      final code = await FB.createFriendLobby(widget.username);
      if (mounted) {
        setState(() {
          _myCode = code;
          _status = 'Share this code with your friend';
        });
      }
      _hostPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (_cancelled || !mounted) return;
        final res = await FB.pollForGuest(code, widget.username);
        if (res == null) return;
        _hostPoll?.cancel();
        if (!mounted) return;
        final opp = res['opponentName'] as String;
        Navigator.pushReplacement(
          context,
          _slide(
            OnlineGame(
              gameId: res['gameId'],
              myNum: 1,
              myName: widget.username,
              oppName: opp,
            ),
          ),
        );
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _hosting = false;
          _status = 'Error: $e';
        });
      }
    }
  }

  Future<void> _joinRoom() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      if (mounted) setState(() => _status = 'Enter 6-character code');
      return;
    }
    if (mounted) {
      setState(() {
        _joining = true;
        _status = 'Joining room $code...';
      });
    }
    try {
      final res = await FB.joinFriendLobby(code, widget.username);
      if (!mounted) return;
      final game = res['game'] as Map<String, dynamic>;
      final opp = (game['p1name'] ?? 'Host') as String;
      Navigator.pushReplacement(
        context,
        _slide(
          OnlineGame(
            gameId: res['gameId'],
            myNum: 2,
            myName: widget.username,
            oppName: opp,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _joining = false;
          _status = 'Error: ${e.toString().replaceAll('Exception:', '')}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final t = TN.of(ctx).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              const _TBar(title: 'Friend Code'),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      _Section(
                        title: 'Create a Room',
                        icon: Icons.add_rounded,
                        color: AT.bl,
                        theme: t,
                        child: Column(
                          children: [
                            if (!_hosting)
                              _GlowBtn(
                                label: 'Create Room',
                                color: AT.bl,
                                onTap: _createRoom,
                              )
                            else if (_myCode.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 18,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x1F4FC3F7),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: const Color(0x664FC3F7),
                                    width: 2,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      'YOUR CODE',
                                      style: TextStyle(
                                        color: t.sub,
                                        fontSize: 11,
                                        letterSpacing: 3,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    SelectableText(
                                      _myCode,
                                      style: const TextStyle(
                                        color: AT.bl,
                                        fontSize: 38,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 8,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            color: AT.bl,
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          'Waiting for friend...',
                                          style: TextStyle(
                                            color: t.sub,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: _myCode),
                                  );
                                  Snd.click();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Code copied!'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy_rounded, size: 16),
                                label: const Text('Copy Code'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AT.bl,
                                  side: const BorderSide(color: AT.bl),
                                ),
                              ),
                            ] else
                              Text(
                                _status,
                                style: TextStyle(color: t.sub, fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Join with Code',
                        icon: Icons.login_rounded,
                        color: AT.gr,
                        theme: t,
                        child: Column(
                          children: [
                            TextField(
                              controller: _codeCtrl,
                              maxLength: 6,
                              textCapitalization: TextCapitalization.characters,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: t.txt,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 6,
                              ),
                              decoration: InputDecoration(
                                counterText: '',
                                hintText: 'XXXXXX',
                                hintStyle: TextStyle(
                                  color: t.sub,
                                  letterSpacing: 6,
                                ),
                                filled: true,
                                fillColor: AT.grDim,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(
                                    color: Color(0x4D56C596),
                                    width: 1.5,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(
                                    color: AT.gr,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            if (!_joining)
                              _GlowBtn(
                                label: 'Join Room',
                                color: AT.gr,
                                onTap: _joinRoom,
                              )
                            else
                              const CircularProgressIndicator(color: AT.gr),
                          ],
                        ),
                      ),
                      if (_status.isNotEmpty && !_hosting) ...[
                        const SizedBox(height: 16),
                        Text(
                          _status,
                          style: TextStyle(
                            color: _status.startsWith('Error') ? AT.r : t.sub,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final AT theme;
  final Widget child;
  const _Section({
    required this.title,
    required this.icon,
    required this.color,
    required this.theme,
    required this.child,
  });
  @override
  Widget build(BuildContext c) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: .25), width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  COIN DROP ANIMATION
// ════════════════════════════════════════════════════════════════════
class _DA {
  final int col, row, key;
  final Color color;
  _DA({
    required this.col,
    required this.row,
    required this.color,
    required this.key,
  });
}

class _Coin extends StatefulWidget {
  final Color color;
  final int row;
  final double cs;
  const _Coin({required this.color, required this.row, required this.cs});
  @override
  State<_Coin> createState() => _CoinState();
}

class _CoinState extends State<_Coin> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _pos;
  late Animation<double> _scaleY;
  late Animation<double> _scaleX;

  @override
  void initState() {
    super.initState();
    final totalRows = widget.row + 1;
    final ms = (180 + totalRows * 40).clamp(200, 480);
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    );
    _pos = Tween<double>(
      begin: -1.0,
      end: widget.row.toDouble(),
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeIn));
    _scaleY = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 80),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.78,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.78,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 10,
      ),
    ]).animate(_c);
    _scaleX = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 80),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 1.22,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.22,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 10,
      ),
    ]).animate(_c);
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.cs - 10;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Transform.translate(
          offset: Offset(0, _pos.value * widget.cs),
          child: Transform.scale(
            scaleX: _scaleX.value,
            scaleY: _scaleY.value,
            child: Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: .65),
                    blurRadius: 14,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: widget.color.withValues(alpha: .25),
                    blurRadius: 28,
                    spreadRadius: 4,
                  ),
                ],
                gradient: RadialGradient(
                  colors: [
                    widget.color.withValues(alpha: 1.0),
                    widget.color.withValues(alpha: 0.8),
                  ],
                  center: const Alignment(-0.3, -0.4),
                  radius: 0.7,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  PULSE INDICATOR
// ════════════════════════════════════════════════════════════════════
class _PulseIndicator extends StatefulWidget {
  final Color color;
  final bool active;
  final String text;
  final Color textColor;
  final Color inactiveColor;
  const _PulseIndicator({
    required this.color,
    required this.active,
    required this.text,
    required this.textColor,
    required this.inactiveColor,
  });
  @override
  State<_PulseIndicator> createState() => _PulseIndicatorState();
}

class _PulseIndicatorState extends State<_PulseIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final v = widget.active ? _pulse.value : 0.0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: widget.active
                ? Color.lerp(
                    widget.color.withValues(alpha: .06),
                    widget.color.withValues(alpha: .12),
                    v,
                  )
                : widget.inactiveColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: widget.active
                  ? widget.color.withValues(alpha: .3 + .2 * v)
                  : widget.color.withValues(alpha: .15),
            ),
          ),
          child: Text(
            widget.text,
            style: TextStyle(
              color: widget.active
                  ? widget.textColor
                  : widget.textColor.withValues(alpha: .4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  MOVE TIMER WIDGET
// ════════════════════════════════════════════════════════════════════
class _MoveTimer extends StatefulWidget {
  final int seconds;
  final VoidCallback onExpire;
  final Color color;
  final bool active;
  const _MoveTimer({
    super.key,
    required this.seconds,
    required this.onExpire,
    required this.color,
    required this.active,
  });
  @override
  State<_MoveTimer> createState() => _MoveTimerState();
}

class _MoveTimerState extends State<_MoveTimer>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late int _remaining;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _remaining = widget.seconds;
    _c = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.seconds),
    );
    if (widget.active) _startTimer();
  }

  @override
  void didUpdateWidget(_MoveTimer old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) {
      if (widget.active) {
        _remaining = widget.seconds;
        _c.reset();
        _startTimer();
      } else {
        _ticker?.cancel();
        _c.stop();
      }
    }
  }

  void _startTimer() {
    _c.forward(from: 0);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (mounted) setState(() => _remaining--);
      if (_remaining <= 5 && _remaining > 0) Snd.tick();
      if (_remaining <= 0) {
        _ticker?.cancel();
        widget.onExpire();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox(width: 44, height: 44);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final progress = 1.0 - _c.value;
        final urgent = _remaining <= 10;
        final color = urgent ? AT.r : widget.color;
        return SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress,
                strokeWidth: 3,
                backgroundColor: color.withValues(alpha: .15),
                valueColor: AlwaysStoppedAnimation(color),
              ),
              Text(
                '$_remaining',
                style: TextStyle(
                  color: urgent ? AT.r : widget.color,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  EMOJI PANEL
// ════════════════════════════════════════════════════════════════════
const kEmojis = [
  '😂',
  '🔥',
  '😱',
  '🤣',
  '👏',
  '💀',
  '🎉',
  '😤',
  '🤔',
  '😎',
  '😭',
  '❤️',
];

class _EmojiPanel extends StatelessWidget {
  final void Function(String) onSelect;
  const _EmojiPanel({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: t.bdr),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .3),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: t.bdr,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Send Reaction',
            style: TextStyle(
              color: t.sub,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: kEmojis
                .map(
                  (e) => GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      onSelect(e);
                    },
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: t.stBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: t.bdr),
                      ),
                      child: Center(
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _FloatingEmoji extends StatefulWidget {
  final String emoji;
  final String from;
  final Color color;
  const _FloatingEmoji({
    required this.emoji,
    required this.from,
    required this.color,
  });
  @override
  State<_FloatingEmoji> createState() => _FloatingEmojiState();
}

class _FloatingEmojiState extends State<_FloatingEmoji>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _scale, _opacity, _offset;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _scale = TweenSequence([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.3,
          end: 1.3,
        ).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 40,
      ),
      TweenSequenceItem(tween: ConstantTween(1.3), weight: 40),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.3,
          end: 0.8,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 20,
      ),
    ]).animate(_c);
    _opacity = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 20),
    ]).animate(_c);
    _offset = Tween(
      begin: 0.0,
      end: -40.0,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Opacity(
      opacity: _opacity.value,
      child: Transform.translate(
        offset: Offset(0, _offset.value),
        child: Transform.scale(
          scale: _scale.value,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.emoji, style: const TextStyle(fontSize: 52)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: widget.color.withValues(alpha: .4)),
                ),
                child: Text(
                  widget.from,
                  style: TextStyle(
                    color: widget.color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  REMATCH INCOMING DIALOG — with 5s auto-accept countdown
// ════════════════════════════════════════════════════════════════════
class _RematchIncomingDialog extends StatefulWidget {
  final String oppName;
  final Color oppColor;
  final String lastEmoji; // rage emoji if available
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const _RematchIncomingDialog({
    required this.oppName,
    required this.oppColor,
    required this.lastEmoji,
    required this.onAccept,
    required this.onDecline,
  });
  @override
  State<_RematchIncomingDialog> createState() => _RematchIncomingDialogState();
}

class _RematchIncomingDialogState extends State<_RematchIncomingDialog>
    with SingleTickerProviderStateMixin {
  static const kAutoSeconds = 5;
  int _remaining = kAutoSeconds;
  Timer? _ticker;
  late AnimationController _ring;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(
      vsync: this,
      duration: const Duration(seconds: kAutoSeconds),
    )..forward();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (mounted) setState(() => _remaining--);
      if (_remaining <= 0) {
        _ticker?.cancel();
        widget.onAccept(); // auto-accept
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    final hasEmoji = widget.lastEmoji.isNotEmpty;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: widget.oppColor.withValues(alpha: .4), width: 2),
          boxShadow: [
            BoxShadow(
              color: widget.oppColor.withValues(alpha: .15),
              blurRadius: 40,
              spreadRadius: 4,
            ),
            const BoxShadow(color: AT.black50, blurRadius: 20),
          ],
        ),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Opponent avatar + emoji combo
            Stack(
              alignment: Alignment.topRight,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.oppColor.withValues(alpha: .15),
                    border: Border.all(
                      color: widget.oppColor.withValues(alpha: .5),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      widget.oppName.isNotEmpty
                          ? widget.oppName[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: widget.oppColor,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (hasEmoji)
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: t.card,
                      shape: BoxShape.circle,
                      border: Border.all(color: t.bdr),
                    ),
                    child: Center(
                      child: Text(
                        widget.lastEmoji,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '${widget.oppName} wants revenge! 😈',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.txt,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Rematch request — scores carry over',
              style: TextStyle(color: t.sub, fontSize: 12),
            ),
            const SizedBox(height: 20),
            // Countdown ring
            AnimatedBuilder(
              animation: _ring,
              builder: (_, _) => SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: 1.0 - _ring.value,
                      strokeWidth: 4,
                      backgroundColor: widget.oppColor.withValues(alpha: .15),
                      valueColor: AlwaysStoppedAnimation(widget.oppColor),
                    ),
                    Text(
                      '$_remaining',
                      style: TextStyle(
                        color: widget.oppColor,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Auto-accepting in $_remaining s',
              style: TextStyle(color: t.sub, fontSize: 11),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      _ticker?.cancel();
                      widget.onDecline();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: t.stBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: t.bdr),
                      ),
                      child: Text(
                        'Decline',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: t.sub,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      _ticker?.cancel();
                      widget.onAccept();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: widget.oppColor,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: widget.oppColor.withValues(alpha: .4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Text(
                        'Accept ⚔️',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  WAITING FOR REMATCH WIDGET — animated dots + cancel
// ════════════════════════════════════════════════════════════════════
class _WaitingRematchWidget extends StatefulWidget {
  final String oppName;
  final VoidCallback onCancel;
  const _WaitingRematchWidget({required this.oppName, required this.onCancel});
  @override
  State<_WaitingRematchWidget> createState() => _WaitingRematchWidgetState();
}

class _WaitingRematchWidgetState extends State<_WaitingRematchWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _dots;

  @override
  void initState() {
    super.initState();
    _dots = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Animated waiting dots
        AnimatedBuilder(
          animation: _dots,
          builder: (_, _) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final delay = i / 3.0;
                final raw = (_dots.value - delay) % 1.0;
                final v = (raw < 0.5 ? raw * 2 : (1.0 - raw) * 2).clamp(
                  0.0,
                  1.0,
                );
                return Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AT.bl.withValues(alpha: 0.3 + 0.7 * v),
                  ),
                  transform: Matrix4.translationValues(0, -6 * v, 0),
                );
              }),
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          'Waiting for ${widget.oppName}...',
          style: TextStyle(color: t.sub, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: widget.onCancel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            decoration: BoxDecoration(
              color: AT.r.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AT.r.withValues(alpha: .3)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.close_rounded, color: AT.r, size: 14),
                SizedBox(width: 6),
                Text(
                  'Cancel Rematch',
                  style: TextStyle(
                    color: AT.r,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  GAME PAGE (Bot + Local) — FIXED SCORES
// ════════════════════════════════════════════════════════════════════
class GamePage extends StatefulWidget {
  final GM mode;
  final Diff diff;
  final String p1, p2;
  final int initialS1;
  final int initialS2;
  final String? tournamentId;
  final String? matchId;
  final void Function(String winner)? onTournamentResult;

  const GamePage({
    super.key,
    required this.mode,
    this.diff = Diff.med,
    this.p1 = 'Player 1',
    this.p2 = 'Player 2',
    this.initialS1 = 0,
    this.initialS2 = 0,
    this.tournamentId,
    this.matchId,
    this.onTournamentResult,
  });
  @override
  State<GamePage> createState() => _GPState();
}

class _GPState extends State<GamePage> with TickerProviderStateMixin {
  static const R = 6, C = 7;
  static const kMoveSeconds = 30;

  List<List<int>> board = List.generate(6, (_) => List.filled(7, 0));
  int cur = 1;
  bool over = false, busy = false;
  Set<String> wc = {};
  int? hov;
  late int s1;
  late int s2;
  final List<_DA> _as = [];
  int _k = 0;
  final _rand = Random();
  bool get local => widget.mode == GM.local;

  @override
  void initState() {
    super.initState();
    s1 = widget.initialS1;
    s2 = widget.initialS2;
  }

  Future<void> _drop(int col) async {
    if (over || !_vl(board, col)) return;
    if (widget.mode == GM.bot && (busy || cur != 1)) return;
    final row = _rw(board, col);
    await _an(col, row, cur);
    if (mounted) setState(() => board[row][col] = cur);
    final w = _wn(board, row, col);
    if (w != null) {
      if (cur == 1) {
        s1++;
      } else {
        s2++;
      }
      if (mounted) {
        setState(() {
          over = true;
          wc = w.map((e) => '${e[0]},${e[1]}').toSet();
        });
      }
      Snd.win();
      await Future.delayed(const Duration(milliseconds: 500));
      _res(
        cur == 1
            ? '${local ? "🔴 " : "🎉 "}${widget.p1} Wins!'
            : local
            ? '🟡 ${widget.p2} Wins!'
            : '🤖 Bot Wins!',
      );
      return;
    }
    if (_dr(board)) {
      if (mounted) setState(() => over = true);
      Snd.draw();
      await Future.delayed(const Duration(milliseconds: 300));
      _res("It's a Draw!");
      return;
    }
    if (widget.mode == GM.bot) {
      if (mounted) {
        setState(() {
          cur = 2;
          busy = true;
        });
      }
      await Future.delayed(const Duration(milliseconds: 420));
      await _bot();
    } else {
      if (mounted) {
        setState(() {
          cur = cur == 1 ? 2 : 1;
        });
      }
    }
  }

  void _onTimerExpire() {
    if (over || busy) return;
    final valid = List.generate(
      C,
      (i) => i,
    ).where((c) => _vl(board, c)).toList();
    if (valid.isEmpty) return;
    _drop(valid[_rand.nextInt(valid.length)]);
  }

  Future<void> _an(int col, int row, int player) async {
    final color = player == 1 ? AT.r : AT.y;
    final k = _k++;
    final totalRows = row + 1;
    final ms = (180 + totalRows * 40).clamp(200, 480);
    if (mounted) setState(() => _as.add(_DA(col: col, row: row, color: color, key: k)));
    Snd.drop();
    await Future.delayed(Duration(milliseconds: ms + 60));
    if (mounted) setState(() => _as.removeWhere((a) => a.key == k));
  }

  Future<void> _bot() async {
    final col = _bc();
    final row = _rw(board, col);
    await _an(col, row, 2);
    if (mounted) setState(() => board[row][col] = 2);
    final w = _wn(board, row, col);
    if (w != null) {
      s2++;
      if (mounted) {
        setState(() {
          over = true;
          busy = false;
          wc = w.map((e) => '${e[0]},${e[1]}').toSet();
        });
      }
      Snd.win();
      await Future.delayed(const Duration(milliseconds: 500));
      _res('🤖 Bot Wins!');
      return;
    }
    if (_dr(board)) {
      if (mounted) {
        setState(() {
          over = true;
          busy = false;
        });
      }
      Snd.draw();
      _res("It's a Draw!");
      return;
    }
    if (mounted) {
      setState(() {
        cur = 1;
        busy = false;
      });
    }
  }

  int _bc() {
    switch (widget.diff) {
      case Diff.easy:
        return _be();
      case Diff.med:
        return _bm();
      case Diff.hard:
        return _bh();
    }
  }

  int _be() {
    for (int c = 0; c < C; c++) {
      if (!_vl(board, c)) continue;
      int r = _rw(board, c);
      board[r][c] = 2;
      bool w = _wn(board, r, c) != null;
      board[r][c] = 0;
      if (w) return c;
    }
    final v = List.generate(C, (i) => i).where((c) => _vl(board, c)).toList();
    return v[_rand.nextInt(v.length)];
  }

  int _bm() {
    for (int c = 0; c < C; c++) {
      if (!_vl(board, c)) continue;
      int r = _rw(board, c);
      board[r][c] = 2;
      bool w = _wn(board, r, c) != null;
      board[r][c] = 0;
      if (w) return c;
    }
    for (int c = 0; c < C; c++) {
      if (!_vl(board, c)) continue;
      int r = _rw(board, c);
      board[r][c] = 1;
      bool w = _wn(board, r, c) != null;
      board[r][c] = 0;
      if (w) return c;
    }
    for (int c in [3, 2, 4, 1, 5, 0, 6]) {
      if (_vl(board, c)) return c;
    }
    return 0;
  }

  int _bh() {
    int best = -999999, bc = 3;
    for (int c in [3, 2, 4, 1, 5, 0, 6]) {
      if (!_vl(board, c)) continue;
      int r = _rw(board, c);
      board[r][c] = 2;
      int s = _mm(board, 7, -999999, 999999, false);
      board[r][c] = 0;
      if (s > best) {
        best = s;
        bc = c;
      }
    }
    return bc;
  }

  int _mm(List<List<int>> b, int d, int a, int be, bool mx) {
    for (int r = 0; r < R; r++) {
      for (int c = 0; c < C; c++) {
        if (b[r][c] != 0 && _wn(b, r, c) != null) {
          return b[r][c] == 2 ? (1000 + d) : -(1000 + d);
        }
      }
    }
    if (d == 0 || _dr(b)) return _ev(b);
    if (mx) {
      int v = -999999;
      for (int c in [3, 2, 4, 1, 5, 0, 6]) {
        if (!_vl(b, c)) continue;
        int r = _rw(b, c);
        b[r][c] = 2;
        int sc = _mm(b, d - 1, a, be, false);
        b[r][c] = 0;
        if (sc > v) v = sc;
        if (v > a) a = v;
        if (be <= a) break;
      }
      return v;
    } else {
      int v = 999999;
      for (int c in [3, 2, 4, 1, 5, 0, 6]) {
        if (!_vl(b, c)) continue;
        int r = _rw(b, c);
        b[r][c] = 1;
        int sc = _mm(b, d - 1, a, be, true);
        b[r][c] = 0;
        if (sc < v) v = sc;
        if (v < be) be = v;
        if (be <= a) break;
      }
      return v;
    }
  }

  int _ev(List<List<int>> b) {
    int s = 0;
    for (int r = 0; r < R; r++) {
      if (b[r][3] == 2) s += 3;
      if (b[r][3] == 1) s -= 3;
    }
    for (int r = 0; r < R; r++) {
      for (int c = 0; c <= C - 4; c++) {
        s += _sw([b[r][c], b[r][c + 1], b[r][c + 2], b[r][c + 3]]);
      }
    }
    for (int c = 0; c < C; c++) {
      for (int r = 0; r <= R - 4; r++) {
        s += _sw([b[r][c], b[r + 1][c], b[r + 2][c], b[r + 3][c]]);
      }
    }
    for (int r = 0; r <= R - 4; r++) {
      for (int c = 0; c <= C - 4; c++) {
        s += _sw([b[r][c], b[r + 1][c + 1], b[r + 2][c + 2], b[r + 3][c + 3]]);
      }
    }
    for (int r = 3; r < R; r++) {
      for (int c = 0; c <= C - 4; c++) {
        s += _sw([b[r][c], b[r - 1][c + 1], b[r - 2][c + 2], b[r - 3][c + 3]]);
      }
    }
    return s;
  }

  int _sw(List<int> w) {
    int bot = w.where((x) => x == 2).length;
    int hum = w.where((x) => x == 1).length;
    int emp = w.where((x) => x == 0).length;
    if (bot == 4) return 100;
    if (bot == 3 && emp == 1) return 5;
    if (bot == 2 && emp == 2) return 2;
    if (hum == 4) return -100;
    if (hum == 3 && emp == 1) return -4;
    return 0;
  }

  bool _vl(List<List<int>> b, int c) => c >= 0 && c < C && b[0][c] == 0;
  int _rw(List<List<int>> b, int c) {
    for (int r = R - 1; r >= 0; r--) {
      if (b[r][c] == 0) return r;
    }
    return -1;
  }

  bool _dr(List<List<int>> b) => b[0].every((c) => c != 0);

  List<List<int>>? _wn(List<List<int>> b, int row, int col) {
    int p = b[row][col];
    if (p == 0) return null;
    List<List<int>> ln(int dx, int dy) {
      List<List<int>> cs = [
        [row, col],
      ];
      for (int i = 1; i < 4; i++) {
        int r = row + dx * i, c = col + dy * i;
        if (r >= 0 && r < R && c >= 0 && c < C && b[r][c] == p) {
          cs.add([r, c]);
        } else {
          break;
        }
      }
      for (int i = 1; i < 4; i++) {
        int r = row - dx * i, c = col - dy * i;
        if (r >= 0 && r < R && c >= 0 && c < C && b[r][c] == p) {
          cs.add([r, c]);
        } else {
          break;
        }
      }
      return cs;
    }

    for (var d in [
      [1, 0],
      [0, 1],
      [1, 1],
      [1, -1],
    ]) {
      final l = ln(d[0], d[1]);
      if (l.length >= 4) return l;
    }
    return null;
  }

  void _reset() {
    if (mounted) {
      setState(() {
        board = List.generate(R, (_) => List.filled(C, 0));
        cur = 1;
        over = false;
        busy = false;
        wc = {};
        hov = null;
        _as.clear();
      });
    }
  }

  void _leave() {
    showDialog(
      context: context,
      builder: (_) => _ConfirmDlg(
        title: 'Leave Match?',
        body: 'Your progress will be lost.',
        confirmLabel: 'Leave',
        confirmColor: AT.r,
        onConfirm: () {
          Navigator.pop(context);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _res(String msg) {

    if (widget.onTournamentResult != null) {
      final winnerName = msg.contains(widget.p1) ? widget.p1 : widget.p2;
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) widget.onTournamentResult?.call(winnerName);
      });
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RDlg(
        msg: msg,
        s1: s1,
        s2: s2,
        l1: widget.p1,
        l2: local ? widget.p2 : 'Bot',
        showRematch: widget.onTournamentResult == null,
        onAgain: () {
          Navigator.pop(context);
          if (widget.onTournamentResult != null) {
            Navigator.pop(context);
          } else {
            Navigator.pushReplacement(
              context,
              _slide(
                GamePage(
                  mode: widget.mode,
                  diff: widget.diff,
                  p1: widget.p1,
                  p2: widget.p2,
                  initialS1: s1,
                  initialS2: s2,
                ),
              ),
            );
          }
        },
        onMenu: () {
          Navigator.pop(context);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    final bW = MediaQuery.of(context).size.width - 24;
    final cs = bW / C;
    final p2l = local ? widget.p2 : 'Bot';
    final tc = cur == 1 ? AT.r : AT.y;
    final tt = over
        ? 'Game Over'
        : busy
        ? 'Bot thinking...'
        : cur == 1
        ? "${widget.p1}'s Turn"
        : "$p2l's Turn";
    final isMyTurn = !over && !busy;

    return Scaffold(
      backgroundColor: t.bg,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              _TBar(
                title: local ? 'vs Friend' : 'vs Bot',
                action: widget.mode == GM.bot ? _DBadge(widget.diff) : null,
                onLeave: _leave,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _SC(
                      label: widget.p1,
                      score: s1,
                      color: AT.r,
                      active: cur == 1 && !over && !busy,
                    ),
                    _PulseIndicator(
                      color: over || busy ? t.bdr : tc,
                      active: !over && !busy,
                      text: tt,
                      textColor: over || busy ? t.sub : tc,
                      inactiveColor: t.stBg,
                    ),
                    _SC(
                      label: p2l,
                      score: s2,
                      color: AT.y,
                      active: cur == 2 && !over && !busy,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _MoveTimer(
                  key: ValueKey(
                    'timer_${cur}_${board.expand((r) => r).join()}',
                  ),
                  seconds: kMoveSeconds,
                  color: cur == 1 ? AT.r : AT.y,
                  active: isMyTurn && !over,
                  onExpire: _onTimerExpire,
                ),
              ),
              Expanded(
                child: Center(
                  child: RepaintBoundary(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _BoardWidget(
                          board: board,
                          wc: wc,
                          hov: hov,
                          cur: cur,
                          over: over,
                          busy: busy,
                          isLocal: local,
                          bW: bW,
                          onDrop: _drop,
                          onHov: (c) {
                            if (mounted) setState(() => hov = c);
                          },
                          onHovEnd: () {
                            if (mounted) setState(() => hov = null);
                          },
                        ),
                        ..._as.map(
                          (a) => Positioned(
                            left: 12.0 + 8.0 + a.col * cs + 5.0,
                            top: 32.0,
                            child: _Coin(color: a.color, row: a.row, cs: cs),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 18, top: 8),
                child: _CBtn(
                  icon: Icons.refresh_rounded,
                  label: 'New Game',
                  onTap: _reset,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  ONLINE GAME — FIXED REMATCH SYSTEM
// ════════════════════════════════════════════════════════════════════
class OnlineGame extends StatefulWidget {
  final String gameId, myName, oppName;
  final int myNum;
  final int initialP1Score;
  final int initialP2Score;
  final String p1id;
  final String p2id;

  const OnlineGame({
    super.key,
    required this.gameId,
    required this.myNum,
    required this.myName,
    required this.oppName,
    this.initialP1Score = 0,
    this.initialP2Score = 0,
    this.p1id = '',
    this.p2id = '',
  });
  @override
  State<OnlineGame> createState() => _OGState();
}

class _OGState extends State<OnlineGame> with TickerProviderStateMixin {
  static const R = 6, C = 7;
  static const kMoveSeconds = 30;
  int unreadCount = 0;
  int lastMessageCount = 0;
  Timer? _unreadTimer;

  List<List<int>> board = List.generate(6, (_) => List.filled(7, 0));
  int cur = 1;
  bool over = false;

  // ── Rematch state (cleaned up) ──────────────────────────────────
  bool _rematchSent = false; // I have sent a rematch request
  bool _rematchDialogShown = false; // Guard: show incoming dialog only once
  bool _rematchNavigated = false; // Guard: navigate only once
  String _lastSentEmoji = ''; // Track last emoji to show in incoming dialog

  Set<String> wc = {};
  int? hov;
  String status = 'Connecting...';
  bool _myTurnLock = false;
  final List<_DA> _as = [];
  int _k = 0;
  Timer? _poll;
  Timer? _rematchPollTimer; // Dedicated poll when I'm P1 and waiting for P2
  String _oppBoard = '';

  late int _p1score;
  late int _p2score;

  String _p1id = '';
  String _p2id = '';
  String _p1name = '';
  String _p2name = '';

  String _currentEmoji = '';
  String _emojiFrom = '';
  int _lastEmojiTs = 0;
  Timer? _emojiClearTimer;
  bool _showEmoji = false;

  bool _resultShown = false;

  @override
  void initState() {
    super.initState();
    _p1score = widget.initialP1Score;
    _p2score = widget.initialP2Score;
    _p1id = widget.p1id.isNotEmpty
        ? widget.p1id
        : (widget.myNum == 1 ? FB.uid : '');
    _p2id = widget.p2id.isNotEmpty
        ? widget.p2id
        : (widget.myNum == 2 ? FB.uid : '');
    _p1name = widget.myNum == 1 ? widget.myName : widget.oppName;
    _p2name = widget.myNum == 2 ? widget.myName : widget.oppName;
    _poll = Timer.periodic(const Duration(milliseconds: 1200), (_) => _fetch());
    //startChatPolling();
    _unreadTimer = Timer.periodic(Duration(seconds: 2), (_) async {
      final count = await FB.getUnreadCount(widget.gameId, widget.myNum);
      if (mounted) {
        if (mounted) setState(() => unreadCount = count);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _unreadTimer?.cancel();
    _rematchPollTimer?.cancel();
    _emojiClearTimer?.cancel();
    super.dispose();
  }

  // ── Navigate to new rematch game ──────────────────────────────
  void _goToNewGame(String newGid) {
    if (_rematchNavigated || !mounted) return;
    _rematchNavigated = true;
    _poll?.cancel();
    _rematchPollTimer?.cancel();
    Navigator.pushReplacement(
      context,
      _slide(
        OnlineGame(
          gameId: newGid,
          myNum: widget.myNum,
          myName: widget.myName,
          oppName: widget.oppName,
          initialP1Score: _p1score,
          initialP2Score: _p2score,
          p1id: _p1id,
          p2id: _p2id,
        ),
      ),
    );
  }

  // ── Show rematch incoming dialog (opponent wants revenge) ──────
  void _showRematchIncoming() {
    if (!mounted) return;
    final oppColor = widget.myNum == 1 ? AT.y : AT.r;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RematchIncomingDialog(
        oppName: widget.oppName,
        oppColor: oppColor,
        lastEmoji: _lastSentEmoji,
        onAccept: () {
          Navigator.pop(context); // close dialog
          _acceptRematch();
        },
        onDecline: () {
          Navigator.pop(context); // close dialog
          // Opponent will see no response — they'll get the "no response" UX
        },
      ),
    );
  }

  // ── I accept the rematch ──────────────────────────────────────
  Future<void> _acceptRematch() async {
    if (mounted) setState(() => _rematchSent = true);
    await FB.pushRematch(widget.gameId, widget.myNum);
    if (widget.myNum == 1) {
      _startRematchAsHost();
    } else {
      // P2 accepted — restart poll to catch rematchGameId once P1 creates it
      _poll?.cancel();
      _poll = Timer.periodic(
        const Duration(milliseconds: 1200),
        (_) => _fetch(),
      );
    }
  }

  // ── P1 polls until P2 also confirms, then creates game ────────
  void _startRematchAsHost() {
    _rematchPollTimer?.cancel();
    _rematchPollTimer = Timer.periodic(const Duration(milliseconds: 1000), (
      t,
    ) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      final data = await FB.fetchGame(widget.gameId);
      if (data == null) return;
      final rematch = data['rematch'] as int? ?? 0;
      final rematchGid = data['rematchGameId'] as String? ?? '';

      // If new game already exists already, just navigate
      if (rematchGid.isNotEmpty) {
        t.cancel();
        _goToNewGame(rematchGid);
        return;
      }

      // P1 already sent rematch=1. Wait until P2 sends rematch=2.
      // When rematch==2, both sides have confirmed.
      if (rematch != 2) return;

      t.cancel();
      final newGid = await FB.createRematch(
        widget.gameId,
        _p1name,
        _p2name,
        _p1id.isNotEmpty ? _p1id : FB.uid,
        _p2id.isNotEmpty ? _p2id : '',
        _p1score,
        _p2score,
      );
      if (mounted) _goToNewGame(newGid);
    });
  }

  Future<void> _fetch() async {
    if (_rematchNavigated) return;
    final data = await FB.fetchGame(widget.gameId);
    if (data == null || !mounted) return;

    final newBoard = data['board'] as String;
    final newCur = data['currentPlayer'] as int;
    final winner = data['winner'] as int? ?? 0;
    final st = data['status'] as String? ?? 'active';
    final emojiVal = data['emoji'] as String? ?? '';
    final emojiFrom = data['emojiFrom'] as int? ?? 0;
    final emojiTs = data['emojiTs'] as int? ?? 0;
    final rematch = data['rematch'] as int? ?? 0;
    final rematchGid = data['rematchGameId'] as String? ?? '';

    // Sync IDs
    if (_p1id.isEmpty && data['p1id'] != null) _p1id = data['p1id'] as String;
    if (_p2id.isEmpty && data['p2id'] != null) _p2id = data['p2id'] as String;

    // Emoji from opponent
    if (emojiVal.isNotEmpty &&
        emojiTs != _lastEmojiTs &&
        emojiFrom != widget.myNum) {
      _lastEmojiTs = emojiTs;
      _showFloatingEmoji(
        emojiVal,
        widget.oppName,
        widget.myNum == 1 ? AT.y : AT.r,
      );
    }

    // Board sync when opponent just moved
    if (newBoard != _oppBoard && newCur == widget.myNum && !_myTurnLock) {
      _oppBoard = newBoard;
      final parsed = FB.parseBoard(newBoard);
      _animateOpponentMove(parsed);
      if (mounted) {
        setState(() {
          board = parsed;
          cur = newCur;
          status = 'Your Turn ▶';
        });
      }
    } else if (_oppBoard.isEmpty) {
      _oppBoard = newBoard;
      final parsed = FB.parseBoard(newBoard);
      if (mounted) {
        setState(() {
          board = parsed;
          cur = newCur;
          status = cur == widget.myNum
              ? 'Your Turn ▶'
              : "${widget.oppName}'s Turn...";
        });
      }
    }

    // ── Rematch signal from opponent ──────────────────────────────
    // Only show incoming dialog if:
    //   - game is finished
    //   - opponent set the rematch field (rematch != 0 && rematch != myNum)
    //   - I haven't already sent my own rematch or shown the dialog
    if (over &&
        !_rematchSent &&
        !_rematchDialogShown &&
        rematch != 0 &&
        rematch != widget.myNum) {
      _rematchDialogShown = true;
      _showRematchIncoming();
    }

    // ── Navigate to new game when P1 created it ────────────────────
    if (over && rematchGid.isNotEmpty && !_rematchNavigated) {
      _goToNewGame(rematchGid);
      return;
    }

    // ── Handle finished game ───────────────────────────────────────
    if (st == 'finished' && winner != 0 && !over) {
      if (mounted) {
        setState(() {
          over = true;
        });
      }
      _poll?.cancel();

      final p1s = data['p1score'] as int? ?? _p1score;
      final p2s = data['p2score'] as int? ?? _p2score;
      if (mounted) {
        setState(() {
          _p1score = p1s;
          _p2score = p2s;
        });
      }

      Snd.win();
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted || _resultShown) return;
      _resultShown = true;
      final msg = winner == widget.myNum
          ? '🎉 You Win!'
          : winner == 3
          ? "It's a Draw!"
          : '😞 ${widget.oppName} Wins!';
      _res(msg);
    }
  }

  void _animateOpponentMove(List<List<int>> newBoard) {
    for (int r = 0; r < R; r++) {
      for (int c = 0; c < C; c++) {
        if (newBoard[r][c] != board[r][c] && newBoard[r][c] != 0) {
          final color = newBoard[r][c] == 1 ? AT.r : AT.y;
          final k = _k++;
          if (mounted) setState(() => _as.add(_DA(col: c, row: r, color: color, key: k)));
          Snd.drop();
          final totalRows = r + 1;
          final ms = (180 + totalRows * 40).clamp(200, 480);
          Future.delayed(Duration(milliseconds: ms + 60), () {
            if (mounted) setState(() => _as.removeWhere((a) => a.key == k));
          });
          return;
        }
      }
    }
  }

  void _showFloatingEmoji(String emoji, String from, Color color) {
    _emojiClearTimer?.cancel();
    if (mounted) {
      setState(() {
        _currentEmoji = emoji;
        _emojiFrom = from;
        _showEmoji = true;
      });
    }
    _emojiClearTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) {
        setState(() {
          _showEmoji = false;
        });
      }
    });
  }

  Future<void> _drop(int col) async {
    if (over || cur != widget.myNum || _myTurnLock) return;
    if (col < 0 || col >= C || board[0][col] != 0) return;
    int row = -1;
    for (int r = R - 1; r >= 0; r--) {
      if (board[r][col] == 0) {
        row = r;
        break;
      }
    }
    if (row == -1) return;

    _myTurnLock = true;
        final myC = widget.myNum == 1 ? AT.r : AT.y;
    final k = _k++;
    if (mounted) setState(() => _as.add(_DA(col: col, row: row, color: myC, key: k)));
    Snd.drop();

    final totalRows = row + 1;
    final ms = (180 + totalRows * 40).clamp(200, 480);
    await Future.delayed(Duration(milliseconds: ms + 60));
    if (mounted) setState(() => _as.removeWhere((a) => a.key == k));

    final nb = board.map((r) => List<int>.from(r)).toList();
    nb[row][col] = widget.myNum;
    final win = _chkWin(nb, row, col);
    final draw = nb[0].every((c) => c != 0);
    final nextPlayer = widget.myNum == 1 ? 2 : 1;

    int newP1 = _p1score, newP2 = _p2score;
    if (win != null) {
      if (widget.myNum == 1) {
        newP1++;
      } else {
        newP2++;
      }
    }

    if (mounted) {
      setState(() {
        board = nb;
        cur = nextPlayer;
        _oppBoard = nb.expand((r) => r).join(',');
        if (win != null) {
          over = true;
          wc = win.map((e) => '${e[0]},${e[1]}').toSet();
        } else if (draw) {
          over = true;
        }
        status = over ? 'Game Over' : "${widget.oppName}'s Turn...";
        _p1score = newP1;
        _p2score = newP2;
      });
    }

    await FB.pushMove(widget.gameId, nb, nextPlayer);
    if (win != null) {
      await FB.pushWinner(
        widget.gameId,
        widget.myNum,
        p1score: newP1,
        p2score: newP2,
      );
      _poll?.cancel();
      Snd.win();
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted && !_resultShown) {
        _resultShown = true;
        _res('🎉 You Win!');
      }
    } else if (draw) {
      await FB.pushWinner(widget.gameId, 3, p1score: newP1, p2score: newP2);
      _poll?.cancel();
      Snd.draw();
      if (mounted && !_resultShown) {
        _resultShown = true;
        _res("It's a Draw!");
      }
    }
    _myTurnLock = false;
  }

  void _onTimerExpire() {
    if (over || cur != widget.myNum || _myTurnLock) return;
    final valid = List.generate(
      C,
      (i) => i,
    ).where((c) => board[0][c] == 0).toList();
    if (valid.isEmpty) return;
    _drop(valid[Random().nextInt(valid.length)]);
  }

  void _sendEmoji(String emoji) async {
    _lastSentEmoji = emoji; // track for rematch dialog context
    _showFloatingEmoji(emoji, widget.myName, widget.myNum == 1 ? AT.r : AT.y);
    await FB.pushEmoji(widget.gameId, emoji, widget.myNum);
    await Future.delayed(const Duration(milliseconds: 2500));
    FB.clearEmoji(widget.gameId);
  }

  void _openEmojiPanel() {
    Snd.click();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _EmojiPanel(onSelect: _sendEmoji),
    );
  }

  // ── Request rematch (I click "Rematch" first) ──────────────────
  Future<void> _requestRematch() async {
    if (_rematchSent) return;
    if (mounted) setState(() => _rematchSent = true);
    await FB.pushRematch(widget.gameId, widget.myNum);

    // Restart poll to pick up opponent's response
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 1200), (_) => _fetch());

    // If I'm P1, start the host-side poller immediately
    if (widget.myNum == 1) {
      _startRematchAsHost();
    }
    // If I'm P2, the main _poll/_fetch loop will detect rematchGameId when P1 creates it
  }

  // ── Cancel my rematch request ──────────────────────────────────
  Future<void> _cancelRematch() async {
    if (mounted) {
      setState(() {
        _rematchSent = false;
        _rematchDialogShown = false;
      });
    }
    await FB.cancelRematch(widget.gameId);
    _rematchPollTimer?.cancel();
  }

  List<List<int>>? _chkWin(List<List<int>> b, int row, int col) {
    int p = b[row][col];
    List<List<int>> ln(int dx, int dy) {
      List<List<int>> cs = [
        [row, col],
      ];
      for (int i = 1; i < 4; i++) {
        int r = row + dx * i, c = col + dy * i;
        if (r >= 0 && r < R && c >= 0 && c < C && b[r][c] == p) {
          cs.add([r, c]);
        } else {
          break;
        }
      }
      for (int i = 1; i < 4; i++) {
        int r = row - dx * i, c = col - dy * i;
        if (r >= 0 && r < R && c >= 0 && c < C && b[r][c] == p) {
          cs.add([r, c]);
        } else {
          break;
        }
      }
      return cs;
    }

    for (var d in [
      [1, 0],
      [0, 1],
      [1, 1],
      [1, -1],
    ]) {
      final l = ln(d[0], d[1]);
      if (l.length >= 4) return l;
    }
    return null;
  }

  void _leave() {
    showDialog(
      context: context,
      builder: (_) => _ConfirmDlg(
        title: 'Leave Match?',
        body: 'Your opponent will be notified. This counts as a forfeit.',
        confirmLabel: 'Leave',
        confirmColor: AT.r,
        onConfirm: () async {
          if (!over) {
            final oppNum = widget.myNum == 1 ? 2 : 1;
            int newP1 = _p1score, newP2 = _p2score;
            if (oppNum == 1) {
              newP1++;
            } else {
              newP2++;
            }
            await FB.pushWinner(
              widget.gameId,
              oppNum,
              p1score: newP1,
              p2score: newP2,
            );
          }
          if (mounted) {
            Navigator.pop(context);
            Navigator.popUntil(context, (r) => r.isFirst);
          }
        },
      ),
    );
  }

  void _res(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _OnlineRDlg(
        msg: msg,
        s1: _p1score,
        s2: _p2score,
        l1: _p1name,
        l2: _p2name,
        rematchSent: _rematchSent,
        oppName: widget.oppName,
        onRematch: () async {
          if (!_rematchSent) await _requestRematch();
        },
        onCancelRematch: () async {
          await _cancelRematch();
        },
        onMenu: () {
          Navigator.pop(ctx);
          Navigator.popUntil(context, (r) => r.isFirst);
        },
        rematchStateNotifier: _RematchStateNotifier(this),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    final bW = MediaQuery.of(context).size.width - 24;
    final cs = bW / C;
    final myC = widget.myNum == 1 ? AT.r : AT.y;
    final myTurn = cur == widget.myNum && !over;

    return Scaffold(
      appBar: AppBar(
        title: Text("Game vs ${widget.oppName}"),
        actions: [
          IconButton(
            icon: Stack(
              children: [
                Icon(Icons.chat),

                if (unreadCount > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$unreadCount',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatPage(
                    gameId: widget.gameId,
                    myNum: widget.myNum,
                    myName: widget.myName,
                    oppName: widget.oppName,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      backgroundColor: t.bg,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: Column(
            children: [
              _TBar(
                title:
                    'Online  ·  ${widget.gameId.substring(0, 6).toUpperCase()}',
                onLeave: _leave,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _SC(
                      label: widget.myNum == 1 ? widget.myName : widget.oppName,
                      score: _p1score,
                      color: AT.r,
                      active: cur == 1 && !over,
                    ),
                    _PulseIndicator(
                      color: myTurn ? myC : t.bdr,
                      active: myTurn,
                      text: status,
                      textColor: myTurn ? myC : t.sub,
                      inactiveColor: t.stBg,
                    ),
                    _SC(
                      label: widget.myNum == 2 ? widget.myName : widget.oppName,
                      score: _p2score,
                      color: AT.y,
                      active: cur == 2 && !over,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _MoveTimer(
                  key: ValueKey(
                    'otimer_${cur}_${board.expand((r) => r).join()}',
                  ),
                  seconds: kMoveSeconds,
                  color: myC,
                  active: myTurn && !over,
                  onExpire: _onTimerExpire,
                ),
              ),
              Expanded(
                child: Center(
                  child: RepaintBoundary(
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        _BoardWidget(
                          board: board,
                          wc: wc,
                          hov: hov,
                          cur: cur,
                          over: over,
                          busy: !myTurn,
                          isLocal: false,
                          bW: bW,
                          onDrop: _drop,
                          onHov: (c) {
                            if (myTurn) if (mounted) setState(() => hov = c);
                          },
                          onHovEnd: () {
                            if (mounted) setState(() => hov = null);
                          },
                        ),
                        ..._as.map(
                          (a) => Positioned(
                            left: 12.0 + 8.0 + a.col * cs + 5.0,
                            top: 32.0,
                            child: _Coin(color: a.color, row: a.row, cs: cs),
                          ),
                        ),
                        if (_showEmoji)
                          Positioned(
                            top: 40,
                            child: _FloatingEmoji(
                              emoji: _currentEmoji,
                              from: _emojiFrom,
                              color: _emojiFrom == widget.myName
                                  ? myC
                                  : (myC == AT.r ? AT.y : AT.r),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 18, top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _CBtn(
                      icon: Icons.emoji_emotions_outlined,
                      label: 'React',
                      onTap: _openEmojiPanel,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'You: ${widget.myNum == 1 ? "🔴 Red" : "🟡 Yellow"}',
                      style: TextStyle(color: t.sub, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  REMATCH STATE NOTIFIER — bridges _OGState ↔ dialog
// ════════════════════════════════════════════════════════════════════
class _RematchStateNotifier extends ChangeNotifier {
  final _OGState _state;
  _RematchStateNotifier(this._state);
  bool get rematchSent => _state._rematchSent;
  void notify() => notifyListeners();

}

// ════════════════════════════════════════════════════════════════════
//  ONLINE RESULT DIALOG — with live rematch state
// ════════════════════════════════════════════════════════════════════
class _OnlineRDlg extends StatefulWidget {
  final String msg, l1, l2;
  final int s1, s2;
  final bool rematchSent;
  final String oppName;
  final VoidCallback onRematch;
  final VoidCallback onCancelRematch;
  final VoidCallback onMenu;
  final _RematchStateNotifier rematchStateNotifier;

  const _OnlineRDlg({
    required this.msg,
    required this.s1,
    required this.s2,
    required this.l1,
    required this.l2,
    required this.rematchSent,
    required this.oppName,
    required this.onRematch,
    required this.onCancelRematch,
    required this.onMenu,
    required this.rematchStateNotifier,
  });

  @override
  State<_OnlineRDlg> createState() => _OnlineRDlgState();
}

class _OnlineRDlgState extends State<_OnlineRDlg> {
  late bool _sent;

  @override
  void initState() {
    super.initState();
    _sent = widget.rematchSent;
    widget.rematchStateNotifier.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    if (mounted) {
      setState(() => _sent = widget.rematchStateNotifier.rematchSent);
    }
  }

  @override
  void dispose() {
    widget.rematchStateNotifier.removeListener(_onStateChanged);
    widget.rematchStateNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: t.bdr, width: 1.5),
          boxShadow: const [BoxShadow(color: AT.black50, blurRadius: 30)],
        ),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x26FFD700),
                border: Border.all(color: const Color(0x66FFD700)),
              ),
              child: const Icon(
                Icons.emoji_events_rounded,
                color: AT.y,
                size: 34,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.msg,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.txt,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Series Score',
              style: TextStyle(color: t.sub, fontSize: 12, letterSpacing: 1),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SD(label: widget.l1, score: widget.s1, color: AT.r, t: t),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    '—',
                    style: TextStyle(
                      color: t.sub,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _SD(label: widget.l2, score: widget.s2, color: AT.y, t: t),
              ],
            ),
            const SizedBox(height: 24),
            // Emoji + rematch combo hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AT.or.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AT.or.withValues(alpha: .2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('😤', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(
                    'Send a reaction before rematching!',
                    style: TextStyle(color: t.sub, fontSize: 11),
                  ),
                ],
              ),
            ),
            // Rematch button or waiting widget
            if (!_sent) ...[
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Snd.click();
                        widget.onRematch();
                        if (mounted) setState(() => _sent = true);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: AT.bl,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x4D4FC3F7),
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('⚔️', style: TextStyle(fontSize: 14)),
                            SizedBox(width: 6),
                            Text(
                              'Rematch',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: widget.onMenu,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: t.stBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: t.bdr),
                        ),
                        child: Text(
                          'Menu',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: t.txt.withValues(alpha: .7),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Waiting animation + cancel
              _WaitingRematchWidget(
                oppName: widget.oppName,
                onCancel: () {
                  widget.onCancelRematch();
                  if (mounted) setState(() => _sent = false);
                },
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: widget.onMenu,
                child: Text(
                  'Back to Menu',
                  style: TextStyle(color: t.sub, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  TOURNAMENT SCREEN — 8-player bracket
// ════════════════════════════════════════════════════════════════════
class TournamentScreen extends StatefulWidget {
  final String username;
  const TournamentScreen({super.key, required this.username});
  @override
  State<TournamentScreen> createState() => _TSState();
}

class _TSState extends State<TournamentScreen> {
  final List<TextEditingController> _players = List.generate(
    8,
    (i) => TextEditingController(),
  );
  TournamentBracket? _bracket;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _players[0].text = widget.username;
  }

  @override
  void dispose() {
    for (final c in _players) {
      c.dispose();
    }
    super.dispose();
  }

  void _startTournament() {
    final names = _players.map((c) => c.text.trim()).toList();
    if (names.any((n) => n.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill in all 8 player names'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (names.toSet().length != 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Player names must be unique'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    Snd.click();
    final tid = FB.mkTournamentId();
    final bracket = TournamentBracket.create(tid, names, widget.username);
    if (mounted) {
      setState(() {
        _bracket = bracket;
        _started = true;
      });
    }
  }

  void _playMatch(TournamentMatch match) {
    if (match.p1.isEmpty || match.p2.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Waiting for previous round results'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (match.winner.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${match.winner} already won this match'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    Snd.click();
    Navigator.push(
      context,
      _slide(
        GamePage(
          mode: GM.local,
          p1: match.p1,
          p2: match.p2,
          onTournamentResult: (winner) {
            if (!mounted) return;
            if (mounted) {
              setState(() {
                match.winner = winner;
                _bracket?.advanceWinner(match.id, winner);
              });
            }
            Navigator.of(context).pop();
            final champ = _bracket?.champion;
            if (champ != null && champ.isNotEmpty) {
              _showChampion(champ);
            }
          },
        ),
      ),
    );
  }

  void _showChampion(String name) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        final t = TN.of(context).t;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            decoration: BoxDecoration(
              color: t.card,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AT.y.withValues(alpha: .5), width: 2),
              boxShadow: [
                BoxShadow(
                  color: AT.y.withValues(alpha: .15),
                  blurRadius: 40,
                  spreadRadius: 4,
                ),
              ],
            ),
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🏆', style: TextStyle(fontSize: 64)),
                const SizedBox(height: 12),
                Text(
                  'CHAMPION',
                  style: TextStyle(
                    color: AT.y,
                    fontSize: 14,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  name,
                  style: TextStyle(
                    color: t.txt,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Tournament Winner!',
                  style: TextStyle(color: t.sub, fontSize: 14),
                ),
                const SizedBox(height: 28),
                _GlowBtn(
                  label: 'New Tournament',
                  color: AT.pu,
                  onTap: () {
                    Navigator.pop(context);
                    if (mounted) {
                      setState(() {
                        _bracket = null;
                        _started = false;
                        for (int i = 1; i < 8; i++) {
                          _players[i].text = '';
                        }
                      });
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.pop(context);
                  },
                  child: Text('Back to Menu', style: TextStyle(color: t.sub)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.grad),
        child: SafeArea(
          child: _started && _bracket != null
              ? _BracketView(
                  bracket: _bracket!,
                  theme: t,
                  onPlayMatch: _playMatch,
                )
              : _SetupView(
                  players: _players,
                  theme: t,
                  onStart: _startTournament,
                ),
        ),
      ),
    );
  }
}

class _SetupView extends StatelessWidget {
  final List<TextEditingController> players;
  final AT theme;
  final VoidCallback onStart;
  const _SetupView({
    required this.players,
    required this.theme,
    required this.onStart,
  });

  static const _colors = [AT.r, AT.y, AT.bl, AT.gr, AT.or, AT.pu, AT.r, AT.y];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _TBar(title: 'Tournament Setup'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AT.pu.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AT.pu.withValues(alpha: .3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: AT.pu,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '8 players → 4 QF → 2 SF → Final\nAll matches are local pass-and-play',
                          style: TextStyle(color: theme.sub, fontSize: 12),
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ...List.generate(
                  8,
                  (i) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: players[i],
                      maxLength: 14,
                      style: TextStyle(
                        color: theme.txt,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        labelText: 'Player ${i + 1}',
                        labelStyle: TextStyle(
                          color: _colors[i].withValues(alpha: .8),
                          fontSize: 13,
                        ),
                        prefixIcon: Container(
                          margin: const EdgeInsets.all(10),
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _colors[i],
                          ),
                          child: Center(
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        filled: true,
                        fillColor: _colors[i].withValues(alpha: .06),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: _colors[i].withValues(alpha: .25),
                            width: 1.5,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _colors[i], width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _GlowBtn(
                  label: '🏆 Start Tournament',
                  color: AT.pu,
                  onTap: onStart,
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BracketView extends StatelessWidget {
  final TournamentBracket bracket;
  final AT theme;
  final void Function(TournamentMatch) onPlayMatch;
  const _BracketView({
    required this.bracket,
    required this.theme,
    required this.onPlayMatch,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _TBar(title: 'Tournament Bracket'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RoundHeader('Quarter Finals', AT.bl, theme),
                ...bracket.qf.map(
                  (m) => _MatchCard(
                    match: m,
                    theme: theme,
                    onTap: () => onPlayMatch(m),
                    roundColor: AT.bl,
                  ),
                ),
                const SizedBox(height: 16),
                _RoundHeader('Semi Finals', AT.or, theme),
                ...bracket.sf.map(
                  (m) => _MatchCard(
                    match: m,
                    theme: theme,
                    onTap: () => onPlayMatch(m),
                    roundColor: AT.or,
                  ),
                ),
                const SizedBox(height: 16),
                _RoundHeader('🏆 Final', AT.y, theme),
                ...bracket.final_.map(
                  (m) => _MatchCard(
                    match: m,
                    theme: theme,
                    onTap: () => onPlayMatch(m),
                    roundColor: AT.y,
                  ),
                ),
                if (bracket.champion.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AT.y.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AT.y.withValues(alpha: .5), width: 2),
                      boxShadow: [
                        BoxShadow(color: AT.y.withValues(alpha: .1), blurRadius: 20),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Text('🏆', style: TextStyle(fontSize: 40)),
                        const SizedBox(height: 6),
                        Text(
                          'CHAMPION',
                          style: TextStyle(
                            color: AT.y,
                            fontSize: 11,
                            letterSpacing: 4,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          bracket.champion,
                          style: TextStyle(
                            color: theme.txt,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundHeader extends StatelessWidget {
  final String title;
  final Color color;
  final AT theme;
  const _RoundHeader(this.title, this.color, this.theme);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ],
    ),
  );
}

class _MatchCard extends StatelessWidget {
  final TournamentMatch match;
  final AT theme;
  final VoidCallback onTap;
  final Color roundColor;
  const _MatchCard({
    required this.match,
    required this.theme,
    required this.onTap,
    required this.roundColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = match.winner.isNotEmpty;
    final pending = match.p1.isEmpty || match.p2.isEmpty;
    final color = isDone
        ? AT.gr
        : pending
        ? theme.sub
        : roundColor;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: color.withValues(alpha: isDone ? .5 : .25),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  _PlayerRow(
                    name: match.p1.isEmpty ? 'TBD' : match.p1,
                    isWinner: match.winner == match.p1,
                    color: AT.r,
                    theme: theme,
                    pending: match.p1.isEmpty,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'vs',
                      style: TextStyle(
                        color: theme.sub,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _PlayerRow(
                    name: match.p2.isEmpty ? 'TBD' : match.p2,
                    isWinner: match.winner == match.p2,
                    color: AT.y,
                    theme: theme,
                    pending: match.p2.isEmpty,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isDone)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AT.gr.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AT.gr.withValues(alpha: .4)),
                ),
                child: const Text(
                  'Done ✓',
                  style: TextStyle(
                    color: AT.gr,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else if (!pending)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: roundColor.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: roundColor.withValues(alpha: .4)),
                ),
                child: Text(
                  'Play ▶',
                  style: TextStyle(
                    color: roundColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.stBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Wait...',
                  style: TextStyle(color: theme.sub, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  final String name;
  final bool isWinner;
  final Color color;
  final AT theme;
  final bool pending;
  const _PlayerRow({
    required this.name,
    required this.isWinner,
    required this.color,
    required this.theme,
    required this.pending,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: pending ? theme.sub : color,
          boxShadow: isWinner
              ? [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 8)]
              : null,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          name,
          style: TextStyle(
            color: pending ? theme.sub : (isWinner ? color : theme.txt),
            fontSize: 14,
            fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (isWinner) const Text('🏅', style: TextStyle(fontSize: 14)),
    ],
  );
}

// ════════════════════════════════════════════════════════════════════
//  BOARD WIDGET
// ════════════════════════════════════════════════════════════════════
class _BoardWidget extends StatelessWidget {
  final List<List<int>> board;
  final Set<String> wc;
  final int? hov;
  final int cur;
  final bool over, busy, isLocal;
  final double bW;
  final Future<void> Function(int) onDrop;
  final void Function(int) onHov;
  final VoidCallback onHovEnd;
  static const R = 6, C = 7;

  const _BoardWidget({
    required this.board,
    required this.wc,
    required this.hov,
    required this.cur,
    required this.over,
    required this.busy,
    required this.isLocal,
    required this.bW,
    required this.onDrop,
    required this.onHov,
    required this.onHovEnd,
  });

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Container(
      width: bW,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: t.brd,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.bdr, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.dark ? 0.6 : 0.14),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: List.generate(C, (col) {
                final can =
                    !over &&
                    !busy &&
                    (isLocal || cur == 1) &&
                    board[0][col] == 0;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => onDrop(col),
                    onTapDown: (_) => onHov(col),
                    onTapUp: (_) => onHovEnd(),
                    onTapCancel: () => onHovEnd(),
                    child: Container(
                      color: Colors.transparent,
                      alignment: Alignment.center,
                      child: AnimatedOpacity(
                        opacity: hov == col && can ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 120),
                        child: Icon(
                          Icons.arrow_drop_down_rounded,
                          color: cur == 1 ? AT.r : AT.y,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Column(
              children: List.generate(
                R,
                (r) => Row(
                  children: List.generate(C, (c) {
                    final isW = wc.contains('$r,$c');
                    final fill = board[r][c] != 0;
                    final h =
                        hov == c &&
                        board[r][c] == 0 &&
                        !over &&
                        !busy &&
                        (isLocal || cur == 1);
                    Color cc;
                    if (board[r][c] == 1) {
                      cc = AT.r;
                    } else if (board[r][c] == 2) {
                      cc = AT.y;
                    } else {
                      cc = h ? AT.white12 : AT.white06;
                    }

                    return Expanded(
                      child: GestureDetector(
                        onTap: () => onDrop(c),
                        onTapDown: (_) => onHov(c),
                        onTapUp: (_) => onHovEnd(),
                        onTapCancel: () => onHovEnd(),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: isW
                                ? _WinCell(color: cc)
                                : AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: cc,
                                      boxShadow: fill
                                          ? [
                                              BoxShadow(
                                                color: cc.withValues(alpha: .4),
                                                blurRadius: 8,
                                              ),
                                            ]
                                          : null,
                                      border: Border.all(
                                        color: AT.white06,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WinCell extends StatefulWidget {
  final Color color;
  const _WinCell({required this.color});
  @override
  State<_WinCell> createState() => _WinCellState();
}

class _WinCellState extends State<_WinCell>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color,
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: 0.6 + 0.35 * _c.value),
            blurRadius: 12 + 8 * _c.value,
            spreadRadius: 2,
          ),
        ],
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4 + 0.5 * _c.value),
          width: 2.5,
        ),
      ),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  LOGO
// ════════════════════════════════════════════════════════════════════
class _Logo extends StatefulWidget {
  const _Logo();
  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  static const _colors = [AT.r, AT.y, null, AT.y, AT.r, null, AT.r];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(7, (i) {
        final col = _colors[i];
        return Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: col ?? const Color(0x14FFFFFF),
            boxShadow: col != null
                ? [
                    BoxShadow(
                      color: col.withValues(alpha: 0.3 + 0.4 * _c.value),
                      blurRadius: 10 + 6 * _c.value,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
        );
      }),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  SHARED SMALL WIDGETS
// ════════════════════════════════════════════════════════════════════
class _TBar extends StatelessWidget {
  final String title;
  final Widget? action;
  final VoidCallback? onLeave;
  const _TBar({required this.title, this.action, this.onLeave});
  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: t.txt.withValues(alpha: .6),
              size: 18,
            ),
            onPressed: () {
              Snd.click();
              Navigator.pop(context);
            },
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.txt,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: .5,
              ),
            ),
          ),
          if (onLeave != null)
            _LeaveBtn(onLeave: onLeave!)
          else
            action ?? const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _LeaveBtn extends StatelessWidget {
  final VoidCallback onLeave;
  const _LeaveBtn({required this.onLeave});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Snd.click();
        onLeave();
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AT.r.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AT.r.withValues(alpha: .35)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.exit_to_app_rounded, color: AT.r, size: 14),
            SizedBox(width: 5),
            Text(
              'Leave',
              style: TextStyle(
                color: AT.r,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmDlg extends StatelessWidget {
  final String title, body, confirmLabel;
  final Color confirmColor;
  final VoidCallback onConfirm;
  const _ConfirmDlg({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.confirmColor,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final t = TN.of(context).t;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 36),
      child: Container(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: t.bdr),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                color: t.txt,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.sub, fontSize: 13),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: t.stBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: t.bdr),
                      ),
                      child: Text(
                        'Cancel',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: t.txt.withValues(alpha: .7),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: onConfirm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: confirmColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        confirmLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DBadge extends StatelessWidget {
  final Diff d;
  const _DBadge(this.d);
  @override
  Widget build(BuildContext ctx) {
    final color = d == Diff.easy
        ? AT.gr
        : d == Diff.med
        ? AT.or
        : AT.r;
    final lbl = d == Diff.easy
        ? 'Easy'
        : d == Diff.med
        ? 'Med'
        : 'Hard';
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Text(
        lbl,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _SC extends StatelessWidget {
  final String label;
  final int score;
  final Color color;
  final bool active;
  const _SC({
    required this.label,
    required this.score,
    required this.color,
    required this.active,
  });
  @override
  Widget build(BuildContext ctx) {
    final t = TN.of(ctx).t;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: .12) : t.stBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? color.withValues(alpha: .4) : t.bdr,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: .6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.length > 8 ? '${label.substring(0, 7)}…' : label,
                style: TextStyle(
                  color: active ? color : t.sub,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '$score',
                style: TextStyle(
                  color: active ? t.txt : t.sub,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  height: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlowBtn extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _GlowBtn({
    required this.label,
    required this.color,
    required this.onTap,
  });
  @override
  State<_GlowBtn> createState() => _GBState();
}

class _GBState extends State<_GlowBtn> {
  bool _p = false;
  @override
  Widget build(BuildContext ctx) => GestureDetector(
    onTapDown: (_) {
      if (mounted) setState(() => _p = true);
      Snd.click();
    },
    onTapUp: (_) {
      if (mounted) setState(() => _p = false);
      widget.onTap();
    },
    onTapCancel: () {
      if (mounted) setState(() => _p = false);
    },
    child: AnimatedScale(
      scale: _p ? 0.95 : 1.0,
      duration: const Duration(milliseconds: 90),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 15),
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: _p ? 0.2 : 0.45),
              blurRadius: _p ? 10 : 22,
              spreadRadius: _p ? 0 : 2,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          widget.label,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}

class _CBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext ctx) {
    final t = TN.of(ctx).t;
    return GestureDetector(
      onTap: () {
        Snd.click();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
        decoration: BoxDecoration(
          color: t.card.withValues(alpha: t.dark ? 0.06 : 0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: t.bdr),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: t.sub, size: 18),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: t.sub, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _IPill extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _IPill({required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext c) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Icon(icon, color: color, size: 20),
    ),
  );
}

class _Card extends StatefulWidget {
  final IconData icon;
  final String title, sub;
  final Color color;
  final VoidCallback onTap;
  const _Card({
    required this.icon,
    required this.title,
    required this.sub,
    required this.color,
    required this.onTap,
  });
  @override
  State<_Card> createState() => _CdState();
}

class _CdState extends State<_Card> {
  bool _p = false;
  @override
  Widget build(BuildContext ctx) {
    final t = TN.of(ctx).t;
    return GestureDetector(
      onTapDown: (_) {
        if (mounted) setState(() => _p = true);
        Snd.click();
      },
      onTapUp: (_) {
        if (mounted) setState(() => _p = false);
        widget.onTap();
      },
      onTapCancel: () {
        if (mounted) setState(() => _p = false);
      },
      child: AnimatedScale(
        scale: _p ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: widget.color.withValues(alpha: _p ? 0.6 : 0.25),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: _p ? 0.12 : 0.04),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: .15),
                  border: Border.all(color: widget.color.withValues(alpha: .3)),
                ),
                child: Icon(widget.icon, color: widget.color, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: widget.color,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.sub,
                      style: TextStyle(color: t.sub, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: widget.color.withValues(alpha: .5),
                size: 15,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final Color color;
  final AT theme;
  const _NField({
    required this.ctrl,
    required this.label,
    required this.color,
    required this.theme,
  });
  @override
  Widget build(BuildContext c) => TextField(
    controller: ctrl,
    maxLength: 14,
    style: TextStyle(color: theme.txt, fontWeight: FontWeight.w600),
    decoration: InputDecoration(
      counterText: '',
      labelText: label,
      labelStyle: TextStyle(color: color.withValues(alpha: .8), fontSize: 13),
      prefixIcon: Icon(Icons.person_rounded, color: color, size: 20),
      filled: true,
      fillColor: color.withValues(alpha: .07),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color.withValues(alpha: .3), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: 2),
      ),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  RESULT DIALOG (Bot/Local)
// ════════════════════════════════════════════════════════════════════
class _RDlg extends StatelessWidget {
  final String msg, l1, l2;
  final String againLbl = 'Play Again';
  final int s1, s2;
  final bool showRematch;
  final VoidCallback onAgain, onMenu;
  const _RDlg({
    required this.msg,
    required this.s1,
    required this.s2,
    required this.l1,
    required this.l2,
    required this.onAgain,
    required this.onMenu,
    this.showRematch = false,
  });
  @override
  Widget build(BuildContext ctx) {
    final t = TN.of(ctx).t;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: t.bdr, width: 1.5),
          boxShadow: const [BoxShadow(color: AT.black50, blurRadius: 30)],
        ),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x26FFD700),
                border: Border.all(color: const Color(0x66FFD700)),
              ),
              child: const Icon(
                Icons.emoji_events_rounded,
                color: AT.y,
                size: 34,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.txt,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Series Score',
              style: TextStyle(color: t.sub, fontSize: 12, letterSpacing: 1),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SD(label: l1, score: s1, color: AT.r, t: t),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    '—',
                    style: TextStyle(
                      color: t.sub,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _SD(label: l2, score: s2, color: AT.y, t: t),
              ],
            ),
            const SizedBox(height: 24),
            if (showRematch)
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: onAgain,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: AT.bl,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x4D4FC3F7),
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Text(
                          againLbl,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: onMenu,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: t.stBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: t.bdr),
                        ),
                        child: Text(
                          'Menu',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: t.txt.withValues(alpha: .7),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
              GestureDetector(
                onTap: onMenu,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: AT.bl,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    'Continue',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SD extends StatelessWidget {
  final String label;
  final int score;
  final Color color;
  final AT t;
  const _SD({
    required this.label,
    required this.score,
    required this.color,
    required this.t,
  });
  @override
  Widget build(BuildContext c) => Column(
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: .5), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label.length > 10 ? '${label.substring(0, 9)}…' : label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        '$score',
        style: TextStyle(
          color: t.txt,
          fontSize: 28,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    ],
  );
}

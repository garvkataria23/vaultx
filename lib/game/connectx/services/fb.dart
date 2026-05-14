import 'dart:convert';
import 'package:http/http.dart' as http;

const String kDbUrl = "https://connect4-199ee-default-rtdb.firebaseio.com";

class FB {
  static Future<void> sendMessage(String gid, String text, int sender) async {
    final msgId = DateTime.now().millisecondsSinceEpoch.toString();

    await http.patch(
      Uri.parse('$kDbUrl/games/$gid/chats/$msgId.json'),
      body: jsonEncode({
        'text': text,
        'sender': sender,
        'time': DateTime.now().millisecondsSinceEpoch,
        'seen': false,
      }),
    );
  }

  static Future<Map<String, dynamic>?> fetchMessages(String gid) async {
    final res = await http.get(Uri.parse('$kDbUrl/games/$gid/chats.json'));

    if (res.body == 'null') return null;

    final data = jsonDecode(res.body);
    if (data is! Map) return null;

    return Map<String, dynamic>.from(data);
  }

  static Future<void> markSeen(String gid, String msgId) async {
    await http.patch(
      Uri.parse('$kDbUrl/games/$gid/chats/$msgId.json'),
      body: jsonEncode({'seen': true}),
    );
  }

  static Future<void> setTyping(String gid, int player, bool val) async {
    await http.patch(
      Uri.parse('$kDbUrl/games/$gid/typing.json'),
      body: jsonEncode({'player': player, 'isTyping': val}),
    );
  }

  static Future<Map<String, dynamic>?> getTyping(String gid) async {
    final res = await http.get(Uri.parse('$kDbUrl/games/$gid/typing.json'));

    if (res.body == 'null') return null;

    final data = jsonDecode(res.body);
    if (data is! Map) return null;

    return Map<String, dynamic>.from(data);
  }
}

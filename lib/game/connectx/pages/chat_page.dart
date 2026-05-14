import 'dart:async';
import 'package:flutter/material.dart';
import '../services/fb.dart';

class ChatPage extends StatefulWidget {
  final String gameId;
  final int myNum;
  final String myName;
  final String oppName;

  const ChatPage({
    super.key,
    required this.gameId,
    required this.myNum,
    required this.myName,
    required this.oppName,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  Timer? poll;
  Timer? typingTimer;
  int lastMessageCount = 0;
  int unreadCount = 0;
  

  List<Map<String, dynamic>> messages = [];
  final TextEditingController _ctrl = TextEditingController();
  bool isTyping = false;
  bool mute = false;

  @override
  void initState() {
    super.initState();
    startPolling();
  }

  void startPolling() {
  poll = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
    if (!mounted) return;

    final data = await FB.fetchMessages(widget.gameId);

    if (data != null) {
      final msgs = data.entries.map((e) {
        final m = Map<String, dynamic>.from(e.value);
        m['id'] = e.key;
        return m;
      }).toList();

      msgs.sort((a, b) => (a['time'] ?? 0).compareTo(b['time'] ?? 0));

      // 🔥 NEW MESSAGE DETECTION
       if (msgs.length > lastMessageCount && lastMessageCount != 0) {
        final newMsg = msgs.last;

        if (newMsg['sender'] != widget.myNum) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("📩 New message received"),
              duration: Duration(milliseconds: 800),
            ),
          );
        }
      }

      // 🔥 UPDATE UI ONLY IF CHANGED
      if (msgs.length != lastMessageCount) {
        lastMessageCount = msgs.length;

        setState(() {
          messages = List<Map<String, dynamic>>.from(msgs.reversed);
        });
      }

      // 🔥 MARK SEEN
      for (var m in msgs) {
        if (m['sender'] != widget.myNum && m['seen'] != true) {
          FB.markSeen(widget.gameId, m['id']);
        }
      }
    }

    // 🔥 TYPING
    final typingData = await FB.getTyping(widget.gameId);

    if (!mounted) return;

    setState(() {
      isTyping = typingData != null &&
          typingData['player'] != widget.myNum &&
          typingData['isTyping'] == true;
    });
  });
}

  @override
void dispose() {
  poll?.cancel();
  typingTimer?.cancel();
  _ctrl.dispose();
  super.dispose();
}

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    await FB.sendMessage(widget.gameId, text.trim(), widget.myNum);
    await FB.setTyping(widget.gameId, widget.myNum, false);

    _ctrl.clear();
  }

  void setTyping(bool val) async {
    await FB.setTyping(widget.gameId, widget.myNum, val);
  }

  Widget buildMessage(Map<String, dynamic> msg) {
    final isMe = msg['sender'] == widget.myNum;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 250),
        decoration: BoxDecoration(
          color: isMe ? Colors.blue : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(msg['text'], style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg['seen'] == true ? "✓✓" : "✓",
                  style: TextStyle(
                    color: isMe
                        ? (msg['seen'] == true
                            ? Colors.blueAccent
                            : Colors.white70)
                        : Colors.transparent,
                    fontSize: 11,
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.oppName),
            if (isTyping)
              const Text("Typing...", style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(mute ? Icons.volume_off : Icons.volume_up),
            onPressed: () => setState(() => mute = !mute),
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length,
              itemBuilder: (_, i) => buildMessage(messages[i]),
            ),
          ),

          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: ["😂", "🔥", "😎", "😭", "❤️"].map((e) {
                return GestureDetector(
                  onTap: () => sendMessage(e),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
                );
              }).toList(),
            ),
          ),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  onChanged: (val) {
  setTyping(true);

  typingTimer?.cancel();
  typingTimer = Timer(const Duration(seconds: 1), () {
    setTyping(false);
  });
},
                  decoration: const InputDecoration(
                    hintText: "Type message...",
                    contentPadding: EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => sendMessage(_ctrl.text),
              )
            ],
          )
        ],
      ),
    );
  }
}
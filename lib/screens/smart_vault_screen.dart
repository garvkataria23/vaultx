import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:record/record.dart' as record;

import '../models/models.dart';
import '../services/services.dart';
import '../services/ai_navigation_service.dart';
import 'note_editor.dart';

class SmartVaultScreen extends StatefulWidget {
  final List<SecureNote> notes;
  final VaultRepository? repo;
  final EncryptedBlobService? blobs;
  final VaultKind vaultKind;
  final VaultAuthService auth;
  final AuthResult? authResult;

  const SmartVaultScreen({
    super.key,
    required this.notes,
    this.repo,
    this.blobs,
    required this.vaultKind,
    required this.auth,
    this.authResult,
  });

  @override
  State<SmartVaultScreen> createState() => _SmartVaultScreenState();
}

class _ChatMessage {
  final bool isUser;
  final String text;
  final SmartVaultResult? result;
  final DateTime timestamp;

  _ChatMessage({
    required this.isUser,
    required this.text,
    this.result,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class _SmartVaultScreenState extends State<SmartVaultScreen>
    with TickerProviderStateMixin {
  final _service = SmartVaultService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<_ChatMessage> _messages = [];
  bool _isProcessing = false;
  bool _showSuggestions = true;
  String _statusText = '';

  late AnimationController _orbController;
  late AnimationController _pulseController;
  late Animation<double> _orbFloat;
  late Animation<double> _orbPulse;

  DriveService? _drive;
  PasswordVaultService? _passwordVault;
  ItemActionService? _itemActions;
  TrashService? _trash;

  List<String> get _suggestions => _service.getSuggestions(widget.notes);

  @override
  void initState() {
    super.initState();

    if (widget.authResult != null && widget.authResult!.masterKey != null) {
      final masterKey = widget.authResult!.masterKey!;
      _drive = DriveService(masterKey, widget.vaultKind);
      _passwordVault = PasswordVaultService(masterKey, widget.vaultKind);
      if (widget.repo != null && _drive != null) {
        _itemActions = ItemActionService(
          repo: widget.repo!,
          drive: _drive!,
          masterKey: masterKey,
        );
      }
      if (widget.repo != null && _drive != null && _passwordVault != null) {
        _trash = TrashService(
          repo: widget.repo!,
          drive: _drive!,
          passwords: _passwordVault!,
          vaultKind: widget.vaultKind,
        );
      }
    }

    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    _orbFloat = Tween<double>(begin: -8.0, end: 8.0).animate(
      CurvedAnimation(parent: _orbController, curve: Curves.easeInOutSine),
    );

    _orbPulse = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutSine),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addWelcomeMessage();
    });
  }

  void _addWelcomeMessage() {
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage(
        isUser: false,
        text: 'Hello! I\'m your Smart Vault AI. Ask me anything about your notes, or try one of the suggestions below.\n\nAll processing is offline and private — your data never leaves this device.',
        result: null,
      ));
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _orbController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || _isProcessing) return;

    HapticFeedback.lightImpact();
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage(isUser: true, text: trimmed));
      _isProcessing = true;
      _showSuggestions = false;
      _statusText = 'Thinking...';
    });
    _textController.clear();
    _scrollToBottom();

    try {
      final result = await _service.processQuery(trimmed, widget.notes);

      if (result.type == 'navigate') {
        final intent = IntentParser.parse(trimmed);
        if (mounted) {
          final success = await ActionExecutor.execute(
            context,
            intent,
            arguments: {
              'auth': widget.auth,
              'repo': widget.repo,
              'drive': _drive,
              'passwordVault': _passwordVault,
              'itemActions': _itemActions,
              'trashService': _trash,
              'isDecoy': widget.vaultKind == VaultKind.decoy,
              'vaultKind': widget.vaultKind,
              'onDataChanged': () async {}, // Placeholder
            },
          );
          if (success) {
            setState(() {
              _isProcessing = false;
              _statusText = '';
            });
            return;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          isUser: false,
          text: result.title,
          result: result,
        ));
        _isProcessing = false;
        _statusText = '';
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          isUser: false,
          text: 'Sorry, I encountered an error processing your request.',
          result: SmartVaultResult(
            type: 'error',
            title: 'Error processing query',
            subtitle: e.toString(),
          ),
        ));
        _isProcessing = false;
        _statusText = '';
      });
      _scrollToBottom();
    }
  }

  Future<void> _openNote(SecureNote note) async {
    if (widget.repo == null) return;
    if (!mounted) return;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NoteEditor(
            note: note,
            blobs: widget.blobs,
            allNotes: widget.notes,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open note: $e')),
      );
    }
  }

  Future<void> _handleVoiceInput() async {
    if (_isProcessing) return;
    final trimmed = _textController.text.trim();
    if (trimmed.isNotEmpty) {
      await _sendQuery(trimmed);
      return;
    }
    if (!TranscriptionService.isAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice not available on this device'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final modelReady = await TranscriptionService.ensureModel();
    if (!modelReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Download vosk model in Settings > Voice Recognition first'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }
    if (!mounted) return;
    final path = await _recordAndGetPath();
    if (path == null) return;
    try {
      final text = await TranscriptionService.transcribeFile(path);
      if (text != null && text.isNotEmpty) {
        _textController.text = text;
        await _sendQuery(text);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No speech detected, try again'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Voice error: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<String?> _recordAndGetPath() async {
    final buildContext = context;
    if (!mounted) return null;
    final dir = await path_provider.getTemporaryDirectory();
    final path = '${dir.path}/vaultx_voice_query_${DateTime.now().millisecondsSinceEpoch}.wav';
    final completer = Completer<String?>();

    await showDialog<void>(
      // ignore: use_build_context_synchronously
      context: buildContext,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _VoiceRecordDialog(
          outputPath: path,
          onResult: (result) {
            Navigator.of(dialogContext).pop();
            completer.complete(result);
          },
        );
      },
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildOrb(cs),
            const SizedBox(width: 10),
            Text(
              'Smart Vault AI',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              icon: Icon(
                _showSuggestions ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              ),
              onPressed: () {
                setState(() => _showSuggestions = !_showSuggestions);
              },
              tooltip: 'Toggle suggestions',
            ),
          if (_messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() {
                  _messages.clear();
                  _showSuggestions = true;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _addWelcomeMessage();
                });
              },
              tooltip: 'Reset chat',
            ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              cs.surface,
              cs.surface.withValues(alpha: 0.95),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? _buildSuggestionsView(cs)
                    : _buildMessagesList(cs),
              ),
              if (_isProcessing) _buildProcessingIndicator(cs),
              if (_messages.isEmpty && _showSuggestions)
                _buildSuggestionChips(cs),
              if (_messages.isNotEmpty && _showSuggestions)
                _buildMiniSuggestionChips(cs),
              _buildInputBar(cs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOrb(ColorScheme cs) {
    return AnimatedBuilder(
      animation: Listenable.merge([_orbController, _pulseController]),
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(0, _orbFloat.value),
          child: Transform.scale(
            scale: _orbPulse.value,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    cs.primary.withValues(alpha: 0.8),
                    cs.tertiary.withValues(alpha: 0.8),
                    cs.secondary.withValues(alpha: 0.8),
                    cs.primary.withValues(alpha: 0.8),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 16,
                color: cs.onPrimary,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSuggestionsView(ColorScheme cs) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              _buildOrbLarge(cs),
              const SizedBox(height: 24),
              Text(
                'Smart Vault AI',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Ask anything about your notes',
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Fully offline \u2022 100% private',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.primary.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(flex: 1),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrbLarge(ColorScheme cs) {
    return AnimatedBuilder(
      animation: Listenable.merge([_orbController, _pulseController]),
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(0, _orbFloat.value * 2),
          child: Transform.scale(
            scale: _orbPulse.value,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    cs.primary.withValues(alpha: 0.6),
                    cs.tertiary.withValues(alpha: 0.6),
                    cs.secondary.withValues(alpha: 0.6),
                    cs.primary.withValues(alpha: 0.6),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.2),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 36,
                color: cs.onPrimary,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessagesList(ColorScheme cs) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return _buildMessageBubble(msg, cs);
      },
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg, ColorScheme cs) {
    if (msg.isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20).copyWith(
                    bottomRight: const Radius.circular(4),
                  ),
                ),
                child: Text(
                  msg.text,
                  style: TextStyle(color: cs.onSurface),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primary.withValues(alpha: 0.2),
                ),
                child: Icon(Icons.auto_awesome_rounded, size: 14, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16).copyWith(
                      topLeft: const Radius.circular(4),
                    ),
                    border: Border.all(
                      color: cs.outline.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMessageContent(msg, cs),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessageContent(_ChatMessage msg, ColorScheme cs) {
    final result = msg.result;
    if (result == null) {
      return Text(msg.text, style: TextStyle(color: cs.onSurface, height: 1.5));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          msg.text,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: cs.onSurface,
          ),
        ),
        if (result.subtitle != null && result.subtitle!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            result.subtitle!,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.7),
              height: 1.5,
              fontSize: 13,
            ),
          ),
        ],
        if (result.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildResultNotes(result, cs),
        ],
      ],
    );
  }

  Widget _buildResultNotes(SmartVaultResult result, ColorScheme cs) {
    final notes = result.notes;
    final showCount = notes.length > 5 ? 5 : notes.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...notes.take(showCount).map((note) => _buildNoteCard(note, cs)),
        if (notes.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: () {
                setState(() {
                  _messages.add(_ChatMessage(
                    isUser: false,
                    text: result.title,
                    result: SmartVaultResult(
                      type: result.type,
                      title: result.title,
                      subtitle: 'Showing all ${notes.length} notes',
                      notes: notes,
                    ),
                  ));
                });
              },
              child: Text('+ ${notes.length - 5} more notes'),
            ),
          ),
      ],
    );
  }

  Widget _buildNoteCard(SecureNote note, ColorScheme cs) {
    final typeIcons = {
      NoteType.text: Icons.text_fields,
      NoteType.checklist: Icons.checklist,
      NoteType.voice: Icons.mic,
      NoteType.drawing: Icons.brush,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        onTap: () => _openNote(note),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  typeIcons[note.type] ?? Icons.note,
                  size: 18,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title.isEmpty ? 'Untitled' : note.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: cs.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          note.folder,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.primary.withValues(alpha: 0.7),
                          ),
                        ),
                        if (note.attachments.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.attachment, size: 12, color: cs.onSurface.withValues(alpha: 0.4)),
                        ],
                        const Spacer(),
                        Text(
                          _formatDate(note.updatedAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: cs.onSurface.withValues(alpha: 0.3)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingIndicator(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cs.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _statusText,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionChips(ColorScheme cs) {
    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            return ActionChip(
              label: Text(
                suggestions[index],
                style: TextStyle(fontSize: 12, color: cs.primary),
              ),
              onPressed: _isProcessing ? null : () => _sendQuery(suggestions[index]),
              backgroundColor: cs.primary.withValues(alpha: 0.08),
              side: BorderSide.none,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMiniSuggestionChips(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          ActionChip(
            label: Text('Suggestions', style: TextStyle(fontSize: 11, color: cs.primary.withValues(alpha: 0.6))),
            onPressed: null,
            backgroundColor: Colors.transparent,
            side: BorderSide.none,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          ...(_suggestions.take(3).map((s) => Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              label: Text(s, style: TextStyle(fontSize: 11, color: cs.primary)),
              onPressed: _isProcessing ? null : () => _sendQuery(s),
              backgroundColor: cs.primary.withValues(alpha: 0.06),
              side: BorderSide.none,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ))),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: cs.outline.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: cs.outline.withValues(alpha: 0.2),
                ),
              ),
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                textInputAction: TextInputAction.send,
                onSubmitted: _isProcessing ? null : _sendQuery,
                minLines: 1,
                maxLines: 4,
                enabled: !_isProcessing,
                decoration: InputDecoration(
                  hintText: 'Ask AI about your notes...',
                  hintStyle: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.4),
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      Icons.mic,
                      color: _isProcessing
                          ? cs.onSurface.withValues(alpha: 0.2)
                          : cs.onSurface.withValues(alpha: 0.5),
                    ),
                    onPressed: _isProcessing ? null : _handleVoiceInput,
                    tooltip: 'Voice search / Send text',
                  ),
                ),
                style: TextStyle(color: cs.onSurface, fontSize: 14),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: _isProcessing
                ? cs.primary.withValues(alpha: 0.4)
                : cs.primary,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: _isProcessing ? null : () => _sendQuery(_textController.text),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: _isProcessing
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : Icon(Icons.arrow_upward_rounded, color: cs.onPrimary, size: 22),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}/${date.year}';
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;

  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outline.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: padding ?? const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _VoiceRecordDialog extends StatefulWidget {
  final String outputPath;
  final ValueChanged<String?> onResult;

  const _VoiceRecordDialog({
    required this.outputPath,
    required this.onResult,
  });

  @override
  State<_VoiceRecordDialog> createState() => _VoiceRecordDialogState();
}

class _VoiceRecordDialogState extends State<_VoiceRecordDialog>
    with SingleTickerProviderStateMixin {
  final _recorder = record.AudioRecorder();
  bool _isRecording = false;
  bool _isDone = false;
  late AnimationController _pulseAnim;
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _pulseAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _startRecording();
  }

  @override
  void dispose() {
    _pulseAnim.dispose();
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      widget.onResult(null);
      return;
    }
    if (!mounted) return;
    setState(() => _isRecording = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
    await _recorder.start(
      record.RecordConfig(
        encoder: record.AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: widget.outputPath,
    );
  }

  Future<void> _stopRecording() async {
    if (!_isRecording || _isDone) return;
    setState(() => _isDone = true);
    _timer?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    widget.onResult(widget.outputPath);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (ctx, _) {
              return Transform.scale(
                scale: 1.0 + (_pulseAnim.value * 0.15),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isDone
                        ? cs.primary
                        : cs.error.withValues(alpha: 0.9),
                  ),
                  child: Icon(
                    _isDone ? Icons.check : Icons.mic,
                    color: cs.onPrimary,
                    size: 32,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          Text(
            _isDone
                ? 'Transcribing...'
                : 'Recording...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isDone ? 'Processing speech' : '${_seconds}s',
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w300,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _isDone ? null : _stopRecording,
            icon: Icon(_isDone ? Icons.check : Icons.stop),
            label: Text(_isDone ? 'Done' : 'Stop & Transcribe'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

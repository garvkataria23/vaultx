import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:record/record.dart' as record;

import '../models/models.dart';
import '../services/services.dart';
import '../services/auth_session_manager.dart';
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

enum _NoteSortBy { relevance, newest, oldest, alphabetical }
enum _DateFilter { all, today, week, month }

class _SmartVaultScreenState extends State<SmartVaultScreen>
    with TickerProviderStateMixin {
  final _service = SmartVaultService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<_ChatMessage> _messages = [];
  bool _isProcessing = false;
  bool _authenticated = false;
  bool _authInProgress = false;
  bool _bioAvailable = false;
  bool _showSuggestions = true;
  String _statusText = '';

  // Filter state
  Set<NoteType> _typeFilter = {};
  String? _folderFilter;
  _NoteSortBy _sortBy = _NoteSortBy.relevance;
  _DateFilter _dateFilter = _DateFilter.all;

  late AnimationController _orbController;
  late AnimationController _pulseController;
  late Animation<double> _orbFloat;
  late Animation<double> _orbPulse;

  DriveService? _drive;
  PasswordVaultService? _passwordVault;
  ItemActionService? _itemActions;
  TrashService? _trash;

  bool get _filtersActive =>
      _typeFilter.isNotEmpty ||
      _folderFilter != null ||
      _sortBy != _NoteSortBy.relevance ||
      _dateFilter != _DateFilter.all;

  List<String> get _allFolders =>
      widget.notes.map((n) => n.folder).toSet().toList()..sort();

  List<SecureNote> get _filteredNotes {
    var notes = widget.notes;
    if (_typeFilter.isNotEmpty) {
      notes = notes.where((n) => _typeFilter.contains(n.type)).toList();
    }
    if (_folderFilter != null) {
      notes = notes.where((n) => n.folder == _folderFilter).toList();
    }
    final now = DateTime.now();
    if (_dateFilter == _DateFilter.today) {
      notes = notes.where((n) =>
          n.updatedAt.year == now.year &&
          n.updatedAt.month == now.month &&
          n.updatedAt.day == now.day).toList();
    } else if (_dateFilter == _DateFilter.week) {
      final weekAgo = now.subtract(const Duration(days: 7));
      notes = notes.where((n) => n.updatedAt.isAfter(weekAgo)).toList();
    } else if (_dateFilter == _DateFilter.month) {
      final monthAgo = now.subtract(const Duration(days: 30));
      notes = notes.where((n) => n.updatedAt.isAfter(monthAgo)).toList();
    }
    switch (_sortBy) {
      case _NoteSortBy.newest:
        notes = List.from(notes)..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case _NoteSortBy.oldest:
        notes = List.from(notes)..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      case _NoteSortBy.alphabetical:
        notes = List.from(notes)..sort((a, b) => a.title.compareTo(b.title));
      case _NoteSortBy.relevance:
        break;
    }
    return notes;
  }

  List<String> get _suggestions => _service.getSuggestions(_filteredNotes);

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _checkBio();
  }

  Future<void> _checkBio() async {
    final avail = await widget.auth.isBiometricUnlockAvailable();
    if (mounted) setState(() => _bioAvailable = avail);
    if (avail && mounted) {
      final authed = await widget.auth.authenticateBiometric();
      if (mounted && authed) {
        setState(() => _authenticated = true);
        _initServices();
        _addWelcomeMessage();
      }
    }
  }

  void _initServices() {
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
  }

  void _setupAnimations() {
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
      _statusText = 'Thinking...';
    });
    _textController.clear();
    _scrollToBottom();

    try {
      final svc = SmartVaultContext(
        repo: widget.repo,
        passwords: _passwordVault,
        drive: _drive,
        trash: _trash,
        itemActions: _itemActions,
        auth: widget.auth,
        vaultKind: widget.vaultKind,
      );
      var result = await _service.processQuery(trimmed, _filteredNotes, context: svc);

      // Handle navigation intent
      if (result.type == 'navigate') {
        final intent = IntentParser.parse(trimmed);
        if (mounted) {
          final success = await ActionExecutor.execute(
            context,
            intent,
            arguments: {
              'auth': widget.auth,
              'repo': widget.repo,
              'masterKey': widget.authResult?.masterKey,
              'drive': _drive,
              'passwordVault': _passwordVault,
              'itemActions': _itemActions,
              'trashService': _trash,
              'notes': widget.notes,
              'blobs': widget.blobs,
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
          result = SmartVaultResult(
            type: 'error',
            title: 'Could not navigate to ${result.title.replaceAll('Navigating to ', '')}',
            subtitle: 'This action is not available right now.',
          );
        }
      }

      // Handle lock vault
      if (result.type == 'lock_vault' && mounted) {
        AuthSessionManager.instance.lock();
        setState(() {
          _isProcessing = false;
          _statusText = '';
        });
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }

      // Handle trigger backup
      if (result.type == 'trigger_backup' && mounted) {
        final masterKey = widget.authResult?.masterKey;
        if (masterKey != null) {
          final success = await ActionExecutor.execute(
            context,
            AIIntent.openBackup,
            arguments: {
              'auth': widget.auth,
              'repo': widget.repo,
              'masterKey': masterKey,
              'vaultKind': widget.vaultKind,
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
        // Fallback: show message
        result = const SmartVaultResult(
          type: 'error',
          title: 'Could not start backup',
          subtitle: 'Backup screen not available right now.',
        );
      }

      // Handle CRUD actions that may have modified notes list
      if (result.type == 'create_note' || result.type == 'action_done') {
        _statusText = 'Action completed';
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

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _FilterSheet(
        typeFilter: _typeFilter,
        folderFilter: _folderFilter,
        sortBy: _sortBy,
        dateFilter: _dateFilter,
        allFolders: _allFolders,
        onApply: (types, folder, sort, date) {
          setState(() {
            _typeFilter = types;
            _folderFilter = folder;
            _sortBy = sort;
            _dateFilter = date;
          });
          Navigator.of(ctx).pop();
        },
        onReset: () {
          setState(() {
            _typeFilter = {};
            _folderFilter = null;
            _sortBy = _NoteSortBy.relevance;
            _dateFilter = _DateFilter.all;
          });
          Navigator.of(ctx).pop();
        },
      ),
    );
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
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.filter_list),
                onPressed: _showFilterSheet,
                tooltip: 'Filters',
              ),
              if (_filtersActive)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
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
      body: !_authenticated
          ? _buildAuthGate(cs)
          : Container(
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
                    Expanded(child: _buildMessagesList(cs)),
                    if (_isProcessing) _buildProcessingIndicator(cs),
                    if (_showSuggestions) _buildSuggestionChips(cs),
                    _buildInputBar(cs),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildAuthGate(ColorScheme cs) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 72, color: cs.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 24),
            Text(
              'Authenticate to use Smart AI',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Verify your identity to access AI features.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 32),
            if (!_authInProgress) _buildBioButton(cs),
            if (_bioAvailable && !_authInProgress) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    Expanded(child: Divider(color: cs.outlineVariant)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or use password',
                        style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
                    ),
                    Expanded(child: Divider(color: cs.outlineVariant)),
                  ],
                ),
              ),
            ],
            _buildPasswordField(cs),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBioButton(ColorScheme cs) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () async {
          final ok = await widget.auth.isBiometricUnlockAvailable();
          if (!ok || !mounted) return;
          final authed = await widget.auth.authenticateBiometric();
          if (!mounted) return;
          if (authed) {
            setState(() => _authenticated = true);
            _initServices();
            _addWelcomeMessage();
          }
        },
        icon: const Icon(Icons.fingerprint),
        label: const Text('Use biometrics'),
      ),
    );
  }

  Widget _buildPasswordField(ColorScheme cs) {
    final ctrl = TextEditingController();
    return Column(
      children: [
        TextField(
          controller: ctrl,
          obscureText: true,
          enabled: !_authInProgress,
          decoration: InputDecoration(
            labelText: 'Master password',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (val) => _verifyPassword(val, ctrl),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _authInProgress ? null : () => _verifyPassword(ctrl.text, ctrl),
            icon: _authInProgress
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.password),
            label: Text(_authInProgress ? 'Verifying...' : 'Unlock with password'),
          ),
        ),
      ],
    );
  }

  Future<void> _verifyPassword(String password, TextEditingController ctrl) async {
    if (password.isEmpty) return;
    setState(() => _authInProgress = true);
    try {
      var result = widget.vaultKind == VaultKind.hidden
          ? await widget.auth.unlockHidden(password)
          : await widget.auth.unlockWithPassword(password);
      result = await widget.auth.verify(result);
      if (!mounted) return;
      if (result.ok && result.kind == widget.vaultKind) {
        ctrl.dispose();
        setState(() => _authenticated = true);
        _initServices();
        _addWelcomeMessage();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid password'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _authInProgress = false);
    }
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
    var notes = result.notes;
    if (_typeFilter.isNotEmpty) {
      notes = notes.where((n) => _typeFilter.contains(n.type)).toList();
    }
    if (_folderFilter != null) {
      notes = notes.where((n) => n.folder == _folderFilter).toList();
    }
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
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          itemBuilder: (context, index) {
            return ActionChip(
              label: Text(
                suggestions[index],
                style: TextStyle(fontSize: 13, color: cs.primary),
              ),
              onPressed: _isProcessing ? null : () => _sendQuery(suggestions[index]),
              backgroundColor: cs.primary.withValues(alpha: 0.08),
              side: BorderSide.none,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              visualDensity: VisualDensity.standard,
            );
          },
        ),
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

class _FilterSheet extends StatefulWidget {
  final Set<NoteType> typeFilter;
  final String? folderFilter;
  final _NoteSortBy sortBy;
  final _DateFilter dateFilter;
  final List<String> allFolders;
  final void Function(Set<NoteType>, String?, _NoteSortBy, _DateFilter) onApply;
  final VoidCallback onReset;

  const _FilterSheet({
    required this.typeFilter,
    required this.folderFilter,
    required this.sortBy,
    required this.dateFilter,
    required this.allFolders,
    required this.onApply,
    required this.onReset,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late Set<NoteType> _types;
  late String? _folder;
  late _NoteSortBy _sort;
  late _DateFilter _date;

  @override
  void initState() {
    super.initState();
    _types = Set.from(widget.typeFilter);
    _folder = widget.folderFilter;
    _sort = widget.sortBy;
    _date = widget.dateFilter;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 500,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Filters',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onReset,
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: [
                  // Note Type
                  Text('Note Type', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: NoteType.values.map((t) {
                      final selected = _types.contains(t);
                      return FilterChip(
                        label: Text(t.name[0].toUpperCase() + t.name.substring(1)),
                        selected: selected,
                        onSelected: (val) {
                          setState(() {
                            if (val) { _types.add(t); } else { _types.remove(t); }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // Folder
                  Text('Folder', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    value: _folder,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All folders')),
                      ...widget.allFolders.map((f) =>
                        DropdownMenuItem(value: f, child: Text(f))),
                    ],
                    onChanged: (v) => setState(() => _folder = v),
                  ),
                  const SizedBox(height: 20),

                  // Sort
                  Text('Sort By', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _NoteSortBy.values.map((s) {
                      final selected = _sort == s;
                      return ChoiceChip(
                        label: Text(_sortLabel(s)),
                        selected: selected,
                        onSelected: (_) => setState(() => _sort = s),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // Date
                  Text('Date Range', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _DateFilter.values.map((d) {
                      final selected = _date == d;
                      return ChoiceChip(
                        label: Text(_dateLabel(d)),
                        selected: selected,
                        onSelected: (_) => setState(() => _date = d),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => widget.onApply(_types, _folder, _sort, _date),
                  child: const Text('Apply Filters'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _sortLabel(_NoteSortBy s) {
    switch (s) {
      case _NoteSortBy.relevance: return 'Relevance';
      case _NoteSortBy.newest: return 'Newest';
      case _NoteSortBy.oldest: return 'Oldest';
      case _NoteSortBy.alphabetical: return 'A-Z';
    }
  }

  String _dateLabel(_DateFilter d) {
    switch (d) {
      case _DateFilter.all: return 'All Time';
      case _DateFilter.today: return 'Today';
      case _DateFilter.week: return 'This Week';
      case _DateFilter.month: return 'This Month';
    }
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

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:open_file/open_file.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';

/// Full-screen image viewer with pinch-to-zoom.
class _FullscreenImageViewer extends StatelessWidget {
  const _FullscreenImageViewer({required this.path, required this.name});
  final String path;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, style: const TextStyle(fontSize: 14)),
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => Center(
              child: Text(
                'Unsupported image format',
                style: TextStyle(color: cs.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Widget that decrypts and displays an image attachment safely.
class _ImagePreview extends StatefulWidget {
  const _ImagePreview({
    required this.blobs,
    required this.noteId,
    required this.attachment,
  });
  final EncryptedBlobService? blobs;
  final String noteId;
  final SecureAttachment attachment;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  String? _tempPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final path = await widget.blobs?.decryptAttachmentToTemp(
        widget.noteId,
        widget.attachment,
      );
      if (mounted) setState(() => _tempPath = path);
    } catch (e) {
      if (mounted) setState(() => _error = 'Image validation failed: $e');
    }
  }

  void _openFullscreen(BuildContext context) {
    if (_tempPath == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenImageViewer(
          path: _tempPath!,
          name: widget.attachment.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      final cs = Theme.of(context).colorScheme;
      return Card(
        color: cs.errorContainer.withValues(alpha: 0.3),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Icon(Icons.warning_amber, color: cs.error),
              const SizedBox(height: 8),
              Text(_error!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(
                'Image could not be decrypted. The file may be corrupted or the encryption key has changed.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    if (_tempPath == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return GestureDetector(
      onTap: () => _openFullscreen(context),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_tempPath!),
              fit: BoxFit.cover,
              width: double.infinity,
              cacheWidth: 360,
              errorBuilder: (context, error, stack) =>
                  const Text('Unsupported image format'),
            ),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.zoom_out_map, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text(
                    'Tap to expand',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Editor for creating and modifying encrypted notes.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.note,
    required this.blobs,
    this.allNotes = const [],
    this.onAutoSave,
  });
  final SecureNote? note;
  final EncryptedBlobService? blobs;
  final List<SecureNote> allNotes;
  final Future<void> Function(SecureNote)? onAutoSave;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late SecureNote _note;
  late TextEditingController _title;
  late TextEditingController _body;
  late TextEditingController _folder;
  late TextEditingController _tags;

  late SmartOrganizationService _orgService;
  List<SecureNote> _relatedNotes = [];
  List<SecureNote> _backlinks = [];

  // ✅ FIX: FocusNode + saved selection so format buttons work after tap
  final FocusNode _bodyFocus = FocusNode();
  TextSelection _savedSelection = const TextSelection.collapsed(offset: 0);

  // ✅ FIX: Note lock state — uses local_auth (already in pubspec.yaml)
  bool _isLocked = false;
  bool _authFailed = false;
  final LocalAuthentication _localAuth = LocalAuthentication();

  bool _recording = false;
  VoiceNoteRecorder? _recorder;
  Timer? _clipboardTimer;
  AudioPlayer? _audioPlayer;
  String? _playingAttachmentId;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;
  bool _isAudioPlaying = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _stateSub;

  final TextEditingController _ocrText = TextEditingController();
  List<String>? _ocrJobIds;
  final OcrQueueService _queueService = OcrQueueService();

  bool _transcribing = false;
  bool _usePcm = false;

  // Auto-save state
  Timer? _autoSaveTimer;
  bool _isAutoSaving = false;
  bool _isManualSaving = false;
  DateTime? _lastSaved;
  bool _hasUnsavedChanges = false;
  bool _isPreviewMode = false;

  @override
  void initState() {
    super.initState();
    _note = widget.note ?? SecureNote(
      id: '',
      title: '',
      body: '',
      type: NoteType.text,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _title = TextEditingController(text: _note.title);
    _body = TextEditingController(text: _note.body);
    _folder = TextEditingController(text: _note.folder);
    _tags = TextEditingController(text: _note.tags.join(', '));
    _ocrText.text = _note.ocrText;

    _orgService = SmartOrganizationService(widget.allNotes);
    _computeRelationships();

    // Initialize change tracking
    _body.addListener(_onContentChanged);
    _title.addListener(_onContentChanged);
    _folder.addListener(_onContentChanged);
    _tags.addListener(_onContentChanged);

    // ✅ FIX: Lock screen if note.locked == true
    if (_note.locked) {
      _isLocked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
    }
  }

  void _computeRelationships() {
    if (_note.id.isNotEmpty) {
      setState(() {
        _relatedNotes = _orgService.getRelatedNotes(_note);
        _backlinks = _orgService.getBacklinks(_note);
      });
    }
  }

  void _onContentChanged() {
    if (_bodyFocus.hasFocus) {
      _savedSelection = _body.selection;
    }
    
    // Check if truly changed compared to last known state
    final isDifferent = _title.text != _note.title ||
                       _body.text != _note.body ||
                       _folder.text != _note.folder ||
                       _tags.text != _note.tags.join(', ') ||
                       _ocrText.text != _note.ocrText;
                       
    if (isDifferent && !_hasUnsavedChanges) {
      setState(() => _hasUnsavedChanges = true);
    }
    
    _scanSensitiveText();
    _triggerAutoSave();
  }

  void _triggerAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), _performAutoSave);
  }

  Future<void> _performAutoSave() => _saveNote(isManual: false);

  Future<void> _manualSave() async {
    _autoSaveTimer?.cancel();
    await _saveNote(isManual: true);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _saveNote({required bool isManual}) async {
    if (widget.onAutoSave == null || !mounted) return;
    if (_isAutoSaving || _isManualSaving) return;

    // Don't save if everything is empty (for new notes)
    if (_title.text.trim().isEmpty && _body.text.trim().isEmpty) return;
    
    // Don't save if no changes
    if (!_hasUnsavedChanges && !isManual) return;

    setState(() {
      if (isManual) {
        _isManualSaving = true;
      } else {
        _isAutoSaving = true;
      }
    });

    try {
      final updatedNote = _note.copyWith(
        title: _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim(),
        body: _body.text,
        folder: _folder.text.trim().isEmpty ? 'Private' : _folder.text.trim(),
        tags: _tags.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        ocrText: _ocrText.text,
        lastOpenedAt: DateTime.now(), // Ensure note opening/editing updates history
      );

      await widget.onAutoSave!(updatedNote);
      
      if (mounted) {
        setState(() {
          _note = updatedNote;
          _isAutoSaving = false;
          _isManualSaving = false;
          _hasUnsavedChanges = false;
          _lastSaved = DateTime.now();
        });
        _computeRelationships();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAutoSaving = false;
          _isManualSaving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _clipboardTimer?.cancel();
    _title.dispose();
    _body.dispose();
    _folder.dispose();
    _tags.dispose();
    _bodyFocus.dispose();
    _ocrText.dispose();
    _queueService.cancelAll();
    _queueService.removeNoteJobs(_note.id);
    _disposeAudio();
    super.dispose();
  }

  // ✅ FIX: Real biometric/PIN authentication for locked notes
  Future<void> _authenticate() async {
    try {
      final canCheck =
          await _localAuth.canCheckBiometrics ||
          await _localAuth.isDeviceSupported();
      if (!canCheck) {
        // No biometrics available — unlock with warning
        if (mounted) setState(() => _isLocked = false);
        return;
      }
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate to unlock this note',
        options: const AuthenticationOptions(
          biometricOnly: false, // allows PIN/pattern fallback
          stickyAuth: true,
        ),
      );
      if (mounted) {
        setState(() {
          _isLocked = !authenticated;
          _authFailed = !authenticated;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _authFailed = true);
    }
  }

  void _disposeAudio() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _audioPlayer?.dispose();
    _audioPlayer = null;
    _playingAttachmentId = null;
    _isAudioPlaying = false;
  }

  Future<void> _playVoiceAttachment(SecureAttachment attachment) async {
    if (_playingAttachmentId == attachment.id) {
      if (_isAudioPlaying) {
        await _audioPlayer?.pause();
        setState(() => _isAudioPlaying = false);
      } else {
        await _audioPlayer?.resume();
        setState(() => _isAudioPlaying = true);
      }
      return;
    }
    _disposeAudio();

    final tempPath = await widget.blobs?.decryptAttachmentToTemp(
      _note.id,
      attachment,
    );
    if (tempPath == null || !mounted) return;

    final player = AudioPlayer();
    _audioPlayer = player;
    _playingAttachmentId = attachment.id;

    _positionSub = player.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _audioPosition = pos);
    });
    _durationSub = player.onDurationChanged.listen((dur) {
      if (mounted) setState(() => _audioDuration = dur);
    });
    _stateSub = player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isAudioPlaying = state == PlayerState.playing);
      }
    });

    await player.play(DeviceFileSource(tempPath));
    if (mounted) setState(() {});
  }

  Future<void> _seekTo(double value) async {
    final player = _audioPlayer;
    if (player == null) return;
    final position = Duration(
      milliseconds: (value * _audioDuration.inMilliseconds).toInt(),
    );
    await player.seek(position);
    if (mounted) setState(() => _audioPosition = position);
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _scanSensitiveText() {
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(
      const Duration(seconds: 45),
      () => Clipboard.setData(const ClipboardData(text: '')),
    );
  }

  bool get _sensitiveDetected {
    final text = _body.text.toLowerCase();
    return RegExp(
      r'(password|seed phrase|private key|cvv|card number|ssn|otp|api[_ -]?key)',
    ).hasMatch(text);
  }

  bool get _hasImageAttachments =>
      _note.attachments.any((a) => a.kind == 'image');

  Future<void> _enqueueOcrJobs() async {
    if (!OcrService.isAvailable()) return;
    final images = _note.attachments.where((a) => a.kind == 'image').toList();
    final items = <OcrBatchItem>[];
    for (final a in images) {
      if (!mounted) return;
      final path = await widget.blobs?.decryptAttachmentToTemp(_note.id, a);
      if (path != null) {
        items.add(
          OcrBatchItem(
            noteId: _note.id,
            attachmentName: a.name,
            tempPath: path,
          ),
        );
      }
    }
    if (items.isEmpty) return;
    final ids = _queueService.enqueueBatch(items);
    setState(() => _ocrJobIds = ids);
  }

  void _showVersionHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _VersionHistorySheet(
        versions: _note.versions,
        onRestore: (snapshot) {
          setState(() {
            _title.text = snapshot['title'] as String? ?? '';
            _body.text = snapshot['body'] as String? ?? '';
          });
          Navigator.pop(context);
          FloatingNotificationService.instance.show('Version restored — save to keep');
        },
      ),
    );
  }

  Future<void> _addAttachment() async {
    final attachment = await widget.blobs?.pickAndEncryptFile(_note.id);
    if (attachment == null) return;
    if (!mounted) return;
    setState(
      () => _note = _note.copyWith(
        attachments: [..._note.attachments, attachment],
      ),
    );
  }

  Future<void> _exportAttachment(SecureAttachment attachment) async {
    final path = await widget.blobs?.decryptAttachmentToTemp(
      _note.id,
      attachment,
    );
    if (!mounted || path == null) return;

    if (attachment.kind == 'image') {
      Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) =>
              _FullscreenImageViewer(path: path, name: attachment.name),
        ),
      );
    } else {
      final result = await OpenFile.open(path);
      if (result.type != ResultType.done && mounted) {
        FloatingNotificationService.instance.show('Could not open file: ${result.message}');
      }
    }
  }

  // ✅ FIX: Uses _savedSelection so wrapping works even after button tap steals focus
  void _wrapSelection(String left, String right) {
    final text = _body.text;
    final selection = _savedSelection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final selected = text.substring(start, end);
    final updated = text.replaceRange(start, end, '$left$selected$right');

    _body.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: start + left.length,
        extentOffset: start + left.length + selected.length,
      ),
    );
    _bodyFocus.requestFocus();
    _savedSelection = _body.selection;
  }

  // ✅ FIX: Proper list item insertion at cursor line
  void _insertListItem() {
    final text = _body.text;
    final selection = _savedSelection;
    final offset = selection.start < 0 ? text.length : selection.start;
    final insert = offset == 0 || text[offset - 1] == '\n' ? '- ' : '\n- ';
    final updated = text.replaceRange(offset, offset, insert);

    _body.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: offset + insert.length),
    );
    _bodyFocus.requestFocus();
    _savedSelection = _body.selection;
  }

  Future<void> _toggleRecording() async {
    if (widget.blobs == null) return;
    if (_recording) {
      final attachment = await _recorder?.stopAndEncrypt();
      if (!mounted) return;
      if (attachment != null) {
        final wasPcm = _recorder?.isPcmMode ?? false;
        setState(() {
          _recording = false;
          _note = _note.copyWith(
            type: NoteType.voice,
            attachments: [..._note.attachments, attachment],
          );
        });
        if (wasPcm) {
          _transcribeAttachment(attachment);
        }
      } else {
        setState(() => _recording = false);
      }
      return;
    }
    _recorder = VoiceNoteRecorder(widget.blobs!, _note.id);
    final started = _usePcm
        ? await _recorder!.startPcm()
        : await _recorder!.start();
    if (mounted) setState(() => _recording = started);
  }

  Future<void> _transcribeAttachment(SecureAttachment attachment) async {
    if (widget.blobs == null || !TranscriptionService.isAvailable()) return;
    setState(() => _transcribing = true);

    try {
      final tempPath = await widget.blobs!.decryptAttachmentToTemp(
        _note.id,
        attachment,
      );
      if (!mounted || tempPath.isEmpty) {
        setState(() => _transcribing = false);
        return;
      }

      final text = await TranscriptionService.transcribeFile(tempPath);
      if (!mounted) return;

      if (text != null && text.isNotEmpty) {
        setState(() {
          _note = _note.copyWith(transcript: text);
          _transcribing = false;
        });
        _triggerAutoSave();
      } else {
        setState(() => _transcribing = false);
        if (mounted) {
          FloatingNotificationService.instance.show(
            'No speech detected in recording',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _transcribing = false);
        FloatingNotificationService.instance.show(
          'Transcription failed: $e',
        );
      }
    }
  }

  Future<void> _createSharePackage() async {
    if (widget.blobs == null) return;
    if (!mounted) return;

    final result = await SharePackageService.exportNote(
      _note,
      widget.blobs!,
      widget.blobs!.masterKey,
    );

    if (!mounted || result == null) {
      if (mounted) {
        FloatingNotificationService.instance.show('Failed to create share package');
      }
      return;
    }

    await SharePackageService.sharePackage(
      result.filePath,
      shareCode: result.shareCode,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Share code: ${result.shareCode}'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: result.shareCode));
              FloatingNotificationService.instance.show('Share code copied');
            },
          ),
        ),
      );
    }
  }

  // ✅ FIX: Lock screen shown when note is locked and not yet authenticated
  Widget _buildLockScreen() {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Secure note'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock,
                size: 64,
                color: _authFailed ? cs.error : cs.primary,
              ),
              const SizedBox(height: 24),
              Text(
                _authFailed ? 'Authentication failed' : 'This note is locked',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _authFailed
                    ? 'Please try again to access this note.'
                    : 'Authenticate with biometrics or PIN to unlock.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _authenticate,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock note'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Convert [[Note Title]] syntax to markdown links with a custom scheme.
  String _renderWikiLinks(String text) {
    return text.replaceAllMapped(
      RegExp(r'\[\[(.+?)\]\]'),
      (m) {
        final title = m.group(1)!.trim();
        final encoded = Uri.encodeComponent(title);
        return '[$title](vaultx-note://$encoded)';
      },
    );
  }

  /// Navigate to the note with the given title (if it exists in the vault).
  void _navigateToLinkedNote(String title) {
    final resolver = LinkResolver();
    resolver.rebuild(widget.allNotes);
    final targetId = resolver.resolve(title);
    
    if (targetId == null) {
      FloatingNotificationService.instance.show(
        'Note not found: $title',
        type: AppNotificationType.info,
      );
      return;
    }

    final targetNote = widget.allNotes.firstWhere((n) => n.id == targetId);
    
    // Open a new editor for the target note
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditor(
          note: targetNote,
          blobs: widget.blobs,
          allNotes: widget.allNotes,
          onAutoSave: widget.onAutoSave,
        ),
      ),
    );
  }

  Widget _buildRelatedNotes() {
    if (_relatedNotes.isEmpty && _backlinks.isEmpty) return const SizedBox.shrink();
    
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Row(
          children: [
            Icon(Icons.hub_outlined, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              'Related Notes & References',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_backlinks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Linked by:', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _backlinks.map((n) => ActionChip(
              avatar: const Icon(Icons.link, size: 14),
              label: Text(n.title.isEmpty ? 'Untitled' : n.title, style: const TextStyle(fontSize: 12)),
              onPressed: () => _navigateToLinkedNote(n.title),
              visualDensity: VisualDensity.compact,
            )).toList(),
          ),
          const SizedBox(height: 16),
        ],
        if (_relatedNotes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Suggested relations:', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _relatedNotes.length,
              itemBuilder: (ctx, i) {
                final n = _relatedNotes[i];
                return Container(
                  width: 160,
                  margin: const EdgeInsets.only(right: 12),
                  child: Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
                    ),
                    child: InkWell(
                      onTap: () => _navigateToLinkedNote(n.title),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              n.title.isEmpty ? 'Untitled' : n.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              n.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Show lock screen until authenticated
    if (_isLocked) return _buildLockScreen();

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          // Final save attempt when leaving
          _performAutoSave();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Secure note'),
            if (_isManualSaving || _isAutoSaving)
              Text(
                'Saving...',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 10,
                  height: 1,
                ),
              )
            else if (_hasUnsavedChanges)
              Text(
                'Unsaved changes',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 10,
                  height: 1,
                ),
              )
            else if (_lastSaved != null)
              Text(
                'Saved',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10,
                  height: 1,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: (_isManualSaving || _isAutoSaving) ? null : _manualSave,
            icon: _isManualSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            tooltip: 'Save note',
            color: _hasUnsavedChanges
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          IconButton(
            onPressed: () => setState(() => _isPreviewMode = !_isPreviewMode),
            icon: Icon(_isPreviewMode ? Icons.edit : Icons.preview),
            tooltip: _isPreviewMode ? 'Edit Mode' : 'Reading Mode',
          ),
          IconButton(
            onPressed: () => ClipboardGuard.copySensitive(_body.text),
            icon: const Icon(Icons.copy),
            tooltip: 'Copy and auto-clear',
          ),
          IconButton(
            onPressed: () =>
                setState(() => _note = _note.copyWith(pinned: !_note.pinned)),
            icon: Icon(_note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
          ),
          IconButton(
            onPressed: () => setState(
              () => _note = _note.copyWith(favorite: !_note.favorite),
            ),
            icon: Icon(_note.favorite ? Icons.star : Icons.star_outline),
          ),
          IconButton(
            onPressed: _createSharePackage,
            icon: const Icon(Icons.share),
            tooltip: 'Create encrypted share package',
          ),
          if (_note.versions.isNotEmpty)
            IconButton(
              onPressed: _showVersionHistory,
              icon: const Icon(Icons.history),
              tooltip: 'Version history',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          if (_sensitiveDetected)
            Card(
              color: Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.3),
              child: ListTile(
                leading: const Icon(Icons.privacy_tip),
                title: const Text('Sensitive content detected locally'),
                subtitle: const Text(
                  'Consider note lock, hidden vault, one-time view, or shorter expiry.',
                ),
                trailing: Switch(
                  value: _note.locked,
                  onChanged: (v) =>
                      setState(() => _note = _note.copyWith(locked: v)),
                ),
              ),
            ),
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _folder,
                  decoration: const InputDecoration(labelText: 'Folder'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _tags,
                  decoration: const InputDecoration(
                    labelText: 'Tags, comma separated',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ✅ FIX: Format toolbar always visible for all note types
          // ✅ FIX: Uses _FormatButton which fires onTapDown BEFORE focus loss
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FormatButton(
                icon: Icons.format_bold,
                tooltip: 'Bold (**text**)',
                onTap: () => _wrapSelection('**', '**'),
              ),
              _FormatButton(
                icon: Icons.format_italic,
                tooltip: 'Italic (_text_)',
                onTap: () => _wrapSelection('_', '_'),
              ),
              _FormatButton(
                icon: Icons.code,
                tooltip: 'Code (`text`)',
                onTap: () => _wrapSelection('`', '`'),
              ),
              _FormatButton(
                icon: Icons.format_list_bulleted,
                tooltip: 'Bullet list',
                onTap: _insertListItem,
              ),
            ],
          ),

          if (_note.type == NoteType.checklist) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => setState(
                () => _body.text =
                    '${_body.text}${_body.text.endsWith('\n') || _body.text.isEmpty ? '' : '\n'}- [ ] New item',
              ),
              icon: const Icon(Icons.add_task),
              label: const Text('Add checklist item'),
            ),
          ],
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 1,
                label: Text('High'),
                icon: Icon(Icons.priority_high),
              ),
              ButtonSegment(
                value: 2,
                label: Text('Normal'),
                icon: Icon(Icons.remove),
              ),
              ButtonSegment(
                value: 3,
                label: Text('Low'),
                icon: Icon(Icons.low_priority),
              ),
            ],
            selected: {_note.priority},
            onSelectionChanged: (v) =>
                setState(() => _note = _note.copyWith(priority: v.first)),
          ),
          const SizedBox(height: 12),
          // ✅ REMOVED: Incognito typing chip
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('Note lock'),
                selected: _note.locked,
                onSelected: (v) =>
                    setState(() => _note = _note.copyWith(locked: v)),
              ),
              FilterChip(
                label: const Text('One-time view'),
                selected: _note.oneTimeView,
                onSelected: (v) =>
                    setState(() => _note = _note.copyWith(oneTimeView: v)),
              ),
              _ExpiryChip(
                expiresAt: _note.expiresAt,
                onChange: (v) => setState(
                  () => _note = _note.copyWith(expiresAt: v),
                ),
              ),
              FilterChip(
                label: const Text('Include in backup'),
                selected: !_note.backupExcluded,
                onSelected: (v) =>
                    setState(() => _note = _note.copyWith(backupExcluded: !v)),
              ),
            ],
          ),
          if (_note.backupExcluded)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Stored only on this device',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (_isPreviewMode)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: MarkdownBody(
                data: _renderWikiLinks(_body.text),
                selectable: true,
                onTapLink: (text, href, title) {
                  if (href == null) return;
                  if (href.startsWith('vaultx-note://')) {
                    final titleEncoded = href.substring('vaultx-note://'.length);
                    final noteTitle = Uri.decodeComponent(titleEncoded);
                    _navigateToLinkedNote(noteTitle);
                  } else {
                    launchUrl(Uri.parse(href));
                  }
                },
                styleSheet: MarkdownStyleSheet(
                  p: Theme.of(context).textTheme.bodyMedium,
                  h1: Theme.of(context).textTheme.headlineMedium,
                  h2: Theme.of(context).textTheme.headlineSmall,
                  h3: Theme.of(context).textTheme.titleLarge,
                  listBullet: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          else
            TextField(
              controller: _body,
              focusNode: _bodyFocus, // ✅ FIX: track focus for selection saving
              minLines: 12,
              maxLines: 24,
              enableSuggestions: true, // ✅ REMOVED incognito
              autocorrect: true, // ✅ REMOVED incognito
              decoration: InputDecoration(
                labelText: switch (_note.type) {
                  NoteType.checklist => 'Checklist lines',
                  NoteType.voice => 'Voice note transcript',
                  NoteType.drawing => 'Drawing description',
                  _ => 'Encrypted note body',
                },
              ),
            ),
          
          _buildRelatedNotes(),

          if (_note.body.length >= 120) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          'Smart Summary',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const Spacer(),
                        if (_note.summary.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => setState(
                              () => _note = _note.copyWith(summary: ''),
                            ),
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Regenerate'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_note.summary.isNotEmpty)
                      SelectableText(
                        _note.summary,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () {
                          final s = SummarizationService.summarize(
                            _body.text,
                          );
                          if (s.isNotEmpty) {
                            setState(() {
                              _note = _note.copyWith(summary: s);
                            });
                            _triggerAutoSave();
                          }
                        },
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('Generate summary'),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addAttachment,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Attach encrypted file'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _toggleRecording,
                  icon: Icon(_recording ? Icons.stop : Icons.mic),
                  label: Text(_recording ? 'Stop recording' : 'Record voice'),
                ),
              ),
            ],
          ),
          if (TranscriptionService.isAvailable())
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilterChip(
                label: const Text('Transcribe after recording'),
                selected: _usePcm,
                onSelected: (v) => setState(() => _usePcm = v),
              ),
            ),
          if (_note.attachments.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Encrypted attachments',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            ..._note.attachments.map(
              (a) => Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (a.kind == 'image')
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: _ImagePreview(
                            blobs: widget.blobs,
                            noteId: _note.id,
                            attachment: a,
                          ),
                        ),
                      ),
                    ListTile(
                      leading: Icon(
                        a.kind == 'voice'
                            ? Icons.graphic_eq
                            : a.kind == 'image'
                            ? Icons.image
                            : Icons.attach_file,
                      ),
                      title: Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${a.kind}  ${(a.size / 1024).toStringAsFixed(1)} KB',
                      ),
                      trailing: SizedBox(
                        width: a.kind == 'voice' ? 144 : 96,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                          if (a.kind == 'voice')
                            IconButton(
                              icon: Icon(
                                _playingAttachmentId == a.id && _isAudioPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                              onPressed: () => _playVoiceAttachment(a),
                              tooltip: 'Play recording',
                            ),
                          IconButton(
                            icon: const Icon(Icons.file_open),
                            onPressed: () => _exportAttachment(a),
                            tooltip: 'Open file',
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              if (_playingAttachmentId == a.id) _disposeAudio();
                              setState(
                                () => _note = _note.copyWith(
                                  attachments: _note.attachments
                                      .where((x) => x.id != a.id)
                                      .toList(),
                                ),
                              );
                            },
                          ),
                          ],
                        ),
                      ),
                    ),
                    if (_playingAttachmentId == a.id && a.kind == 'voice')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          children: [
                            Slider(
                              value: _audioDuration.inMilliseconds > 0
                                  ? _audioPosition.inMilliseconds /
                                        _audioDuration.inMilliseconds
                                  : 0,
                              onChanged: _seekTo,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(_audioPosition),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                Text(
                                  _formatDuration(_audioDuration),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (_note.attachments.any((a) => a.kind == 'voice')) ...[
            const SizedBox(height: 8),
            Text('Transcription', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            if (_transcribing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Transcribing...', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            if (_note.transcript.isNotEmpty && !_transcribing) ...[
              TextField(
                readOnly: true,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Transcript',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(8),
                ),
                controller: TextEditingController(text: _note.transcript),
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _body.text = _body.text.isEmpty ? _note.transcript : '${_body.text}\n\n--- Transcript ---\n${_note.transcript}';
                  });
                },
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy to body'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
            if (_note.transcript.isEmpty && !_transcribing && TranscriptionService.isAvailable())
              OutlinedButton.icon(
                onPressed: () {
                  final v = _note.attachments.firstWhere((a) => a.kind == 'voice');
                  _transcribeAttachment(v);
                },
                icon: const Icon(Icons.transcribe, size: 16),
                label: const Text('Transcribe'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
          ],
          if (_hasImageAttachments || _ocrText.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('OCR', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            if (_ocrJobIds != null)
              OcrQueueIndicator(
                service: _queueService,
                onResults: (jobs) {
                  final texts = jobs.where((j) => j.result != null).map((j) => j.result).join('\n\n');
                  if (texts.isNotEmpty) _ocrText.text = texts;
                  setState(() => _ocrJobIds = null);
                },
              ),
            if (_hasImageAttachments && _ocrJobIds == null)
              OutlinedButton.icon(
                onPressed: _enqueueOcrJobs,
                icon: const Icon(Icons.text_snippet, size: 16),
                label: const Text('Extract Text'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            if (_ocrText.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _ocrText,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Extracted text',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(8),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _body.text = _body.text.isEmpty ? _ocrText.text : '${_body.text}\n\n--- OCR ---\n${_ocrText.text}';
                      },
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy to body'),
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                  ),
                  IconButton(
                    onPressed: () { _ocrText.clear(); setState(() {}); },
                    icon: const Icon(Icons.clear, size: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ],
          if (_note.versions.isNotEmpty)
            ExpansionTile(
              leading: const Icon(Icons.history),
              title: Text('Version history (${_note.versions.length})'),
              children: _note.versions.reversed
                  .take(5)
                  .map(
                    (v) => ListTile(
                      title: Text(v['title']?.toString() ?? 'Untitled'),
                      subtitle: Text(v['at']?.toString() ?? ''),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    ),
    );
  }
}

/// ✅ KEY FIX: Custom format button that uses [onTapDown] instead of [onPressed].
/// onTapDown fires BEFORE the TextField loses focus, so _savedSelection
/// still contains the user's cursor/selection when _wrapSelection runs.
/// Regular IconButton uses onPressed which fires AFTER focus is lost — too late.
class _FormatButton extends StatelessWidget {
  const _FormatButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTapDown: (_) =>
              onTap(), // fires before focus loss — this is the fix
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet showing note version history.
class _VersionHistorySheet extends StatelessWidget {
  const _VersionHistorySheet({required this.versions, required this.onRestore});
  final List<Map<String, dynamic>> versions;
  final void Function(Map<String, dynamic> snapshot) onRestore;

  @override
  Widget build(BuildContext context) {
    final reversed = versions.reversed.toList();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      'Version History',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${reversed.length} of 20',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: reversed.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final v = reversed[i];
                    final ts =
                        v['updatedAt'] as String? ?? v['at'] as String? ?? '';
                    final title = v['title'] as String? ?? '';
                    final body = v['body'] as String? ?? '';
                    final dt = DateTime.tryParse(ts);
                    final timeStr = dt?.toLocal().toString() ?? ts;

                    return Card(
                      child: ListTile(
                        title: Text(
                          title.isEmpty ? 'Untitled' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              timeStr,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                            if (body.isNotEmpty)
                              Text(
                                body.length > 120
                                    ? '${body.substring(0, 120)}\u2026'
                                    : body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                        trailing: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 128),
                          child: FilledButton.tonalIcon(
                            onPressed: () => onRestore(v),
                            icon: const Icon(Icons.restore, size: 16),
                            label: const Text('Restore'),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Self-destruct expiry chip with preset durations and custom date picker.
class _ExpiryChip extends StatelessWidget {
  const _ExpiryChip({required this.expiresAt, required this.onChange});
  final DateTime? expiresAt;
  final ValueChanged<DateTime?> onChange;

  static final _presets = <Duration, String>{
    const Duration(hours: 1): '1h',
    const Duration(hours: 6): '6h',
    const Duration(hours: 24): '24h',
    const Duration(days: 2): '2d',
    const Duration(days: 7): '7d',
    const Duration(days: 30): '30d',
  };

  String? _remainingLabel(DateTime expiry) {
    final remaining = expiry.difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';
    if (remaining.inDays > 0) return '${remaining.inDays}d ${remaining.inHours % 24}h';
    if (remaining.inHours > 0) return '${remaining.inHours}h ${remaining.inMinutes % 60}m';
    return '${remaining.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (expiresAt != null) {
      return ActionChip(
        avatar: Icon(Icons.timer, size: 16, color: cs.error),
        label: Text(_remainingLabel(expiresAt!) ?? ''),
        onPressed: () => onChange(null),
      );
    }

    return PopupMenuButton<Duration>(
      onSelected: (d) {
        if (d == const Duration()) {
          _pickCustom(context);
        } else {
          onChange(DateTime.now().add(d));
        }
      },
      itemBuilder: (_) => [
        ..._presets.entries.map(
          (e) => PopupMenuItem(
            value: e.key,
            child: Text('Self-destruct ${e.value}'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: Duration(),
          child: ListTile(
            leading: Icon(Icons.calendar_today),
            title: Text('Custom date/time'),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
      ],
      child: Chip(
        avatar: Icon(Icons.timer_outlined, size: 16, color: cs.onSurfaceVariant),
        label: const Text('Self-destruct'),
      ),
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !context.mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !context.mounted) return;

    onChange(DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }
}


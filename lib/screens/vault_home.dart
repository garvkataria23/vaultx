import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vaultx/l10n/app_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../services/auth_session_manager.dart';
import '../widgets/widgets.dart';
import '../widgets/note_views_renderer.dart';
import 'archive_screen.dart';
import 'drive_screen.dart';
import 'note_editor.dart';
import 'settings_screen.dart';
import 'decoy_calculator_screen.dart';
import 'game_screen.dart';
import 'smart_view_screen.dart';
import 'smart_vault_screen.dart';

const _kPageSize = 50;

/// Main home screen after authentication.
class VaultHome extends StatefulWidget {
  const VaultHome({super.key, required this.auth, required this.authResult});
  final VaultAuthService auth;
  final AuthResult authResult;

  @override
  State<VaultHome> createState() => _VaultHomeState();
}

class _VaultHomeState extends State<VaultHome> with WidgetsBindingObserver {
  VaultRepository? _repo;
  EncryptedBlobService? _blobs;
  DriveService? _drive;
  TrashService? _trash;
  PasswordVaultService? _passwordVault;
  ItemActionService? _itemActions;
  List<SecureNote> _notes = [];
  bool _loadingNotes = false;
  String _query = '';
  String _folder = 'All';
  String _sort = 'date';
  int _index = 0;
  Timer? _lockTimer;
  DateTime? _backgroundedAt;
  Map<String, dynamic> _posture = {};
  List<SecureNote> _filteredNotes = [];
  int _searchGeneration = 0;
  final _visibleCount = ValueNotifier<int>(_kPageSize);
  int _archivedCount = 0;
  bool _hasHiddenVault = false;
  Map<String, SecureDriveFolder> _folderMetadata = {};
  final Set<String> _sessionUnlockedFolders = {};
  bool _isHoldingLock = false;
  Timer? _lockHoldTimer;
  double _lockHoldProgress = 0.0;
  late PageController _pageController;

  late NoteViewMode _viewMode;

  final Set<String> _selectedIds = {};

  final _searchService = SearchService();
  SearchFilters _searchFilters = const SearchFilters();
  Map<String, String> _noteCategories = {};
  List<String> _cachedAvailableCategories = [];
  List<String> _cachedFolders = ['All'];
  List<String> _searchSuggestions = [];
  Set<FilterChipType> _activeFilterTypes = {};
  VoidCallback? _restoreListener;

  @override
  void initState() {
    super.initState();
    final savedMode = Hive.box('vaultx_settings').get('viewMode', defaultValue: 'list') as String;
    if (savedMode == 'grid') {
      Hive.box('vaultx_settings').delete('viewMode');
      _viewMode = NoteViewMode.list;
    } else {
      _viewMode = NoteViewMode.values.firstWhere((e) => e.name == savedMode, orElse: () => NoteViewMode.list);
    }
    _pageController = PageController(initialPage: _index);
    WidgetsBinding.instance.addObserver(this);
    widget.auth.isHiddenVaultConfigured().then((v) {
      if (mounted) setState(() => _hasHiddenVault = v);
    });
    if (widget.authResult.kind != VaultKind.decoy) {
      _repo = VaultRepository(
        widget.authResult.masterKey!,
        widget.authResult.kind,
      );
      _blobs = EncryptedBlobService(widget.authResult.masterKey!);
      _drive = DriveService(
        widget.authResult.masterKey!,
        widget.authResult.kind,
      );
      _passwordVault = PasswordVaultService(
        widget.authResult.masterKey!,
        widget.authResult.kind,
      );
      context.read<PasswordManagerProvider>().initialize(_passwordVault!);
      _itemActions = ItemActionService(        repo: _repo!,
        drive: _drive!,
        masterKey: widget.authResult.masterKey!,
      );
      _trash = TrashService(
        repo: _repo!,
        drive: _drive!,
        passwords: _passwordVault!,
        vaultKind: widget.authResult.kind,
      );
      Future.microtask(() => _trash!.autoCleanup());
      Future.microtask(() => BrowserExtensionService.instance.start(_passwordVault!));
    }
    DeadMansService.resetTimer();
    Future.microtask(() {
      if (!mounted) return;
      PasswordMemoryService.checkAndShow(context, widget.auth);
    });
    _load();
    _restoreListener = () {
      debugPrint('[VaultHome] Restore completed — reloading all data');
      _load();
    };
    RestoreService.restoreCompleted.addListener(_restoreListener!);
    _resetLockTimer();
    SecurityPlatform.devicePosture().then((v) {
      if (!mounted) return;
      setState(() => _posture = v);
      if (v['rooted'] == true || v['debuggable'] == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          FloatingNotificationService.instance.show(
            'Device risk detected. Review security settings before storing sensitive notes.',
            type: AppNotificationType.warning,
            persistent: true,
          );
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_restoreListener != null) {
      RestoreService.restoreCompleted.removeListener(_restoreListener!);
    }
    SmartOcrScanner.stop();
    _lockTimer?.cancel();
    _lockHoldTimer?.cancel();
    _searchService.dispose();
    _visibleCount.dispose();
    _pageController.dispose();
    EncryptedBlobService.cleanupTempExports();
    DriveService.cleanupTempExports();
    BrowserExtensionService.instance.stop();
    _wipeSessionKey();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
      if (SecurityPlatform.isSensitiveOperationActive) {
        _lockNow();
      }
    } else if (state == AppLifecycleState.resumed) {
      final now = DateTime.now();
      final lockMinutes =
          Hive.box('vaultx_settings').get('lockMinutes', defaultValue: 1)
              as int;
      if (_backgroundedAt != null &&
          now.difference(_backgroundedAt!) > Duration(minutes: lockMinutes)) {
        _lockNow();
      }
      _backgroundedAt = null;
    }
  }

  Future<void> _load() async {
    StartupDiagnostics.instance.markNotesLoaded();
    if (widget.authResult.kind == VaultKind.decoy) {
      final notes = await DecoySeedService.loadNotes();
      if (mounted) {
        setState(() {
          _notes = notes;
          _cachedFolders = ['All', ...{for (final n in notes) n.folder}];
          _folderMetadata = {};
        });
        _computeCategoriesAsync(notes);
        _buildSearchSuggestionsAsync(notes);
        _archivedCount = notes.where((n) => n.archived).length;
        _runSearch();
      }
      return;
    }
    if (mounted) setState(() => _loadingNotes = true);
    Future.microtask(() async {
      if (!mounted) return;
      final sw = Stopwatch()..start();
      try {
        // Single decryption batch — onProgress not needed since all notes
        // arrive at once. Skeleton cards are shown until this completes.
        final finalNotes = await _repo!.loadNotes();

        debugPrint("Load notes completed in ${sw.elapsedMilliseconds} ms");

        sw.reset();
        final metadata = await _repo!.loadFolderMetadata();
        debugPrint("Load folder metadata took ${sw.elapsedMilliseconds} ms");

        if (mounted) {
          sw.reset();
          setState(() {
            _loadingNotes = false;
            _notes = finalNotes;
            _cachedFolders = ['All', ...{for (final n in finalNotes) n.folder}];
            _folderMetadata = { for (final f in metadata) f.name : f };
          });
          _computeCategoriesAsync(finalNotes);
          _buildSearchSuggestionsAsync(finalNotes);
          _archivedCount = finalNotes.where((n) => n.archived).length;
          if (_passwordVault != null) {
            _loadArchivedCountAsync();
          }
          await _runSearch();
          debugPrint("UI state update and search prep took ${sw.elapsedMilliseconds} ms");

          if (_blobs != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              SmartOcrScanner.start(_repo!, _blobs!);
              StartupDiagnostics.instance.markAiReady();
            });
          }
        }
      } catch (e) {
        debugPrint('Failed to load notes: $e');
        if (mounted) setState(() => _loadingNotes = false);
      }
    });
    StartupDiagnostics.instance.markFirstFrame();
    StartupDiagnostics.instance.report();
  }

  void _computeCategoriesAsync(List<SecureNote> notes) {
    if (notes.isEmpty) return;
    _searchService.getCategoriesAsync(notes).then((cats) {
      if (!mounted) return;
      _noteCategories = {};
      _cachedAvailableCategories = [];
      for (final entry in cats.entries) {
        _cachedAvailableCategories.add(entry.key.name);
        for (final note in entry.value) {
          _noteCategories[note.id] = entry.key.name;
        }
      }
      // Trigger a silent rebuild if needed, but categories are usually just for filters
    });
  }

  void _buildSearchSuggestionsAsync(List<SecureNote> notes) {
    if (notes.isEmpty) return;
    _searchService.getSuggestionsAsync(notes).then((suggestions) {
      if (!mounted) return;
      setState(() => _searchSuggestions = suggestions);
    });
  }

  void _loadArchivedCountAsync() {
    _passwordVault!.archivedCount().then((c) {
      if (mounted) setState(() => _archivedCount += c);
      StartupDiagnostics.instance.markPasswordsLoaded();
    });
  }

  void _computeCategories() {
    final cats = _searchService.getCategories(_notes);
    _noteCategories = {};
    _cachedAvailableCategories = [];
    for (final entry in cats.entries) {
      _cachedAvailableCategories.add(entry.key.name);
      for (final note in entry.value) {
        _noteCategories[note.id] = entry.key.name;
      }
    }
  }

  List<String> get _availableCategories => _cachedAvailableCategories;

  List<SecureNote> get _activeNotes =>
      _notes.where((n) => !n.archived).toList();

  Future<void> _runSearch() async {
    if (_notes.isEmpty) {
      if (mounted) setState(() => _filteredNotes = []);
      return;
    }

    bool isFolderAccessible(String folderName) {
      final meta = _folderMetadata[folderName];
      if (meta == null || !meta.isLocked) return true;
      return _sessionUnlockedFolders.contains(folderName);
    }

    final source = _activeNotes.where((n) => isFolderAccessible(n.folder)).toList();
    final query = _query;
    final folder = _folder;
    final filters = _searchFilters.copyWith(
      query: query,
      folder: folder == 'All' ? null : folder,
      sort: _sort,
    );
    final gen = ++_searchGeneration;

    final noFilters = query.isEmpty &&
        filters.noteType == null &&
        filters.folder == null &&
        filters.pinned == null &&
        filters.favorite == null &&
        filters.hasAttachments == null &&
        filters.category == null;

    if (noFilters) {
      if (mounted) {
        setState(() {
          _filteredNotes = source;
          _visibleCount.value = _kPageSize;
        });
      }
      return;
    }

    final results = await _searchService.searchAsync(source, filters);
    if (mounted && gen == _searchGeneration) {
      setState(() {
        _filteredNotes = results.map((m) => m.note).toList();
        _visibleCount.value = _kPageSize;
      });
    }
  }

  void _onSelectionToggle(SecureNote note) {
    setState(() {
      if (_selectedIds.contains(note.id)) {
        _selectedIds.remove(note.id);
      } else {
        _selectedIds.add(note.id);
      }
    });
  }

  void _selectBatch(int count) {
    setState(() {
      final toSelect = _filteredNotes.take(count);
      for (final n in toSelect) {
        _selectedIds.add(n.id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      for (final n in _filteredNotes) {
        _selectedIds.add(n.id);
      }
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedIds.clear();
    });
  }

  Future<void> _bulkAction(String action) async {
    final selectedNotes = _notes.where((n) => _selectedIds.contains(n.id)).toList();
    if (selectedNotes.isEmpty) return;

    final ok = await _authenticateForAction('Bulk $action');
    if (!ok) return;

    switch (action) {
      case 'delete':
        for (final n in selectedNotes) {
          if (widget.authResult.kind == VaultKind.decoy) {
            await DecoySeedService.deleteNote(n.id);
          } else {
            await _repo!.moveToTrash(n);
          }
        }
        FloatingNotificationService.instance.show('${selectedNotes.length} notes moved to trash');
        break;
      case 'archive':
        for (final n in selectedNotes) {
          if (widget.authResult.kind != VaultKind.decoy) {
            await _repo!.save(n.copyWith(archived: true));
          }
        }
        FloatingNotificationService.instance.show('${selectedNotes.length} notes archived');
        break;
      case 'favorite':
        for (final n in selectedNotes) {
          if (widget.authResult.kind == VaultKind.decoy) {
            await DecoySeedService.saveNote(n.copyWith(favorite: true));
          } else {
            await _repo!.save(n.copyWith(favorite: true));
          }
        }
        break;
      case 'restore':
        for (final n in selectedNotes) {
          if (widget.authResult.kind != VaultKind.decoy) {
            await _repo!.save(n.copyWith(archived: false, deleted: false));
          }
        }
        FloatingNotificationService.instance.show('${selectedNotes.length} notes restored');
        break;
    }

    if (!mounted) return;
    _deselectAll();
    await _load();
  }

  void _startLockHold() {
    _lockHoldTimer?.cancel();
    setState(() {
      _isHoldingLock = true;
      _lockHoldProgress = 0.0;
    });

    const tick = Duration(milliseconds: 100);
    _lockHoldTimer = Timer.periodic(tick, (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _lockHoldProgress += 0.1 / 7.0;
      });

      if (_lockHoldProgress >= 1.0) {
        t.cancel();
        _activateDecoyMode();
      }
    });
  }

  void _cancelLockHold() {
    if (!_isHoldingLock) return;
    _lockHoldTimer?.cancel();
    setState(() {
      _isHoldingLock = false;
      _lockHoldProgress = 0.0;
    });
  }

  Future<void> _activateDecoyMode() async {
    HapticFeedback.vibrate();
    await Hive.box('vaultx_settings').put('decoyCalculatorEnabled', true);
    _wipeSessionKey();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => DecoyCalculatorScreen(auth: widget.auth),
      ),
      (_) => false,
    );
  }

  void _resetLockTimer() {
    _lockTimer?.cancel();
    final minutes = Hive.box('vaultx_settings').get('lockMinutes', defaultValue: 1) as int;
    _lockTimer = Timer(Duration(minutes: minutes), () {
      if (mounted) _lockNow();
    });
  }

  void _lockNow() {
    _backgroundedAt = null;
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    ClipboardGuard.clearNow();
    FloatingNotificationService.instance.clear();
    AuthSessionManager.instance.lock();
    // Key cleanup happens in dispose() via _wipeSessionKey
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _switchVault(VaultKind target) async {
    if (target == widget.authResult.kind) return;

    AuthResult? result;
    final appState = context.read<VaultAppState>();

    if (target == VaultKind.main) {
      final bioAvailable = await widget.auth.isBiometricUnlockAvailable();
      if (bioAvailable && !appState.isBiometricEscalated) {
        result = await widget.auth.unlockWithBiometric();
        result = await widget.auth.verify(result);
        if (result.ok) {
          appState.resetBiometricAttempts();
        } else if (result.error != null && !result.error!.contains('cancelled')) {
          await appState.recordFailedBiometricAttempt();
        }
      }

      if (result == null || !result.ok) {
        if (!mounted) return;
        final password = await _showPasswordDialog(
          title: 'Switch to Main Vault',
          label: 'Master password',
        );
        if (password != null) {
          result = await widget.auth.unlockWithPassword(password);
          result = await widget.auth.verify(result);
          if (result.ok) {
            appState.resetBiometricAttempts();
            appState.resetPinAttempts();
          }
        }
      }
    } else if (target == VaultKind.hidden) {
      final password = await _showPasswordDialog(
        title: 'Switch to Hidden Vault',
        label: 'Hidden password',
      );
      if (password != null) {
        result = await widget.auth.unlockHidden(password);
        result = await widget.auth.verify(result);
        if (result.ok) {
          appState.resetBiometricAttempts();
          appState.resetPinAttempts();
        }
      }
    }

    if (result != null && result.ok) {
      _wipeSessionKey();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => VaultHome(
            auth: widget.auth,
            authResult: result!,
          ),
          transitionDuration: const Duration(milliseconds: 400),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    } else if (result != null && !result.ok) {
      FloatingNotificationService.instance.show(result.error ?? 'Authentication failed', error: true);
    }
  }

  Future<String?> _showPasswordDialog({
    required String title,
    required String label,
  }) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PasswordVerifyDialog(
        title: title,
        labelText: label,
        buttonText: 'Unlock',
      ),
    );
  }

  Set<FilterChipType> _updateActiveFilters() {
    final types = <FilterChipType>{};
    if (_searchFilters.noteType != null) types.add(FilterChipType.type);
    if (_searchFilters.category != null) types.add(FilterChipType.category);
    if (_searchFilters.pinned != null) types.add(FilterChipType.pinned);
    if (_searchFilters.favorite != null) types.add(FilterChipType.favorite);
    if (_searchFilters.hasAttachments != null) {
      types.add(FilterChipType.attachments);
    }
    return types;
  }

  void _showHomeFilterSheet() {
    final folders = _cachedFolders.where((f) => f != 'All').toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _HomeFilterSheet(
        noteType: _searchFilters.noteType,
        folder: _searchFilters.folder,
        sort: _searchFilters.sort ?? 'date',
        category: _searchFilters.category,
        pinned: _searchFilters.pinned,
        favorite: _searchFilters.favorite,
        hasAttachments: _searchFilters.hasAttachments,
        folders: folders,
        categories: _availableCategories,
        onApply: (type, folder, sort, category, pinned, favorite, attachments) {
          setState(() {
            _searchFilters = _searchFilters.copyWith(
              noteType: type,
              folder: folder,
              sort: sort,
              category: category,
              pinned: pinned,
              favorite: favorite,
              hasAttachments: attachments,
            );
            _folder = folder ?? 'All';
            _sort = sort ?? 'date';
            _activeFilterTypes = _updateActiveFilters();
          });
          Navigator.of(ctx).pop();
          _runSearch();
        },
        onReset: () {
          setState(() {
            _searchFilters = const SearchFilters();
            _folder = 'All';
            _sort = 'date';
            _activeFilterTypes = {};
          });
          Navigator.of(ctx).pop();
          _runSearch();
        },
      ),
    );
  }

  void _wipeSessionKey() {
    final key = widget.authResult.masterKey;
    if (key != null && widget.authResult.kind != VaultKind.decoy) {
      CryptoService().wipe(key);
    }
  }

  Future<void> _saveNote(SecureNote edited, SecureNote? original) async {
    final isDecoy = widget.authResult.kind == VaultKind.decoy;
    List<Map<String, dynamic>> versions = edited.versions;
    if (original != null && !isDecoy) {
      final changed = edited.title != original.title || edited.body != original.body;
      if (changed) {
        bool shouldAddVersion = true;
        if (original.versions.isNotEmpty) {
          final lastVer = original.versions.last;
          final lastAt = DateTime.tryParse(lastVer['updatedAt'] as String? ?? '');
          if (lastAt != null && DateTime.now().difference(lastAt).inMinutes < 5) {
            shouldAddVersion = false;
          }
        }
        if (shouldAddVersion) {
          versions = [
            ...original.versions,
            {...original.toJson(), 'updatedAt': DateTime.now().toIso8601String()},
          ].take(20).toList();
        }
      }
    }

    if (isDecoy) {
      await DecoySeedService.saveNote(edited.copyWith(versions: versions));
    } else {
      await _repo!.save(edited.copyWith(versions: versions));
    }
  }

  Future<void> _openEditor([SecureNote? note]) async {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (note != null) {
      await NavigationService.openNote(
        context: context,
        note: note,
        repo: _repo,
        blobs: _blobs,
        allNotes: _notes,
        isDecoy: widget.authResult.kind == VaultKind.decoy,
        onSave: (edited) => _saveNote(edited, note),
      );
    } else {
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => NoteEditor(
            note: null,
            blobs: _blobs,
            allNotes: _notes,
            onAutoSave: (edited) => _saveNote(edited, null),
          ),
        ),
      );
    }
    if (mounted) await _load();
  }

  Future<bool> _authenticateForAction(String title) async {
    await SecurityPlatform.enableScreenProtection();
    final bioEnabled = await widget.auth.isBiometricUnlockAvailable();
    if (bioEnabled) {
      final ok = await widget.auth.authenticateBiometric();
      if (ok) return true;
    }

    if (!mounted) return false;
    
    final secret = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => PasswordVerifyDialog(
        title: title,
        description: 'Enter your ${widget.authResult.kind == VaultKind.hidden ? 'hidden vault' : widget.authResult.kind == VaultKind.decoy ? 'decoy' : 'master'} password to continue.',
        labelText: widget.authResult.kind == VaultKind.hidden
            ? 'Hidden vault password'
            : widget.authResult.kind == VaultKind.decoy
                ? 'Decoy password'
                : 'Master password',
        buttonText: 'Verify',
      ),
    );

    if (secret == null || secret.isEmpty) return false;
    if (!mounted) return false;

    bool success = false;
    if (widget.authResult.kind == VaultKind.decoy) {
      success = await widget.auth.verifyDecoyPassword(secret);
    } else {
      var result = widget.authResult.kind == VaultKind.hidden
          ? await widget.auth.unlockHidden(secret)
          : await widget.auth.unlockWithPassword(secret);
      result = await widget.auth.verify(result);
      success = result.ok && result.kind == widget.authResult.kind;
    }

    if (!success && mounted) {
      FloatingNotificationService.instance.show('Authentication failed: Invalid password', error: true);
    }
    return success;
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
  }

  void _onDestinationSelected(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final folders = _cachedFolders;
    final isSelectionMode = _selectedIds.isNotEmpty;
    final l10n = AppLocalizations.of(context)!;

    return PopScope(
      canPop: _index == 0 && !isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isSelectionMode) {
          _deselectAll();
          return;
        }
        if (_index != 0) {
          _onDestinationSelected(0);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanDown: (_) => _resetLockTimer(),
        child: Scaffold(
          appBar: AppBar(
            leading: isSelectionMode 
                ? IconButton(onPressed: _deselectAll, icon: const Icon(Icons.close))
                : null,
            title: isSelectionMode 
                ? Text('${_selectedIds.length} selected')
                : _VaultSwitcher(
                    currentKind: widget.authResult.kind,
                    hasHidden: _hasHiddenVault,
                    onSwitch: _switchVault,
                  ),
            actions: [
              if (isSelectionMode) ...[
                IconButton(onPressed: () => _bulkAction('favorite'), icon: const Icon(Icons.star_outline)),
                IconButton(onPressed: () => _bulkAction('archive'), icon: const Icon(Icons.archive_outlined)),
                IconButton(onPressed: () => _bulkAction('delete'), icon: const Icon(Icons.delete_outline)),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'select_50') _selectBatch(50);
                    if (v == 'select_next_50') _selectBatch(_selectedIds.length + 50);
                    if (v == 'select_100') _selectBatch(100);
                    if (v == 'select_all') _selectAll();
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: 'select_50', child: Text('Select 50')),
                    const PopupMenuItem(value: 'select_next_50', child: Text('Select next 50')),
                    const PopupMenuItem(value: 'select_100', child: Text('Select 100')),
                    const PopupMenuItem(value: 'select_all', child: Text('Select all')),
                  ],
                ),
              ] else ...[
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh all notes',
                ),
                Stack(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.filter_list),
                      onPressed: _showHomeFilterSheet,
                      tooltip: 'Filters',
                    ),
                    if (_activeFilterTypes.isNotEmpty)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: _lockNow,
                    onLongPressStart: (_) => _startLockHold(),
                    onLongPressEnd: (_) => _cancelLockHold(),
                    onLongPressCancel: () => _cancelLockHold(),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (_isHoldingLock)
                          SizedBox(
                            width: 42,
                            height: 42,
                            child: CircularProgressIndicator(
                              value: _lockHoldProgress,
                              strokeWidth: 3,
                              color: Theme.of(context).colorScheme.error,
                              backgroundColor: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
                            ),
                          ),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _isHoldingLock 
                                ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.2)
                                : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.emergency_share,
                            color: _isHoldingLock 
                                ? Theme.of(context).colorScheme.error 
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          body: Column(
            children: [
              SelectionBanner(
                selectedCount: _selectedIds.length,
                totalCount: _filteredNotes.length,
                onSelectAll: _selectAll,
                onClear: _deselectAll,
                itemName: 'notes',
              ),
              Expanded(
                child: RepaintBoundary(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    physics: isSelectionMode ? const NeverScrollableScrollPhysics() : null,
                    children: [
                      _NotesTabWrapper(child: _buildNotesTab(folders)),
                      DriveScreen(
                        auth: widget.auth,
                        drive: _drive,
                        passwordVault: _passwordVault,
                        itemActions: _itemActions,
                        isDecoy: widget.authResult.kind == VaultKind.decoy,
                      ),
                      SettingsScreen(
                        auth: widget.auth,
                        repo: widget.authResult.kind == VaultKind.decoy ? null : _repo,
                        posture: _posture,
                        onDataChanged: _load,
                        vaultKind: widget.authResult.kind,
                        onSwitchVault: _switchVault,
                        trashService: _trash,
                        onGoHome: () => _onDestinationSelected(0),
                      ),
                      const VaultXGameScreen(),
                    ],
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: (_index == 0 && !isSelectionMode)
              ? FloatingActionButton.extended(
                  heroTag: 'mainVaultFab',
                  onPressed: () async {
                    final type = await showModalBottomSheet<NoteType>(
                      context: context,
                      builder: (_) => const NoteTypePicker(),
                    );
                    if (type != null) {
                      if (widget.authResult.kind == VaultKind.decoy) {
                        _openEditor(await DecoySeedService.createBlank());
                      } else {
                        _openEditor(await _repo!.createBlank(type));
                      }
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New'),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _onDestinationSelected,
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.dashboard_outlined),
                selectedIcon: const Icon(Icons.dashboard),
                label: l10n.home,
              ),
              NavigationDestination(
                icon: const Icon(Icons.folder_outlined),
                selectedIcon: const Icon(Icons.folder),
                label: l10n.drive,
              ),
              NavigationDestination(
                icon: const Icon(Icons.shield_outlined),
                selectedIcon: const Icon(Icons.shield),
                label: l10n.security,
              ),
              NavigationDestination(
                icon: const Icon(Icons.sports_esports_outlined),
                selectedIcon: const Icon(Icons.sports_esports),
                label: l10n.game,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotesTab(List<String> folders) {
    final filtered = _filteredNotes;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: SmartSearchBar(
                  onChanged: (v) {
                    _searchService.cancelDebounce();
                    _searchService.debouncedSearch(v, () {
                      if (mounted) {
                        setState(() => _query = v);
                        _runSearch();
                      }
                    });
                  },
                  suggestions: _searchSuggestions,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SmartViewScreen(
                        notes: _notes,
                        repo: _repo,
                        blobs: _blobs,
                        vaultKind: widget.authResult.kind,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.auto_awesome),
                tooltip: 'Smart View',
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => Dialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: ViewSwitcherSheet(
                          currentMode: _viewMode,
                          onModeSelected: (mode) {
                            setState(() => _viewMode = mode);
                            Hive.box('vaultx_settings').put('viewMode', mode.name);
                          },
                        ),
                      ),
                    ),
                  );
                },
                icon: Icon(noteViewIcons[_viewMode]),
                tooltip: 'Change view layout',
              ),
            ],
          ),
        ),
        SearchFiltersBar(
          activeFilters: _activeFilterTypes,
          selectedType: _searchFilters.noteType?.name,
          selectedFolder: _searchFilters.folder,
          selectedSort: _searchFilters.sort,
          selectedCategory: _searchFilters.category,
          selectedPinned: _searchFilters.pinned,
          selectedFavorite: _searchFilters.favorite,
          selectedAttachments: _searchFilters.hasAttachments,
          folders: folders.where((f) => f != 'All').toList(),
          categories: _availableCategories,
          onFilterChanged: (type, value) {
            setState(() {
              switch (type) {
                case FilterChipType.type:
                  _searchFilters = _searchFilters.copyWith(
                    noteType: value != null
                        ? NoteType.values.byName(value as String)
                        : null,
                  );
                case FilterChipType.folder:
                  _folder = value as String? ?? 'All';
                  _searchFilters = _searchFilters.copyWith(
                    folder: _folder == 'All' ? null : _folder,
                  );
                case FilterChipType.sort:
                  _sort = value as String? ?? 'date';
                  _searchFilters = _searchFilters.copyWith(sort: _sort);
                case FilterChipType.category:
                  _searchFilters = _searchFilters.copyWith(
                    category: value as String?,
                  );
                case FilterChipType.pinned:
                  _searchFilters = _searchFilters.copyWith(
                    pinned: value as bool?,
                  );
                case FilterChipType.favorite:
                  _searchFilters = _searchFilters.copyWith(
                    favorite: value as bool?,
                  );
                case FilterChipType.attachments:
                  _searchFilters = _searchFilters.copyWith(
                    hasAttachments: value as bool?,
                  );
              }
              _activeFilterTypes = _updateActiveFilters();
            });
            _runSearch();
          },
          onClearAll: () {
            setState(() {
              _searchFilters = const SearchFilters();
              _folder = 'All';
              _sort = 'date';
              _activeFilterTypes = {};
            });
            _runSearch();
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: _buildDashboardTile(
                  context,
                  icon: Icons.archive_outlined,
                  label: l10n.archive,
                  count: _archivedCount,
                  onTap: () async {
                    if (widget.authResult.kind == VaultKind.decoy ||
                        _passwordVault == null) {
                      _showDecoyInfo('Archive');
                      return;
                    }
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArchiveScreen(
                          repo: _repo!,
                          passwordVault: _passwordVault!,
                          auth: widget.auth,
                        ),
                      ),
                    );
                    if (mounted) _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDashboardTile(
                  context,
                  icon: Icons.auto_awesome_rounded,
                  label: l10n.smartAi,
                  onTap: () {
                    if (widget.authResult.kind == VaultKind.decoy) {
                      _showDecoyInfo('Smart AI');
                      return;
                    }
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SmartVaultScreen(
                          notes: _notes,
                          repo: _repo,
                          blobs: _blobs,
                          vaultKind: widget.authResult.kind,
                          auth: widget.auth,
                          authResult: widget.authResult,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? _loadingNotes
                  ? _buildSkeletonList()
                  : EmptyState(
                      icon: Icons.note_add_outlined,
                      title: 'No secure notes yet',
                      body: 'Create your first encrypted note, voice memo, checklist, or drawing.',
                    )
              : ValueListenableBuilder<int>(
                  valueListenable: _visibleCount,
                  builder: (context, visible, _) {
                    final showCount = visible.clamp(0, filtered.length);
                    final visibleNotes = filtered.take(showCount).toList();

                    return RefreshIndicator(
                      onRefresh: _load,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 32),
                          child: NoteViewsRenderer(
                            key: ValueKey('${_viewMode.name}_$_query'),
                            mode: _viewMode,
                            notes: visibleNotes,
                            categories: _noteCategories,
                            selectedIds: _selectedIds,
                            isSelectionMode: _selectedIds.isNotEmpty,
                            onSelectionToggle: _onSelectionToggle,
                            blobs: _blobs,
                            hasMore: showCount < filtered.length,
                            onLoadMore: () {
                              _visibleCount.value = (visible + _kPageSize).clamp(0, filtered.length);
                            },
                            onTap: (note) async {
                              if (note.locked) {
                                final authenticated = await _authenticateForAction('Unlock Note');
                                if (!authenticated || !mounted) return;
                              }
                              if (!mounted) return;
                              await _openEditor(note);
                              if (!mounted) return;
                              if (note.oneTimeView) {
                                if (widget.authResult.kind == VaultKind.decoy) {
                                  await DecoySeedService.deleteNote(note.id);
                                } else {
                                  await _repo!.delete(note.id);
                                }
                              }
                            },
                            onDelete: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) {
                                await DecoySeedService.deleteNote(note.id);
                              } else {
                                await _itemActions?.deleteNote(context, note);
                              }
                              if (mounted) await _load();
                            },
                            onToggleArchive: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) return;
                              await _itemActions?.archiveNote(context, note);
                              if (mounted) await _load();
                            },
                            onToggleFavorite: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) {
                                await DecoySeedService.saveNote(
                                  note.copyWith(favorite: !note.favorite),
                                );
                              } else {
                                await _repo!.save(note.copyWith(favorite: !note.favorite));
                              }
                              if (mounted) await _load();
                            },
                            onTogglePin: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) return;
                              await _itemActions?.pinNote(context, note);
                              if (mounted) await _load();
                            },
                            onToggleLock: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) return;
                              await _itemActions?.lockNote(context, note);
                              if (mounted) await _load();
                            },
                            onShare: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) return;
                              await _itemActions?.shareNote(context, note);
                            },
                            onMove: (note) async {
                              if (widget.authResult.kind == VaultKind.decoy) return;
                              await _itemActions?.moveNote(context, note);
                              if (mounted) await _load();
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static Widget _buildSkeletonList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
      itemCount: 8,
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 180,
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 12,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    int? count,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, color: cs.primary, size: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (count != null) ...[
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: count > 0
                      ? cs.primary.withValues(alpha: 0.15)
                      : cs.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: count > 0 ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showDecoyInfo(String feature) {
    FloatingNotificationService.instance.show(
      '$feature unavailable in decoy mode',
      type: AppNotificationType.info,
    );
  }
}

class _HomeFilterSheet extends StatefulWidget {
  final NoteType? noteType;
  final String? folder;
  final String sort;
  final String? category;
  final bool? pinned;
  final bool? favorite;
  final bool? hasAttachments;
  final List<String> folders;
  final List<String> categories;
  final void Function(NoteType?, String?, String?, String?, bool?, bool?, bool?) onApply;
  final VoidCallback onReset;

  const _HomeFilterSheet({
    required this.noteType,
    required this.folder,
    required this.sort,
    required this.category,
    required this.pinned,
    required this.favorite,
    required this.hasAttachments,
    required this.folders,
    required this.categories,
    required this.onApply,
    required this.onReset,
  });

  @override
  State<_HomeFilterSheet> createState() => _HomeFilterSheetState();
}

class _HomeFilterSheetState extends State<_HomeFilterSheet> {
  late NoteType? _type;
  late String? _folder;
  late String _sort;
  late String? _category;
  late bool? _pinned;
  late bool? _favorite;
  late bool? _attachments;

  @override
  void initState() {
    super.initState();
    _type = widget.noteType;
    _folder = widget.folder;
    _sort = widget.sort;
    _category = widget.category;
    _pinned = widget.pinned;
    _favorite = widget.favorite;
    _attachments = widget.hasAttachments;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 520,
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
                    children: [
                      ChoiceChip(
                        label: const Text('Any'),
                        selected: _type == null,
                        onSelected: (_) => setState(() => _type = null),
                      ),
                      ...NoteType.values.map((t) {
                        final selected = _type == t;
                        return ChoiceChip(
                          label: Text(t.name[0].toUpperCase() + t.name.substring(1)),
                          selected: selected,
                          onSelected: (_) => setState(() => _type = t),
                        );
                      }),
                    ],
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
                      ...widget.folders.map((f) =>
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
                    children: ['date', 'title', 'type', 'priority'].map((s) {
                      final selected = _sort == s;
                      return ChoiceChip(
                        label: Text(_sortLabel(s)),
                        selected: selected,
                        onSelected: (_) => setState(() => _sort = s),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // Category
                  if (widget.categories.isNotEmpty) ...[
                    Text('Category', style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: cs.onSurface,
                    )),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      value: _category,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem(value: null, child: Text('All categories')),
                        ...widget.categories.map((c) =>
                          DropdownMenuItem(value: c, child: Text(c))),
                      ],
                      onChanged: (v) => setState(() => _category = v),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Toggles
                  Text('Properties', style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilterChip(
                        label: const Text('Pinned'),
                        selected: _pinned == true,
                        onSelected: (v) => setState(() => _pinned = v ? true : null),
                      ),
                      FilterChip(
                        label: const Text('Favorites'),
                        selected: _favorite == true,
                        onSelected: (v) => setState(() => _favorite = v ? true : null),
                      ),
                      FilterChip(
                        label: const Text('Has attachments'),
                        selected: _attachments == true,
                        onSelected: (v) => setState(() => _attachments = v ? true : null),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => widget.onApply(_type, _folder, _sort, _category, _pinned, _favorite, _attachments),
                  child: const Text('Apply Filters'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _sortLabel(String s) {
    switch (s) {
      case 'date': return 'Date';
      case 'title': return 'Title';
      case 'type': return 'Type';
      case 'priority': return 'Priority';
      default: return s;
    }
  }
}

class PasswordVerifyDialog extends StatefulWidget {
  final String title;
  final String? description;
  final String labelText;
  final String buttonText;

  const PasswordVerifyDialog({
    super.key,
    required this.title,
    this.description,
    required this.labelText,
    required this.buttonText,
  });

  @override
  State<PasswordVerifyDialog> createState() => _PasswordVerifyDialogState();
}

class _PasswordVerifyDialogState extends State<PasswordVerifyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.description != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  widget.description!,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            TextField(
              controller: _controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.labelText,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (val) => Navigator.of(context).pop(val),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.buttonText),
        ),
      ],
    );
  }
}

class _NotesTabWrapper extends StatefulWidget {
  const _NotesTabWrapper({required this.child});
  final Widget child;

  @override
  State<_NotesTabWrapper> createState() => _NotesTabWrapperState();
}

class _NotesTabWrapperState extends State<_NotesTabWrapper> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _VaultSwitcher extends StatelessWidget {
  const _VaultSwitcher({
    required this.currentKind,
    required this.hasHidden,
    required this.onSwitch,
  });

  final VaultKind currentKind;
  final bool hasHidden;
  final ValueChanged<VaultKind> onSwitch;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    if (!hasHidden && currentKind != VaultKind.hidden && currentKind != VaultKind.decoy) {
      return const Text('Notex');
    }

    if (currentKind == VaultKind.decoy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.notes),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => onSwitch(VaultKind.main),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: cs.primary,
            ),
            child: Text(l10n.unlockMain),
          ),
        ],
      );
    }

    return SegmentedButton<VaultKind>(
      segments: [
        ButtonSegment(
          value: VaultKind.main,
          label: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(l10n.mainVault),
          ),
          icon: const Icon(Icons.lock_outline, size: 16),
        ),
        if (hasHidden || currentKind == VaultKind.hidden)
          ButtonSegment(
            value: VaultKind.hidden,
            label: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(l10n.hiddenVault),
            ),
            icon: const Icon(Icons.visibility_off_outlined, size: 16),
          ),
      ],
      selected: {currentKind},
      onSelectionChanged: (Set<VaultKind> selected) {
        onSwitch(selected.first);
      },
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        selectedBackgroundColor: cs.primaryContainer,
        selectedForegroundColor: cs.onPrimaryContainer,
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
    );
  }
}

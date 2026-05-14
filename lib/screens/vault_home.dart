import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';
import 'archive_screen.dart';
import 'drive_screen.dart';
import 'login_screen.dart';
import 'note_editor.dart';
import 'settings_screen.dart';
import 'decoy_calculator_screen.dart';
import 'game_screen.dart';

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
  PasswordVaultService? _passwordVault;
  ItemActionService? _itemActions;
  List<SecureNote> _notes = [];
  String _query = '';
  String _folder = 'All';
  String _sort = 'date';
  int _index = 0;
  Timer? _lockTimer;
  DateTime? _backgroundedAt;
  Map<String, dynamic> _posture = {};
  List<SecureNote> _filteredNotes = [];
  List<SearchMatch>? _searchMatches;
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

  final _searchService = SearchService();
  SearchFilters _searchFilters = const SearchFilters();
  Map<String, String> _noteCategories = {};
  List<String> _cachedAvailableCategories = [];
  List<String> _cachedFolders = ['All'];
  List<String> _searchSuggestions = [];
  Set<FilterChipType> _activeFilterTypes = {};

  @override
  void initState() {
    super.initState();
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
      _itemActions = ItemActionService(
        repo: _repo!,
        drive: _drive!,
        masterKey: widget.authResult.masterKey!,
      );
    }
    DeadMansService.resetTimer();
    _load();
    _resetLockTimer();
    SecurityPlatform.devicePosture().then((v) {
      if (!mounted) return;
      setState(() => _posture = v);
      if (v['rooted'] == true || v['debuggable'] == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Use floating notification instead of SnackBar
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
    _lockTimer?.cancel();
    _lockHoldTimer?.cancel();
    _searchService.dispose();
    _visibleCount.dispose();
    _pageController.dispose();
    EncryptedBlobService.cleanupTempExports();
    DriveService.cleanupTempExports();
    _wipeSessionKey();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _backgroundedAt = DateTime.now();
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
    if (widget.authResult.kind == VaultKind.decoy) {
      final notes = await DecoySeedService.loadNotes();
      if (mounted) {
        setState(() {
          _notes = notes;
          _cachedFolders = ['All', ...{for (final n in notes) n.folder}];
          _computeCategories();
          _searchSuggestions = _searchService.getSuggestions(_notes);
          _archivedCount = notes.where((n) => n.archived).length;
          _folderMetadata = {};
        });
        _runSearch();
      }
      return;
    }
    final notes = await _repo!.loadNotes();
    final metadata = await _repo!.loadFolderMetadata();
    if (mounted) {
      setState(() {
        _notes = notes;
        _cachedFolders = ['All', ...{for (final n in notes) n.folder}];
        _computeCategories();
        _searchSuggestions = _searchService.getSuggestions(_notes);
        _archivedCount = notes.where((n) => n.archived).length;
        _folderMetadata = { for (final f in metadata) f.name : f };
      });
      if (_passwordVault != null) {
        _passwordVault!.archivedCount().then((c) {
          if (mounted) setState(() => _archivedCount += c);
        });
      }
      _runSearch();
    }
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

    final noFilters =
        query.isEmpty &&
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
          _searchMatches = null;
          _visibleCount.value = _kPageSize;
        });
      }
      return;
    }

    final results = await _searchService.searchAsync(source, filters);
    if (mounted && gen == _searchGeneration) {
      setState(() {
        _searchMatches = results;
        _filteredNotes = results.map((m) => m.note).toList();
        _visibleCount.value = _kPageSize;
      });
    }
  }

  Future<bool> _unlockFolder(String folderName) async {
    final meta = _folderMetadata[folderName];
    if (meta == null || !meta.isLocked) return true;
    if (_sessionUnlockedFolders.contains(folderName)) return true;

    bool authenticated = false;
    if (await widget.auth.isBiometricUnlockAvailable()) {
      authenticated = await widget.auth.authenticateBiometric();
    }

    if (!authenticated && mounted) {
      final password = await _showPasswordDialog(
        title: 'Unlock Folder',
        label: 'Enter master password',
      );
      if (password != null) {
        final result = await widget.auth.unlockWithPassword(password);
        final verified = await widget.auth.verify(result);
        authenticated = verified.ok;
      }
    }

    if (authenticated) {
      if (mounted) {
        setState(() {
          _sessionUnlockedFolders.add(folderName);
          _runSearch();
        });
      }
      return true;
    }
    return false;
  }

  Future<void> _toggleFolderLock(String folderName) async {
    if (widget.authResult.kind == VaultKind.decoy) return;
    final meta = _folderMetadata[folderName] ?? SecureDriveFolder(name: folderName);
    final isLocked = meta.isLocked;
    
    if (isLocked) {
      if (!await _unlockFolder(folderName)) return;
    }

    final updated = meta.copyWith(isLocked: !isLocked);
    await _repo!.saveFolderMetadata(updated);
    if (mounted) {
      setState(() {
        _folderMetadata[folderName] = updated;
        if (!updated.isLocked) {
          _sessionUnlockedFolders.remove(folderName);
        }
        _runSearch();
      });
      FloatingNotificationService.instance.show(
        updated.isLocked
            ? 'Folder "$folderName" is now locked'
            : 'Folder "$folderName" is now unlocked',
      );
    }
  }

  void _manageFolders() {
    final folders = {for (final n in _notes) n.folder}.toList();
    folders.sort();

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manage Folders',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              ...folders.map((f) {
                final meta = _folderMetadata[f];
                final isLocked = meta?.isLocked ?? false;
                return ListTile(
                  leading: Icon(isLocked ? Icons.lock : Icons.folder_open),
                  title: Text(f),
                  trailing: Switch(
                    value: isLocked,
                    onChanged: (v) async {
                      Navigator.pop(ctx);
                      await _toggleFolderLock(f);
                    },
                  ),
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
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
        _lockHoldProgress += 0.1 / 7.0; // 7 seconds total
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
    final minutes =
        Hive.box('vaultx_settings').get('lockMinutes', defaultValue: 1) as int;
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
    _wipeSessionKey();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
      (_) => false,
    );
  }

  Future<void> _switchVault(VaultKind target) async {
    if (target == widget.authResult.kind) return;

    AuthResult? result;
    final appState = context.read<VaultAppState>();

    if (target == VaultKind.main) {
      // Try biometric first if enabled and available
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
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
        ),
      );
    } else if (result != null && !result.ok) {
      FloatingNotificationService.instance.show(
        result.error ?? 'Authentication failed',
        error: true,
      );
    }
  }

  Future<String?> _showPasswordDialog({
    required String title,
    required String label,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Unlock'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
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

  void _wipeSessionKey() {
    final key = widget.authResult.masterKey;
    if (key != null && widget.authResult.kind != VaultKind.decoy) {
      CryptoService().wipe(key);
    }
  }

  SearchMatch? _matchFor(SecureNote note) {
    if (_query.isEmpty || _searchMatches == null) return null;
    for (final m in _searchMatches!) {
      if (m.note.id == note.id) return m;
    }
    return null;
  }

  Future<void> _openEditor([SecureNote? note]) async {
    final edited = await Navigator.of(context).push<SecureNote>(
      MaterialPageRoute(
        builder: (_) => NoteEditor(note: note, blobs: _blobs),
      ),
    );
    if (edited != null && mounted) {
      final isDecoy = widget.authResult.kind == VaultKind.decoy;
      final versions = note == null || isDecoy
          ? edited.versions
          : [
              ...note.versions,
              {...note.toJson(), 'updatedAt': DateTime.now().toIso8601String()},
            ].take(20).toList();
      if (isDecoy) {
        await DecoySeedService.saveNote(edited.copyWith(versions: versions));
      } else {
        await _repo!.save(edited.copyWith(versions: versions));
      }
      await _load();
    }
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

    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_index != 0) {
          _onDestinationSelected(0);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanDown: (_) => _resetLockTimer(),
        child: Scaffold(
          appBar: AppBar(
              title: _VaultSwitcher(
                currentKind: widget.authResult.kind,
                hasHidden: _hasHiddenVault,
                onSwitch: _switchVault,
              ),
              actions: [
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
            ),
            body: RepaintBoundary(
              child: PageView(
              controller: _pageController,
              onPageChanged: _onPageChanged,
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
                ),
                const VaultXGameScreen(),
              ],
            ),
            ),
            floatingActionButton: _index == 0
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
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: 'Drive',
                ),
                NavigationDestination(
                  icon: Icon(Icons.shield_outlined),
                  selectedIcon: Icon(Icons.shield),
                  label: 'Security',
                ),
                NavigationDestination(
                  icon: Icon(Icons.sports_esports_outlined),
                  selectedIcon: Icon(Icons.sports_esports),
                  label: 'VaultX Game',
                ),
              ],
            ),
          ),
      ),
    );
  }

  Widget _buildNotesTab(List<String> folders) {
    final filtered = _filteredNotes;
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
                  _activeFilterTypes = _updateActiveFilters();
                case FilterChipType.folder:
                  _folder = value as String? ?? 'All';
                  _searchFilters = _searchFilters.copyWith(
                    folder: _folder == 'All' ? null : _folder,
                  );
                  _activeFilterTypes = _updateActiveFilters();
                case FilterChipType.sort:
                  _sort = value as String? ?? 'date';
                  _searchFilters = _searchFilters.copyWith(sort: _sort);
                case FilterChipType.category:
                  _searchFilters = _searchFilters.copyWith(
                    category: value as String?,
                  );
                  _activeFilterTypes = _updateActiveFilters();
                case FilterChipType.pinned:
                  _searchFilters = _searchFilters.copyWith(
                    pinned: value as bool?,
                  );
                  _activeFilterTypes = _updateActiveFilters();
                case FilterChipType.favorite:
                  _searchFilters = _searchFilters.copyWith(
                    favorite: value as bool?,
                  );
                  _activeFilterTypes = _updateActiveFilters();
                case FilterChipType.attachments:
                  _searchFilters = _searchFilters.copyWith(
                    hasAttachments: value as bool?,
                  );
                  _activeFilterTypes = _updateActiveFilters();
              }
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
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    if (widget.authResult.kind == VaultKind.decoy ||
                        _passwordVault == null) {
                      FloatingNotificationService.instance.show(
                        'Archive unavailable in decoy mode',
                        type: AppNotificationType.info,
                      );
                      return;
                    }
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArchiveScreen(
                          repo: _repo!,
                          passwordVault: _passwordVault!,
                        ),
                      ),
                    );
                    if (mounted) _load();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.archive_outlined, color: cs.primary, size: 20),
                        const SizedBox(width: 10),
                        Text(
                          'Archived items',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _archivedCount > 0
                                ? cs.primary.withValues(alpha: 0.15)
                                : cs.onSurface.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$_archivedCount',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: _archivedCount > 0
                                  ? cs.primary
                                  : cs.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _manageFolders,
                icon: const Icon(Icons.folder_shared_outlined),
                tooltip: 'Manage folders',
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: filtered.isEmpty
                ? EmptyState(
                    icon: Icons.note_add_outlined,
                    title: 'No secure notes yet',
                    body:
                        'Create your first encrypted note, voice memo, checklist, or drawing.',
                  )
                : ValueListenableBuilder<int>(
                    valueListenable: _visibleCount,
                    builder: (context, visible, _) {
                      final showCount = visible.clamp(0, filtered.length);
                      final visibleNotes = filtered.take(showCount).toList();
                      return Column(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              key: ValueKey(_query),
                              padding: const EdgeInsets.all(12),
                              itemCount: visibleNotes.length,
                              itemBuilder: (context, i) => NoteCard(
                                    key: ValueKey(visibleNotes[i].id),
                                      note: visibleNotes[i],
                                      category:
                                          _noteCategories[visibleNotes[i].id],
                                      relevanceScore: _query.isNotEmpty
                                          ? _matchFor(visibleNotes[i])?.score
                                          : null,
                                      onTap: () async {
                                        final note = visibleNotes[i];
                                        await _openEditor(note);
                                        if (note.oneTimeView) {
                                          if (widget.authResult.kind ==
                                              VaultKind.decoy) {
                                            await DecoySeedService.deleteNote(
                                              note.id,
                                            );
                                          } else {
                                            await _repo!.delete(note.id);
                                          }
                                        }
                                      },
                                      onDelete: () async {
                                        if (widget.authResult.kind == VaultKind.decoy) {
                                          await DecoySeedService.deleteNote(visibleNotes[i].id);
                                        } else {
                                          await _itemActions?.deleteNote(context, visibleNotes[i]);
                                        }
                                        await _load();
                                      },
                                      onToggleArchive: () async {
                                        if (widget.authResult.kind == VaultKind.decoy) return;
                                        await _itemActions?.archiveNote(context, visibleNotes[i]);
                                        await _load();
                                      },
                                      onToggleFavorite: () async {
                                        if (widget.authResult.kind ==
                                            VaultKind.decoy) {
                                          await DecoySeedService.saveNote(
                                            visibleNotes[i].copyWith(
                                              favorite:
                                                  !visibleNotes[i].favorite,
                                            ),
                                          );
                                        } else {
                                          await _repo!.save(
                                            visibleNotes[i].copyWith(
                                              favorite:
                                                  !visibleNotes[i].favorite,
                                            ),
                                          );
                                        }
                                        await _load();
                                      },
                                      onTogglePin: () async {
                                        if (widget.authResult.kind == VaultKind.decoy) return;
                                        await _itemActions?.pinNote(context, visibleNotes[i]);
                                        await _load();
                                      },
                                      onShare: () async {
                                        if (widget.authResult.kind == VaultKind.decoy) return;
                                        await _itemActions?.shareNote(context, visibleNotes[i]);
                                      },
                                      onMove: () async {
                                        if (widget.authResult.kind == VaultKind.decoy) return;
                                        await _itemActions?.moveNote(context, visibleNotes[i]);
                                        await _load();
                                      },
                                      onToggleBackup: () async {
                                        if (widget.authResult.kind == VaultKind.decoy) return;
                                        await _itemActions?.toggleNoteBackup(context, visibleNotes[i]);
                                        await _load();
                                      },
                                    ),
                                  ),
                            ),
                          if (showCount < filtered.length)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: TextButton(
                                onPressed: () =>
                                    _visibleCount.value = (visible + _kPageSize)
                                        .clamp(0, filtered.length),
                                child: Text(
                                  'Load more (${filtered.length - showCount} remaining)',
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
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

    // If no hidden vault and not in decoy/hidden, just show app title
    if (!hasHidden &&
        currentKind != VaultKind.hidden &&
        currentKind != VaultKind.decoy) {
      return const Text('VaultX');
    }

    // In decoy mode, we might want to keep it simple, but for navigation UX
    // we'll show the title and a small switch if they want to go to Main.
    if (currentKind == VaultKind.decoy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Notes'),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => onSwitch(VaultKind.main),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: cs.primary,
            ),
            child: const Text('Unlock Main'),
          ),
        ],
      );
    }

    return SegmentedButton<VaultKind>(
      segments: [
        const ButtonSegment(
          value: VaultKind.main,
          label: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Main'),
          ),
          icon: Icon(Icons.lock_outline, size: 16),
        ),
        if (hasHidden || currentKind == VaultKind.hidden)
          const ButtonSegment(
            value: VaultKind.hidden,
            label: Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('Hidden'),
            ),
            icon: Icon(Icons.visibility_off_outlined, size: 16),
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

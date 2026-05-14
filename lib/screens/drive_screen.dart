import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_file.dart';
import '../services/item_action_service.dart';
import '../services/auth_service.dart';
import 'vaultx_app.dart';
import '../widgets/swipe_action_tile.dart';
import '../services/decoy_seed_service.dart';
import '../services/drive_service.dart';
import '../services/compression_service.dart';
import '../widgets/smart_compression_sheet.dart';
import '../widgets/document_conversion_sheet.dart';
import '../services/password_vault_service.dart';
import '../widgets/drive_file_tile.dart';
import 'drive_file_viewer.dart';
import 'password_manager_screen.dart';
import '../services/floating_notification_service.dart';
import 'drive_tools_screen.dart';

class _FolderEntry {
  const _FolderEntry(this.key, this.count, this.icon, this.service);
  final String key;
  final int count;
  final IconData icon;
  final PasswordVaultService? service;
}

enum _DriveView { folders, files, search, favorites }

class DriveScreen extends StatefulWidget {
  const DriveScreen({
    super.key,
    this.auth,
    this.drive,
    this.passwordVault,
    this.itemActions,
    this.isDecoy = false,
  });

  final VaultAuthService? auth;
  final DriveService? drive;
  final PasswordVaultService? passwordVault;
  final ItemActionService? itemActions;
  final bool isDecoy;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with AutomaticKeepAliveClientMixin {
  _DriveView _view = _DriveView.folders;
  List<SecureDriveFile> _files = [];
  List<SecureDriveFile> _filtered = [];
  List<String> _folders = [];
  Map<String, SecureDriveFolder> _folderMetadata = {};
  final Set<String> _sessionUnlockedFolders = {};
  String? _selectedFolder;
  bool _loading = true;
  String? _loadError;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final drive = widget.drive;
      if (!widget.isDecoy && drive == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadError = 'Drive service not available';
        });
        return;
      }

      final files = widget.isDecoy
          ? await DecoySeedService.loadDriveFiles()
          : await drive!.loadFiles();
      
      final metadata = widget.isDecoy 
          ? <SecureDriveFolder>[] 
          : await drive!.loadFolderMetadata();

      if (!mounted) return;
      setState(() {
        _files = files;
        _folders = widget.isDecoy
            ? ['Photos', 'Screenshots', 'PDFs', 'Documents', 'IDs', 'Travel']
            : drive!.getFolders();
        _folderMetadata = { for (final f in metadata) f.name : f };
        _loading = false;
        _loadError = null;
        _applyFilter();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  bool _isFolderAccessible(String folderName) {
    final meta = _folderMetadata[folderName];
    if (meta == null || !meta.isLocked) return true;
    return _sessionUnlockedFolders.contains(folderName);
  }

  void _applyFilter() {
    final search = _searchQuery.toLowerCase();

    if (search.isNotEmpty) {
      final drive = widget.drive;
      final source = widget.isDecoy || drive == null
          ? _files
                .where(
                  (f) =>
                      f.name.toLowerCase().contains(search) ||
                      f.folder.toLowerCase().contains(search) ||
                      f.tags.any((t) => t.toLowerCase().contains(search)),
                )
                .toList()
          : drive.search(_searchQuery);

      _filtered = source.where((f) => _isFolderAccessible(f.folder)).toList();
    } else if (_selectedFolder != null) {
      final folder = _selectedFolder!;
      if (!_isFolderAccessible(folder)) {
        _filtered = [];
      } else {
        final drive = widget.drive;
        _filtered = widget.isDecoy || drive == null
            ? _files.where((f) => f.folder == folder).toList()
            : drive.filterByFolder(folder);
      }
    } else {
      _filtered = _files.where((f) => _isFolderAccessible(f.folder)).toList();
    }
  }
  Future<bool> _unlockFolder(String folderName) async {
    final isLockedByDefault = folderName == 'Passwords';
    final meta = _folderMetadata[folderName];
    final isLocked = isLockedByDefault || (meta?.isLocked ?? false);
    
    if (!isLocked) return true;
    if (_sessionUnlockedFolders.contains(folderName)) return true;

    final auth = widget.auth ?? VaultAuthService();
    final appState = Provider.of<VaultAppState>(context, listen: false);
    bool authenticated = false;

    if (await auth.isBiometricUnlockAvailable() && !appState.isBiometricEscalated) {
      authenticated = await auth.authenticateBiometric();
      if (authenticated) {
        appState.resetBiometricAttempts();
      } else {
        await appState.recordFailedBiometricAttempt();
      }
    }

    if (!authenticated && mounted) {
      final password = await _showPasswordDialog(
        title: 'Unlock Folder',
        label: 'Enter master password',
      );
      if (password != null) {
        final result = await auth.unlockWithPassword(password);
        final verified = await auth.verify(result);
        authenticated = verified.ok;
        if (authenticated) {
          appState.resetBiometricAttempts();
          appState.resetPinAttempts();
        }
      }
    }

    if (authenticated) {
      if (mounted) {
        setState(() {
          _sessionUnlockedFolders.add(folderName);
          _applyFilter();
        });
      }
      return true;
    }
    return false;
  }

  Future<String?> _showPasswordDialog({
    required String title,
    required String label,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (context) {
        return _PasswordDialog(title: title, label: label);
      },
    );
  }

  bool _isImporting = false;
  Future<void> _importFile() async {
    if (widget.isDecoy) {
      if (!mounted) return;
      FloatingNotificationService.instance.show('Import disabled in decoy mode');
      return;
    }
    if (_isImporting) return;
    if (_selectedFolder != null && !await _unlockFolder(_selectedFolder!)) return;

    setState(() => _isImporting = true);
    try {
      final file = await widget.drive!.importFromPicker(folder: _selectedFolder);
      if (file != null && mounted) {
        await _load();
        FloatingNotificationService.instance.show('Imported ${file.name}');
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _deleteFile(SecureDriveFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file'),
        content: Text('Permanently delete "${file.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    if (widget.isDecoy) {
      setState(() {
        _files.removeWhere((f) => f.id == file.id);
        _applyFilter();
      });
      return;
    }
    final ok = await widget.drive!.deleteFile(file);
    if (ok && mounted) {
      setState(() {
        _files.removeWhere((f) => f.id == file.id);
        _folders = widget.drive!.getFolders();
        _applyFilter();
      });
      FloatingNotificationService.instance.show('Deleted ${file.name}');
    }
  }

  Future<void> _compressFile(SecureDriveFile file) async {
    if (widget.isDecoy) {
      FloatingNotificationService.instance.show('Optimization disabled in decoy mode');
      return;
    }

    final svc = widget.drive;
    if (svc == null) return;

    // 1. Prepare/Decrypt
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    final tempPath = await svc.decryptToTemp(file);
    
    if (mounted) Navigator.pop(context); // Close "Preparing" dialog

    if (tempPath == null) {
      FloatingNotificationService.instance.show('Failed to prepare file for optimization', error: true);
      return;
    }

    // 2. Show Compression Sheet
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SmartCompressionSheet(
        filePath: tempPath,
        onComplete: (compressionResult, keepOriginal) async {
          Navigator.pop(context); // Close sheet
          if (!compressionResult.success) {
            try { await File(tempPath).delete(); } catch (_) {}
            return;
          }
          if (keepOriginal) {
            await _performImport(
              compressionResult.path, 
              compressionResult, 
              file.folder, 
              true, 
              displayName: compressionResult.newName,
            );
          } else {
            await _performReplace(file, compressionResult);
          }
          
          // Cleanup decrypted temp file
          try { await File(tempPath).delete(); } catch(_) {}
        },
      ),
    );
  }

  Future<void> _convertFile(SecureDriveFile file) async {
    if (widget.isDecoy) {
      FloatingNotificationService.instance.show('Conversion disabled in decoy mode');
      return;
    }

    final svc = widget.drive;
    if (svc == null) return;

    // 1. Prepare/Decrypt
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    final tempPath = await svc.decryptToTemp(file);
    
    if (mounted) Navigator.pop(context); // Close "Preparing" dialog

    if (tempPath == null) {
      FloatingNotificationService.instance.show('Failed to prepare file for conversion', error: true);
      return;
    }

    // 2. Show Conversion Sheet
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DocumentConversionSheet(
        filePath: tempPath,
        onComplete: (conversionResult, keepOriginal) async {
          Navigator.pop(context); // Close sheet
          
          final ext = conversionResult.path.split('.').last.toLowerCase();
          final mimeType = ext == 'pdf' ? 'application/pdf' : (ext == 'txt' ? 'text/plain' : 'application/octet-stream');
          final kind = SecureDriveFile.detectKind(conversionResult.path, mimeType);

          if (keepOriginal) {
            final nameParts = file.name.split('.');
            if (nameParts.length > 1) nameParts.removeLast();
            final baseName = nameParts.join('.');
            final convertedExt = conversionResult.path.split('.').last.toLowerCase();
            final newConvertedName = '${baseName}_converted.$convertedExt';
            
            await _performImport(conversionResult.path, CompressionResult(
              path: conversionResult.path,
              originalSize: file.size,
              compressedSize: await File(conversionResult.path).length(),
            ), file.folder, true, displayName: newConvertedName);
          } else {
            await _performReplace(file, CompressionResult(
              path: conversionResult.path,
              originalSize: file.size,
              compressedSize: await File(conversionResult.path).length(),
            ), kind: kind, mimeType: mimeType);
          }
          
          // Cleanup decrypted temp file
          try { await File(tempPath).delete(); } catch(_) {}
        },
      ),
    );
  }

  Future<void> _performReplace(
    SecureDriveFile originalFile,
    CompressionResult compression, {
    String? kind,
    String? mimeType,
  }) async {
    final svc = widget.drive;
    if (svc == null || !mounted) return;

    var progress = 0.0;
    var progressLabel = 'Encrypting...';
    
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Updating File'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 12),
              Text(progressLabel),
            ],
          ),
        ),
      ),
    );

    final updatedFile = await svc.replaceFileWithCompressed(
      originalFile: originalFile,
      compression: compression,
      kind: kind,
      mimeType: mimeType,
      onProgress: (value, label) {
        progress = value;
        progressLabel = label;
      },
    );

    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // Close progress dialog

    if (updatedFile != null && mounted) {
      setState(() {
        final idx = _files.indexWhere((f) => f.id == updatedFile.id);
        if (idx >= 0) _files[idx] = updatedFile;
        _applyFilter();
      });
      
      String msg = 'Optimization complete';
      if (compression.savedPercentage > 0) {
        msg += ' (Saved ${compression.savedPercentage.toInt()}%)';
      }
      FloatingNotificationService.instance.show(msg);
    }
  }

  Future<void> _openFile(SecureDriveFile file) async {
    if (widget.isDecoy) {
      _showDecoyFileInfo(file);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DriveFileViewer(file: file, drive: widget.drive!),
      ),
    );
    if (mounted) {
      setState(() {
        final idx = _files.indexWhere((f) => f.id == file.id);
        if (idx >= 0) _files[idx] = file;
        _applyFilter();
      });
    }
  }

  void _showDecoyFileInfo(SecureDriveFile file) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(file.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Type', file.kind),
            _infoRow('Folder', file.folder),
            _infoRow('Size', _formatSize(file.size)),
            _infoRow('Tags', file.tags.join(', ')),
            _infoRow('Created', _formatDate(file.createdAt)),
            _infoRow('Modified', _formatDate(file.updatedAt)),
            if (file.favorite) const SizedBox(height: 8),
            if (file.favorite)
              const Row(
                children: [
                  Icon(Icons.star, color: Colors.amber, size: 16),
                  SizedBox(width: 4),
                  Text('Favorited'),
                ],
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _DriveAddMenu(
        onAddPhotos: () => _importTyped(FileType.image, 'Photos'),
        onAddVideos: () => _importTyped(FileType.video, 'Videos'),
        onAddAudio: () => _importTyped(FileType.audio, 'Audio'),
        onAddDocuments: () => _importTyped(FileType.any, null),
        onCreateFolder: _createFolder,
      ),
    );
  }

  Future<void> _importTyped(FileType type, String? folder) async {
    if (widget.isDecoy) {
      if (mounted) {
        FloatingNotificationService.instance.show('Import disabled in decoy mode');
      }
      return;
    }
    final svc = widget.drive;
    if (svc == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: type,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;

    if (!mounted) return;

    // Use SmartCompressionSheet
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SmartCompressionSheet(
        filePath: path,
        onComplete: (compressionResult, keepOriginal) async {
          Navigator.pop(context); // Close sheet
          await _performImport(path, compressionResult, folder, keepOriginal);
        },
      ),
    );
  }

  Future<void> _performImport(
    String originalPath,
    CompressionResult compression,
    String? folder,
    bool keepOriginal, {
    String? displayName,
  }) async {
    final svc = widget.drive;
    if (svc == null || !mounted) return;

    var progress = 0.0;
    var progressLabel = 'Encrypting...';
    
    // We need a way to trigger dialog rebuild
    void Function(void Function())? dialogSetter;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          dialogSetter = setDialogState;
          return AlertDialog(
            title: const Text('Securing File'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 12),
                Text(progressLabel),
              ],
            ),
          );
        },
      ),
    );

    final finalName = displayName ?? originalPath.split(Platform.pathSeparator).last;
    
    // Import the (possibly) compressed version
    final file = await svc.importCompressedFile(
      compression: compression,
      originalName: finalName,
      folder: folder ?? _selectedFolder,
      onProgress: (value, label) {
        if (dialogSetter != null) {
          dialogSetter!(() {
            progress = value;
            progressLabel = label;
          });
        }
      },
    );

    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // Close progress dialog

    if (file != null && mounted) {
      await _load();
      
      String msg = 'Imported ${file.name}';
      if (compression.savedPercentage > 5) {
        msg += ' (Saved ${compression.savedPercentage.toInt()}%)';
      }
      FloatingNotificationService.instance.show(msg);
    }
  }

  Future<void> _createFolder() async {
    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _CreateFolderDialog(),
    );
    if (name == null || name.isEmpty) return;
    if (!mounted) return;
    setState(() {
      if (!_folders.contains(name)) {
        _folders = [..._folders, name];
      }
      _selectedFolder = name;
      _view = _DriveView.files;
      _applyFilter();
    });
    FloatingNotificationService.instance.show('Folder "$name" created');
  }

  Future<void> _toggleFolderLock(String folderName) async {
    if (widget.isDecoy) return;
    final meta = _folderMetadata[folderName] ?? SecureDriveFolder(name: folderName);
    final isLocked = meta.isLocked;
    
    // If unlocking permanent lock, we should probably authenticate
    if (isLocked) {
      if (!await _unlockFolder(folderName)) return;
    }

    final updated = meta.copyWith(isLocked: !isLocked);
    await widget.drive!.saveFolderMetadata(updated);
    if (mounted) {
      setState(() {
        _folderMetadata[folderName] = updated;
        if (!updated.isLocked) {
          _sessionUnlockedFolders.remove(folderName);
        }
        _applyFilter();
      });
      FloatingNotificationService.instance.show(
        updated.isLocked
            ? 'Folder "$folderName" is now locked'
            : 'Folder "$folderName" is now unlocked',
      );
    }
  }

  Future<void> _toggleFolderExclusion(String folderName) async {
    if (widget.isDecoy) return;
    final meta = _folderMetadata[folderName] ?? SecureDriveFolder(name: folderName);
    final isExcluded = meta.backupExcluded;
    final updated = meta.copyWith(backupExcluded: !isExcluded);
    await widget.drive!.saveFolderMetadata(updated);
    if (mounted) {
      setState(() {
        _folderMetadata[folderName] = updated;
      });
      FloatingNotificationService.instance.show(
        updated.backupExcluded
            ? 'Folder "$folderName" is now local-only'
            : 'Folder "$folderName" will be backed up',
      );
    }
  }

  void _showFolderOptions(String folderName) {
    final meta = _folderMetadata[folderName] ?? SecureDriveFolder(name: folderName);
    final isExcluded = meta.backupExcluded;
    final isLocked = meta.isLocked;

    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    isLocked ? Icons.lock_open : Icons.lock_outline,
                  ),
                  title: Text(
                    isLocked ? 'Unlock Folder Permanently' : 'Lock Folder',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleFolderLock(folderName);
                  },
                ),
                ListTile(
                  leading: Icon(
                    isExcluded ? Icons.cloud_done : Icons.cloud_off,
                  ),
                  title: Text(
                    isExcluded ? 'Include in backup' : 'Make local only',
                  ),
                  subtitle: Text(
                    isExcluded
                        ? 'This folder will be included in future backups'
                        : 'This folder will be skipped during cloud backups',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleFolderExclusion(folderName);
                  },
                ),
              ],
            ),
          ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;

    return PopScope(
      canPop: _view == _DriveView.folders,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_view != _DriveView.folders) {
          setState(() {
            _view = _DriveView.folders;
            _selectedFolder = null;
            _applyFilter();
          });
        }
      },
      child: Scaffold(
      appBar: _buildAppBar(cs),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 64, color: cs.error),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load files',
                      style: TextStyle(color: cs.error),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _loadError!,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _loadError = null;
                        });
                        _load();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : _buildBody(cs),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'driveFab',
        onPressed: _showAddMenu,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
    ));
  }

  PreferredSizeWidget _buildAppBar(ColorScheme cs) {
    if (_view == _DriveView.search) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            setState(() {
              _view = _selectedFolder != null
                  ? _DriveView.files
                  : _DriveView.folders;
              _searchQuery = '';
              _searchCtrl.clear();
              _applyFilter();
            });
          },
        ),
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search files\u2026',
            border: InputBorder.none,
          ),
          onChanged: (v) {
            setState(() {
              _searchQuery = v;
              _applyFilter();
            });
          },
        ),
      );
    }

    final showBack = _view == _DriveView.files || _view == _DriveView.favorites;

    return AppBar(
      leading: showBack
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                setState(() {
                  _view = _DriveView.folders;
                  _selectedFolder = null;
                  _applyFilter();
                });
              },
            )
          : null,
      title: Text(
        _view == _DriveView.folders
            ? 'Secure Drive'
            : _view == _DriveView.favorites
            ? 'Favorites'
            : _selectedFolder ?? 'All Files',
      ),
      actions: [
        if (showBack)
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        IconButton(
          icon: const Icon(Icons.auto_fix_high),
          onPressed: () {
            if (widget.drive != null && !widget.isDecoy) {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DriveToolsScreen(drive: widget.drive!, unlockedFolders: _sessionUnlockedFolders)),
              );
            } else if (widget.isDecoy) {
              FloatingNotificationService.instance.show('Smart tools disabled in decoy mode');
            }
          },
          tooltip: 'Smart Tools',
        ),
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => _view = _DriveView.search),
          tooltip: 'Search',
        ),
      ],
    );
  }

  Widget _buildBody(ColorScheme cs) {
    switch (_view) {
      case _DriveView.folders:
        return _buildFolderGrid(cs);
      case _DriveView.files:
        return _buildFileList(cs);
      case _DriveView.search:
        return _buildSearchResults(cs);
      case _DriveView.favorites:
        return _buildFavoritesList(cs);
    }
  }

  Widget _buildDriveHealthCard(ColorScheme cs) {
    if (widget.isDecoy) return const SizedBox.shrink();
    
    final accessibleFiles = _files.where((f) => _isFolderAccessible(f.folder)).toList();
    
    int totalSize = 0;
    int originalSize = 0;
    for (final f in accessibleFiles) {
      totalSize += f.size;
      originalSize += (f.originalSize ?? 0) > 0 ? (f.originalSize ?? 0) : f.size;
    }
    
    final savings = originalSize - totalSize;
    final savingsPercent = originalSize > 0 ? (savings / originalSize * 100).toInt() : 0;

    return InkWell(
      onTap: () {
        if (widget.drive != null) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DriveToolsScreen(drive: widget.drive!, unlockedFolders: _sessionUnlockedFolders)),
          );
        }
      },
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: cs.primary.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Drive Health',
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatSize(totalSize),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    savings > 0 
                      ? 'Saved ${_formatSize(savings)} ($savingsPercent%)' 
                      : 'Optimize files to save space',
                    style: TextStyle(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.auto_fix_high, color: cs.primary, size: 28),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderGrid(ColorScheme cs) {
    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open,
              size: 64,
              color: cs.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No files stored yet',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 8),
            Text(
              'Import files to see them organized by category',
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.35),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: _importFile,
              icon: const Icon(Icons.add),
              label: const Text('Import file'),
            ),
          ],
        ),
      );
    }

    final accessibleFiles = _files.where((f) => _isFolderAccessible(f.folder)).toList();

    final folderCounts = <String, int>{};
    for (final f in accessibleFiles) {
      folderCounts[f.folder] = (folderCounts[f.folder] ?? 0) + 1;
    }
    final displayFolders = <_FolderEntry>[
      _FolderEntry('All Files', accessibleFiles.length, Icons.storage, null),
      _FolderEntry(
        'Favorites',
        accessibleFiles.where((f) => f.favorite).length,
        Icons.star,
        null,
      ),
      if (widget.passwordVault != null && !widget.isDecoy)
        _FolderEntry('Passwords', 0, Icons.lock, widget.passwordVault),
      ..._folders.map(
        (f) => _FolderEntry(f, folderCounts[f] ?? 0, Icons.folder, null),
      ),
    ];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildDriveHealthCard(cs),
          const SizedBox(height: 24),
          Text(
            '${accessibleFiles.length} files stored',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 12),
          ...displayFolders.map(
            (entry) {
              final meta = _folderMetadata[entry.key];
              final isLockedByDefault = entry.key == 'Passwords';
              final isLocked = isLockedByDefault || (meta?.isLocked ?? false);
              final isUnlocked = _sessionUnlockedFolders.contains(entry.key);
              final isExcluded = meta?.backupExcluded ?? false;

              return SwipeActionTile(
                isArchived: isExcluded,
                onAction: (action) {
                  if (entry.key == 'All Files' || entry.key == 'Favorites' || entry.key == 'Passwords') return;
                  switch (action) {
                    case SwipeAction.archive:
                      _toggleFolderExclusion(entry.key);
                    case SwipeAction.delete:
                      FloatingNotificationService.instance.show('Delete folder not implemented yet', error: true);
                    default:
                      break;
                  }
                },
                child: Card(
                  child: ListTile(
                    leading: entry.key == 'Passwords'
                        ? Text(isLocked && !isUnlocked ? '🔒' : '🔓', style: TextStyle(fontSize: 24))
                        : Stack(
                            children: [
                              Icon(
                                isLocked && !isUnlocked ? Icons.lock : entry.icon,
                                color: entry.key == 'Favorites'
                                    ? Colors.amber
                                    : cs.primary,
                              ),
                              if (isExcluded)
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(1),
                                    decoration: BoxDecoration(
                                      color: cs.surface,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.cloud_off,
                                      size: 10,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                    title: Text(entry.key),
                    subtitle: isExcluded
                        ? Text(
                            'Local only',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          )
                        : null,
                    trailing: entry.service == null
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              isLocked && !isUnlocked ? '??' : '${entry.count}',
                              style: TextStyle(
                                color: cs.primary,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          )
                        : Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                    onTap: () async {
                      if (isLocked && !isUnlocked) {
                        if (!await _unlockFolder(entry.key)) return;
                      }

                      if (entry.service != null) {
                        if (!mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                PasswordManagerScreen(service: entry.service!),
                          ),
                        );
                        return;
                      }

                      setState(() {
                        if (entry.key == 'All Files') {
                          _selectedFolder = null;
                          _view = _DriveView.files;
                        } else if (entry.key == 'Favorites') {
                          _view = _DriveView.favorites;
                        } else {
                          _selectedFolder = entry.key;
                          _view = _DriveView.files;
                        }
                        _applyFilter();
                      });
                    },
                    onLongPress: entry.key == 'All Files' || 
                                 entry.key == 'Favorites' || 
                                 entry.key == 'Passwords' 
                        ? null 
                        : () => _showFolderOptions(entry.key),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFileList(ColorScheme cs) {
    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open,
              size: 64,
              color: cs.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              _selectedFolder != null
                  ? 'No files in "$_selectedFolder"'
                  : 'No files yet',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _importFile,
              icon: const Icon(Icons.add),
              label: const Text('Import file'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: _filtered.length,
        itemBuilder: (_, i) => DriveFileTile(
          file: _filtered[i],
          onTap: () => _openFile(_filtered[i]),
          onDelete: () async {
            if (widget.itemActions != null) {
              await widget.itemActions!.deleteFile(context, _filtered[i]);
              await _load();
            } else {
              _deleteFile(_filtered[i]);
            }
          },
          onFavorite: () async {
            if (widget.isDecoy) {
              if (mounted) setState(() => _applyFilter());
            } else {
              await widget.drive!.toggleFavorite(_filtered[i].id);
              if (mounted) setState(() => _applyFilter());
            }
          },
          onMove: widget.isDecoy
              ? null
              : (folder) async {
                  await widget.drive!.moveFile(_filtered[i].id, folder);
                  if (mounted) {
                    setState(() {
                      _folders = widget.drive!.getFolders();
                      _applyFilter();
                    });
                  }
                },
          onTogglePin: () async {
            if (widget.itemActions != null) {
              await widget.itemActions!.pinFile(context, _filtered[i]);
              await _load();
            }
          },
          onToggleArchive: () async {
            if (widget.itemActions != null) {
              await widget.itemActions!.archiveFile(context, _filtered[i]);
              await _load();
            }
          },
          onShare: () async {
            if (widget.itemActions != null) {
              await widget.itemActions!.shareFile(context, _filtered[i]);
            }
          },
          onCompress: () => _compressFile(_filtered[i]),
          onConvert: () => _convertFile(_filtered[i]),
          onToggleBackup: () => _toggleFileBackup(_filtered[i]),
        ),
      ),
    );
  }

  Widget _buildSearchResults(ColorScheme cs) {
    if (_searchQuery.isEmpty) {
      return Center(
        child: Text(
          'Type to search files\u2026',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
        ),
      );
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Text(
          'No results for "$_searchQuery"',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: _filtered.length,
      itemBuilder: (_, i) => DriveFileTile(
        file: _filtered[i],
        onTap: () => _openFile(_filtered[i]),
        onDelete: () => _deleteFile(_filtered[i]),
        onFavorite: () async {
          if (widget.isDecoy) {
            if (mounted) setState(() => _applyFilter());
          } else {
            await widget.drive!.toggleFavorite(_filtered[i].id);
            if (mounted) setState(() => _applyFilter());
          }
        },
        onCompress: () => _compressFile(_filtered[i]),
        onConvert: () => _convertFile(_filtered[i]),
        onToggleBackup: () => _toggleFileBackup(_filtered[i]),
      ),
    );
  }

  Widget _buildFavoritesList(ColorScheme cs) {
    final favorites = _files.where((f) => f.favorite).toList();
    if (favorites.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.star_border,
              size: 64,
              color: cs.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No favorites yet',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: favorites.length,
      itemBuilder: (_, i) => DriveFileTile(
        file: favorites[i],
        onTap: () => _openFile(favorites[i]),
        onDelete: () => _deleteFile(favorites[i]),
        onFavorite: () async {
          if (widget.isDecoy) {
            if (mounted) setState(() => _applyFilter());
          } else {
            await widget.drive!.toggleFavorite(favorites[i].id);
            if (mounted) setState(() => _applyFilter());
          }
        },
        onCompress: () => _compressFile(favorites[i]),
        onConvert: () => _convertFile(favorites[i]),
        onToggleBackup: () => _toggleFileBackup(favorites[i]),
      ),
    );
  }

  void _toggleFileBackup(SecureDriveFile file) async {
    if (widget.itemActions != null) {
      await widget.itemActions!.toggleFileBackup(context, file);
      if (mounted) _load();
    }
  }
}

// ── Add menu bottom sheet ───────────────────────────────────────────────────

class _DriveAddMenu extends StatefulWidget {
  const _DriveAddMenu({
    required this.onAddPhotos,
    required this.onAddVideos,
    required this.onAddAudio,
    required this.onAddDocuments,
    required this.onCreateFolder,
  });

  final VoidCallback onAddPhotos;
  final VoidCallback onAddVideos;
  final VoidCallback onAddAudio;
  final VoidCallback onAddDocuments;
  final VoidCallback onCreateFolder;

  @override
  State<_DriveAddMenu> createState() => _DriveAddMenuState();
}

class _DriveAddMenuState extends State<_DriveAddMenu> {
  bool _tapped = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Add to Secure Drive',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            _menuGrid(context, cs),
          ],
        ),
      ),
    );
  }

  Widget _menuGrid(BuildContext context, ColorScheme cs) {
    final items = [
      _MenuItem(Icons.image_rounded, 'Photos', widget.onAddPhotos),
      _MenuItem(Icons.videocam_rounded, 'Videos', widget.onAddVideos),
      _MenuItem(Icons.audiotrack_rounded, 'Audio', widget.onAddAudio),
      _MenuItem(Icons.description_rounded, 'Documents', widget.onAddDocuments),
      _MenuItem(Icons.create_new_folder_rounded, 'Folder', widget.onCreateFolder),
    ];

    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.9,
      children: items.map((item) => _menuItemTile(context, cs, item)).toList(),
    );
  }

  Widget _menuItemTile(BuildContext context, ColorScheme cs, _MenuItem item) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (_tapped) return;
          _tapped = true;
          final cb = item.onTap;
          Navigator.pop(context);
          WidgetsBinding.instance.addPostFrameCallback((_) => cb());
        },
        child: Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(item.icon, color: cs.primary, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem {
  const _MenuItem(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog();

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Folder'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Folder name'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final t = _ctrl.text.trim();
            if (t.isNotEmpty) Navigator.pop(context, t);
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.title, required this.label});
  final String title;
  final String label;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
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
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

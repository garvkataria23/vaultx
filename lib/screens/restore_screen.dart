import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/auth.dart';
import '../models/backup.dart';
import '../services/cloud_storage_provider.dart';
import '../services/format_utils.dart';
import '../services/services.dart';

/// Restore screen that handles the complete restore flow:
///
/// 1. Shows backup detection result
/// 2. Prompts for vault password
/// 3. Downloads & verifies backup
/// 4. Detects local data conflicts
/// 5. Commits restore with progress
///
/// Can be launched either:
/// - Automatically (from login screen after password entry)
/// - Manually (from settings or backup screen)
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({
    super.key,
    required this.authService,
    required this.driveService,
    required this.masterKey,
    required this.kind,
    this.autoRestore = false,
    this.onComplete,
  });

  final VaultAuthService authService;
  final CloudStorageProvider driveService;
  final Uint8List masterKey;
  final VaultKind kind;
  final bool autoRestore;
  final void Function(bool success)? onComplete;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  late final RestoreService _restoreService;
  final _passwordCtrl = TextEditingController();
  bool _passwordVisible = false;

  // State machine
  _RestoreView _view = _RestoreView.detecting;
  String? _error;
  BackupVersion? _detectedVersion;
  RestoreInfo? _restoreInfo;
  RestoreResult? _restoreResult;
  RestoreProgress? _progress;
  bool _busy = false;
  bool _committing = false;
  bool _hasLocalData = false;

  @override
  void initState() {
    super.initState();
    _restoreService = RestoreService(
      authService: widget.authService,
      driveService: widget.driveService,
      masterKey: widget.masterKey,
      kind: widget.kind,
      onProgress: _onProgress,
    );
    // Start auto-detection immediately
    _detectBackup();
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  String get _providerTag => widget.driveService.providerName == 'Google Drive' ? 'GOOGLE' : 'MEGA';

  void _logUI(String msg) => debugPrint('[$_providerTag RESTORE UI] $msg');

  void _onProgress(RestoreProgress progress) {
    if (mounted) setState(() => _progress = progress);
  }

  // ── Core restore pipeline ────────────────────────────────────────────────

  Future<void> _detectBackup() async {
    if (_busy) return;
    _logUI('_detectBackup started');
    setState(() {
      _view = _RestoreView.detecting;
      _error = null;
      _busy = true;
    });

    try {
      final version = await _restoreService.detectBackup();

      if (!mounted) return;

      if (version == null) {
        _logUI('no backup found');
        debugPrint('RESTORE UI: no backup found on Drive');
        setState(() {
          _view = _RestoreView.noBackup;
          _busy = false;
        });
        return;
      }

      _logUI(
        'backup detected — file=${version.fileName} size=${version.totalSizeBytes}B',
      );

      // Check if local data exists (for conflict detection)
      final hasLocalData = await _restoreService.hasLocalData();

      if (!mounted) return;

      _logUI('hasLocalData=$hasLocalData');

      setState(() {
        _detectedVersion = version;
        _hasLocalData = hasLocalData;
        _view = _RestoreView.prompt;
        _busy = false;
      });

      // If auto-restore is enabled, skip to password entry
      if (widget.autoRestore && mounted) {
        debugPrint('RESTORE UI: autoRestore=true, jumping to password view');
        setState(() => _view = _RestoreView.password);
      }
    } catch (e, st) {
      debugPrint('RESTORE UI: _detectBackup exception: $e\n$st');
      if (mounted) {
        setState(() {
          _view = _RestoreView.noBackup;
          _error = 'Detection failed: ${e.toString()}';
          _busy = false;
        });
      }
    }
  }

  Future<void> _startRestore() async {
    _logUI('_startRestore called — busy=$_busy');
    if (_busy) {
      _logUI('_startRestore blocked — busy flag is true');
      return;
    }

    if (_passwordCtrl.text.isEmpty) {
      if (mounted) setState(() => _error = 'Enter your vault password to restore.');
      return;
    }

    if (_detectedVersion == null) {
      _logUI('_startRestore blocked — _detectedVersion is null');
      if (mounted) setState(() => _error = 'No backup version detected. Go back and retry.');
      return;
    }

    final version = _detectedVersion;
    if (version == null) {
      if (mounted) {
        setState(() {
          _view = _RestoreView.detecting;
          _error = 'No backup version detected.';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
        _view = _RestoreView.restoring;
      });
    }

    try {
      debugPrint(
        'RESTORE UI: calling prepareRestore for version=${version.fileName}',
      );

      final info = await _restoreService.prepareRestore(
        version: version,
        password: _passwordCtrl.text,
      );

      if (!mounted) {
        _logUI('widget unmounted during prepareRestore');
        return;
      }

      if (info == null) {
        _logUI('prepareRestore returned null — likely wrong password or download failure');
        setState(() {
          _view = _RestoreView.password;
          _error =
              'Restore preparation failed. Check your password, internet connection, and try again.';
          _busy = false;
        });
        return;
      }

      if (info.error != null) {
        _logUI('prepareRestore returned error: ${info.error}');
        setState(() {
          _view = _RestoreView.password;
          _error = info.error;
          _busy = false;
        });
        return;
      }

      _logUI(
        'prepareRestore success — '
        'notes=${info.mainNoteCount} hidden=${info.hiddenNoteCount} '
        'drive=${info.driveFileCount} passwords=${info.passwordEntryCount}',
      );

      setState(() {
        _restoreInfo = info;
      });

      // If local data exists, show conflict resolution
      if (_hasLocalData) {
        setState(() {
          _view = _RestoreView.conflict;
          _busy = false;
        });
        return;
      }

      // No local data — proceed directly with replace mode
      _logUI('no local data conflict — proceeding with replace mode');
      await _commitRestore(RestoreMode.replace);
    } catch (e, st) {
      _logUI('_startRestore EXCEPTION: $e');
      debugPrint('RESTORE UI: _startRestore EXCEPTION: $e\n$st');
      if (mounted) {
        setState(() {
          _view = _RestoreView.password;
          _error = 'Restore failed unexpectedly: ${e.toString()}';
          _busy = false;
        });
      }
    }
  }

  Future<void> _commitRestore(RestoreMode mode) async {
    _logUI(
      '_commitRestore called — mode=$mode committing=$_committing restoreInfo=${_restoreInfo != null}',
    );

    if (_restoreInfo == null) {
      _logUI('_commitRestore aborted — restoreInfo is null');
      return;
    }
    if (_committing) {
      _logUI('_commitRestore aborted — already committing');
      return;
    }

    _committing = true;

    if (mounted) {
      setState(() {
        _view = _RestoreView.restoring;
        _busy = true;
        _error = null;
      });
    }

    try {
      _logUI('calling commitRestore...');

      final result = await _restoreService.commitRestore(
        _restoreInfo!,
        mode: mode,
      );

      if (!mounted) {
        _logUI('widget unmounted during commitRestore');
        return;
      }

      _logUI('commitRestore result — success=${result.success} error=${result.error}');

      if (result.success) {
        setState(() {
          _restoreResult = result;
          _view = _RestoreView.success;
          _busy = false;
        });
        FloatingNotificationService.instance.show(
          'Vault restored successfully!',
          type: AppNotificationType.success,
        );
        widget.onComplete?.call(true);
      } else {
        _logUI('restore FAILED: ${result.error}');
        final errorMsg = result.error?.isNotEmpty == true
            ? result.error!
            : 'Restore failed for an unknown reason. Please try again.';
        setState(() {
          _view = _RestoreView.failed;
          _error = errorMsg;
          _busy = false;
        });
        widget.onComplete?.call(false);
      }
    } catch (e, st) {
      _logUI('_commitRestore EXCEPTION: $e');
      debugPrint('RESTORE UI: _commitRestore EXCEPTION: $e\n$st');
      if (mounted) {
        setState(() {
          _view = _RestoreView.failed;
          _error = 'Restore failed: ${e.toString()}';
          _busy = false;
        });
        widget.onComplete?.call(false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _committing = false;
        });
      }
      _logUI('_committing reset to false');
    }
  }

  void _cancel() {
    _logUI('_cancel called');
    if (_restoreInfo != null) {
      _restoreService.cancelRestore(_restoreInfo!);
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _skip() {
    _logUI('_skip called');
    if (mounted) Navigator.of(context).pop('skip');
  }

  void _later() {
    _logUI('_later called');
    if (mounted) Navigator.of(context).pop('later');
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Restore Backup'),
        leading: _view == _RestoreView.restoring
            ? const SizedBox.shrink()
            : null,
        automaticallyImplyLeading: _view != _RestoreView.restoring,
      ),
      body: SafeArea(
        child: switch (_view) {
          _RestoreView.detecting => _buildDetecting(cs),
          _RestoreView.noBackup => _buildNoBackup(cs),
          _RestoreView.prompt => _buildPrompt(cs),
          _RestoreView.password => _buildPassword(cs),
          _RestoreView.restoring => _buildRestoring(cs),
          _RestoreView.conflict => _buildConflict(cs),
          _RestoreView.success => _buildSuccess(cs),
          _RestoreView.failed => _buildFailed(cs),
        },
      ),
    );
  }

  // ── View: Detecting ──────────────────────────────────────────────────────

  Widget _buildDetecting(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
          ),
          const SizedBox(height: 20),
          Text(
            'Checking ${widget.driveService.providerName} for backup...',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'This may take a moment',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── View: No backup found ────────────────────────────────────────────────

  Widget _buildNoBackup(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No backup found',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'No VaultX backup was found on your ${widget.driveService.providerName} account.\n\n'
              'Create a backup from the Settings screen first.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _buildErrorBox(cs, _error!),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _cancel,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Go back'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _detectBackup,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry detection'),
            ),
          ],
        ),
      ),
    );
  }

  // ── View: Restore prompt ─────────────────────────────────────────────────

  Widget _buildPrompt(ColorScheme cs) {
    final v = _detectedVersion;
    if (v == null) {
      // Shouldn't happen but guard defensively
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.restore_page, size: 56, color: cs.primary),
        const SizedBox(height: 16),
        Text(
          'Backup Found',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'An existing VaultX backup was found on your ${widget.driveService.providerName}.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        _buildInfoCard(cs, v),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () {
                  debugPrint('RESTORE UI: "Restore Now" button pressed');
                  setState(() => _view = _RestoreView.password);
                },
          icon: const Icon(Icons.restore),
          label: const Text('Restore Now'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _skip,
          child: const Text('Skip'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : _later,
          child: const Text('Later'),
        ),
      ],
    );
  }

  // ── View: Password entry ─────────────────────────────────────────────────

  Widget _buildPassword(ColorScheme cs) {
    final v = _detectedVersion;
    if (v == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.lock_outline, size: 48, color: cs.primary),
        const SizedBox(height: 16),
        Text(
          'Enter Vault Password',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Enter your master vault password to decrypt the backup.\n'
          'This must be the SAME password used on the original device.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        _buildInfoCard(cs, v),
        const SizedBox(height: 20),
        TextField(
          controller: _passwordCtrl,
          obscureText: !_passwordVisible,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: 'Vault password',
            prefixIcon: const Icon(Icons.key),
            suffixIcon: IconButton(
              icon: Icon(
                _passwordVisible ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () =>
                  setState(() => _passwordVisible = !_passwordVisible),
            ),
          ),
          onSubmitted: (_) {
            if (!_busy) {
              debugPrint('RESTORE UI: password submitted via keyboard');
              _startRestore();
            }
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _buildErrorBox(cs, _error!),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () {
                  debugPrint('RESTORE UI: "Verify & Restore" button pressed');
                  _startRestore();
                },
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.restore),
          label: Text(_busy ? 'Verifying...' : 'Verify & Restore'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _cancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  // ── View: Restoring (progress) ───────────────────────────────────────────

  Widget _buildRestoring(ColorScheme cs) {
    final p = _progress;
    final stage = p?.stage ?? RestoreStage.restoring;
    final fraction = p?.fraction ?? 0.0;
    final done = stage == RestoreStage.completed;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              value: done ? 1.0 : (fraction > 0 ? fraction : null),
              color: done ? Colors.green : cs.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _stageTitle(stage),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (p != null &&
              p.componentName != null &&
              p.componentName!.isNotEmpty)
            Text(
              p.componentName!,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          if (fraction > 0) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${(fraction * 100).toStringAsFixed(0)}%',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
          const SizedBox(height: 24),
          _buildStageList(cs, stage),
          if (p?.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                p!.error!,
                style: TextStyle(color: cs.error, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStageList(ColorScheme cs, RestoreStage current) {
    final stages = RestoreStage.values
        .where((s) => s != RestoreStage.completed && s != RestoreStage.failed)
        .toList();
    return Column(
      children: stages.map((s) {
        final isActive = s == current;
        final isDone = _stageIndex(s) < _stageIndex(current);
        IconData icon;
        Color color;
        if (isDone) {
          icon = Icons.check_circle;
          color = Colors.green;
        } else if (isActive) {
          icon = Icons.play_circle_filled;
          color = cs.primary;
        } else {
          icon = Icons.radio_button_unchecked;
          color = cs.onSurfaceVariant.withValues(alpha: 0.4);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                _stageLabel(s),
                style: TextStyle(
                  color: isActive
                      ? cs.onSurface
                      : cs.onSurfaceVariant.withValues(
                          alpha: isDone ? 0.7 : 0.4,
                        ),
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  int _stageIndex(RestoreStage s) {
    const order = [
      RestoreStage.detecting,
      RestoreStage.downloading,
      RestoreStage.decrypting,
      RestoreStage.verifying,
      RestoreStage.resolvingConflicts,
      RestoreStage.restoring,
      RestoreStage.rebuildingIndexes,
    ];
    return order.indexOf(s);
  }

  String _stageLabel(RestoreStage s) => switch (s) {
    RestoreStage.detecting => 'Detecting backup',
    RestoreStage.downloading => 'Downloading',
    RestoreStage.decrypting => 'Decrypting',
    RestoreStage.verifying => 'Verifying',
    RestoreStage.resolvingConflicts => 'Checking conflicts',
    RestoreStage.restoring => 'Restoring data',
    RestoreStage.rebuildingIndexes => 'Rebuilding indexes',
    _ => '',
  };

  String _stageTitle(RestoreStage s) => switch (s) {
    RestoreStage.detecting => 'Detecting backup...',
    RestoreStage.downloading => 'Downloading backup...',
    RestoreStage.decrypting => 'Decrypting backup...',
    RestoreStage.verifying => 'Verifying backup integrity...',
    RestoreStage.resolvingConflicts => 'Checking for conflicts...',
    RestoreStage.restoring => 'Restoring your vault...',
    RestoreStage.rebuildingIndexes => 'Rebuilding indexes...',
    RestoreStage.completed => 'Restore complete!',
    RestoreStage.failed => 'Restore failed',
  };

  // ── View: Conflict resolution ────────────────────────────────────────────

  Widget _buildConflict(ColorScheme cs) {
    final info = _restoreInfo;
    if (info == null) return const Center(child: Text('No restore info available'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.warning_amber_rounded, size: 48, color: Colors.orange),
        const SizedBox(height: 16),
        Text(
          'Existing data found',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Your vault already has data on this device.\n\n'
          'Backup contains:',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        _buildCountTable(cs, info),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _committing
                ? null
                : () {
                    debugPrint('RESTORE UI: "Replace local data" pressed');
                    _commitRestore(RestoreMode.replace);
                  },
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Replace local data'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _committing
                ? null
                : () {
                    debugPrint('RESTORE UI: "Merge" pressed');
                    _commitRestore(RestoreMode.merge);
                  },
            icon: const Icon(Icons.merge),
            label: const Text('Merge (keep existing)'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _committing ? null : _cancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  // ── View: Success ────────────────────────────────────────────────────────

  Widget _buildSuccess(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            Text(
              'Restore successful!',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_restoreInfo != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _countRow(
                      Icons.description,
                      'Notes',
                      _restoreResult?.mainNotesRestored ?? _restoreInfo!.mainNoteCount,
                    ),
                    _countRow(
                      Icons.visibility_off,
                      'Hidden',
                      _restoreResult?.hiddenNotesRestored ?? _restoreInfo!.hiddenNoteCount,
                    ),
                    _countRow(
                      Icons.folder,
                      'Drive files',
                      _restoreResult?.driveFilesRestored ?? _restoreInfo!.driveFileCount,
                    ),
                    _countRow(
                      Icons.key,
                      'Passwords',
                      _restoreResult?.passwordEntriesRestored ?? _restoreInfo!.passwordEntryCount,
                    ),
                  ],
                ),
              ),
            if (_restoreResult != null && _restoreResult!.preservedLocalItems > 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Preserved ${_restoreResult!.preservedLocalItems} local-only items',
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                debugPrint('RESTORE UI: "Open vault" pressed after success');
                final key = _restoreInfo?.masterKey;
                if (key != null) {
                  Navigator.of(context).pop(base64Encode(key));
                } else {
                  Navigator.of(context).pop('success');
                }
              },
              child: const Text('Open vault'),
            ),
          ],
        ),
      ),
    );
  }

  // ── View: Failed ─────────────────────────────────────────────────────────

  Widget _buildFailed(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: cs.error),
            const SizedBox(height: 16),
            Text(
              'Restore failed',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_error != null) _buildErrorBox(cs, _error!),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                debugPrint('RESTORE UI: "Try again" pressed from failed view');
                setState(() {
                  _view = _RestoreView.password;
                  _error = null;
                  // Reset committing flag so another attempt is allowed
                  _committing = false;
                  _busy = false;
                });
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _cancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  // ── Shared widgets ───────────────────────────────────────────────────────

  Widget _buildErrorBox(ColorScheme cs, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(ColorScheme cs, BackupVersion v) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(Icons.calendar_today, 'Backup date', v.label),
            const SizedBox(height: 4),
            _infoRow(Icons.storage, 'Size', formatBytes(v.totalSizeBytes)),
            const SizedBox(height: 4),
            _infoRow(
              Icons.phonelink,
              'Device',
              v.fileName.isNotEmpty ? v.fileName.split('_').last : 'Unknown',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountTable(ColorScheme cs, RestoreInfo info) {
    final rows = <Widget>[];
    if (info.mainNoteCount > 0) {
      rows.add(_countRow(Icons.description, 'Notes', info.mainNoteCount));
    }
    if (info.hiddenNoteCount > 0) {
      rows.add(_countRow(Icons.visibility_off, 'Hidden', info.hiddenNoteCount));
    }
    if (info.driveFileCount > 0) {
      rows.add(_countRow(Icons.folder, 'Drive files', info.driveFileCount));
    }
    if (info.driveBlobCount > 0) {
      rows.add(_countRow(Icons.cloud, 'Drive blobs', info.driveBlobCount));
    }
    if (info.attachmentBlobCount > 0) {
      rows.add(
        _countRow(Icons.attach_file, 'Attachments', info.attachmentBlobCount),
      );
    }
    if (info.passwordEntryCount > 0) {
      rows.add(_countRow(Icons.key, 'Passwords', info.passwordEntryCount));
    }
    if (info.settingsCount > 0) {
      rows.add(_countRow(Icons.settings, 'Settings', info.settingsCount));
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: rows),
    );
  }

  Widget _countRow(IconData icon, String label, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(
            '$count',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(
          icon,
          size: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }


}

enum _RestoreView {
  detecting,
  noBackup,
  prompt,
  password,
  restoring,
  conflict,
  success,
  failed,
}

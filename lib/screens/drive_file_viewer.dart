import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../models/drive_file.dart';
import '../services/drive_service.dart';
import '../services/floating_notification_service.dart';

class DriveFileViewer extends StatefulWidget {
  const DriveFileViewer({super.key, required this.file, required this.drive});

  final SecureDriveFile file;
  final DriveService drive;

  @override
  State<DriveFileViewer> createState() => _DriveFileViewerState();
}

class _DriveFileViewerState extends State<DriveFileViewer> {
  String? _tempPath;
  bool _loading = true;
  String? _error;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _decrypt();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _cleanup();
    super.dispose();
  }

  Future<void> _decrypt() async {
    final path = await widget.drive.decryptToTemp(widget.file);
    if (!mounted) return;
    if (path != null) {
      setState(() {
        _tempPath = path;
        _loading = false;
      });
      if (widget.file.kind == 'video') {
        _initVideo();
      }
    } else {
      setState(() {
        _error = 'Failed to decrypt file';
        _loading = false;
      });
    }
  }

  Future<void> _initVideo() async {
    if (_tempPath == null) return;
    try {
      final ctrl = VideoPlayerController.file(File(_tempPath!));
      await ctrl.initialize();
      if (!mounted) return;
      setState(() {
        _videoController?.dispose();
        _videoController = ctrl;
      });
      ctrl.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load video: $e';
        _loading = false;
      });
    }
  }

  void _cleanup() {
    if (_tempPath != null) {
      try {
        File(_tempPath!).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _share() async {
    if (_tempPath == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(_tempPath!)]));
  }

  Future<void> _openExternal() async {
    if (_tempPath == null) return;
    final result = await OpenFile.open(_tempPath!);
    if (result.type != ResultType.done && mounted) {
      FloatingNotificationService.instance.show('Could not open: ${result.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _share,
            icon: const Icon(Icons.share),
            tooltip: 'Share',
          ),
          IconButton(
            onPressed: _loading ? null : _openExternal,
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open externally',
          ),
        ],
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: cs.error),
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: cs.error)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _decrypt();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_tempPath == null) {
      return const Center(child: Text('File unavailable'));
    }

    return _buildViewer(cs);
  }

  Widget _buildViewer(ColorScheme cs) {
    switch (widget.file.kind) {
      case 'image':
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Center(
            child: Image.file(
              File(_tempPath!),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('Unsupported image format'),
            ),
          ),
        );
      case 'video':
        return _buildVideoPlayer(cs);
      case 'pdf':
      case 'document':
      case 'id':
      case 'password':
      default:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.insert_drive_file, size: 80, color: cs.primary),
                const SizedBox(height: 16),
                Text(
                  widget.file.name,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.file.sizeLabel}  ·  ${widget.file.kind}',
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _openExternal,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open with external app'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.share),
                  label: const Text('Share'),
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _buildVideoPlayer(ColorScheme cs) {
    final ctrl = _videoController;
    if (ctrl == null) {
      return const Center(child: Text('Initializing video...'));
    }
    final isInitialized = ctrl.value.isInitialized;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: isInitialized
                ? AspectRatio(
                    aspectRatio: ctrl.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        VideoPlayer(ctrl),
                        _VideoControls(controller: ctrl),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
        if (isInitialized)
          _VideoProgressBar(controller: ctrl, cs: cs),
      ],
    );
  }
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({required this.controller});
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      },
      child: Container(
        color: Colors.black26,
        child: Center(
          child: controller.value.isPlaying
              ? const SizedBox.shrink()
              : const Icon(Icons.play_arrow, size: 64, color: Colors.white),
        ),
      ),
    );
  }
}

class _VideoProgressBar extends StatelessWidget {
  const _VideoProgressBar({required this.controller, required this.cs});
  final VideoPlayerController controller;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return VideoProgressIndicator(
      controller,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      colors: VideoProgressColors(
        playedColor: cs.primary,
        bufferedColor: cs.primary.withValues(alpha: 0.3),
        backgroundColor: cs.surfaceContainerHighest,
      ),
    );
  }
}

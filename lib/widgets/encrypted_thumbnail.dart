import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/services.dart';

class EncryptedThumbnail extends StatefulWidget {
  const EncryptedThumbnail({
    super.key,
    required this.noteId,
    required this.attachment,
    this.blobs,
    this.fit = BoxFit.cover,
  });

  final String noteId;
  final SecureAttachment attachment;
  final EncryptedBlobService? blobs;
  final BoxFit fit;

  @override
  State<EncryptedThumbnail> createState() => _EncryptedThumbnailState();
}

class _EncryptedThumbnailState extends State<EncryptedThumbnail> {
  Future<Uint8List>? _futureBytes;
  
  // A simple static memory cache mapping attachment.id to Uint8List to avoid flickering
  static final Map<String, Uint8List> _imageCache = {};

  @override
  void initState() {
    super.initState();
    _loadBytes();
  }

  @override
  void didUpdateWidget(covariant EncryptedThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id) {
      _loadBytes();
    }
  }

  void _loadBytes() {
    if (_imageCache.containsKey(widget.attachment.id)) {
      return; // Already cached
    }
    
    if (widget.blobs == null) {
      return;
    }

    setState(() {
      _futureBytes = widget.blobs!.decryptAttachmentToBytes(
        widget.noteId,
        widget.attachment,
      ).then((bytes) {
        // We could resize the image here using the image package to save memory if needed,
        // but MemoryImage is usually fine for thumbnails. Let's just cache the raw bytes.
        if (mounted) {
          _imageCache[widget.attachment.id] = bytes;
          
          // Basic LRU logic to prevent memory bloat (max 50 cached thumbnails)
          if (_imageCache.length > 50) {
            _imageCache.remove(_imageCache.keys.first);
          }
        }
        return bytes;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_imageCache.containsKey(widget.attachment.id)) {
      return Image.memory(
        _imageCache[widget.attachment.id]!,
        fit: widget.fit,
        cacheWidth: 300, // Hint to Flutter to decode it smaller for thumbnails
      );
    }

    if (widget.blobs == null) {
      return _buildPlaceholder(context);
    }

    return FutureBuilder<Uint8List>(
      future: _futureBytes,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return _buildPlaceholder(context, error: true);
        }

        return Image.memory(
          snapshot.data!,
          fit: widget.fit,
          cacheWidth: 300, // Important for performance in Gallery View
        );
      },
    );
  }

  Widget _buildPlaceholder(BuildContext context, {bool error = false}) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          error ? Icons.broken_image_outlined : Icons.image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          size: 48,
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ocr_preprocessor.dart';
import 'ocr_service.dart';

enum OcrJobState {
  queued,
  preprocessing,
  processing,
  completed,
  failed,
  cancelled,
}

class OcrJob {
  OcrJob({
    required this.id,
    required this.noteId,
    required this.imagePath,
    required this.attachmentName,
    this.state = OcrJobState.queued,
    this.result,
    this.error,
    this.optimizedPath,
    this.preprocessingResult,
  });

  final String id;
  final String noteId;
  final String imagePath;
  final String attachmentName;
  OcrJobState state;
  String? result;
  String? error;
  String? optimizedPath;
  OcrPreprocessingResult? preprocessingResult;

  OcrJob copyWith({
    OcrJobState? state,
    String? result,
    String? error,
    String? optimizedPath,
    OcrPreprocessingResult? preprocessingResult,
  }) {
    return OcrJob(
      id: id,
      noteId: noteId,
      imagePath: imagePath,
      attachmentName: attachmentName,
      state: state ?? this.state,
      result: result ?? this.result,
      error: error ?? this.error,
      optimizedPath: optimizedPath ?? this.optimizedPath,
      preprocessingResult: preprocessingResult ?? this.preprocessingResult,
    );
  }
}

class OcrBatchItem {
  OcrBatchItem({
    required this.noteId,
    required this.attachmentName,
    required this.tempPath,
  });

  final String noteId;
  final String attachmentName;
  final String tempPath;
}

class OcrQueueService extends ChangeNotifier {
  OcrQueueService._();
  static final OcrQueueService _instance = OcrQueueService._();
  factory OcrQueueService() => _instance;

  final List<OcrJob> _queue = [];
  bool _processing = false;
  final Set<String> _cancelled = {};
  final Set<String> _tempFiles = {};
  bool _disposed = false;

  static const _preprocessTimeout = Duration(seconds: 15);
  static const _ocrTimeout = Duration(seconds: 30);
  static const _yieldDelay = Duration(milliseconds: 50);
  static const _maxPreprocessBatch = 3;

  List<OcrJob> get queue => List.unmodifiable(_queue);
  bool get isProcessing => _processing;
  int get pendingCount =>
      _queue.where((j) => j.state == OcrJobState.queued).length;
  int get completedCount =>
      _queue.where((j) => j.state == OcrJobState.completed).length;
  int get totalCount => _queue.length;

  List<OcrJob> get completedJobs =>
      _queue.where((j) => j.state == OcrJobState.completed).toList();

  bool _notifyPending = false;

  void _scheduleNotify() {
    if (_disposed) return;
    if (_notifyPending) return;
    _notifyPending = true;
    Future.microtask(() {
      if (_disposed) return;
      _notifyPending = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String enqueue({
    required String noteId,
    required String imagePath,
    required String attachmentName,
  }) {
    final id = 'ocr_${DateTime.now().microsecondsSinceEpoch}_${_queue.length}';
    _queue.add(
      OcrJob(
        id: id,
        noteId: noteId,
        imagePath: imagePath,
        attachmentName: attachmentName,
      ),
    );
    _tempFiles.add(imagePath);
    _scheduleNotify();
    _processQueue();
    return id;
  }

  List<String> enqueueBatch(List<OcrBatchItem> items) {
    final ids = <String>[];
    for (final item in items) {
      final id =
          'ocr_${DateTime.now().microsecondsSinceEpoch}_${_queue.length}';
      _queue.add(
        OcrJob(
          id: id,
          noteId: item.noteId,
          imagePath: item.tempPath,
          attachmentName: item.attachmentName,
        ),
      );
      _tempFiles.add(item.tempPath);
      ids.add(id);
    }
    _scheduleNotify();
    if (!_processing) _processQueue();
    return ids;
  }

  void cancel(String jobId) {
    _cancelled.add(jobId);
    final job = _queue.where((j) => j.id == jobId).firstOrNull;
    if (job != null &&
        (job.state == OcrJobState.queued ||
            job.state == OcrJobState.preprocessing)) {
      job.state = OcrJobState.cancelled;
      _cleanupTemp(job);
    }
    _scheduleNotify();
  }

  void cancelAll() {
    for (final job in _queue) {
      if (job.state == OcrJobState.queued ||
          job.state == OcrJobState.preprocessing) {
        _cancelled.add(job.id);
        job.state = OcrJobState.cancelled;
        _cleanupTemp(job);
      } else if (job.state == OcrJobState.processing) {
        _cancelled.add(job.id);
      }
    }
    _scheduleNotify();
  }

  void retry(String jobId) {
    final job = _queue.where((j) => j.id == jobId).firstOrNull;
    if (job == null) return;
    if (job.state == OcrJobState.completed || job.state == OcrJobState.failed) {
      job.state = OcrJobState.queued;
      job.result = null;
      job.error = null;
      job.optimizedPath = null;
      job.preprocessingResult = null;
      _scheduleNotify();
      _processQueue();
    }
  }

  void removeJob(String jobId) {
    final job = _queue.where((j) => j.id == jobId).firstOrNull;
    if (job != null) {
      _cleanupTemp(job);
      _queue.remove(job);
    }
    _scheduleNotify();
  }

  void removeNoteJobs(String noteId) {
    final toRemove = _queue.where((j) => j.noteId == noteId).toList();
    for (final job in toRemove) {
      _cleanupTemp(job);
      _queue.remove(job);
    }
    _scheduleNotify();
  }

  void clearCompleted() {
    final toRemove = _queue
        .where(
          (j) =>
              j.state == OcrJobState.completed ||
              j.state == OcrJobState.cancelled,
        )
        .toList();
    for (final job in toRemove) {
      _cleanupTemp(job);
      _queue.remove(job);
    }
    _scheduleNotify();
  }

  void _cleanupTemp(OcrJob job) {
    _cancelled.remove(job.id);
    for (final path in [job.imagePath, job.optimizedPath]) {
      if (path == null) continue;
      _tempFiles.remove(path);
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    _scheduleNotify();

    while (true) {
      final pending = _queue
          .where((j) => j.state == OcrJobState.queued)
          .toList();
      if (pending.isEmpty) break;

      final batch = pending.take(_maxPreprocessBatch).toList();

      for (final job in batch) {
        job.state = OcrJobState.preprocessing;
      }
      _scheduleNotify();

      final preprocessResults = await Future.wait(
        batch.map((job) => _preprocessSingle(job)),
      );

      for (final job in preprocessResults) {
        if (job.state != OcrJobState.preprocessing &&
            job.state != OcrJobState.queued) {
          await Future.delayed(_yieldDelay);
          continue;
        }

        job.state = OcrJobState.processing;
        _scheduleNotify();

        try {
          final ocrPath = job.optimizedPath ?? job.imagePath;
          final text = await OcrService.extractText(
            ocrPath,
          ).timeout(_ocrTimeout);

          if (_cancelled.contains(job.id)) {
            job.state = OcrJobState.cancelled;
            _cancelled.remove(job.id);
          } else if (text != null && text.isNotEmpty) {
            job.state = OcrJobState.completed;
            job.result = text;
          } else {
            job.state = OcrJobState.failed;
            job.error = 'No text found in image';
          }
        } on TimeoutException {
          job.state = OcrJobState.failed;
          job.error = 'OCR timed out after 30 seconds';
        } catch (e) {
          job.state = OcrJobState.failed;
          job.error = e.toString();
        }

        _cleanupTemp(job);
        _scheduleNotify();
        await Future.delayed(_yieldDelay);
      }
    }

    _processing = false;
    _scheduleNotify();
  }

  Future<OcrJob> _preprocessSingle(OcrJob job) async {
    try {
      final result = await OcrPreprocessor.preprocess(
        job.imagePath,
      ).timeout(_preprocessTimeout);

      if (_cancelled.contains(job.id)) {
        job.state = OcrJobState.cancelled;
        _cancelled.remove(job.id);
        _cleanupTemp(job);
        _scheduleNotify();
        return job;
      }

      if (result != null) {
        job.optimizedPath = result.optimizedPath;
        job.preprocessingResult = result;
        _tempFiles.add(result.optimizedPath);
      } else {
        job.state = OcrJobState.failed;
        job.error =
            'Image preprocessing failed — file may be corrupted or unsupported';
        _cleanupTemp(job);
      }
    } on TimeoutException {
      job.state = OcrJobState.failed;
      job.error = 'Image preprocessing timed out';
      _cleanupTemp(job);
    } catch (e) {
      job.state = OcrJobState.failed;
      job.error = 'Preprocessing error: $e';
      _cleanupTemp(job);
    }

    _scheduleNotify();
    return job;
  }
}

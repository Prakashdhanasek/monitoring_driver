import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class FFmpegVideoRecorderService {
  FFmpegSession? _session;
  bool _isRecording = false;
  Timer? _queueScannerTimer;

  bool get isRecording => _isRecording;

  /// Starts the segmented recording session.
  Future<void> startRecording(String streamUrl) async {
    if (_isRecording) {
      debugPrint('[FFmpegRecorder] Already recording.');
      return;
    }

    final docDir = await _getVisibleDirectory();
    final segmentsDir = Directory(p.join(docDir.path, 'esp32_segments'));
    final queueDir = Directory(p.join(docDir.path, 'esp32_upload_queue'));

    if (!await segmentsDir.exists()) await segmentsDir.create(recursive: true);
    if (!await queueDir.exists()) await queueDir.create(recursive: true);

    // Segment output format: esp32_segments/video_1718545800000_%03d.mp4
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String outputPattern = p.join(segmentsDir.path, 'segment_${timestamp}_%03d.mp4');

    // FFmpeg segments command (using H.264 transcoding for web browser compatibility)
    // Use TCP transport for RTSP streams to prevent UDP packet loss
    final String rtspOpt = streamUrl.startsWith('rtsp') ? '-rtsp_transport tcp ' : '';
    final String ffmpegCommand =
        '-y ${rtspOpt}-i $streamUrl -c:v libx264 -r 15 -g 30 -preset ultrafast -profile:v baseline -pix_fmt yuv420p -f segment -segment_time 60 -reset_timestamps 1 "$outputPattern"';

    debugPrint('[FFmpegRecorder] Starting FFmpeg session...');
    debugPrint('[FFmpegRecorder] Command: ffmpeg $ffmpegCommand');

    _isRecording = true;
    _session = await FFmpegKit.executeAsync(
      ffmpegCommand,
      (session) async {
        final state = await session.getState();
        final returnCode = await session.getReturnCode();
        debugPrint('[FFmpegRecorder] FFmpeg session ended. State: $state, Return Code: $returnCode');
        _isRecording = false;
      },
      (log) {
        // Output all ffmpeg logs to console (useful for tracking connection errors/success)
        final String message = log.getMessage();
        if (message.contains('Error') || message.contains('failed') || message.contains('timeout')) {
          debugPrint('[FFmpeg Log ERROR] $message');
        } else {
          debugPrint('[FFmpeg Log] $message');
        }
      },
      (stats) {
        // Output continuous stream stats so you can verify data is actively arriving
        debugPrint('[FFmpeg Stats] Frame: ${stats.getVideoFrameNumber()}, Speed: ${stats.getSpeed()}x, Size: ${stats.getSize()} bytes');
      },
    );

    // Start a periodic scanner to check for completed segments every 5 seconds
    _queueScannerTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _scanAndQueueCompletedSegments(segmentsDir, queueDir);
    });
  }

  /// Stops the active recording session and moves any remaining segment to the queue.
  Future<void> stopRecording() async {
    _queueScannerTimer?.cancel();
    _queueScannerTimer = null;

    if (!_isRecording || _session == null) {
      debugPrint('[FFmpegRecorder] No active recording session to stop.');
      return;
    }

    debugPrint('[FFmpegRecorder] Stopping FFmpeg session...');
    await FFmpegKit.cancel(_session!.getSessionId());
    _isRecording = false;

    // Give FFmpeg a brief moment to release file handles, then scan and move everything
    await Future.delayed(const Duration(milliseconds: 500));
    final docDir = await _getVisibleDirectory();
    final segmentsDir = Directory(p.join(docDir.path, 'esp32_segments'));
    final queueDir = Directory(p.join(docDir.path, 'esp32_upload_queue'));
    await _moveAllRemainingSegments(segmentsDir, queueDir);
  }

  /// Helper: Scans the segments directory, sorts files by modified date,
  /// and moves all but the latest (active) file to the upload queue.
  void _scanAndQueueCompletedSegments(Directory segmentsDir, Directory queueDir) {
    try {
      if (!segmentsDir.existsSync()) return;
      final List<FileSystemEntity> files = segmentsDir.listSync().where((f) => f.path.endsWith('.mp4')).toList();
      if (files.length <= 1) return;

      // Sort by modified time ascending (oldest first)
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

      // The last file in sorted list is currently being written by FFmpeg.
      // Move all previous completed files to the upload queue.
      for (int i = 0; i < files.length - 1; i++) {
        final File file = files[i] as File;
        final String fileName = p.basename(file.path);
        final String newPath = p.join(queueDir.path, fileName);
        file.renameSync(newPath);
        debugPrint('[FFmpegRecorder] ✓ Moved completed segment to upload queue: $fileName');
      }
    } catch (e) {
      debugPrint('[FFmpegRecorder] Error scanning segments: $e');
    }
  }

  /// Helper: Moves all files in the segments folder to the queue (called when stopped).
  Future<void> _moveAllRemainingSegments(Directory segmentsDir, Directory queueDir) async {
    try {
      if (!segmentsDir.existsSync()) return;
      final List<FileSystemEntity> files = segmentsDir.listSync().where((f) => f.path.endsWith('.mp4')).toList();
      if (files.isEmpty) return;

      // Sort by modified time ascending (oldest first)
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

      // The last file in the list is the active segment that was interrupted and is corrupted.
      // We delete it so it doesn't clutter the queue with unplayable files.
      final lastFile = files.last;
      if (lastFile is File) {
        debugPrint('[FFmpegRecorder] Deleting incomplete/corrupted active segment: ${p.basename(lastFile.path)}');
        try {
          await lastFile.delete();
        } catch (delErr) {
          debugPrint('[FFmpegRecorder] Error deleting active segment: $delErr');
        }
        files.removeLast();
      }

      for (final file in files) {
        if (file is File) {
          final String fileName = p.basename(file.path);
          final String newPath = p.join(queueDir.path, fileName);
          await file.rename(newPath);
          debugPrint('[FFmpegRecorder] ✓ Moved remaining segment to upload queue: $fileName');
        }
      }
    } catch (e) {
      debugPrint('[FFmpegRecorder] Error moving remaining segments: $e');
    }
  }

  Future<Directory> _getVisibleDirectory() async {
    if (Platform.isAndroid) {
      final downloadDir = Directory('/storage/emulated/0/Download/monitoring_driver');
      if (!await downloadDir.exists()) {
        try {
          await downloadDir.create(recursive: true);
        } catch (_) {
          final extDir = await getExternalStorageDirectory();
          return extDir!;
        }
      }
      return downloadDir;
    } else {
      return await getApplicationDocumentsDirectory();
    }
  }
}

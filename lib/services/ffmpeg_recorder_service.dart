import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Duration of each video chunk in seconds (2 minutes).
const int _kChunkDurationSeconds = 120;

class FFmpegVideoRecorderService {
  bool _isRecording = false;

  /// The currently active FFmpeg session.
  FFmpegSession? _activeSession;

  /// Timer that fires every [_kChunkDurationSeconds] to rotate to the next chunk.
  Timer? _chunkRotationTimer;

  /// The RTSP/HTTP stream URL, kept so we can restart FFmpeg for each chunk.
  String? _streamUrl;

  /// Index counter for the current chunk (increments each rotation).
  int _chunkIndex = 0;

  /// Session-level timestamp prefix so all chunks share the same "session" name.
  String? _sessionTimestamp;

  bool get isRecording => _isRecording;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Starts continuous recording with 2-minute chunks saved to phone storage.
  Future<void> startRecording(String streamUrl) async {
    if (_isRecording) {
      debugPrint('[FFmpegRecorder] Already recording.');
      return;
    }

    _streamUrl = streamUrl;
    _chunkIndex = 0;
    _sessionTimestamp = DateTime.now().millisecondsSinceEpoch.toString();
    _isRecording = true;

    debugPrint('══════════════════════════════════════════════════');
    debugPrint('[FFmpegRecorder] ▶ CONTINUOUS RECORDING STARTED');
    debugPrint('[FFmpegRecorder]   Session  : $_sessionTimestamp');
    debugPrint('[FFmpegRecorder]   Chunk    : ${_kChunkDurationSeconds}s (${_kChunkDurationSeconds ~/ 60} min)');
    debugPrint('[FFmpegRecorder]   Stream   : $streamUrl');
    debugPrint('[FFmpegRecorder]   Storage  : /Download/monitoring_driver/esp32_videos/');
    debugPrint('══════════════════════════════════════════════════');

    // Start the first chunk immediately.
    await _startNewChunk(_chunkIndex);

    // Set a periodic timer to rotate chunks every 2 minutes.
    _chunkRotationTimer = Timer.periodic(
      const Duration(seconds: _kChunkDurationSeconds),
      (_) => _rotateChunk(),
    );
  }

  /// Stops the continuous recording. The in-progress chunk is saved (not discarded).
  Future<void> stopRecording() async {
    if (!_isRecording) {
      debugPrint('[FFmpegRecorder] No active recording to stop.');
      return;
    }

    debugPrint('[FFmpegRecorder] ■ Stopping continuous recording...');
    _chunkRotationTimer?.cancel();
    _chunkRotationTimer = null;
    _isRecording = false;

    // Stop the active session and save whatever it recorded so far.
    if (_activeSession != null) {
      final int savedIndex = _chunkIndex;
      await FFmpegKit.cancel(_activeSession!.getSessionId());
      _activeSession = null;
      await Future.delayed(const Duration(milliseconds: 800));

      // Remux the partial chunk so it's playable, then save.
      final rawPath = await _buildRawOutputPath(savedIndex);
      final rawFile = File(rawPath);
      if (await rawFile.exists() && await rawFile.length() > 0) {
        debugPrint('[FFmpegRecorder] Fixing & saving partial chunk $savedIndex...');
        final fixedPath = await _remuxToPlayableMp4(rawPath, savedIndex);
        if (fixedPath != null) {
          await _saveToPhoneStorage(fixedPath);
          await _moveToQueue(fixedPath);
        }
        // Clean up raw fragmented file.
        try { await rawFile.delete(); } catch (_) {}
      }
    }

    debugPrint('══════════════════════════════════════════════════');
    debugPrint('[FFmpegRecorder] ■ RECORDING FULLY STOPPED');
    debugPrint('[FFmpegRecorder]   Total chunks recorded: ${_chunkIndex + 1}');
    debugPrint('══════════════════════════════════════════════════');
  }

  // ---------------------------------------------------------------------------
  // Core: chunk start & rotation
  // ---------------------------------------------------------------------------

  /// Starts a new FFmpeg session that records to a FRAGMENTED MP4.
  /// Fragmented MP4 is safe to cancel — always has valid metadata.
  Future<void> _startNewChunk(int chunkIdx) async {
    if (_streamUrl == null) return;

    final outputFile = await _buildRawOutputPath(chunkIdx);
    debugPrint('[FFmpegRecorder] 🎬 CHUNK $chunkIdx STARTED → ${p.basename(outputFile)}');

    final String rtspOpt =
        _streamUrl!.startsWith('rtsp') ? '-rtsp_transport tcp ' : '';

    // KEY FIX: -movflags frag_keyframe+empty_moov writes metadata throughout
    // the file (not just at the end), so the MP4 is ALWAYS playable even if
    // FFmpeg is cancelled/killed mid-recording.
    final String ffmpegCommand =
        '-y ${rtspOpt}-i $_streamUrl '
        '-c:v libx264 -r 15 -g 30 -preset ultrafast '
        '-profile:v baseline -pix_fmt yuv420p '
        '-movflags frag_keyframe+empty_moov '
        '-t ${_kChunkDurationSeconds + 5} '
        '"$outputFile"';

    _activeSession = await FFmpegKit.executeAsync(
      ffmpegCommand,
      (session) async {
        final state = await session.getState();
        final returnCode = await session.getReturnCode();
        debugPrint('[FFmpegRecorder] Chunk $chunkIdx session ended — State: $state, RC: $returnCode');

        // If FFmpeg finished on its own (natural end), remux + save.
        if (_isRecording && _chunkIndex == chunkIdx) {
          final file = File(outputFile);
          if (await file.exists() && await file.length() > 0) {
            final fixedPath = await _remuxToPlayableMp4(outputFile, chunkIdx);
            if (fixedPath != null) {
              await _saveToPhoneStorage(fixedPath);
              await _moveToQueue(fixedPath);
            }
            try { await file.delete(); } catch (_) {}
          }
        }
      },
      (log) {
        final String msg = log.getMessage();
        debugPrint('[FFmpeg Log] $msg');
      },
      (stats) {
        debugPrint(
            '[FFmpeg Stats] Frame: ${stats.getVideoFrameNumber()}, Speed: ${stats.getSpeed()}x, Size: ${stats.getSize()} bytes');
      },
    );
  }

  /// Rotates: starts next chunk FIRST (zero-gap), then stops, remuxes & saves old chunk.
  Future<void> _rotateChunk() async {
    if (!_isRecording) return;

    final int completedIndex = _chunkIndex;
    final FFmpegSession? oldSession = _activeSession;
    final String rawFile = await _buildRawOutputPath(completedIndex);

    // ── Step 1: Start the NEXT chunk immediately (zero-gap) ──
    _chunkIndex++;
    debugPrint('[FFmpegRecorder] 🔄 ROTATING: chunk $completedIndex → $_chunkIndex (zero-gap)');
    await _startNewChunk(_chunkIndex);

    // ── Step 2: Now stop the OLD session (new one is already capturing) ──
    if (oldSession != null) {
      try {
        await FFmpegKit.cancel(oldSession.getSessionId());
      } catch (e) {
        debugPrint('[FFmpegRecorder] Error cancelling old session: $e');
      }
    }

    // Brief pause so the old file handle is released.
    await Future.delayed(const Duration(milliseconds: 800));

    // ── Step 3: Remux raw fragmented MP4 → standard playable MP4 ──
    final file = File(rawFile);
    if (await file.exists() && await file.length() > 0) {
      final sizeKB = (await file.length()) ~/ 1024;
      final sizeMB = (sizeKB / 1024).toStringAsFixed(1);
      debugPrint('[FFmpegRecorder] ✅ CHUNK $completedIndex COMPLETE — $sizeMB MB (raw)');

      final fixedPath = await _remuxToPlayableMp4(rawFile, completedIndex);
      if (fixedPath != null) {
        await _saveToPhoneStorage(fixedPath);
        await _moveToQueue(fixedPath);
      }

      // Clean up raw fragmented file.
      try { await file.delete(); } catch (_) {}
    } else {
      debugPrint('[FFmpegRecorder] ⚠ Chunk $completedIndex is empty — skipped.');
    }
  }

  // ---------------------------------------------------------------------------
  // Remux: converts fragmented MP4 → standard playable MP4
  // ---------------------------------------------------------------------------

  /// Takes a raw fragmented MP4 and remuxes it (no re-encoding, instant) into
  /// a standard MP4 with the moov atom at the front. Every phone player can
  /// play the resulting file.
  Future<String?> _remuxToPlayableMp4(String rawPath, int chunkIdx) async {
    final docDir = await _getVisibleDirectory();
    final segmentsDir = Directory(p.join(docDir.path, 'esp32_segments'));
    final String fixedName =
        'chunk_${_sessionTimestamp}_${chunkIdx.toString().padLeft(3, '0')}.mp4';
    final String fixedPath = p.join(segmentsDir.path, fixedName);

    // -c copy = no re-encoding, just copies audio/video streams (instant).
    // -movflags +faststart = moov atom at front → instant playback on phone.
    final String remuxCommand =
        '-y -i "$rawPath" -c copy -movflags +faststart "$fixedPath"';

    debugPrint('[FFmpegRecorder] 🔧 Remuxing chunk $chunkIdx to playable MP4...');

    final session = await FFmpegKit.execute(remuxCommand);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      final fixedFile = File(fixedPath);
      if (await fixedFile.exists() && await fixedFile.length() > 0) {
        final sizeKB = (await fixedFile.length()) ~/ 1024;
        debugPrint('[FFmpegRecorder] 🔧 Remux OK → $fixedName (${sizeKB} KB) — PLAYABLE ✓');
        return fixedPath;
      }
    }

    debugPrint('[FFmpegRecorder] ⚠ Remux failed for chunk $chunkIdx (RC: $returnCode)');
    // Fallback: copy raw file directly (fragmented MP4 still plays on most modern players).
    try {
      await File(rawPath).copy(fixedPath);
      debugPrint('[FFmpegRecorder] ⚠ Using raw fragmented MP4 as fallback.');
      return fixedPath;
    } catch (e) {
      debugPrint('[FFmpegRecorder] Error in fallback copy: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // File / directory helpers
  // ---------------------------------------------------------------------------

  /// Path for the raw fragmented MP4 that FFmpeg writes to (temporary).
  Future<String> _buildRawOutputPath(int index) async {
    final docDir = await _getVisibleDirectory();
    final segmentsDir = Directory(p.join(docDir.path, 'esp32_segments'));
    if (!await segmentsDir.exists()) {
      await segmentsDir.create(recursive: true);
    }
    final String fileName =
        'raw_${_sessionTimestamp}_${index.toString().padLeft(3, '0')}.mp4';
    return p.join(segmentsDir.path, fileName);
  }

  /// COPIES the playable chunk to a permanent phone-visible folder.
  /// Path: /Download/monitoring_driver/esp32_videos/
  Future<void> _saveToPhoneStorage(String filePath) async {
    try {
      final docDir = await _getVisibleDirectory();
      final videosDir = Directory(p.join(docDir.path, 'esp32_videos'));
      if (!await videosDir.exists()) {
        await videosDir.create(recursive: true);
      }
      final fileName = p.basename(filePath);
      final savedPath = p.join(videosDir.path, fileName);
      await File(filePath).copy(savedPath);
      final sizeKB = (await File(savedPath).length()) ~/ 1024;
      debugPrint('[FFmpegRecorder] 💾 SAVED TO PHONE: $fileName (${sizeKB} KB)');
      debugPrint('[FFmpegRecorder]    Path: ${videosDir.path}/$fileName');
    } catch (e) {
      debugPrint('[FFmpegRecorder] Error saving to phone storage: $e');
    }
  }

  /// MOVES the file to the upload queue for SFTP upload.
  /// Path: /Download/monitoring_driver/esp32_upload_queue/
  Future<void> _moveToQueue(String filePath) async {
    try {
      final docDir = await _getVisibleDirectory();
      final queueDir = Directory(p.join(docDir.path, 'esp32_upload_queue'));
      if (!await queueDir.exists()) {
        await queueDir.create(recursive: true);
      }
      final fileName = p.basename(filePath);
      final newPath = p.join(queueDir.path, fileName);
      await File(filePath).rename(newPath);
      debugPrint('[FFmpegRecorder] 📤 Queued for upload: $fileName');
    } catch (e) {
      debugPrint('[FFmpegRecorder] Error moving file to queue: $e');
    }
  }

  Future<Directory> _getVisibleDirectory() async {
    if (Platform.isAndroid) {
      final downloadDir =
          Directory('/storage/emulated/0/Download/monitoring_driver');
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

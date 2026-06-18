// lib/services/dashcam_recording_service.dart
// Automatically records ESP32-CAM RTSP stream in the background during trips.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

class DashcamRecordingService {
  static const String _defaultRtspUrl = 'rtsp://dashcam.local:8554/mjpeg/1';
  
  String _rtspUrl = _defaultRtspUrl;
  FFmpegSession? _currentSession;
  String? _currentOutputPath;

  /// Update the RTSP URL dynamically if needed
  void setRtspUrl(String url) {
    if (url.isNotEmpty) {
      _rtspUrl = url;
      debugPrint('[DashcamService] RTSP URL updated to: $_rtspUrl');
    }
  }

  String get rtspUrl => _rtspUrl;

  /// Starts the background recording of the RTSP stream.
  Future<void> startRecording(String tripId) async {
    if (_currentSession != null) {
      debugPrint('[DashcamService] A recording session is already running. Stopping it first.');
      await stopRecording();
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final outputPath = '${tempDir.path}/dashcam_trip_${tripId}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _currentOutputPath = outputPath;

      // FFmpeg command to capture the RTSP stream and convert it to H.264 MP4
      final ffmpegCommand = '-y -i $_rtspUrl -c:v libx264 -preset ultrafast -crf 28 $outputPath';
      
      debugPrint('==================================================');
      debugPrint('[DashcamService] STARTING BACKGROUND RECORDING');
      debugPrint('[DashcamService] STREAM URL: $_rtspUrl');
      debugPrint('[DashcamService] OUTPUT PATH: $outputPath');
      debugPrint('[DashcamService] FFMPEG CMD: ffmpeg $ffmpegCommand');
      debugPrint('==================================================');

      _currentSession = await FFmpegKit.executeAsync(
        ffmpegCommand,
        (session) async {
          final returnCode = await session.getReturnCode();
          final state = await session.getState();
          debugPrint('[DashcamService] FFmpeg session ended. State: $state, Return Code: $returnCode');

          if (ReturnCode.isSuccess(returnCode)) {
            debugPrint('[DashcamService] FFmpeg conversion completed successfully.');
            
            // Check if file exists and has size > 0
            final file = File(outputPath);
            if (await file.exists()) {
              final length = await file.length();
              debugPrint('[DashcamService] Video file size: $length bytes');
              if (length > 0) {
                try {
                  // Request gallery permission first
                  final hasAccess = await Gal.hasAccess();
                  if (!hasAccess) {
                    await Gal.requestAccess();
                  }

                  debugPrint('[DashcamService] Exporting video to gallery...');
                  await Gal.putVideo(outputPath);
                  debugPrint('[DashcamService] ✓ Successfully saved video to gallery: $outputPath');
                } catch (e) {
                  debugPrint('[DashcamService] ✗ Failed to save video to gallery: $e');
                }
              } else {
                debugPrint('[DashcamService] ✗ Output video file is empty.');
              }
            } else {
              debugPrint('[DashcamService] ✗ Output video file does not exist.');
            }
          } else {
            final failStackTrace = await session.getFailStackTrace();
            debugPrint('[DashcamService] ✗ FFmpeg execution failed. Return code: $returnCode, error: $failStackTrace');
          }
        },
        (log) {
          // Print FFmpeg output to the console in real-time for stream verification
          debugPrint('[FFmpeg Log] ${log.getMessage()}');
        },
      );
    } catch (e) {
      debugPrint('[DashcamService] ✗ Error initiating background recording: $e');
    }
  }

  /// Stops the active recording session and triggers formatting completion.
  Future<void> stopRecording() async {
    if (_currentSession == null) {
      debugPrint('[DashcamService] No active recording session to stop.');
      return;
    }

    final sessionId = _currentSession!.getSessionId();
    debugPrint('==================================================');
    debugPrint('[DashcamService] STOPPING BACKGROUND RECORDING');
    debugPrint('[DashcamService] SESSION ID: $sessionId');
    debugPrint('==================================================');

    try {
      await FFmpegKit.cancel(sessionId);
    } catch (e) {
      debugPrint('[DashcamService] ✗ Error cancelling FFmpeg session: $e');
    } finally {
      _currentSession = null;
    }
  }
}

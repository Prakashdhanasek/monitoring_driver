// lib/core/monitoring_engine.dart
// Central pipeline — processes each camera frame through all 8 monitoring features

import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'monitor_state.dart';
import 'ear_calculator.dart';

class MonitoringEngine {
  static const double kEarVarianceThreshold = 0.005; // Stricter to avoid false sunglasses mode
  static const double kSunglassesEarHigh = 0.33;
  static const double kOneEyeEarLow = 0.10;
  static const double kDrowsySeconds = 1.0;
  static const double kAsleepSeconds = 2.0;
  static const double kBlinkResetSeconds = 0.5;
  static const double kYawThreshold = 20.0; // Stricter distraction threshold
  static const double kPitchThreshold = -10.0;
  static const double kDistractionSeconds = 1.5;
  static const double kHeadDropSeconds = 1.0;
  static const double kYawnMarThreshold = 0.60;
  static const double kYawnSeconds = 2.5;
  static const double kBlinkImpairmentDeviation = 0.50;
  static const double kImpairmentTriggerSeconds = 30.0;
  static const int kCalibrationFrames = 60; // 2 seconds at 30fps, better chance to catch a blink

  final MonitorState state;
  int _noEyeFrames = 0;
  int _sunglass_null_frames = 0;

  MonitoringEngine(this.state);

  /// Main entry point — call once per frame with the detected face (if any)
  void processFrame(Face? face) {
    state.frameCount++;
    final now = DateTime.now();

    if (face == null) {
      // If the face is lost but the head was heavily dropped/tilted back right before,
      // the user might still be sleeping with their head severely tilted.
      // Continue the sleep timer in the background!
      if (state.headDropSince != null) {
        final elapsed = now.difference(state.headDropSince!).inMilliseconds / 1000.0;
        if (elapsed >= 5.0 && (state.drowsinessLevel != DrowsinessLevel.asleep || state.recentAlerts.where((a) => a.type == 'flag_sleeping').isEmpty)) {
          state.drowsinessLevel = DrowsinessLevel.asleep;
          state.addAlert(AlertEvent(
            type: 'flag_sleeping',
            message: 'FLAG: SEVERE DROWSINESS (Sleeping >= 5s)',
            needsScreenshot: true,
            isMajorFlag: true,
          ));
        }
      }
      _handleNoFace(now);
      return;
    }

    if (!state.calibrated) {
      _runCalibration(face, now);
      return;
    }

    _processHeadPose(face, now);
    _processEyesAndMouth(face, now);
    _processBlinks(now);
  }

  void _handleNoFace(DateTime now) {
    // If face disappears mid-session, pause drowsy timer
    state.eyesClosedSince = null;
    if (state.headDropSince == null) {
      state.drowsinessLevel = DrowsinessLevel.alert;
    }
    state.distractionStatus = DistractionStatus.forward;
    state.distractedSince = null;
  }

  // ─────────────────────────────────────────────
  // AUTO-CALIBRATION (first 40 frames)
  // ─────────────────────────────────────────────
  void _runCalibration(Face face, DateTime now) {
    final leftPts = EarCalculator.extractLeftEyePoints(face);
    final rightPts = EarCalculator.extractRightEyePoints(face);
    
    if (leftPts.isEmpty || rightPts.isEmpty) {
      _noEyeFrames++;
      if (_noEyeFrames >= 40) {
        // Only switch to sunglasses if CONSISTENTLY no eye landmarks for 40 frames (>1s)
        state.monitorMode = MonitorMode.sunglasses;
        state.earBaseline = 0.28;
        state.earThreshold = 0.21;
        state.calibrated = true;
        state.blinkBaselineStart = now;
        print('[Monitoring] Sunglasses mode auto-detected during calibration (no eyes seen for 40 frames).');
      }
      return;
    }

    _noEyeFrames = 0; // Reset counter since eyes were successfully found
    state.calibrationFrame++;

    final leftEar = EarCalculator.calculateEar(leftPts);
    final rightEar = EarCalculator.calculateEar(rightPts);
    final avgEar = (leftEar + rightEar) / 2.0;
    state.calibrationEarValues.add(avgEar);

    if (state.calibrationFrame >= kCalibrationFrames) {
      _finalizeCalibration(leftEar, rightEar);
    }
  }

  void _finalizeCalibration(double lastLeft, double lastRight) {
    final vals = state.calibrationEarValues;
    final avg = vals.reduce((a, b) => a + b) / vals.length;
    final variance = vals.map((v) => pow(v - avg, 2)).reduce((a, b) => a + b) / vals.length;

    // Check sunglasses: consistently high EAR with low variance
    if (avg > kSunglassesEarHigh && variance < kEarVarianceThreshold) {
      state.monitorMode = MonitorMode.sunglasses;
    }
    // Check one-eyed: one eye consistently below 0.10
    else if (lastLeft < kOneEyeEarLow) {
      state.monitorMode = MonitorMode.oneEye;
      state.oneEyeSide = 'RIGHT'; // using right eye
    } else if (lastRight < kOneEyeEarLow) {
      state.monitorMode = MonitorMode.oneEye;
      state.oneEyeSide = 'LEFT';
    } else {
      state.monitorMode = MonitorMode.normal;
    }

    // Set personal threshold = 80% of open-eye baseline
    state.earBaseline = avg;
    state.earThreshold = avg * 0.80;
    state.calibrated = true;

    // Start blink baseline period
    state.blinkBaselineStart = DateTime.now();
  }

  // ─────────────────────────────────────────────
  // HEAD POSE — Yaw (distraction) + Pitch (droop)
  // ─────────────────────────────────────────────
  void _processHeadPose(Face face, DateTime now) {
    // MLKit provides head euler angles directly — no solvePnP needed on mobile
    final yaw = face.headEulerAngleY ?? 0.0;    // left/right rotation
    final pitch = face.headEulerAngleX ?? 0.0;  // up/down tilt

    state.yaw = yaw;
    state.pitch = pitch;

    // Distraction: yaw > ±25° for 1.5s
    if (yaw.abs() > kYawThreshold) {
      state.distractedSince ??= now;
      final elapsed = now.difference(state.distractedSince!).inMilliseconds / 1000.0;
      if (elapsed >= kDistractionSeconds && state.distractionStatus != DistractionStatus.distracted) {
        state.distractionStatus = DistractionStatus.distracted;
        state.totalDistractionCount++;
        
        if (state.totalDistractionCount == 5) {
          state.addAlert(AlertEvent(
            type: 'flag_distraction', 
            message: 'FLAG: REPEATED DISTRACTED DRIVING (5+ times)',
            needsScreenshot: true,
            isMajorFlag: true,
          ));
        } else {
          state.addAlert(AlertEvent(
            type: 'distracted',
            message: '⚠ DISTRACTION DETECTED (${state.totalDistractionCount}/5)',
          ));
        }
      }
    } else {
      state.distractedSince = null;
      state.distractionStatus = DistractionStatus.forward;
    }

    // Head droop/tilt back: pitch < -10° (forward) or pitch > 10.0° (backward) for 3s
    if (pitch < kPitchThreshold || pitch > 10.0) {
      state.headDropSince ??= now;
      final elapsed = now.difference(state.headDropSince!).inMilliseconds / 1000.0;
      
      if (elapsed >= 5.0) {
        if (state.drowsinessLevel != DrowsinessLevel.asleep || state.recentAlerts.where((a) => a.type == 'flag_sleep_droop').isEmpty) {
          state.drowsinessLevel = DrowsinessLevel.asleep;
          state.addAlert(AlertEvent(
            type: 'flag_sleep_droop', 
            message: 'FLAG: SEVERE DROWSINESS (Head Drooping >= 5s)',
            needsScreenshot: true,
            isMajorFlag: true,
          ));
        }
      } else if (elapsed >= kHeadDropSeconds) {
        state.drowsinessLevel = DrowsinessLevel.asleep; // Head droop is severe
        state.addAlert(AlertEvent(type: 'head_drop', message: 'WAKE UP – HEAD DROOPING!'));
      }
    } else {
      state.headDropSince = null;
      // Sunglasses reset: when pitch recovers, clear drowsiness/head droop alert
      if (state.monitorMode == MonitorMode.sunglasses && state.yawningSince == null) {
        state.drowsinessLevel = DrowsinessLevel.alert;
        state.eyesClosedSince = null;
      }
    }
  }

  // ─────────────────────────────────────────────
  // EAR + MAR PROCESSING
  // ─────────────────────────────────────────────
  void _processEyesAndMouth(Face face, DateTime now) {
    final leftPts = EarCalculator.extractLeftEyePoints(face);
    final rightPts = EarCalculator.extractRightEyePoints(face);

    // ── Sunglasses Detection via Rolling Variance ─────────────────────────
    // ML Kit 'fast' mode often hallucinates open eye landmarks over dark sunglasses.
    // However, hallucinated eyes NEVER BLINK. We track the variance of EAR over time.
    // If variance is near-zero for 60+ frames, the eyes are occluded (sunglasses).
    
    double ear = 0.0;
    if (leftPts.isNotEmpty && rightPts.isNotEmpty) {
      final leftEar = EarCalculator.calculateEar(leftPts);
      final rightEar = EarCalculator.calculateEar(rightPts);
      state.leftEar = leftEar;
      state.rightEar = rightEar;
      ear = (leftEar + rightEar) / 2.0;

      // Track rolling EAR values (60 frames = 2 seconds at 30fps)
      state.calibrationEarValues.add(ear);
      if (state.calibrationEarValues.length > 60) {
        state.calibrationEarValues.removeAt(0);
      }

      if (state.calibrationEarValues.length == 60) {
        final avg = state.calibrationEarValues.reduce((a, b) => a + b) / 60;
        final variance = state.calibrationEarValues.map((v) => pow(v - avg, 2)).reduce((a, b) => a + b) / 60;

        if (variance < 0.0003 && avg > 0.15) { // Very still = hallucinated eyes over sunglasses
          _sunglass_null_frames++;
          if (_sunglass_null_frames > 10 && state.monitorMode != MonitorMode.sunglasses) {
            state.monitorMode = MonitorMode.sunglasses;
            print('[Monitoring] SUNGLASSES ON (zero variance detected)');
          }
        } else if (variance > 0.001) { // A blink happened = real open eyes, NOT sunglasses
          _sunglass_null_frames = 0;
          // Clear immediately so next detection cycle starts fresh — no lag
          state.calibrationEarValues.clear();
          if (state.monitorMode == MonitorMode.sunglasses) {
            state.monitorMode = MonitorMode.normal;
            print('[Monitoring] SUNGLASSES OFF (blink detected)');
          }
        }
      }

      if (state.monitorMode == MonitorMode.sunglasses) {
        _processMar(face, now);
        return; // EAR not used in sunglasses mode
      }

      switch (state.monitorMode) {
        case MonitorMode.normal:
          break;
        case MonitorMode.oneEye:
          ear = max(leftEar, rightEar);
          break;
        default:
          break;
      }
      _processDrowsinessEar(ear, now);
    } else {
      // If landmarks are completely lost, assume sunglasses if face is present
      if (state.monitorMode != MonitorMode.sunglasses) {
        _sunglass_null_frames++;
        if (_sunglass_null_frames > 25) {
          state.monitorMode = MonitorMode.sunglasses;
          print('[Monitoring] SUNGLASSES ON (no eye landmarks found)');
        }
      } else {
        _processMar(face, now);
      }
    }
  }

  void _processDrowsinessEar(double ear, DateTime now) {
    final eyesClosed = ear < state.earThreshold;

    if (eyesClosed) {
      // Eyes closed — start or continue timer
      state.eyesClosedSince ??= now;
      state.eyesOpenSince = null;

      final closedSecs = now.difference(state.eyesClosedSince!).inMilliseconds / 1000.0;

      if (closedSecs >= 5.0) {
        if (state.drowsinessLevel != DrowsinessLevel.asleep || state.recentAlerts.where((a) => a.type == 'flag_sleep').isEmpty) {
          state.drowsinessLevel = DrowsinessLevel.asleep;
          state.addAlert(AlertEvent(
            type: 'flag_sleep', 
            message: 'FLAG: SEVERE DROWSINESS (Sleeping >= 5s)',
            needsScreenshot: true,
            isMajorFlag: true,
          ));
        }
      } else if (closedSecs >= kDrowsySeconds) {
        if (state.drowsinessLevel == DrowsinessLevel.alert) {
          state.drowsinessLevel = DrowsinessLevel.drowsy;
          state.totalDrowsyCount++;
          
          if (state.totalDrowsyCount > 3) {
            state.addAlert(AlertEvent(
              type: 'flag_repeated_drowsy',
              message: 'FLAG: REPEATED DROWSINESS (>3 times)',
              needsScreenshot: true,
              isMajorFlag: true,
            ));
          } else {
            state.addAlert(AlertEvent(type: 'drowsy', message: 'DROWSINESS DETECTED! (${state.totalDrowsyCount}/3)'));
          }
        }
      }
    } else {
      // Eyes open — blink-tolerant reset: must be open for 500ms to reset timer
      if (state.lastEyeStateOpen == false) {
        // Eye just opened — record blink end
        state.blinkTimestamps.add(now);
        state.eyesOpenSince = now;
      }

      if (state.eyesOpenSince != null) {
        final openSecs = now.difference(state.eyesOpenSince!).inMilliseconds / 1000.0;
        if (openSecs >= kBlinkResetSeconds) {
          state.eyesClosedSince = null;
          state.drowsinessLevel = DrowsinessLevel.alert;
        }
      }
    }

    state.lastEyeStateOpen = !eyesClosed;

    // Clean up blink timestamps older than 60s
    final cutoff = now.subtract(const Duration(seconds: 60));
    state.blinkTimestamps.removeWhere((t) => t.isBefore(cutoff));
  }

  void _processMar(Face face, DateTime now) {
    final mouthPts = EarCalculator.extractMouthPoints(face);
    if (mouthPts.isEmpty) return;

    final mar = EarCalculator.calculateMar(mouthPts);
    state.mar = mar;

    if (mar > kYawnMarThreshold) {
      state.yawningSince ??= now;
      final elapsed = now.difference(state.yawningSince!).inMilliseconds / 1000.0;
      if (elapsed >= kYawnSeconds) {
        if (state.drowsinessLevel == DrowsinessLevel.alert) {
          state.drowsinessLevel = DrowsinessLevel.drowsy;
          state.addAlert(AlertEvent(type: 'yawn', message: 'DROWSY – YAWNING DETECTED!'));
        }
      }
    } else {
      state.yawningSince = null;
    }
  }

  // ─────────────────────────────────────────────
  // BLINK RATE IMPAIRMENT DETECTION
  // ─────────────────────────────────────────────
  void _processBlinks(DateTime now) {
    // Phase 1: build baseline (first 60s after calibration)
    if (!state.blinkBaselineSet && state.blinkBaselineStart != null) {
      final elapsed = now.difference(state.blinkBaselineStart!).inSeconds;
      if (elapsed >= 60) {
        state.blinkBaseline = state.blinkTimestamps.length.toDouble();
        state.blinkBaselineSet = true;
        state.blinkTimestamps.clear();
      }
      return;
    }

    // Phase 2: ongoing monitoring
    if (!state.blinkBaselineSet || state.blinkBaseline < 1) return;

    // Check suppression
    if (state.impairmentSuppressedUntil != null &&
        now.isBefore(state.impairmentSuppressedUntil!)) return;

    final currentRate = state.blinkTimestamps.length.toDouble();
    final deviation = (currentRate - state.blinkBaseline).abs() / state.blinkBaseline;

    if (deviation >= kBlinkImpairmentDeviation) {
      state.impairmentFlaggedSince ??= now;
      final secs = now.difference(state.impairmentFlaggedSince!).inMilliseconds / 1000.0;
      if (secs >= kImpairmentTriggerSeconds && !state.impairmentFlag) {
        state.impairmentFlag = true;
        state.addAlert(AlertEvent(
          type: 'flag_substance', 
          message: 'FLAG: SUSPECTED IMPAIRMENT (Deviated from Baseline)',
          needsScreenshot: true,
          isMajorFlag: true,
        ));
      }
    } else {
      state.impairmentFlaggedSince = null;
    }
  }

  /// Called when supervisor presses C (clear impairment)
  void clearImpairmentFlag() {
    state.impairmentFlag = false;
    state.impairmentFlaggedSince = null;
    state.impairmentSuppressedUntil = DateTime.now().add(const Duration(minutes: 5));
  }
}

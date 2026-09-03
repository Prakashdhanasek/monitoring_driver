import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'monitor_state.dart';
import 'ear_calculator.dart';

/// MonitoringEngine — per-frame drowsiness, distraction and sleep detection.
///
/// KEY BEHAVIOURS:
///  • Eyes CONTINUOUSLY closed >= 5s → WAKE UP alert
///  • Head DROPPED >= 5s            → WAKE UP alert
///  • Drowsiness 3 strikes (4s each) → WARNING audio
///  • Drowsiness 5 strikes           → MAJOR FLAG
///  • Distraction 1-4 strikes (3s each) → soft alert
///  • Distraction 5 strikes             → MAJOR FLAG
class MonitoringEngine {
  static const double kEarVarianceThreshold = 0.005;
  static const double kSunglassesEarHigh = 0.33;
  static const double kOneEyeEarLow = 0.10;
  static const double kBlinkResetSeconds = 0.15;

  // Replaced static kYawThreshold with instance getters for dynamic speed contexts
  double get _dynamicYawThreshold {
    if (state.vehicleSpeed >= 40.0) return 35.0; // Strict at highway speeds
    return 45.0; // Relaxed at lower speeds for mirror/junction checks
  }

  int get _dynamicDistractionDurationMs {
    if (state.vehicleSpeed >= 40.0) return 3500; // 3.5s
    return 6000; // 6s
  }

  static const double kPitchThreshold = -12.0;
  static const double kYawnMarThreshold = 0.60;
  static const int kCalibrationFrames = 60;

  // Drowsiness: 4 seconds of continuous eye closure/yawning = 1 strike
  static const int kDrowsyFramesPerStrike = 120; // ~4s @ 30fps
  static const int kRecoveryFrames = 300; // 10s recovery

  // Distraction: 3 seconds of sustained yaw > threshold = 1 strike
  static const int kDistractedFramesPerStrike = 90; // ~3s @ 30fps
  static const int kDistractionRecoveryFrames = 450; // 15s recovery

  final MonitorState state;
  int _noEyeFrames = 0;
  int _sunglassNullFrames = 0;

  MonitoringEngine(this.state);

  void processFrame(Face? face) {
    state.frameCount++;
    final now = DateTime.now();

    // 5-second sleep checks run FIRST — before calibration guard
    _checkSleepByEyes(now);

    if (face == null) {
      _handleNoFace(now);
      return;
    }

    if (!state.calibrated) {
      _runCalibration(face, now);
      return;
    }

    _processHeadPose(face, now);
    _processEyesAndMouth(face, now);

    // ── Drowsiness evaluation ────────────────────────────────────────────────
    // Clean up old yawn and micro-sleep timestamps
    final thirtySecAgo = now.subtract(const Duration(seconds: 30));
    state.yawnTimestamps.removeWhere((t) => t.isBefore(thirtySecAgo));
    state.microSleepTimestamps.removeWhere((t) => t.isBefore(thirtySecAgo));

    final isCurrentlyDistracted = state.yaw.abs() > _dynamicYawThreshold;
    bool isDrowsyCurrentFrame = false;

    if (!isCurrentlyDistracted) {
      // Condition 1: 1 Yawn
      if (state.yawnTimestamps.isNotEmpty) {
        isDrowsyCurrentFrame = true;
      }

      // Condition 2: Closed eyes 5 times in 30 seconds (micro-sleeps)
      if (state.microSleepTimestamps.length >= 5) {
        isDrowsyCurrentFrame = true;
      }

      // Condition 3: Head Drop (sustained for 6 seconds for API, 3 seconds for UI banner)
      if (state.headDropSince != null) {
        final ms = now.difference(state.headDropSince!).inMilliseconds;
        if (ms >= 6000) {
          isDrowsyCurrentFrame = true;
          state.hasHeadDropWarning = false;
        } else if (ms >= 3000) {
          state.hasHeadDropWarning = true;
        } else {
          state.hasHeadDropWarning = false;
        }
      } else {
        state.hasHeadDropWarning = false;
      }

      // Condition 4: PERCLOS > 0.35 (just in case they fall asleep without dropping head)
      if (state.monitorMode != MonitorMode.sunglasses &&
          state.eyeClosureHistory.isNotEmpty) {
        final perclos =
            state.eyeClosureHistory.where((c) => c).length /
            state.eyeClosureHistory.length;
        if (perclos > 0.35) {
          isDrowsyCurrentFrame = true;
        }
      }
    }

    if (isDrowsyCurrentFrame) {
      if (state.drowsinessLevel != DrowsinessLevel.asleep) {
        state.drowsinessLevel = DrowsinessLevel.drowsy;
      }
      state.yawnTimestamps.clear();
      state.microSleepTimestamps.clear();
      state.continuousDrowsySince ??= now;
      state.continuousRecoverySince = null;
    } else {
      state.continuousRecoverySince ??= now;
      if (now.difference(state.continuousRecoverySince!).inSeconds >= 10) {
        if (state.drowsinessLevel == DrowsinessLevel.drowsy ||
            state.drowsinessLevel == DrowsinessLevel.asleep) {
          state.drowsinessLevel = DrowsinessLevel.alert;
        }
        state.yawnTimestamps.clear();
        state.microSleepTimestamps.clear();
        state.continuousRecoverySince = null;
      }
    }

    _updateDistractionStrikeSystem(isCurrentlyDistracted, now);
  }

  // ── 5-second sleep by eyes ───────────────────────────────────────────────

  void _checkSleepByEyes(DateTime now) {
    if (state.eyesClosedSince == null) {
      state.hasSleepWarning = false;
      return;
    }

    final closedMs = now.difference(state.eyesClosedSince!).inMilliseconds;
    if (closedMs >= 6000) {
      state.drowsinessLevel = DrowsinessLevel.asleep;
      state.hasSleepWarning = false;
    } else if (closedMs >= 4000) {
      state.hasSleepWarning = true;
      return;
    } else {
      state.hasSleepWarning = false;
      return;
    }

    final recentAlert = state.recentAlerts.any(
      (a) =>
          a.type == 'flag_sleeping' &&
          now.difference(a.timestamp).inSeconds < 5,
    );
    if (!recentAlert) {
      state.addAlert(
        AlertEvent(
          type: 'flag_sleeping',
          message: 'WAKE UP! EYES CLOSED >= 4.0s',
          needsScreenshot: true,
          isMajorFlag: true,
        ),
      );
      state.eyesClosedSince = now; // Shift to avoid instant re-trigger
    }
  }

  // ── No face handler ──────────────────────────────────────────────────────

  void _handleNoFace(DateTime now) {
    state.distractionStatus = DistractionStatus.forward;
    state.distractedSince = null;
    state.eyesClosedSince =
        null; // Prevent timeout triggering 'Asleep' when face is lost
    if (state.closedIntervals.isNotEmpty &&
        state.closedIntervals.last.end == null) {
      state.closedIntervals.last.end = now;
    }
  }

  // ── Calibration ──────────────────────────────────────────────────────────

  void _runCalibration(Face face, DateTime now) {
    final leftPts = EarCalculator.extractLeftEyePoints(face);
    final rightPts = EarCalculator.extractRightEyePoints(face);

    if (leftPts.isEmpty || rightPts.isEmpty) {
      _noEyeFrames++;
      if (_noEyeFrames >= 40) {
        state.monitorMode = MonitorMode.sunglasses;
        state.earBaseline = 0.28;
        state.earThreshold = 0.21;
        state.calibrated = true;
        state.blinkBaselineStart = now;
      }
      return;
    }

    _noEyeFrames = 0;
    state.calibrationFrame++;

    final leftEar = EarCalculator.calculateEar(leftPts);
    final rightEar = EarCalculator.calculateEar(rightPts);
    state.calibrationEarValues.add((leftEar + rightEar) / 2.0);

    if (state.calibrationFrame >= kCalibrationFrames) {
      _finalizeCalibration(leftEar, rightEar);
    }
  }

  void _finalizeCalibration(double lastLeft, double lastRight) {
    final vals = state.calibrationEarValues.toList()..sort();
    final openBaseline = vals[(vals.length * 0.75).toInt()];
    final avg = vals.reduce((a, b) => a + b) / vals.length;
    final variance =
        vals.map((v) => pow(v - avg, 2)).reduce((a, b) => a + b) / vals.length;

    if (avg > kSunglassesEarHigh && variance < kEarVarianceThreshold) {
      state.monitorMode = MonitorMode.sunglasses;
    } else if (lastLeft < kOneEyeEarLow) {
      state.monitorMode = MonitorMode.oneEye;
      state.oneEyeSide = 'RIGHT';
    } else if (lastRight < kOneEyeEarLow) {
      state.monitorMode = MonitorMode.oneEye;
      state.oneEyeSide = 'LEFT';
    } else {
      state.monitorMode = MonitorMode.normal;
    }

    state.earBaseline = openBaseline;
    state.earThreshold = openBaseline * 0.75;
    state.calibrated = true;
    state.blinkBaselineStart = DateTime.now();
  }

  // ── Head pose ────────────────────────────────────────────────────────────

  void _processHeadPose(Face face, DateTime now) {
    final yaw = face.headEulerAngleY ?? 0.0;
    final pitch = face.headEulerAngleX ?? 0.0;
    final roll = face.headEulerAngleZ ?? 0.0;

    state.yaw = yaw;
    state.pitch = pitch;
    state.roll = roll;

    // ── Distraction via yaw ──────────────────────────────────────────────
    final isDistracted = yaw.abs() > _dynamicYawThreshold;
    // Note: distractionStatus is updated in _updateDistractionStrikeSystem
    // to benefit from the 1.5s ML-jitter grace period.

    // ── Head drop (sleep indicator) ──────────────────────────────────────
    // CRITICAL FIX: Only trigger head drop when NOT distracted.
    // When turning sideways, roll exceeds 20° and was falsely triggering
    // headDropSince, causing spurious DROWSY/WAKE UP alerts.
    if (!isDistracted &&
        (pitch < kPitchThreshold || pitch > 15.0 || roll.abs() > 20.0)) {
      state.headDropSince ??= now;
    } else {
      // Reset head drop timer when distracted OR when head is level
      state.headDropSince = null;
    }
  }

  // ── Eyes + Mouth ─────────────────────────────────────────────────────────

  void _processEyesAndMouth(Face face, DateTime now) {
    final leftPts = EarCalculator.extractLeftEyePoints(face);
    final rightPts = EarCalculator.extractRightEyePoints(face);

    if (leftPts.isNotEmpty && rightPts.isNotEmpty) {
      final leftEar = EarCalculator.calculateEar(leftPts);
      final rightEar = EarCalculator.calculateEar(rightPts);
      state.leftEar = leftEar;
      state.rightEar = rightEar;

      double ear = (leftEar + rightEar) / 2.0;
      if (state.monitorMode == MonitorMode.oneEye) {
        ear = max(leftEar, rightEar);
      }

      _processDrowsinessEar(ear, now);

      if (state.monitorMode == MonitorMode.sunglasses) {
        _processMar(face, now);
      }
    } else {
      if (state.monitorMode != MonitorMode.sunglasses) {
        _sunglassNullFrames++;
        if (_sunglassNullFrames > 25) {
          state.monitorMode = MonitorMode.sunglasses;
        }

        // Keep the driver in an open-eye state when eye landmarks disappear briefly.
        state.eyesOpenSince ??= now;
        state.eyesClosedSince = null;
        state.lastEyeStateOpen = true;
      }
      if (state.monitorMode == MonitorMode.sunglasses) {
        _processMar(face, now);
      }
    }
  }

  void _processDrowsinessEar(double ear, DateTime now) {
    final eyesClosed = ear < state.earThreshold;

    // CRITICAL FIX: Skip PERCLOS update when distracted.
    // At high yaw, one eye is partially hidden → EAR drops artificially
    // → PERCLOS fills with false closures → false drowsiness alert.
    if (state.yaw.abs() <= _dynamicYawThreshold) {
      state.eyeClosureHistory.add(eyesClosed);
      if (state.eyeClosureHistory.length > 900) {
        state.eyeClosureHistory.removeAt(0);
      }
    }

    if (eyesClosed) {
      state.eyesClosedSince ??= now;
      state.eyesOpenSince = null;
    } else {
      if (state.lastEyeStateOpen == false) {
        state.blinkTimestamps.add(now);
        state.eyesOpenSince = now;

        // Track micro-sleep when eyes reopen
        if (state.eyesClosedSince != null) {
          final closedMs = now
              .difference(state.eyesClosedSince!)
              .inMilliseconds;
          if (closedMs >= 800) {
            state.microSleepTimestamps.add(now);
          }
        }
      }
      // Require 0.5s of sustained open eyes before resetting sleep timer
      if (state.eyesOpenSince != null) {
        final openMs = now.difference(state.eyesOpenSince!).inMilliseconds;
        if (openMs / 1000.0 >= kBlinkResetSeconds) {
          state.eyesClosedSince = null;
        }
      }
    }

    state.lastEyeStateOpen = !eyesClosed;
  }

  void _processMar(Face face, DateTime now) {
    final mouthPts = EarCalculator.extractMouthPoints(face);
    if (mouthPts.isEmpty) return;

    final mar = EarCalculator.calculateMar(mouthPts);
    state.mar = mar;

    if (mar > kYawnMarThreshold) {
      if (state.yawningSince == null) {
        state.yawningSince = now;
        state.yawnTimestamps.add(now);
      }
    } else {
      state.yawningSince = null;
    }

    // Chewing detection (contributes to eating detection)
    final mouthOpen = mar > 0.12 && mar < kYawnMarThreshold;
    if (mouthOpen && !state.lastMouthStateOpen) {
      state.chewTimestamps.add(now);
    }
    state.lastMouthStateOpen = mouthOpen;

    final cutoff = now.subtract(const Duration(seconds: 15));
    state.chewTimestamps.removeWhere((t) => t.isBefore(cutoff));
    state.isChewing = state.chewTimestamps.length >= 3;
  }

  // ── Distraction strike engine ────────────────────────────────────────────
  // One strike = sustained yaw > kYawThreshold for 3 continuous seconds.
  // 1-4 strikes: soft audio alert ("Strike X/5")
  // 5 strikes: MAJOR FLAG

  void _updateDistractionStrikeSystem(bool isDistracted, DateTime now) {
    if (isDistracted) {
      state.continuousDistractedSince ??= now;
      state.continuousForwardSince = null;

      bool instantDistraction = state.yaw.abs() >= 75.0;

      if (instantDistraction ||
          now.difference(state.continuousDistractedSince!).inMilliseconds >=
              _dynamicDistractionDurationMs) {
        state.distractionStatus = DistractionStatus.distracted;

        // Add strike = state.lastDistractionStrikeCooldown;
        final lastStrike = state.lastDistractionStrikeCooldown;
        if (lastStrike == null || now.difference(lastStrike).inSeconds >= 5) {
          state.lastDistractionStrikeCooldown = now;
          state.distractionStrikeCount++;
          state.continuousDistractedSince = now; // Reset for next strike

          if (state.distractionStrikeCount < 5) {
            state.addAlert(
              AlertEvent(
                type: 'audio_alert_distraction',
                message:
                    '⚠ DISTRACTION WARNING: Strike ${state.distractionStrikeCount}/5',
              ),
            );
          } else {
            state.addAlert(
              AlertEvent(
                type: 'flag_distraction_looking_away',
                message: 'FLAG: REPEATED DISTRACTION (5 STRIKES)',
                needsScreenshot: true,
                isMajorFlag: true,
              ),
            );
            state.distractionStrikeCount = 0;
          }
        }
      }
    } else {
      state.continuousForwardSince ??= now;

      // Only break the distraction timer if they've looked forward for 1.5 seconds minimum
      if (now.difference(state.continuousForwardSince!).inMilliseconds >=
          1500) {
        state.distractionStatus = DistractionStatus.forward;
        state.continuousDistractedSince = null;
      }

      if (now.difference(state.continuousForwardSince!).inSeconds >= 10) {
        state.distractionStrikeCount = 0;
        state.continuousForwardSince = null;
      }
    }
  }
}

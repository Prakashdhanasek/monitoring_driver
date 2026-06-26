import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

class ReversingDetectorService {
  final _reversingController = StreamController<bool>.broadcast();
  Stream<bool> get onReversingChanged => _reversingController.stream;

  bool _isReversing = false;
  bool get isReversing => _isReversing;

  // Public getters for real-time UI telemetry
  double get gpsSpeed => _gpsSpeed;
  double get gpsHeading => _gpsHeading;
  double get estimatedVelocity => _estimatedVelocity;
  bool get isCalibrated => _isCalibrated;
  double get headingOffset => _headingOffset;
  double get currentZ => _zHistory.isNotEmpty ? _zHistory.last : 0.0;
  double get compassHeading => _calculateCompassHeading();

  // GPS parameters
  double _gpsLat = 0.0;
  double _gpsLng = 0.0;
  double _gpsSpeed = 0.0;      // m/s
  double _gpsHeading = 0.0;    // degrees (0-360)

  // IMU sensor cache
  double _gx = 0.0;            // Gravity X
  double _gy = 9.8;            // Gravity Y (default vertical)
  double _gz = 0.0;            // Gravity Z
  double _mx = 0.0;            // Mag X
  double _my = 0.0;            // Mag Y
  double _mz = 0.0;            // Mag Z

  // Sensor Fusion & Calibration parameters
  bool _isCalibrated = false;
  double _headingOffset = 0.0;  // Offset to align compass with GPS forward vector

  StreamSubscription<UserAccelerometerEvent>? _userAccelSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  Timer? _holdTimer;
  DateTime? _lastReverseTriggerTime;

  // Motion sensor logic variables
  static const int _windowSize = 5;
  final List<double> _zHistory = [];
  double _estimatedVelocity = 0.0;
  DateTime? _lastAccelTime;

  ReversingDetectorService() {
    _startSensorsListening();
  }

  /// Updates GPS parameters from Geolocator stream.
  void updateGps(double lat, double lng, double speed, double heading) {
    _gpsLat = lat;
    _gpsLng = lng;
    _gpsSpeed = speed;
    _gpsHeading = heading;
    _evaluateReversingState();
  }

  void _startSensorsListening() {
    // 1. Listen to Accelerometer (for tilt-compensated compass base)
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      // Apply simple low-pass filter to isolate gravity/tilt vector
      _gx = 0.9 * _gx + 0.1 * event.x;
      _gy = 0.9 * _gy + 0.1 * event.y;
      _gz = 0.9 * _gz + 0.1 * event.z;
    });

    // 2. Listen to Magnetometer (for absolute heading)
    _magSub = magnetometerEventStream().listen((MagnetometerEvent event) {
      _mx = event.x;
      _my = event.y;
      _mz = event.z;
    });

    // 3. Listen to User Accelerometer (for instant launch detection)
    _lastAccelTime = DateTime.now();
    _userAccelSub = userAccelerometerEventStream().listen((UserAccelerometerEvent event) {
      final now = DateTime.now();
      final dt = now.difference(_lastAccelTime!).inMilliseconds / 1000.0;
      _lastAccelTime = now;

      if (dt <= 0 || dt > 1.0) return;

      double rawZ = event.z;

      // Maintain rolling history of Z axis acceleration
      _zHistory.add(rawZ);
      if (_zHistory.length > _windowSize) {
        _zHistory.removeAt(0);
      }
      double avgZ = _zHistory.reduce((a, b) => a + b) / _zHistory.length;

      // Integrate Z-acceleration to estimate velocity changes.
      _estimatedVelocity += avgZ * dt;
      _estimatedVelocity = _estimatedVelocity.clamp(-5.0, 5.0);

      // Standstill/Low Speed Launch Detection:
      // If speed <= 1.5 m/s (5.4 km/h), rely on the IMU Z-axis launch checks
      if (_gpsSpeed <= 1.5) {
        // Z-axis points towards driver (rear of car). Accel Z > 0 means accelerating backward (reversing).
        if (rawZ > 0.4) {
          debugPrint('[ReversingDetector] Standstill/LowSpeed: Instant launch REVERSE detected (Z: ${rawZ.toStringAsFixed(2)})');
          _triggerHoldActive();
        }
      }

      _evaluateReversingState();
    });
  }

  void _triggerHoldActive() {
    _lastReverseTriggerTime = DateTime.now();
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(seconds: 8), () {
      _holdTimer = null;
      _evaluateReversingState();
    });
  }

  void _cancelHoldActive() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _estimatedVelocity = 0.0;
  }

  /// Calculates the 3D tilt-compensated compass heading in degrees (0 - 360).
  double _calculateCompassHeading() {
    // Normalize gravity vector
    double gNorm = sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gNorm == 0) return 0.0;
    double ax = _gx / gNorm;
    double ay = _gy / gNorm;
    double az = _gz / gNorm;

    // Normalize magnetometer vector
    double mNorm = sqrt(_mx * _mx + _my * _my + _mz * _mz);
    if (mNorm == 0) return 0.0;
    double mx = _mx / mNorm;
    double my = _my / mNorm;
    double mz = _mz / mNorm;

    // East vector = Gravity x Magnetometer
    double ex = ay * mz - az * my;
    double ey = az * mx - ax * mz;
    double ez = ax * my - ay * mx;
    double eNorm = sqrt(ex * ex + ey * ey + ez * ez);
    if (eNorm == 0) return 0.0;
    ex /= eNorm;
    ey /= eNorm;
    ez /= eNorm;

    // North vector = East x Gravity
    double nx = ey * az - ez * ay;

    // Compass Heading = atan2(East, North)
    double headingRad = atan2(ex, nx);
    double headingDeg = headingRad * 180 / pi;
    if (headingDeg < 0) {
      headingDeg += 360;
    }
    return headingDeg;
  }

  void _evaluateReversingState() {
    bool newReversingState = false;

    // Check for negative GPS coordinates or speed (used as testing/simulation overrides)
    bool gpsNegative = _gpsLat < 0 || _gpsLng < 0 || _gpsSpeed < 0;

    if (gpsNegative) {
      newReversingState = true;
    } else {
      // Calculate current tilt-compensated compass heading
      double H_car = _calculateCompassHeading();

      if (_gpsSpeed > 1.5) {
        // --- Sensor Fusion Mode (Moving: Speed > 1.5 m/s) ---
        // We assume the first forward movement aligns the compass and GPS headings.
        if (!_isCalibrated && _gpsHeading != 0.0) {
          _headingOffset = _gpsHeading - H_car;
          _isCalibrated = true;
          debugPrint('[ReversingDetector] Compass calibrated. Offset: ${_headingOffset.toStringAsFixed(1)}°');
        }

        // Apply calibrated offset to compass heading
        double H_car_corr = (H_car + _headingOffset) % 360;
        if (H_car_corr < 0) H_car_corr += 360;

        // Calculate absolute difference between corrected compass heading and GPS trajectory bearing
        double delta = (H_car_corr - _gpsHeading).abs() % 360;
        delta = 180 - (180 - delta).abs(); // Normalize to [0, 180]

        debugPrint('[ReversingDetector] Speed: ${_gpsSpeed.toStringAsFixed(1)} m/s | H-Car: ${H_car_corr.toStringAsFixed(1)}° | H-Gps: ${_gpsHeading.toStringAsFixed(1)}° | Delta: ${delta.toStringAsFixed(1)}°');

        if (delta > 135.0) {
          newReversingState = true; // Delta ~ 180 degrees -> Reversing
        } else if (delta < 45.0) {
          newReversingState = false; // Delta ~ 0 degrees -> Moving Forward
        } else {
          newReversingState = _isReversing; // Keep previous state in transition band
        }
      } else {
        // --- Standstill / Low Speed Mode (Speed <= 1.5 m/s) ---
        // Rely on the linear accelerometer peak hold timer and estimated Z velocity
        bool isHoldActive = _holdTimer != null;
        bool motionSaysReverse = isHoldActive || (_estimatedVelocity > 0.25 && _zHistory.isNotEmpty && _zHistory.last > 0.1);
        
        newReversingState = motionSaysReverse;
      }
    }

    if (newReversingState != _isReversing) {
      _isReversing = newReversingState;
      _reversingController.add(_isReversing);
      debugPrint('[ReversingDetector] Reversing changed: $_isReversing (GPS moving: ${_gpsSpeed > 1.5})');
    }
  }

  void dispose() {
    _holdTimer?.cancel();
    _userAccelSub?.cancel();
    _accelSub?.cancel();
    _magSub?.cancel();
    _reversingController.close();
  }
}

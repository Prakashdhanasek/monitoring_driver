import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'settings_service.dart';
import 'telemetry_service.dart';

class BackgroundTelemetryService {
  BackgroundTelemetryService._();
  static final BackgroundTelemetryService instance =
      BackgroundTelemetryService._();

  final SettingsService _settings = SettingsService();
  final TelemetryService _telemetryService = TelemetryService();

  Timer? _telemetryTimer;
  StreamSubscription<Position>? _positionSubscription;

  String? tripId; // Active trip ID for offline syncing
  double latitude = 0.0;
  double longitude = 0.0;
  double speed = 0.0; // km/h
  double heading = 0.0;
  double accuracy = 0.0;

  bool _started = false;

  /// Call once from main() after Hive initialization.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    debugPrint('[BackgroundTelemetry] Starting GPS tracking and telemetry...');

    await _initGps();

    // Send telemetry every 3 seconds
    _telemetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _sendTelemetry();
    });
  }

  double _lastSentLat = 0.0;
  double _lastSentLng = 0.0;
  DateTime? _lastSentTime;

  /// Update position from an external source (e.g. MonitorFlow's GPS stream).
  void updatePosition(
    double lat,
    double lng,
    double speedKmH, {
    double accuracy = 0.0,
    double heading = 0.0,
  }) {
    if (lat == 0.0 && lng == 0.0) return;

    // Ignore inaccurate GPS fixes (> 30m error radius)
    if (accuracy > 30.0) {
      debugPrint(
        '[BackgroundTelemetry] Discarded low-accuracy fix (${accuracy.toStringAsFixed(1)}m)',
      );
      return;
    }

    // Ignore absurd speeds which indicate a GPS location jump/glitch
    if (speedKmH > 160.0) {
      debugPrint(
        '[BackgroundTelemetry] Discarded absurd speed glitch (${speedKmH.toStringAsFixed(1)} km/h)',
      );
      return;
    }

    final double effectiveSpeed = speedKmH > 0.8 ? speedKmH : 0.0;

    // If stationary / noise drift (< 1.5 km/h AND moved < 5m from last sent position),
    // lock position to last valid coordinates to prevent spiky zigzag route lines.
    if (_lastSentLat != 0.0 && _lastSentLng != 0.0) {
      final dist = Geolocator.distanceBetween(
        _lastSentLat,
        _lastSentLng,
        lat,
        lng,
      );
      if (effectiveSpeed < 1.5 && dist < 5.0) {
        latitude = _lastSentLat;
        longitude = _lastSentLng;
        speed = 0.0;
        return;
      }
    }

    latitude = lat;
    longitude = lng;
    speed = effectiveSpeed;
    this.accuracy = accuracy;
    this.heading = heading;
  }

  Future<void> _initGps() async {
    try {
      // Retry loop: wait for location to be enabled (native code enables it)
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint(
          '[BackgroundTelemetry] Location disabled. Waiting for auto-enable...',
        );
        // Retry up to 5 times with 2s delay (native side should enable it)
        for (int i = 0; i < 5; i++) {
          await Future.delayed(const Duration(seconds: 2));
          serviceEnabled = await Geolocator.isLocationServiceEnabled();
          if (serviceEnabled) break;
        }
        if (!serviceEnabled) {
          debugPrint(
            '[BackgroundTelemetry] Location still disabled after retries. Opening settings...',
          );
          await Geolocator.openLocationSettings();
          // Wait a bit more for user/system to enable
          await Future.delayed(const Duration(seconds: 3));
          serviceEnabled = await Geolocator.isLocationServiceEnabled();
          if (!serviceEnabled) {
            debugPrint('[BackgroundTelemetry] Location services still OFF.');
            return;
          }
        }
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint(
          '[BackgroundTelemetry] Location permissions permanently denied.',
        );
        return;
      }

      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        // Get current position immediately (don't wait for movement)
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: AndroidSettings(
              accuracy: LocationAccuracy.bestForNavigation,
            ),
          ).timeout(const Duration(seconds: 10));
          updatePosition(
            pos.latitude,
            pos.longitude,
            pos.speed > 0 ? (pos.speed * 3.6) : 0.0,
            accuracy: pos.accuracy,
            heading: pos.heading,
          );
          debugPrint(
            '[BackgroundTelemetry] Initial position: $latitude, $longitude',
          );
        } catch (e) {
          debugPrint('[BackgroundTelemetry] getCurrentPosition failed: $e');
        }

        // Then listen for updates on movement
        _positionSubscription =
            Geolocator.getPositionStream(
              locationSettings: AndroidSettings(
                accuracy: LocationAccuracy.bestForNavigation,
                distanceFilter: 0,
                intervalDuration: const Duration(seconds: 1),
              ),
            ).listen((Position position) {
              final speedKmH = position.speed > 0
                  ? (position.speed * 3.6)
                  : 0.0;
              updatePosition(
                position.latitude,
                position.longitude,
                speedKmH,
                accuracy: position.accuracy,
                heading: position.heading,
              );
            });
        debugPrint('[BackgroundTelemetry] GPS position stream started.');
      }
    } catch (e) {
      debugPrint('[BackgroundTelemetry] Error initializing GPS: $e');
    }
  }

  Future<void> _sendTelemetry() async {
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) return;
    if (latitude == 0.0 && longitude == 0.0) return;

    final now = DateTime.now();

    // Avoid sending duplicate jitter positions when vehicle is parked/stationary.
    // Send only if moved >= 5m OR if 30s heartbeat interval passed.
    if (_lastSentLat != 0.0 && _lastSentLng != 0.0 && _lastSentTime != null) {
      final dist = Geolocator.distanceBetween(
        _lastSentLat,
        _lastSentLng,
        latitude,
        longitude,
      );
      final elapsedSec = now.difference(_lastSentTime!).inSeconds;

      if (speed < 1.5 && dist < 5.0 && elapsedSec < 30) {
        return;
      }
    }

    _lastSentLat = latitude;
    _lastSentLng = longitude;
    _lastSentTime = now;

    await _telemetryService.sendLocationTelemetry(
      deviceTabletId: deviceId,
      tripId: tripId,
      latitude: latitude,
      longitude: longitude,
      speed: speed,
      heading: heading,
      accuracy: accuracy,
    );
  }

  void stop() {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _started = false;
    debugPrint('[BackgroundTelemetry] Stopped.');
  }
}

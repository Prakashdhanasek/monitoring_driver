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

  double latitude = 0.0;
  double longitude = 0.0;
  double speed = 0.0; // km/h

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

  /// Update position from an external source (e.g. MonitorFlow's GPS stream).
  void updatePosition(double lat, double lng, double speedKmH) {
    latitude = lat;
    longitude = lng;
    speed = speedKmH;
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
          latitude = pos.latitude;
          longitude = pos.longitude;
          speed = pos.speed > 0 ? (pos.speed * 3.6) : 0.0;
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
              latitude = position.latitude;
              longitude = position.longitude;
              speed = speedKmH;
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

    await _telemetryService.sendLocationTelemetry(
      deviceTabletId: deviceId,
      latitude: latitude,
      longitude: longitude,
      speed: speed,
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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image/image.dart' as img;
import 'package:monitoring_driver/kiosk.dart';
import 'core/face_auth_engine.dart';
import 'core/monitoring_engine.dart';
import 'core/object_detector_engine.dart';
import 'core/monitor_state.dart';

import 'services/settings_service.dart';
import 'services/drivers_service.dart';
import 'services/incidents_service.dart';
import 'services/telemetry_service.dart';

/// The 3 phases of the driver-facing flow.
enum Phase { verifying, details, monitoring }

/// Hidden admin exit PIN (tap the top-right corner 5x to enter it).
const String kAdminPin = '1234';

class MonitorFlow extends StatefulWidget {
  const MonitorFlow({super.key});

  @override
  State<MonitorFlow> createState() => _MonitorFlowState();
}

class _MonitorFlowState extends State<MonitorFlow> with WidgetsBindingObserver {
  // Camera + detector
  CameraController? _camera;
  FaceDetector? _detector;

  // Engines + shared state
  final FaceAuthEngine _authEngine = FaceAuthEngine();
  final ObjectDetectorEngine _objectDetector = ObjectDetectorEngine();
  late final MonitoringEngine _monitoringEngine;
  final MonitorState _state = MonitorState();

  // ── Hive Services ──
  final SettingsService _settings = SettingsService();
  final DriversService _driversService = DriversService();
  final IncidentsService _incidentsService = IncidentsService();
  final TelemetryService _telemetryService = TelemetryService();

  // ── Connectivity tracking ──
  bool _isOnline = true;
  Timer? _connectivityTimer;
  Timer? _telemetryTimer;

  // Flow
  Phase _phase = Phase.verifying;
  bool _camReady = false;
  bool _busy = false;
  bool _streaming = false;
  int _frame = 0;
  bool _initializing = true;

  // Verified driver
  String _driverName = 'Driver';
  String _driverId = '—';
  String? _vehicleId;
  String? _vehicleRegNo;

  // Countdown
  int _countdown = 3;
  Timer? _countdownTimer;

  // Continuous-auth helpers (monitoring phase)
  int _multiFace = 0;

  // Alert audio (assets/audio/*.mp3)
  final AudioPlayer _player = AudioPlayer();
  DateTime? _lastSoundAt;
  DrowsinessLevel _prevDrowsy = DrowsinessLevel.alert;
  DistractionStatus _prevDistract = DistractionStatus.forward;
  AuthStatus _prevAuthSound = AuthStatus.scanning;
  final Map<String, DateTime> _lastIncidentReportAt = {};

  // Still face image captured at the moment of successful verification.
  Uint8List? _capturedFace;

  // Trip counting: a trip ends when the driver is gone for >= 30s, and the
  // next time a driver appears it becomes the next trip.
  int _tripNumber = 0; // incremented to 1 on the first verification
  bool _tripCompleted = false;
  DateTime? _noFaceSince;
  static const int _kTripEndSeconds = 30;

  // Hidden admin-exit gesture (top-right corner x5 -> PIN -> leave kiosk).
  int _exitTaps = 0;
  DateTime? _firstExitTapAt;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitoringEngine = MonitoringEngine(_state);
    _init();

    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _syncIncidentsTask();
    });

    // Check connectivity every 5 seconds
    _connectivityTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkConnectivity();
    });
    _checkConnectivity();

    // Send location telemetry every 3 seconds
    _telemetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _sendTelemetryTask();
    });
  }

  Future<void> _checkConnectivity() async {
    try {
      final result = await InternetAddress.lookup('proximity-driver-api.prod-app.in')
          .timeout(const Duration(seconds: 3));
      final online = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      if (online != _isOnline) {
        _isOnline = online;
        if (mounted) setState(() {});
        debugPrint('==================================================');
        debugPrint('[CONNECTIVITY CHANGE] Device moved to: ${_isOnline ? "ONLINE" : "OFFLINE"}');
        debugPrint('==================================================');
        // Auto-sync immediately when we come back online
        if (_isOnline) {
          _syncIncidentsTask();
        }
      }
    } catch (_) {
      if (_isOnline) {
        _isOnline = false;
        if (mounted) setState(() {});
        debugPrint('==================================================');
        debugPrint('[CONNECTIVITY CHANGE] Device moved to: OFFLINE');
        debugPrint('==================================================');
      }
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _connectivityTimer?.cancel();
    _telemetryTimer?.cancel();
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _detector?.close();
    _objectDetector.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _fetchAndDownloadDrivers() async {
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      debugPrint('[Flow] No device_id stored. Skipping API fetch.');
      return;
    }
    await _driversService.fetchAndCacheDrivers(deviceId);
  }


  Future<void> _init() async {
    // Clear old queued incidents to start fresh with new schema/details
    try {
      await _incidentsService.clearAll();
      debugPrint('[Flow] Cleared old queued incidents for new schema.');
    } catch (e) {
      debugPrint('[Flow] Error clearing incidents queue: $e');
    }

    // 0) Request location permissions upfront so GPS passes correctly.
    try {
      await _requestLocationPermission();
    } catch (e) {
      debugPrint('[Flow] Location permission error: $e');
    }

    // 1) Fetch and download driver list and photos for this device.
    try {
      await _fetchAndDownloadDrivers();
    } catch (e) {
      debugPrint('[Flow] fetch/download drivers error: $e');
    }

    // 2) Load reference faces (creates + closes its own temp detector first).
    try {
      await _authEngine.initialize();
    } catch (e) {
      debugPrint('[Flow] auth init error: $e');
    }
    if (!mounted) return;

    // 2) Object detector (isolate + YOLO).
    try {
      await _objectDetector.initialize();
    } catch (e) {
      debugPrint('[Flow] object detector init error: $e');
    }
    if (!mounted) return;

    // 3) Live face detector (contours for EAR, landmarks for mouth, tracking for auth).
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: true,
        enableLandmarks: true,
        enableClassification: false,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    // 4) Camera.
    await _initCamera();

    if (mounted) {
      setState(() => _initializing = false);
    }
  }

  Future<void> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[Flow] Location services are disabled.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('[Flow] Location permissions are permanently denied.');
      return;
    }

    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen((Position position) {
        _state.gpsLat = position.latitude;
        _state.gpsLng = position.longitude;
        _state.vehicleSpeed = position.speed > 0 ? (position.speed * 3.6) : 0.0;
      });
    }
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      CameraDescription? front;
      for (final c in cams) {
        if (c.lensDirection == CameraLensDirection.front) {
          front = c;
          break;
        }
      }
      front ??= cams.isNotEmpty ? cams.first : null;
      if (front == null) return;

      final controller = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      setState(() => _camReady = true);
      await controller.startImageStream(_processImage);
      _streaming = true;
    } catch (e) {
      debugPrint('[Flow] camera error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────
  // FRAME PIPELINE
  // ─────────────────────────────────────────────────────────
  Future<void> _processImage(CameraImage image) async {
    if (_busy || !_camReady || _detector == null) return;
    _busy = true;
    _frame++;

    try {
      final input = _buildInputImage(image);
      if (input == null) return;

      final all = await _detector!.processImage(input);
      final faces = all.where((f) => f.boundingBox.width > 20).toList();
      _state.faceCount = faces.length;

      switch (_phase) {
        case Phase.verifying:
          if (faces.length == 1) {
            if (_frame % 3 == 0) {
              _authEngine.processAuth(
                faces.first,
                _state,
                image,
                _getCameraRotation(),
              );
            }
            if (_state.authStatus == AuthStatus.authenticated) {
              _capturedFace = _captureFaceJpeg(image);
              _onVerified();
            }
          }
          break;

        case Phase.details:
          // Just holding — countdown runs on its own timer.
          break;

        case Phase.monitoring:
          if (faces.isNotEmpty) {
            // A driver is in view.
            _noFaceSince = null;
            if (_tripCompleted) {
              // Driver returned after the trip ended -> RE-VERIFY for the next
              // trip (it might be a different driver in the same vehicle).
              _startReverification();
              break;
            }

            if (faces.length > 1) {
              _multiFace++;
              if (_multiFace > 15) {
                _state.authStatus = AuthStatus.multipleFaces;
              }
              _monitoringEngine.processFrame(null);
            } else {
              _multiFace = 0;
              final face = faces.first;
              // Light continuous identity check (catches a driver swap mid-trip).
              if (_frame % 5 == 0) {
                _authEngine.processAuth(
                  face,
                  _state,
                  image,
                  _getCameraRotation(),
                );
              }
              _monitoringEngine.processFrame(face);
            }

            // Object detection (phone / cigarette / seatbelt) every 5 frames.
            if (_frame % 5 == 0) {
              _objectDetector.processFrame(image, _state, _getCameraRotation());
            }

            // Play an alert sound on new warnings.
            _handleAlertSounds();
          } else {
            // No driver in view — start / continue the "gone" timer.
            _multiFace = 0;
            _monitoringEngine.processFrame(null);
            _noFaceSince ??= DateTime.now();
            if (!_tripCompleted &&
                DateTime.now().difference(_noFaceSince!).inSeconds >=
                    _kTripEndSeconds) {
              _tripCompleted = true;
              _reportIncident('TripStop', 'Low', 1.0);
            }
          }
          break;
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[Flow] processImage error: $e');
    } finally {
      _busy = false;
    }
  }

  void _onVerified() {
    if (_phase != Phase.verifying) return;
    _tripNumber++; // trip 1 on first verify, trip 2 after a completed trip, ...

    // API-driven identity only. FaceAuthEngine returns the matched label as
    // "driverId|driverName" (built from the downloaded photo filename). There
    // are NO hardcoded driver names anywhere — everything comes from the API.
    final label = _authEngine.lastMatchedLabel;
    if (label != null && label.contains('|')) {
      final parts = label.split('|');
      _driverId = parts.isNotEmpty ? parts[0] : '—';
      _driverName = parts.length > 1 ? parts[1] : 'Driver';
    } else {
      _driverName = label ?? 'Driver';
      _driverId = '—';
    }

    // Set vehicle details from cached driver
    try {
      final drivers = _driversService.getCachedDrivers();
      final driver = drivers.firstWhere(
        (d) => d['id'] == _driverId,
        orElse: () => <String, dynamic>{},
      );
      _vehicleId = driver['assignedVehicleId'] as String?;
      _vehicleRegNo = driver['vehicleRegistrationNumber'] as String?;
    } catch (e) {
      debugPrint('[Flow] Error resolving driver vehicle details: $e');
    }
    _phase = Phase.details;
    _countdown = 3;
    if (mounted) setState(() {});

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _countdown--;
      if (_countdown <= 0) {
        t.cancel();
        // Start fresh calibration for the monitoring session.
        _state.resetCalibration();
        _phase = Phase.monitoring;
      }
      if (mounted) setState(() {});
    });
  }

  /// Trip ended and a driver re-appeared — go back to the verify screen so the
  /// new driver is authenticated before the next trip's monitoring begins.
  void _startReverification() {
    _tripCompleted = false;
    _capturedFace = null;
    _multiFace = 0;
    _noFaceSince = null;
    _state.authStatus = AuthStatus.scanning;
    _state.authDistance = -1.0;
    _state.authenticatedTrackingId = null;
    _phase = Phase.verifying;
  }

  // ─────────────────────────────────────────────────────────
  // INCIDENT REPORTING
  // ─────────────────────────────────────────────────────────
  Future<void> _reportIncident(String eventType, String riskLevel, double confidence) async {
    try {
      final deviceId = _settings.getDeviceId();
      if (deviceId == null || deviceId.isEmpty) return;

      _incidentsService.queueIncident(
        deviceTabletId: deviceId,
        eventType: eventType,
        riskLevel: riskLevel,
        aiConfidence: confidence,
        vehicleSpeed: _state.vehicleSpeed,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        driverId: _driverId == '—' ? null : _driverId,
        driverName: _driverName == 'Driver' ? null : _driverName,
        vehicleId: _vehicleId,
        vehicleRegistrationNumber: _vehicleRegNo,
        isOnline: _isOnline,
      );

      // If online, upload immediately in real-time
      if (_isOnline) {
        _syncIncidentsTask();
      }
    } catch (e) {
      debugPrint('[Flow] Error queueing incident: $e');
    }
  }

  Future<void> _syncIncidentsTask() async {
    if (!mounted) return;
    debugPrint('[Flow] Triggering sync of pending incidents (connection: ${_isOnline ? "ONLINE" : "OFFLINE"})...');
    await _incidentsService.syncPendingIncidents();
  }

  Future<void> _sendTelemetryTask() async {
    if (!mounted) return;
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }
    // Only attempt to send telemetry if online
    if (!_isOnline) {
      debugPrint('[Telemetry] Skipping location telemetry (Device is offline)');
      return;
    }

    await _telemetryService.sendLocationTelemetry(
      deviceTabletId: deviceId,
      latitude: _state.gpsLat,
      longitude: _state.gpsLng,
      speed: _state.vehicleSpeed,
    );
  }

  // ─────────────────────────────────────────────────────────
  // ALERT AUDIO & INCIDENTS
  // ─────────────────────────────────────────────────────────
  void _handleAlertSounds() {
    final now = DateTime.now();
    final phone = _state.detectedObjects
        .any((o) => o.label == 'phone' && o.confidence > 0.45);
    final smoke = _state.detectedObjects
        .any((o) => o.label == 'cigarette' && o.confidence > 0.85);

    bool loud = false;
    bool soft = false;

    // 1. Fire on the TRANSITION into state-based warnings.
    if (_state.authStatus == AuthStatus.unauthorized &&
        _prevAuthSound != AuthStatus.unauthorized) {
      loud = true;
      _reportIncident('UnauthorizedDriver', 'High', 1.0);
    }
    if (_state.drowsinessLevel == DrowsinessLevel.asleep &&
        _prevDrowsy != DrowsinessLevel.asleep) {
      loud = true;
      _reportIncident('Drowsiness', 'High', 1.0);
    }
    if (_state.drowsinessLevel == DrowsinessLevel.drowsy &&
        _prevDrowsy == DrowsinessLevel.alert) {
      soft = true;
      _reportIncident('Drowsiness', 'Medium', 0.8);
    }
    if (_state.distractionStatus == DistractionStatus.distracted &&
        _prevDistract == DistractionStatus.forward) {
      soft = true;
      _reportIncident('Distraction', 'Medium', 0.8);
    }

    // 2. Report ALL AI object detections dynamically at intervals.
    for (final obj in _state.detectedObjects) {
      if (obj.confidence > 0.55) {
        final label = obj.label;
        final lastTime = _lastIncidentReportAt[label];
        // Report every 10 seconds if the incident is actively happening
        if (lastTime == null || now.difference(lastTime).inSeconds >= 10) {
          _lastIncidentReportAt[label] = now;

          String eventType = label;
          if (label == 'phone') eventType = 'PhoneUsage';
          if (label == 'cigarette') eventType = 'Smoking';
          if (label == 'seatbelt') eventType = 'Seatbelt';
          if (label == 'eating') eventType = 'Eating';
          if (label == 'drinking') eventType = 'Drinking';

          _reportIncident(eventType, 'High', obj.confidence);
          loud = true;
        }
      }
    }

    // Remember current states for next-frame transition checks.
    _prevDrowsy = _state.drowsinessLevel;
    _prevDistract = _state.distractionStatus;
    _prevAuthSound = _state.authStatus;

    if (!loud && !soft) return;

    // Global cooldown so sounds don't overlap / spam.
    if (_lastSoundAt != null &&
        now.difference(_lastSoundAt!).inMilliseconds < 3000) {
      return;
    }
    _lastSoundAt = now;
    _playAlert(loud ? 'audio/alert_loud.mp3' : 'audio/alert_soft.mp3');
  }

  Future<void> _playAlert(String assetPath) async {
    try {
      await _player.stop();
      await _player.play(AssetSource(assetPath));
    } catch (e) {
      debugPrint('[Flow] audio error: $e');
    }
  }

  /// Converts the current YUV camera frame to an upright (mirrored for the
  /// front camera) JPEG — used as the captured still on the verified screen.
  Uint8List? _captureFaceJpeg(CameraImage image) {
    try {
      if (image.planes.length < 3) return null;
      final int w = image.width;
      final int h = image.height;
      final out = img.Image(width: w, height: h);

      final yP = image.planes[0];
      final uP = image.planes[1];
      final vP = image.planes[2];
      final yBytes = yP.bytes;
      final uBytes = uP.bytes;
      final vBytes = vP.bytes;
      final int yRow = yP.bytesPerRow;
      final int uvRow = uP.bytesPerRow;
      final int uvPix = uP.bytesPerPixel ?? 1;

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final int yi = y * yRow + x;
          final int uvi = (y >> 1) * uvRow + (x >> 1) * uvPix;
          final int Y = yi < yBytes.length ? yBytes[yi] : 0;
          final int U = uvi < uBytes.length ? uBytes[uvi] - 128 : 0;
          final int V = uvi < vBytes.length ? vBytes[uvi] - 128 : 0;
          final int r = (Y + 1.402 * V).round().clamp(0, 255);
          final int g = (Y - 0.344136 * U - 0.714136 * V).round().clamp(0, 255);
          final int b = (Y + 1.772 * U).round().clamp(0, 255);
          out.setPixelRgb(x, y, r, g, b);
        }
      }

      // Rotate to upright based on the camera sensor.
      img.Image fixed = out;
      final int rot = _getCameraRotation();
      if (rot == 90) {
        fixed = img.copyRotate(out, angle: 90);
      } else if (rot == 180) {
        fixed = img.copyRotate(out, angle: 180);
      } else if (rot == 270) {
        fixed = img.copyRotate(out, angle: 270);
      }

      // Mirror the front camera so it looks like a normal selfie.
      if (_camera?.description.lensDirection == CameraLensDirection.front) {
        fixed = img.flipHorizontal(fixed);
      }

      return Uint8List.fromList(img.encodeJpg(fixed, quality: 85));
    } catch (e) {
      debugPrint('[Flow] capture error: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────
  // CAMERA HELPERS
  // ─────────────────────────────────────────────────────────
  int _getCameraRotation() {
    final c = _camera;
    if (c == null) return 0;
    final sensor = c.description.sensorOrientation;
    if (Platform.isIOS) return sensor;
    var comp = 0;
    switch (c.value.deviceOrientation) {
      case DeviceOrientation.portraitUp:
        comp = 0;
        break;
      case DeviceOrientation.landscapeLeft:
        comp = 90;
        break;
      case DeviceOrientation.portraitDown:
        comp = 180;
        break;
      case DeviceOrientation.landscapeRight:
        comp = 270;
        break;
    }
    if (c.description.lensDirection == CameraLensDirection.front) {
      return (sensor + comp) % 360;
    }
    return (sensor - comp + 360) % 360;
  }

  InputImageRotation? _rotationFor(CameraController c) {
    final sensor = c.description.sensorOrientation;
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensor);
    }
    var comp = 0;
    switch (c.value.deviceOrientation) {
      case DeviceOrientation.portraitUp:
        comp = 0;
        break;
      case DeviceOrientation.landscapeLeft:
        comp = 90;
        break;
      case DeviceOrientation.portraitDown:
        comp = 180;
        break;
      case DeviceOrientation.landscapeRight:
        comp = 270;
        break;
    }
    final r = c.description.lensDirection == CameraLensDirection.front
        ? (sensor + comp) % 360
        : (sensor - comp + 360) % 360;
    return InputImageRotationValue.fromRawValue(r);
  }

  InputImage? _buildInputImage(CameraImage image) {
    final c = _camera;
    if (c == null || image.planes.isEmpty) return null;
    final rotation = _rotationFor(c);
    if (rotation == null) return null;

    if (Platform.isAndroid) {
      final nv21 = _yuv420ToNv21(image);
      return InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );
    } else {
      return InputImage.fromBytes(
        bytes: image.planes.first.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
    }
  }

  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    final int ySize = width * height;
    final int uvSize = (width ~/ 2) * (height ~/ 2) * 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);

    final int yRowStride = yPlane.bytesPerRow;
    int pos = 0;
    if (yRowStride == width) {
      nv21.setRange(0, ySize, yPlane.bytes);
      pos = ySize;
    } else {
      final yb = yPlane.bytes;
      for (int row = 0; row < height; row++) {
        nv21.setRange(pos, pos + width, yb, row * yRowStride);
        pos += width;
      }
    }

    final Uint8List ub = uPlane.bytes;
    final Uint8List vb = vPlane.bytes;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final int chromaH = height ~/ 2;
    final int chromaW = width ~/ 2;
    for (int row = 0; row < chromaH; row++) {
      final int rowStart = row * uvRowStride;
      for (int col = 0; col < chromaW; col++) {
        final int uvOffset = rowStart + col * uvPixelStride;
        nv21[pos++] = uvOffset < vb.length ? vb[uvOffset] : 0;
        nv21[pos++] = uvOffset < ub.length ? ub[uvOffset] : 0;
      }
    }
    return nv21;
  }

  // ─────────────────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_streaming) {
        c.stopImageStream().catchError((_) {});
        _streaming = false;
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_streaming && _camReady) {
        c.startImageStream(_processImage);
        _streaming = true;
      }
    }
  }



  // ─────────────────────────────────────────────────────────
  // HIDDEN ADMIN EXIT (top-right corner tapped 5x within 3s -> PIN)
  // ─────────────────────────────────────────────────────────
  void _onCornerTap() {
    final now = DateTime.now();
    if (_firstExitTapAt == null ||
        now.difference(_firstExitTapAt!).inSeconds > 3) {
      _firstExitTapAt = now;
      _exitTaps = 1;
    } else {
      _exitTaps++;
    }
    if (_exitTaps >= 5) {
      _exitTaps = 0;
      _firstExitTapAt = null;
      _showExitPinDialog();
    }
  }

  void _showExitPinDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin Exit'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter admin PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final ok = controller.text == kAdminPin;
              Navigator.pop(ctx);
              if (ok) Kiosk.stop(); // leave lock-task / kiosk
            },
            child: const Text('Exit'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _cameraLayer(),
        //  if (_phase == Phase.verifying) _verifyingOverlay(),
          if (_phase == Phase.details) _detailsOverlay(),
          if (_phase == Phase.monitoring)
            (_tripCompleted ? _tripCompletedOverlay() : _monitoringOverlay()),

          // Invisible admin-exit hotspot (top-right corner). Tap 5x -> PIN.
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onCornerTap,
              child: const SizedBox(width: 72, height: 72),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cameraLayer() {
    final c = _camera;
    if (!_camReady || c == null || c.value.previewSize == null) {
      // Plain background only — the loader is shown by the phase overlay on top
      // (avoids two spinners appearing at once before the camera is ready).
      return Container(color: Colors.black);
    }
    final ps = c.value.previewSize!;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: ps.height,
        height: ps.width,
        child: CameraPreview(c),
      ),
    );
  }

  // ── VERIFYING ──
  // Widget _verifyingOverlay() {
  //   if (!_initializing && !_authEngine.isEnrolled) {
  //     return Container(
  //       color: Colors.black.withOpacity(0.85),
  //       child: const Center(
  //         child: Column(
  //           mainAxisAlignment: MainAxisAlignment.center,
  //           children: [
  //             Icon(Icons.people_outlined, color: Colors.redAccent, size: 64),
  //             const SizedBox(height: 24),
  //             Text(
  //               'No Drivers Assigned',
  //               style: TextStyle(
  //                   color: Colors.white,
  //                   fontSize: 20,
  //                   fontWeight: FontWeight.w600),
  //             ),
  //             const SizedBox(height: 8),
  //             Text(
  //               'No registered/authorized drivers found for this device.',
  //               style: TextStyle(color: Colors.white70, fontSize: 14),
  //               textAlign: TextAlign.center,
  //             ),
  //           ],
  //         ),
  //       ),
  //     );
  //   }
  //
  //   final isUnverified = _state.authStatus == AuthStatus.unauthorized && _state.faceCount > 0;
  //
  //   return Container(
  //     color: Colors.black.withValues(alpha: 0.45),
  //     child: Column(
  //       mainAxisAlignment: MainAxisAlignment.center,
  //       children: [
  //         SizedBox(
  //           width: 64,
  //           height: 64,
  //           child: isUnverified
  //               ? const Icon(Icons.error_outline, color: Colors.redAccent, size: 64)
  //               : const CircularProgressIndicator(
  //                   strokeWidth: 3,
  //                   color: Color(0xFF3B82F6),
  //                 ),
  //         ),
  //         const SizedBox(height: 24),
  //         Text(
  //           _initializing
  //               ? 'Initializing systems…'
  //               : (isUnverified ? 'Unverified' : 'Verifying your face…'),
  //           style: TextStyle(
  //               color: isUnverified ? Colors.redAccent : Colors.white,
  //               fontSize: 20,
  //               fontWeight: FontWeight.w600),
  //         ),
  //         const SizedBox(height: 8),
  //         Text(
  //           _state.faceCount == 0
  //               ? 'Look at the camera'
  //               : (isUnverified
  //                   ? 'Face not recognised — keep looking'
  //                   : 'Hold still…'),
  //           style: const TextStyle(color: Colors.white70, fontSize: 14),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // ── DETAILS — clean white "Identity Verified" card (matches design) ──
  Widget _detailsOverlay() {
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _verifiedAvatar(),
                const SizedBox(height: 28),
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF16A34A),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Identity Verified!',
                  style: TextStyle(
                    color: Color(0xFF16A34A),
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'You have been successfully verified',
                  style: TextStyle(color: Color(0xFF6B7280), fontSize: 14),
                ),
                const SizedBox(height: 30),
                const Text(
                  'Welcome back,',
                  style: TextStyle(color: Color(0xFF6B7280), fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(
                  _driverName,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Driver ID: $_driverId',
                    style: const TextStyle(
                      color: Color(0xFF2563EB),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Circular live-face avatar with a green ring (fills over the 3s) + confetti.
  Widget _verifiedAvatar() {
    final c = _camera;
    Widget inner;
    if (_capturedFace != null) {
      // The still snapshot taken right when verification succeeded.
      inner = ClipOval(
        child: Image.memory(
          _capturedFace!,
          width: 176,
          height: 176,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    } else if (_camReady && c != null && c.value.previewSize != null) {
      final ps = c.value.previewSize!;
      inner = ClipOval(
        child: SizedBox(
          width: 176,
          height: 176,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: ps.height,
              height: ps.width,
              child: CameraPreview(c),
            ),
          ),
        ),
      );
    } else {
      inner = Container(
        width: 176,
        height: 176,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFE5E7EB),
        ),
        child: const Icon(
          Icons.person_rounded,
          size: 90,
          color: Color(0xFF9CA3AF),
        ),
      );
    }

    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ..._confetti(),
          SizedBox(
            width: 212,
            height: 212,
            child: CircularProgressIndicator(
              strokeWidth: 5,
              value: (_countdown.clamp(0, 3)) / 3.0,
              backgroundColor: const Color(0xFFD1FAE5),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF16A34A)),
            ),
          ),
          Container(
            width: 192,
            height: 192,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
            alignment: Alignment.center,
            child: inner,
          ),
        ],
      ),
    );
  }

  List<Widget> _confetti() {
    const blue = Color(0xFF3B82F6);
    const green = Color(0xFF22C55E);
    const amber = Color(0xFFF59E0B);
    Widget dot(Color col, double s) => Container(
      width: s,
      height: s,
      decoration: BoxDecoration(color: col, shape: BoxShape.circle),
    );
    Widget dia(Color col, double s) => Transform.rotate(
      angle: 0.785398,
      child: Container(width: s, height: s, color: col),
    );
    return [
      Positioned(left: 8, top: 64, child: dia(blue, 9)),
      Positioned(left: 30, top: 112, child: dot(green, 6)),
      Positioned(left: 2, top: 150, child: dot(green, 5)),
      Positioned(left: 34, top: 44, child: dot(green, 4)),
      Positioned(left: 16, top: 192, child: dia(amber, 8)),
      Positioned(right: 8, top: 64, child: dia(blue, 9)),
      Positioned(right: 30, top: 112, child: dot(green, 6)),
      Positioned(right: 2, top: 150, child: dot(amber, 5)),
      Positioned(right: 34, top: 44, child: dot(green, 4)),
      Positioned(right: 16, top: 192, child: dia(green, 8)),
    ];
  }

  // ── MONITORING ──
  Widget _monitoringOverlay() {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        // _monitorBanner(),
          _connectivityBanner(),
          _monitorStatusBar(),
          if (_noFaceSince != null && !_tripCompleted) _noDriverCountdown(),
          const Spacer(),
          _seatbeltIndicator(),
          _monitorBanner(),
          _monitorDiag(),
        ],
      ),
    );
  }

  /// Shows offline/online status and pending incident count.
  Widget _connectivityBanner() {
    final pending = _incidentsService.pendingCount;
    if (_isOnline && pending == 0) return const SizedBox.shrink();

    final Color bgColor;
    final IconData icon;
    final String text;

    if (!_isOnline) {
      bgColor = const Color(0xFFDC2626);
      icon = Icons.wifi_off_rounded;
      text = pending > 0
          ? 'OFFLINE · $pending events queued'
          : 'OFFLINE · Events saving locally';
    } else {
      // Online but still has pending items = syncing
      bgColor = const Color(0xFF2563EB);
      icon = Icons.sync_rounded;
      text = 'SYNCING · $pending events uploading...';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// Shown while no driver is in view — counts down the seconds until the
  /// current trip auto-completes (_kTripEndSeconds).
  Widget _noDriverCountdown() {
    final elapsed = DateTime.now().difference(_noFaceSince!).inSeconds;
    final remaining = (_kTripEndSeconds - elapsed).clamp(0, _kTripEndSeconds);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFF59E0B), width: 3),
            ),
            child: Text(
              '$remaining',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'No driver detected',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Ending Trip $_tripNumber in ${remaining}s',
                  style: const TextStyle(
                    color: Color(0xFFFCD34D),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Top info bar (driving_hud_view style): live dot + calibration + trip.
  Widget _monitorStatusBar() {
    final calText = _state.calibrated
        ? 'CAL ✓'
        : 'Calibrating ${_state.calibrationFrame}/${MonitoringEngine.kCalibrationFrames}';
    final calColor = _state.calibrated ? Colors.greenAccent : Colors.amber;

    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF4ADE80),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'MONITORING',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            calText,
            style: TextStyle(
              color: calColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            'Trip $_tripNumber · $_driverName',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── TRIP COMPLETED (driver gone >= 30s) ──
  Widget _tripCompletedOverlay() {
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF16A34A),
                ),
                child: const Icon(
                  Icons.check_circle_outline_rounded,
                  color: Colors.white,
                  size: 52,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Trip $_tripNumber Completed',
                style: const TextStyle(
                  color: Color(0xFF111827),
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Driver left the seat. Waiting for the next driver to start the next trip…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 26),
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(0xFF3B82F6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Big full-width detection banner (driving_hud_view style). Shows the most
  // important active state: unauthorized / multiple / asleep / phone /
  // cigarette / seatbelt / drowsy / distraction. Hidden when all is well.
  Widget _monitorBanner() {
    final phone = _state.detectedObjects.any(
      (o) => o.label == 'phone' && o.confidence > 0.45,
    );
    final smoke = _state.detectedObjects.any(
      (o) => o.label == 'cigarette' && o.confidence > 0.45,
    );

    Color? bg;
    String? text;
    Color fg = Colors.white;

    if (_state.authStatus == AuthStatus.unauthorized) {
      bg = const Color(0xFF7F1D1D);
      text = '🚫  UNAUTHORIZED DRIVER  🚫';
    } else if (_state.authStatus == AuthStatus.multipleFaces) {
      bg = const Color(0xFFEA580C);
      text = '⚠  MULTIPLE PEOPLE DETECTED  ⚠';
    } else if (_state.drowsinessLevel == DrowsinessLevel.asleep) {
      bg = const Color(0xFFDC2626);
      text = '⚠  WAKE UP!  ⚠';
    } else if (phone) {
      bg = const Color(0xFF7E22CE);
      text = '📵  PHONE DETECTED';
    } else if (smoke) {
      bg = const Color(0xFF7E22CE);
      text = '🚬  SMOKING DETECTED';
       } else if (_state.hasEating || _state.isChewing) {
      bg = const Color(0xFFDC2626);
      text = '🍔  EATING DETECTED';
    } else if (_state.hasDrinking) {
      bg = const Color(0xFFEA580C);
      text = '🥤  DRINKING DETECTED';
    } else if (_state.drowsinessLevel == DrowsinessLevel.drowsy) {
      bg = const Color(0xFFD97706);
      text = '⚠  DROWSINESS DETECTED  ⚠';
    } else if (_state.distractionStatus == DistractionStatus.distracted) {
      bg = const Color(0xFFEAB308);
      fg = Colors.black;
      text = '⚠  EYES ON THE ROAD  ⚠';
    // } else if (_state.seatbeltBuckled) {
    //   bg = const Color(0xFF16A34A);
    //   text = '🔒  SEATBELT ON';
    }

    if (bg == null || text == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w800),
      ),
    );
  }


// Always-visible seatbelt status: red ✗ when off, green ✓ when on.
Widget _seatbeltIndicator() {
  final on = _state.seatbeltBuckled;
  final bg = on ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
  final icon = on ? Icons.check_circle_rounded : Icons.cancel_rounded;
  final text = on ? '🔒  SEATBELT ON' : '⚠️  FASTEN SEATBELT';

  return Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: bg.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: Colors.white, size: 22),
        const SizedBox(width: 10),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}
  // Small live diagnostics strip (EAR / HEAD / STATUS) like driving_hud_view.
  // Remove this from the monitoring column if you want a cleaner screen.
  Widget _monitorDiag() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _diagRow(
            'EAR',
            'L:${_state.leftEar.toStringAsFixed(3)}  R:${_state.rightEar.toStringAsFixed(3)}  Thr:${_state.earThreshold.toStringAsFixed(3)}',
          ),
          _diagRow(
            'HEAD',
            'Yaw:${_state.yaw.toStringAsFixed(1)}°  Pitch:${_state.pitch.toStringAsFixed(1)}°',
          ),
          _diagRow(
            'STATUS',
            '${_state.drowsinessLevel.name.toUpperCase()} | ${_state.distractionStatus.name.toUpperCase()}',
          ),
        ],
      ),
    );
  }

  Widget _diagRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.cyanAccent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
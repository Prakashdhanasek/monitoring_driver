import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image/image.dart' as img;
import 'package:battery_plus/battery_plus.dart';
import 'package:monitoring_driver/kiosk.dart';
import 'package:monitoring_driver/services/geofence_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';

import 'core/face_auth_engine.dart';
import 'core/monitoring_engine.dart';
import 'core/object_detector_engine.dart';
import 'core/monitor_state.dart';

import 'services/settings_service.dart';
import 'services/drivers_service.dart';
import 'services/incidents_service.dart';
import 'services/telemetry_service.dart';
import 'services/trip_service.dart';
import 'services/tts_service.dart';
import 'services/esp32_wifi_service.dart';
import 'services/ffmpeg_recorder_service.dart';
import 'services/sftp_upload_service.dart';
import 'services/http_video_upload_service.dart';
import 'services/live_stream_service.dart';
import 'services/background_telemetry_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'services/reversing_detector_service.dart';
import 'services/app_update_service.dart';
import 'views/reversing_camera_overlay.dart';
import 'views/cam_detection_panel.dart';
import 'views/alert_messages.dart';
import 'views/app_update_screen.dart';
import 'views/alert_messages.dart';

import 'dart:math'; // for sqrt
import 'package:sensors_plus/sensors_plus.dart';

/// The 3 phases of the driver-facing flow.
enum Phase { verifying, details, monitoring }

/// Exactly one camera is active at a time.
/// Switching away from [driverMonitoring] stops the phone camera image stream
/// so the CPU is entirely free for the active ESP32 stream.
// enum CamMode { driverMonitoring, rear, left, right }

enum CamMode { driverMonitoring, rear, left, right, front }

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
  final TripService _tripService = TripService();
  final GeofenceService _geofenceService = GeofenceService();

  // ── Voice alerts (TTS -> Bluetooth speaker if connected) ──
  final TtsService _tts = TtsService();
  final Esp32WifiService _espWifiService = Esp32WifiService();
  final FFmpegVideoRecorderService _ffmpegRecorderService =
  FFmpegVideoRecorderService();
  final SftpUploadService _sftpUploadService = SftpUploadService(
    host: 'sftp.example.com',
    port: 22,
    username: 'upload_user',
    password: 'secret_password',
  );
  final HttpVideoUploadService _httpVideoUploadService =
  HttpVideoUploadService();
  final LiveStreamService _streamService = LiveStreamService();
  final GlobalKey _screenBoundaryKey = GlobalKey();
  bool _isCapturingScreen = false;
  DateTime? _lastScreenFrameTime;
  DateTime? _highResUntil;

  // ── Connectivity tracking ──
  bool _isOnline = true;
  bool _isWifi = false;
  Timer? _connectivityTimer;
  Timer? _telemetryTimer;
  Timer? _sensorUiTimer;

  // ── Brightness control ──
  double _brightness = 1.0;

  // ── Unverified driver: require consecutive high-speed readings ──
  int _consecutiveHighSpeedCount = 0;
  static const int _kHighSpeedConsecutiveRequired = 3;

  bool _isConnectingToEsp32 = false;
  bool _isConnectedToEsp32 = false;
  // True when REAR was opened via the REAR button (manual). Reverting clears this.
  bool _rearManualOverride = false;
  // True when FRONT was opened manually (top button or banner button). Prevents
  // _pollBlindSpotSensors from auto-closing the panel when the sensor reads clear.
  bool _frontManualOverride = false;
  bool _leftManualOverride = false;
  bool _rightManualOverride = false;

  ReversingDetectorService? _reversingDetector;
  // ── Single active camera mode ─────────────────────────────────────────────
  // Only one of these runs at a time. Switching away from driverMonitoring
  // stops the phone image stream so face/object detection is fully paused.
  CamMode _camMode = CamMode.driverMonitoring;
  // String _esp32StreamUrl = 'http://10.119.135.95:82/';

  String _esp32StreamUrl = ''; // Auto-discovered on startup
  String _frontCamStreamUrl = '';

  // ── Side cameras (blind spot)
  // Left cam  — video :86,  sensor :87
  // Right cam  — video :80,  sensor :81
  // Front cam  — video :84,  sensor :85
  // Rear cam   — video :82,  sensor :83  (rearcam.local → 10.119.135.87)
  static const String _kLeftCamStreamUrl = 'http://leftcam.local:86/';
  static const String _kRightCamStreamUrl = 'http://rightcam.local:80/';
  static const String _kFrontCamStreamUrl = 'http://frontcam.local:84/';
  // Resolved IPs for all ESP32 cams — found by subnet scanner on startup.
  // Null until resolved; sensors and panels are skipped while null.
  // Reset to null if we switch networks so the scanner re-discovers them.
  // String? _leftCamIp; // video :86  sensor :87
  // String? _rightCamIp; // video :80  sensor :81
  // String?
  // _frontCamIp; // video :84

  String? _leftCamIp; // video :86  sensor :87 (auto-discovered)
  String? _rightCamIp; // video :80  sensor :81 (auto-discovered)
  String? _frontCamIp; // video :84  sensor :85 (auto-discovered)
  // (resolved by scanner, not shown in strict mode)
  DateTime? _lastSideCamScanAt; // throttle scanner to once per 60 s
  Timer? _blindSpotTimer;
  bool _isPollingBlindSpot = false;
  DateTime? _blindSpotObjectLastSeenAt; // last time object was < 50cm
  static const int _kBlindSpotLingerSec = 5; // keep cam open 5s after clear
  CamMode?
  _camModeBeforeBlindSpot; // cam mode before sensor auto-opened side cam

  // ESP32 camera connection status
  bool _rearCamConnected = false;
  bool _frontCamConnected = false;
  bool _leftCamConnected = false;
  bool _rightCamConnected = false;

  // Flow
  Phase _phase = Phase.verifying;
  bool _initializing = true;
  bool _camReady = false;
  bool _busy = false;
  bool _streaming = false;
  bool _updatingApp =
      false; // true while OTA dialog is open → blocks frame processing
  bool _isCheckingUpdate = false; // guard against concurrent update checks
  DateTime? _lastUpdateCheck; // throttle periodic update checks to once per hour
  int _frame = 0;
  bool _isRefreshingDrivers = false;
  DateTime? _lastAuthAttemptAt;
  bool _faceWasPresentLastFrame = false;
  DateTime? _lastDriversRefreshAt;
  DateTime?
  _unmatchedFaceSince; // tracks how long a face is present but not matching

  // Verified driver
  String _driverName = '';
  String _driverId = '—';
  String? _vehicleId;
  String? _vehicleRegNo;
  String? _tripId;
  double _overspeedThreshold = 0; // km/h from API (0 = disabled)

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
  Map<String, int> _apiCooldownSeconds = {};
  final Map<String, DateTime> _lastVoiceAlertAt = {};
  final Map<String, DateTime> _lastCooldownLogAt = {};
  String? _activeBannerKey;
  DateTime? _activeBannerAt;
  static const Duration _kBannerVisibleDuration = Duration(seconds: 3);
  static const double _kSpeedLimitKmh = 30.0;
  static const int _kUnauthorizedTimeoutSeconds = 30;

  // Seatbelt cyclic alert state
  DateTime? _seatbeltAlertStart; // when unbuckled state first detected
  bool _seatbeltInBeepPhase = true; // true=30s beep, false=60s silence
  DateTime? _seatbeltPhaseStart; // start of current beep/silence phase
  static const int _kSeatbeltBeepDuration = 30; // seconds
  static const int _kSeatbeltSilenceDuration = 60; // seconds
  static const int _kSeatbeltGraceSeconds = 10; // grace period after trip start
  DateTime? _monitoringStartedAt; // when monitoring phase began

  // ESP cam detection alert (person/vehicle detected on front/rear cam)
  String? _camDetectionAlert;
  DateTime? _camDetectionAlertAt;
  DateTime? _lastCamAlertSoundAt;

  // Still face image captured at the moment of successful verification.
  Uint8List? _capturedFace;

  // App version string (fetched from PackageInfo on init)
  String _appVersion = '';

  // Latest camera frame as JPEG — updated every object detection frame.
  // Used for incident snapshots so the correct detection-time image is uploaded.
  Uint8List? _latestFrameJpeg;

  // Rolling buffer of the last 15 JPEG frames (~5 seconds at 3 fps) for incident video.
  final List<Uint8List> _recentFrames = [];

  // Trip counting: a trip ends when the driver is gone for >= 30s, and the
  // next time a driver appears it becomes the next trip.
  int _tripNumber = 0; // incremented to 1 on the first verification
  bool _tripCompleted = false;
  DateTime? _unauthorizedStart;
  DateTime? _lastDriverChangedReportAt;
  bool _unauthorizedTripStop = false;
  DateTime? _tripCompletedAt;
  DateTime? _noFaceSince;
  static const int _kTripEndSeconds = 30; // 10 minutes

  bool _isDriverChangedActive() {
    if (_state.authStatus != AuthStatus.unauthorized) return false;
    if (_lastDriverChangedReportAt != null) {
      final elapsedSinceReport = DateTime.now()
          .difference(_lastDriverChangedReportAt!)
          .inSeconds;
      if (elapsedSinceReport < 300) {
        return false; // 5-minute (300s) cooldown active
      }
    }
    return true;
  }

  //static const int _kTripEndSeconds = 600; // 10 minutes
  // static const int _kTripEndSeconds = 60; // 1 minutes
  // Hidden admin-exit gesture (top-right corner x5 -> PIN -> leave kiosk).
  int _exitTaps = 0;
  DateTime? _firstExitTapAt;
  Timer? _syncTimer;

  // // ── Cable / charging monitor ──
  // final Battery _battery = Battery();
  // StreamSubscription<BatteryState>? _batterySub;
  // // bool _cableUnplugged = false;
  // bool _showCableBanner = false;
  // // Timer? _cableBannerTimer;
  // DateTime? _lastCableReportAt;

  bool _flashScreenshot = false;
  DateTime? _lastFlashAt;

  // ── No-drivers auto-retry (retries fetch every 30 s while stuck) ──
  Timer? _noDriversRetryTimer;

  // Keeps live stream fed while phone camera is paused (ESP cam mode)
  Timer? _espCamStreamTimer;

  // ── Break alert (periodic driver fatigue reminder) ──
  bool _showBreakAlert = false;
  int _breakAlertIndex = 0;
  Map<String, String>? _currentBreakMsg;
  Timer? _breakAlertTimer;
  Timer? _breakAlertDismissTimer;
  static const Duration _kBreakAlertInterval = Duration(hours: 1);
  static const Duration _kBreakAlertDisplayDuration = Duration(seconds: 12);
  static const List<Map<String, String>> _kBreakMessages = [
    {
      'emoji': '☕',
      'title': 'Time for a Break!',
      'sub': 'Pull over safely and rest for a few minutes.',
    },
    {
      'emoji': '💧',
      'title': 'Stay Hydrated!',
      'sub': 'Drink some water to stay alert and focused.',
    },
    {
      'emoji': '🌬️',
      'title': 'Take a Deep Breath',
      'sub': 'Breathe deeply to reduce stress and stay calm.',
    },
  ];

  // ── Geofence / boundary violation ──
  double? _boundaryLat; // geofence center latitude
  double? _boundaryLng; // geofence center longitude
  double? _boundaryRadiusM; // radius in meters
  String? _geofenceId; // needed for the violation payload
  bool _boundaryViolationReported = false; // fire once per exit
  bool _outsideBoundary = false; // true while the vehicle is beyond the radius
  double _boundaryBeyondM = 0; // how far past the limit, in meters

  // ── Harsh driving (accelerometer magnitude + GPS classification) ──
  // DISABLED: Harsh driving detection commented out
  StreamSubscription<UserAccelerometerEvent>? _accelSub;

  // // Force magnitude (m/s²) above which we treat it as a candidate harsh event.
  // static const double _kHarshMagnitude = 7.5;

  // // Ignore events below this speed (parked / crawling → GPS jitter noise).
  // static const double _kMinHarshSpeedKmh = 80.0;

  // // How much forward speed must change to classify accel vs brake (m/s).
  // static const double _kSpeedDeltaMs = 0.8;

  // // Local debounce so one physical event isn't detected dozens of times.
  // DateTime? _lastHarshAt;
  // static const Duration _kHarshDebounce = Duration(seconds: 2);

  // // Short rolling history of (timestamp, speed-in-m/s) for classification.
  // final List<MapEntry<DateTime, double>> _speedHistory = [];
  // // ── Harsh driving dedicated cooldown ──
  // final Map<String, DateTime> _lastHarshReportAt = {};
  // static const int _kHarshCooldownSeconds = 15;
  // Set when a harsh event fires; drives the banner via _getMonitorBannerKey.
  String? _harshBannerText; // e.g. 'HARSH BRAKING'
  DateTime? _harshEventAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitoringEngine = MonitoringEngine(_state);
    _tts.init();
    WakelockPlus.enable();
    _loadAppVersion();
    _fetchIncidentIntervals(); // ← add this

    _init();

    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _syncIncidentsTask();
      _triggerVideoUpload();
      _syncTripsTask();
      // _maybeReReportCable();
    });

    // Check connectivity every 5 seconds
    _connectivityTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkConnectivity();
      _checkCamConnections();
      // Auto-discover cameras if any are still unresolved
      if (_leftCamIp == null ||
          _rightCamIp == null ||
          _frontCamIp == null ||
          _esp32StreamUrl.isEmpty) {
        _resolveSideCamIps();
        if (_esp32StreamUrl.isEmpty) _autoDiscoverRearCam();
      }
    });
    _checkConnectivity();

    // Send location telemetry every 3 seconds
    _telemetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _sendTelemetryTask();
      // Check for app update every 5 minutes while online
      final now = DateTime.now();
      if (_isOnline &&
          (_lastUpdateCheck == null ||
              now.difference(_lastUpdateCheck!).inMinutes >= 5)) {
        _checkForUpdateInBackground();
      }
    });

    // Refresh UI every 200 ms for real-time sensor/direction telemetry.
    _sensorUiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _phase == Phase.monitoring) {
        setState(() {});
      }
    });

    // _initBatteryMonitor();

    // Resolve cam IPs after 10 s so app startup isn't flooded with 150+
    // concurrent subnet probe requests the moment the app opens.
    // Future.delayed(const Duration(seconds: 10), _resolveSideCamIps);

    // Blind spot sensor polling every 500 ms
    _blindSpotTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollBlindSpotSensors();
    });

    // Break alert: remind driver every 30 seconds (testing) / 2 hours (prod)
    _breakAlertTimer = Timer.periodic(_kBreakAlertInterval, (_) {
      _triggerBreakAlert();
    });

    // _startHarshDetection();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = 'v${info.version}+${info.buildNumber}');
      }
    } catch (e) {
      debugPrint('[Flow] Error loading app version: $e');
    }
  }

 /// Loads per-incident interval settings from the API and maps the API's
  /// incidentType names onto the event-type keys this app uses internally.
  Future<void> _fetchIncidentIntervals() async {
    try {
      final res = await http
          .get(
        Uri.parse(
          'https://proximity-driver-api.prod-app.in/api/settings/incident-alerts',
        ),
      )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          _applyIncidentIntervals(decoded);
          debugPrint(
            '[Flow] Incident intervals from API: $_apiCooldownSeconds',
          );
        }
      }
    } catch (e) {
      debugPrint('[Flow] Failed to fetch incident intervals: $e');
    }
  }

  void _applyIncidentIntervals(List<dynamic> list) {
    final map = <String, int>{};
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final type = item['incidentType'] as String?;
      final rawSecs = item['intervalSecs'];
      if (type == null || rawSecs == null) continue;
      final int secs = rawSecs is num
          ? rawSecs.toInt()
          : (int.tryParse(rawSecs.toString()) ?? 60);

      // Map API incidentType → the label keys used inside the app.
      switch (type) {
        case 'Drowsiness':
          map['Drowsiness'] = secs;
          break;
        case 'Distraction':
          map['Distraction'] = secs;
          break;
        case 'Overspeed':
          map['Overspeeding'] = secs; // code uses 'Overspeeding'
          break;
        case 'Phone Usage':
          map['Phone Usage'] = secs;
          break;
        case 'Smoking':
          map['Smoking'] = secs;
          break;
        case 'Seatbelt Not Worn':
          map['Seatbelt Not Worn'] = secs;
          map['seatbelt'] = secs; // _checkCooldown uses the 'seatbelt' key
          break;
        case 'Unauthorized Driver':
          map['Unauthorized Driver'] = secs;
          break;
        case 'Unverified Driver':
          map['Unverified Driver'] = secs;
          break;
        default:
          map[type] = secs; // Cable Unplugged, Driver Changed, future types
      }
    }
    _apiCooldownSeconds = map;
  }


  Future<void> _checkConnectivity() async {
    try {
      // Check WiFi status
      final connResult = await Connectivity().checkConnectivity();
      final wifiNow = connResult.contains(ConnectivityResult.wifi);
      if (wifiNow != _isWifi) {
        _isWifi = wifiNow;
        if (mounted) setState(() {});
      }

      final result = await InternetAddress.lookup(
        'proximity-driver-api.prod-app.in',
      ).timeout(const Duration(seconds: 3));
      final online = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      if (online != _isOnline) {
        _isOnline = online;
        if (mounted) setState(() {});
        debugPrint('==================================================');
        debugPrint(
          '[CONNECTIVITY CHANGE] Device moved to: ${_isOnline ? "ONLINE" : "OFFLINE"}',
        );
        debugPrint('==================================================');
        // Auto-sync immediately when we come back online
        if (_isOnline) {
          _syncIncidentsTask();
          _triggerVideoUpload();
          _fetchIncidentIntervals();

          _syncTripsTask();
          // Check for app update when WiFi becomes available (vehicle turned on)
          _checkForUpdateInBackground();
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
      // Also update WiFi status on error
      final connResult = await Connectivity().checkConnectivity().catchError(
            (_) => <ConnectivityResult>[],
      );
      final wifiNow = connResult.contains(ConnectivityResult.wifi);
      if (wifiNow != _isWifi) {
        _isWifi = wifiNow;
        if (mounted) setState(() {});
      }
    }

    // Front ESP32-CAM continuous recording check (restart recording if stopped)
    if (_frontCamConnected && _frontCamStreamUrl.isNotEmpty) {
      if (!_ffmpegRecorderService.isRecording &&
          _camMode == CamMode.driverMonitoring &&
          _phase == Phase.monitoring) {
        await _ffmpegRecorderService.startRecording(_frontCamStreamUrl);
      }
    }
  }

  /// Checks actual connectivity to each ESP32 camera.
  /// Left/Right: HTTP GET /sensor (validates JSON response).
  /// Front/Rear: Quick TCP probe on video port (single attempt, 2s timeout).
  Future<void> _checkCamConnections() async {
    /// Validates sensor endpoint — returns true only if it responds with distance_cm JSON.
    Future<bool> _pingSensor(String? ip, int sensorPort, String tag) async {
      if (ip == null || ip.isEmpty) return false;
      try {
        final res = await http
            .get(Uri.parse('http://$ip:$sensorPort/sensor'))
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          if (data.containsKey('distance_cm')) {
            debugPrint('[CamPing] $tag → OK (sensor at $ip:$sensorPort)');
            return true;
          }
        }
      } catch (e) {
        debugPrint('[CamPing] $tag → FAIL ($ip:$sensorPort): $e');
      }
      return false;
    }

    // Left/Right: validate via sensor endpoint (proper JSON check).
    final results = await Future.wait([
      _pingSensor(_leftCamIp, 87, 'LEFT'),
      _pingSensor(_rightCamIp, 81, 'RIGHT'),
    ]);

    // Front/Rear: Do NOT ping video port — ESP32-CAM supports only ONE client.
    // Pinging port 84/82 steals the connection from FFmpeg recorder / stream overlay,
    // causing recording failures and intermittent red status.
    // Instead: mark as connected if IP was discovered and stream URL is set.
    final frontConnected = _frontCamIp != null && _frontCamIp!.isNotEmpty;
    final rearConnected = _esp32StreamUrl.isNotEmpty;

    final changed =
        results[0] != _leftCamConnected ||
            results[1] != _rightCamConnected ||
            frontConnected != _frontCamConnected ||
            rearConnected != _rearCamConnected;

    if (changed && mounted) {
      setState(() {
        _leftCamConnected = results[0];
        _rightCamConnected = results[1];
        _frontCamConnected = frontConnected;
        _rearCamConnected = rearConnected;
      });
    }
  }
  // /// Checks TCP connectivity to each ESP32 camera's video port.
  // Future<void> _checkCamConnections() async {
  //   Future<bool> _ping(String? ip, int port) async {
  //     if (ip == null) return false;
  //     try {
  //       final socket = await Socket.connect(
  //         ip,
  //         port,
  //       ).timeout(const Duration(seconds: 2));
  //       await socket.close();
  //       return true;
  //     } catch (_) {
  //       return false;
  //     }
  //   }

  //   // Extract rear cam host from stream URL
  //   final rearHost = Uri.parse(_esp32StreamUrl).host;

  //   final results = await Future.wait([
  //     _ping(_leftCamIp, 86),
  //     _ping(_rightCamIp, 80),
  //     _ping(_frontCamIp, 84),
  //     _ping(rearHost, 82),
  //   ]);

  //   final changed =
  //       results[0] != _leftCamConnected ||
  //       results[1] != _rightCamConnected ||
  //       results[2] != _frontCamConnected ||
  //       results[3] != _rearCamConnected;

  //   if (changed && mounted) {
  //     setState(() {
  //       _leftCamConnected = results[0];
  //       _rightCamConnected = results[1];
  //       _frontCamConnected = results[2];
  //       _rearCamConnected = results[3];
  //     });
  //   }
  // }

  // ─────────────────────────────────────────────────────────
  // CABLE / CHARGING MONITOR
  // ─────────────────────────────────────────────────────────
  // Future<void> _initBatteryMonitor() async {
  //   // Set up listener first — even if initial state check fails
  //   try {
  //     _batterySub = _battery.onBatteryStateChanged.listen(
  //       _onBatteryStateChanged,
  //     );
  //   } catch (e) {
  //     debugPrint('[Flow] battery listener setup error: $e');
  //   }

  //   // Then check initial state
  //   try {
  //     final initial = await _battery.batteryState;
  //     debugPrint('[Flow] 🔋 Initial battery state: $initial');
  //     _cableUnplugged = _isUnplugged(initial);
  //     if (mounted) setState(() {});
  //   } catch (e) {
  //     debugPrint('[Flow] battery initial state error: $e');
  //   }
  // }

  // bool _isUnplugged(BatteryState state) {
  //   // Charging or full means cable is connected
  //   if (state == BatteryState.charging || state == BatteryState.full) {
  //     return false;
  //   }
  //   // Discharging or unknown means cable is NOT connected
  //   // (some devices report unknown instead of discharging on unplug)
  //   return true;
  // }

  // void _onBatteryStateChanged(BatteryState state) {
  //   debugPrint('[Flow] 🔋 Battery state changed: $state');

  //   final nowUnplugged = _isUnplugged(state);

  //   if (nowUnplugged && !_cableUnplugged) {
  //     _cableUnplugged = true;
  //     debugPrint('[Flow] ⚠️ Charging cable UNPLUGGED.');

  //     // FIX: Only report cable-unplug incident if a driver is verified.
  //     // Before face verification, we have no confirmed driver — sending an
  //     // incident would attach a blank image and possibly a stale driver name.
  //     if (_phase == Phase.monitoring && _driverId != '—') {
  //       _reportIncident('Cable Unplugged', 'High', 1.0);
  //       _lastCableReportAt = DateTime.now();
  //     } else {
  //       debugPrint(
  //         '[Flow] Skipping cable-unplug incident — no verified driver yet.',
  //       );
  //     }

  //     // Show banner for 5 seconds only
  //     _showCableBanner = true;
  //     _cableBannerTimer?.cancel();
  //     _cableBannerTimer = Timer(const Duration(seconds: 5), () {
  //       if (mounted) setState(() => _showCableBanner = false);
  //     });

  //     _playAlert('audio/alert_loud.mp3');
  //     _tts.speak('Warning. Charging cable unplugged.');
  //     if (mounted) setState(() {});
  //   } else if (!nowUnplugged && _cableUnplugged) {
  //     _cableUnplugged = false;
  //     _showCableBanner = false;
  //     _cableBannerTimer?.cancel();
  //     _lastCableReportAt = null;
  //     debugPrint('[Flow] Charging cable reconnected.');
  //     if (mounted) setState(() {});
  //   }
  // }

  // void _maybeReReportCable() {
  //   if (!_cableUnplugged) return;
  //   // FIX: Don't re-report cable unplug unless driver is verified and monitoring
  //   if (_phase != Phase.monitoring || _driverId == '—') return;
  //   final last = _lastCableReportAt;
  //   if (last == null || DateTime.now().difference(last).inSeconds >= 5 * 60) {
  //     _lastCableReportAt = DateTime.now();
  //     _reportIncident('Cable Unplugged', 'High', 1.0);
  //   }
  // }

  /// Polls the server for a newer APK version.
  /// Navigates to [AppUpdateScreen] if an update is available.
  /// Cancels the timer once an update is found to avoid repeated prompts.
  Future<void> _checkForUpdateInBackground() async {
    if (!mounted || _isCheckingUpdate || _updatingApp) return;
    _isCheckingUpdate = true;
    _lastUpdateCheck = DateTime.now(); // reset cooldown regardless of call site
    final updateInfo = await AppUpdateService().checkForUpdate();
    _isCheckingUpdate = false;
    if (!mounted) return;
    if (updateInfo != null) {
      // Pause camera ML and ALL background tasks to give download full resources.
      _updatingApp = true;
      final wasStreaming = _streaming;
      if (_streaming) {
        _camera?.stopImageStream().catchError((_) {});
        _streaming = false;
      }
      _syncTimer?.cancel();
      _connectivityTimer?.cancel();
      _telemetryTimer?.cancel();
      _sensorUiTimer?.cancel();
      _blindSpotTimer?.cancel();

      await showDialog<void>(
        context: context,
        barrierDismissible: !updateInfo.forceUpdate,
        barrierColor: Colors.black54,
        builder: (_) => AppUpdateScreen(updateInfo: updateInfo),
      );

      // Dialog dismissed without a successful install — restore everything.
      if (!mounted) return;
      _updatingApp = false;
      if (wasStreaming && _camReady && _camMode == CamMode.driverMonitoring) {
        _camera?.startImageStream(_processImage).catchError((_) {});
        _streaming = true;
      }
      _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        _syncIncidentsTask();
        _syncTripsTask();
      });
      _connectivityTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _checkConnectivity();
        _checkCamConnections();
        if (_leftCamIp == null ||
            _rightCamIp == null ||
            _frontCamIp == null ||
            _esp32StreamUrl.isEmpty) {
          _resolveSideCamIps();
          if (_esp32StreamUrl.isEmpty) _autoDiscoverRearCam();
        }
      });
      _telemetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _sendTelemetryTask();
        // Check for app update every 5 minutes while online
        final now = DateTime.now();
        if (_isOnline &&
            (_lastUpdateCheck == null ||
                now.difference(_lastUpdateCheck!).inMinutes >= 5)) {
          _checkForUpdateInBackground();
        }
      });
      _sensorUiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted && _phase == Phase.monitoring) setState(() {});
      });
      _blindSpotTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _pollBlindSpotSensors();
      });
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _connectivityTimer?.cancel();
    _telemetryTimer?.cancel();
    _sensorUiTimer?.cancel();
    _countdownTimer?.cancel();
    // _cableBannerTimer?.cancel();
    // _batterySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _detector?.close();
    _objectDetector.dispose();
    _player.dispose();
    _tts.dispose();
    _streamService.dispose();
    WakelockPlus.disable();
    _ffmpegRecorderService.stopRecording();
    _espWifiService.disconnectFromEsp32();
    _reversingDetector?.dispose();
    _blindSpotTimer?.cancel();
    _breakAlertTimer?.cancel();
    _breakAlertDismissTimer?.cancel();
    _noDriversRetryTimer?.cancel();
    _espCamStreamTimer?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchAndDownloadDrivers() async {
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      debugPrint('[Flow] No device_id stored. Skipping API fetch.');
      return;
    }
    final drivers = await _driversService.fetchAndCacheDrivers(deviceId);

    // Extract vehicle registration number from the first driver's assigned vehicles
    // so it's available on the verifying screen before face auth completes.
    if (_vehicleRegNo == null || _vehicleRegNo!.isEmpty) {
      for (final driver in drivers) {
        final vehicles = driver['assignedVehicles'] as List<dynamic>?;
        if (vehicles != null && vehicles.isNotEmpty) {
          final first = vehicles.first as Map<String, dynamic>;
          final regNo = first['vehicleRegistrationNumber'] as String?;
          if (regNo != null && regNo.isNotEmpty) {
            _vehicleRegNo = regNo;
            debugPrint('[Flow] Vehicle reg from driver list: $_vehicleRegNo');
            if (mounted) setState(() {});
            break;
          }
        }
        // Fallback to flat field
        final regNo = driver['vehicleRegistrationNumber'] as String?;
        if (regNo != null && regNo.isNotEmpty) {
          _vehicleRegNo = regNo;
          debugPrint('[Flow] Vehicle reg from driver (flat): $_vehicleRegNo');
          if (mounted) setState(() {});
          break;
        }
      }
    }
  }

  Future<String?> _findEsp32IpFromArpTable() async {
    // Strategy 1: Try reading the ARP table (works on older Android versions)
    try {
      final file = File('/proc/net/arp');
      if (await file.exists()) {
        final content = await file.readAsString();
        final lines = content.split('\n');
        for (var line in lines) {
          final parts = line
              .split(RegExp(r'\s+'))
              .where((p) => p.isNotEmpty)
              .toList();
          if (parts.length >= 4 && parts[0] != 'IP') {
            final ip = parts[0];
            final mac = parts[3].toLowerCase();
            if (mac != '00:00:00:00:00:00') {
              debugPrint('[ESP32-ARP] Client in ARP: IP=$ip, MAC=$mac');
              try {
                final socket = await Socket.connect(
                  ip,
                  80,
                ).timeout(const Duration(milliseconds: 1000));
                await socket.close();
                debugPrint('[ESP32-ARP] Found responsive HTTP server at $ip');
                return ip;
              } catch (_) {
                // Keep looking
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[ESP32-ARP] ARP read failed (expected on Android 10+): $e');
    }

    // Strategy 2: Subnet scan fallback (works on Android 10+)
    try {
      debugPrint('[SubnetScan] Starting subnet scan fallback...');
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      String? localIp;
      // Step 1: Look for interface starting with wlan, ap, softap (Wi-Fi/Hotspot)
      for (var interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.contains('wlan') ||
            name.contains('ap') ||
            name.contains('softap')) {
          for (var addr in interface.addresses) {
            if (!addr.isLoopback &&
                (addr.address.startsWith('192.168.') ||
                    addr.address.startsWith('10.'))) {
              localIp = addr.address;
              break;
            }
          }
        }
        if (localIp != null) break;
      }

      // Step 2: Fallback to any interface that has a 192.168.x.x private IP (highly likely local Wi-Fi/hotspot)
      if (localIp == null) {
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
              localIp = addr.address;
              break;
            }
          }
          if (localIp != null) break;
        }
      }

      if (localIp == null) {
        debugPrint('[SubnetScan] No valid local IP found.');
        return null;
      }

      debugPrint('[SubnetScan] Local IP identified: $localIp');
      final lastDot = localIp.lastIndexOf('.');
      if (lastDot == -1) return null;
      final prefix = localIp.substring(0, lastDot + 1); // e.g. "192.168.175."

      debugPrint(
        '[SubnetScan] Probing subnet ${prefix}* on port 80 concurrently...',
      );

      // Spawn concurrent probes to scan the entire subnet in parallel
      final List<Future<String?>> probes = [];
      for (int i = 2; i <= 254; i++) {
        final target = '$prefix$i';
        if (target == localIp) continue;

        probes.add(() async {
          try {
            final socket = await Socket.connect(
              target,
              80,
            ).timeout(const Duration(milliseconds: 800));
            await socket.close();
            debugPrint('[SubnetScan] ✓ Found camera at $target');
            return target;
          } catch (_) {
            return null;
          }
        }());
      }

      final results = await Future.wait(probes);
      for (var ip in results) {
        if (ip != null) return ip;
      }
      debugPrint('[SubnetScan] No responsive camera found on subnet.');
    } catch (e) {
      debugPrint('[SubnetScan] Subnet scan failed: $e');
    }
    return null;
  }

  Future<void> _connectToEsp32Wifi() async {
    if (_isConnectingToEsp32) return;
    setState(() {
      _isConnectingToEsp32 = true;
    });

    const String targetSsid = 'motorola edge 50 pro';

    // Auto-discover rear cam on the current subnet
    String streamUrl = '';
    String esp32Host = '';
    const int esp32Port = 82;

    debugPrint('==================================================');
    debugPrint('[ESP32 STREAM STATUS CHECK]');
    debugPrint('[ESP32] Checking current Wi-Fi SSID...');

    // Step 1: Get current SSID
    String? currentSsid;
    try {
      currentSsid = await _espWifiService.getCurrentSsid().timeout(
        const Duration(seconds: 5),
      );
    } catch (e) {
      debugPrint('[ESP32] Timeout/error getting SSID: $e');
      currentSsid = null;
    }

    debugPrint('[ESP32] Current SSID: $currentSsid');

    // Step 2: If not on any WiFi, try to connect to ESP32 AP
    if (currentSsid == null ||
        currentSsid.isEmpty ||
        currentSsid == '<unknown ssid>') {
      debugPrint(
        '[Esp32Wifi] ✗ Not on any Wi-Fi. Trying to connect to: $targetSsid',
      );
      debugPrint('==================================================');
      final apConnected = await _espWifiService.connectToEsp32(
        targetSsid,
        password: 'Rohit@1213',
      );
      if (!apConnected) {
        debugPrint('[ESP32] ✗ Could not connect to ESP32 Access Point.');
        if (mounted) {
          setState(() {
            _isConnectingToEsp32 = false;
            _isConnectedToEsp32 = false;
          });
        }
        return;
      }
      currentSsid = await _espWifiService.getCurrentSsid().timeout(
        const Duration(seconds: 5),
      );
    }

    debugPrint(
      '[Esp32Wifi] ✓ On Wi-Fi: $currentSsid. Scanning subnet for rear cam on port $esp32Port...',
    );

    // Step 3: Auto-discover rear cam by scanning subnet for port 82
    String? subnet;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4 && parts[0] != '127') {
            subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
            break;
          }
        }
        if (subnet != null) break;
      }
    } catch (e) {
      debugPrint('[ESP32] Cannot get subnet: $e');
    }

    if (subnet != null) {
      debugPrint(
        '[ESP32] Scanning $subnet.1-254 for rear cam (port $esp32Port)...',
      );
      for (int start = 1; start <= 254; start += 50) {
        final end = (start + 49).clamp(1, 254);
        final probes = <Future<String?>>[];
        for (int i = start; i <= end; i++) {
          final ip = '$subnet.$i';
          probes.add(() async {
            try {
              final socket = await Socket.connect(
                ip,
                esp32Port,
              ).timeout(const Duration(milliseconds: 600));
              await socket.close();
              return ip;
            } catch (_) {
              return null;
            }
          }());
        }
        final results = await Future.wait(probes);
        final found = results.firstWhere((r) => r != null, orElse: () => null);
        if (found != null) {
          esp32Host = found;
          streamUrl = 'http://$found:$esp32Port/';
          debugPrint('[ESP32] ✓ Auto-discovered rear cam at $found:$esp32Port');
          break;
        }
      }
    }

    // Step 4: TCP test — verify ESP32-CAM host is reachable
    bool cameraReachable = esp32Host.isNotEmpty;
    if (cameraReachable) {
      try {
        final socket = await Socket.connect(
          esp32Host,
          esp32Port,
        ).timeout(const Duration(seconds: 3));
        await socket.close();
        debugPrint('[ESP32] ✓ Camera reachable at $esp32Host:$esp32Port');
        debugPrint('==================================================');
      } catch (e) {
        cameraReachable = false;
        debugPrint('==================================================');
        debugPrint(
          '[ESP32] ✗ Camera check failed at $esp32Host:$esp32Port: $e',
        );
        debugPrint('==================================================');
      }
    } else {
      debugPrint('[ESP32] ✗ No rear cam found on subnet scan.');
      debugPrint('==================================================');
    }

    if (mounted) {
      setState(() {
        _isConnectingToEsp32 = false;
        // Mark as connected/attempting so UI reflects status
        _isConnectedToEsp32 = cameraReachable;
        _esp32StreamUrl = streamUrl;
      });
      if (cameraReachable &&
          _phase == Phase.monitoring &&
          _camMode == CamMode.driverMonitoring) {
        _ffmpegRecorderService.startRecording(streamUrl);
      }

      // Also trigger side cam discovery on the same subnet
      _lastSideCamScanAt = null; // Reset throttle so it scans immediately
      _resolveSideCamIps();
    }
  }

  Future<void> _triggerVideoUpload() async {
    if (!_isOnline) return;
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) return;

    if (_vehicleId == null || _vehicleId!.isEmpty) {
      // Do not upload videos before the trip has started and vehicle ID is known.
      return;
    }
    final effectiveVehicleId = _vehicleId!;

    debugPrint(
      '[Flow] Online. Starting HTTP background video upload... (vehicleId: $effectiveVehicleId)',
    );
    try {
      final int
      uploadedCount = await _httpVideoUploadService.uploadPendingFiles(
        uploadUrl:
        'https://proximity-driver-api.prod-app.in/api/video-recordings/upload',
        vehicleId: effectiveVehicleId,
        deviceTabletId: deviceId,
        driverId: (_driverId == '—' || _driverId == '-' || _driverId.isEmpty)
            ? null
            : _driverId,
        tripId: _tripId,
        cameraType: 'FrontCam',
      );

      // if (uploadedCount > 0 && mounted) {
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     SnackBar(
      //       content: Text(
      //         'API Upload Success: $uploadedCount video(s) sent.',
      //         style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      //       ),
      //       backgroundColor: Colors.green,
      //       duration: const Duration(seconds: 4),
      //     ),
      //   );
      // }
    } catch (e) {
      debugPrint('[Flow] Video upload error: $e');
    }
  }

  Future<void> _init() async {
    // Reset in-memory driver state to defaults
    _driverId = '—';
    _driverName = 'Driver';
    _vehicleId = null;
    _vehicleRegNo = null;
    _tripId = null;

    // 0) Request location and storage permissions upfront.
    try {
      await _requestPermissions();
    } catch (e) {
      debugPrint('[Flow] Permission error: $e');
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

    // Set documentsDirectoryPath early so incident snapshots can be saved
    // even during verifying phase (before object detector processes a frame).
    if (_state.documentsDirectoryPath == null) {
      try {
        final docsDir = Directory('/storage/emulated/0/Documents');
        if (await docsDir.exists()) {
          _state.documentsDirectoryPath = docsDir.path;
        } else {
          await docsDir.create(recursive: true);
          _state.documentsDirectoryPath = docsDir.path;
        }
        debugPrint(
          '[Flow] documentsDirectoryPath: ${_state.documentsDirectoryPath}',
        );
      } catch (e) {
        _state.documentsDirectoryPath = Directory.systemTemp.path;
        debugPrint(
          '[Flow] documentsDirectoryPath fallback: ${_state.documentsDirectoryPath}',
        );
      }
    }

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

    // Give ML Kit native context time to finish initialization before streaming.
    await Future.delayed(const Duration(milliseconds: 800));

    // 4) Camera.
    await _initCamera();

    // Initialize reversing detector
    _reversingDetector = ReversingDetectorService();
    _reversingDetector!.onReversingChanged.listen((reversing) {
      // Disable automatic switching to rear camera
      /*
      if (!mounted) return;
      
      // Only trigger automatic reverse camera during the active monitoring phase.
      // This prevents the camera from suddenly opening due to phone handling during face verification.
      if (_phase != Phase.monitoring) return;

      if (reversing) {
        _setCamMode(CamMode.rear);
      } else if (_camMode == CamMode.rear && !_rearManualOverride) {
        // Auto-return only when reversing ends AND rear wasn't manually opened.
        _setCamMode(CamMode.driverMonitoring);
      }
      */
    });

    // Connect to ESP32 WiFi at startup to stay connected and minimize latency
    // _connectToEsp32Wifi();

    final deviceId = _settings.getDeviceId() ?? 'unknown_device';
    _streamService.connect(deviceId);

    // Sync any leftover offline-queued incidents on startup
    _syncIncidentsTask();

    if (mounted) setState(() => _initializing = false);

    // Check for update once on startup (handles case where WiFi is already
    // connected when app launches — connectivity change event never fires).
    _checkForUpdateInBackground();
  }

  Future<void> _requestPermissions() async {
    // 0. Microphone (required for push-to-talk audio)
    try {
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        await Permission.microphone.request();
      }
    } catch (e) {
      debugPrint('[Flow] Error requesting microphone permission: $e');
    }

    // 1. Storage Permissions (required to save video to public Downloads folder)
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        if (info.version.sdkInt >= 30) {
          // Android 11+
          var manageStatus = await Permission.manageExternalStorage.status;
          if (!manageStatus.isGranted) {
            await Permission.manageExternalStorage.request();
          }
        } else {
          // Android 10 and below
          var storageStatus = await Permission.storage.status;
          if (!storageStatus.isGranted) {
            await Permission.storage.request();
          }
        }
      }
    } catch (e) {
      debugPrint('[Flow] Error requesting storage permission: $e');
    }

    // 2. Location Permissions (for GPS telemetry)
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

    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      // Get initial position immediately so telemetry doesn't send 0,0
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(const Duration(seconds: 10));
        _state.gpsLat = pos.latitude;
        _state.gpsLng = pos.longitude;
        _state.vehicleSpeed = pos.speed > 0 ? (pos.speed * 3.6) : 0.0;
        BackgroundTelemetryService.instance.updatePosition(
          pos.latitude,
          pos.longitude,
          _state.vehicleSpeed,
        );
        debugPrint('[Flow] Initial GPS fix: ${pos.latitude}, ${pos.longitude}');
      } catch (e) {
        debugPrint('[Flow] Initial GPS fix failed: $e');
      }

      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen((Position position) {
        final speedKmH = position.speed > 0 ? (position.speed * 3.6) : 0.0;
        _state.gpsLat = position.latitude;
        _state.gpsLng = position.longitude;
        _state.vehicleSpeed = speedKmH;
        // Keep background telemetry in sync with latest position
        BackgroundTelemetryService.instance.updatePosition(
          position.latitude,
          position.longitude,
          speedKmH,
        );
        _reversingDetector?.updateGps(
          position.latitude,
          position.longitude,
          position.speed > 0 ? position.speed : 0.0,
          position.heading,
        );
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
  Future<void> _captureAndSendScreen() async {
    if (!_streamService.isStreaming || _isCapturingScreen) return;

    final now = DateTime.now();

    // 0.75x pixel ratio — good balance of quality vs bandwidth
    const double pixelRatio = 0.75;

    // 40ms throttle = ~25 FPS
    const int throttleMs = 40;

    if (_lastScreenFrameTime != null &&
        now.difference(_lastScreenFrameTime!).inMilliseconds < throttleMs) {
      return;
    }
    _lastScreenFrameTime = now;
    _isCapturingScreen = true;

    try {
      final RenderRepaintBoundary? boundary =
      _screenBoundaryKey.currentContext?.findRenderObject()
      as RenderRepaintBoundary?;
      if (boundary == null) return;

      // Capture screen dynamically based on warning status
      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      final width = image.width;
      final height = image.height;

      // Extract raw RGBA bytes on the UI thread
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose(); // Free GPU memory immediately

      if (byteData != null) {
        final rawBytes = byteData.buffer.asUint8List();
        // Send to isolate for background JPEG compression
        _streamService.feedScreenFrame(rawBytes, width, height);
      }
    } catch (e) {
      debugPrint('[Stream] Screen capture error: $e');
    } finally {
      _isCapturingScreen = false;
    }
  }

  Future<void> _processImage(CameraImage image) async {
    if (_updatingApp) return;

    if (_streamService.isStreaming) {
      _captureAndSendScreen();
    }

    if (_camMode != CamMode.driverMonitoring) return;
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
          final now = DateTime.now();
          final shouldRefresh =
              !_authEngine.isEnrolled ||
                  _lastDriversRefreshAt == null ||
                  now.difference(_lastDriversRefreshAt!).inSeconds >= 15;

          if (faces.isNotEmpty &&
              !_faceWasPresentLastFrame &&
              !_isRefreshingDrivers &&
              shouldRefresh) {
            _refreshDriversOnFaceDetection();
          }
          _faceWasPresentLastFrame = faces.isNotEmpty;

          // Capture frames during verifying phase for unverified-driver incidents
          if (_frame % 5 == 0) {
            final jpeg = _captureFaceJpeg(image, targetWidth: 240);
            if (jpeg != null) {
              _latestFrameJpeg = jpeg;
              _recentFrames.add(jpeg);
              if (_recentFrames.length > 30) {
                _recentFrames.removeAt(0);
              }
            }
          }

          if (faces.length == 1 && !_isRefreshingDrivers) {
            final now = DateTime.now();
            if (_lastAuthAttemptAt == null ||
                now.difference(_lastAuthAttemptAt!).inMilliseconds >= 1000) {
              _lastAuthAttemptAt = now;
              _authEngine.processAuth(
                faces.first,
                _state,
                image,
                _getCameraRotation(),
              );
            }
            if (_state.authStatus == AuthStatus.authenticated) {
              _unmatchedFaceSince = null;
              _capturedFace = _captureFaceJpeg(image, targetWidth: 480);
              _onVerified(isMatched: true);
            } else if (_state.authStatus == AuthStatus.unauthorized) {
              // Face present but doesn't match. Wait 10 seconds before
              // proceeding as Unknown Driver — gives registered drivers
              // time to get a good match under poor lighting/angles.
              _unmatchedFaceSince ??= DateTime.now();
              if (DateTime.now().difference(_unmatchedFaceSince!).inSeconds >=
                  10) {
                _unmatchedFaceSince = null;
                _capturedFace = _captureFaceJpeg(image, targetWidth: 480);
                final embedding = _authEngine.extractLiveEmbedding(
                  image,
                  _getCameraRotation(),
                  faces.first.boundingBox,
                );
                _authEngine.setActiveTripEmbedding(embedding);
                _onVerified(isMatched: false);
              }
            } else {
              _unmatchedFaceSince = null;
            }
          } else {
            _unmatchedFaceSince = null;
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
              if (_tripCompletedAt != null &&
                  DateTime.now().difference(_tripCompletedAt!).inSeconds < 10) {
                break;
              }
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
              // Continuous identity check — fast instant driver swap detection (<0.3s)
              final now = DateTime.now();
              if (_lastAuthAttemptAt == null ||
                  now.difference(_lastAuthAttemptAt!).inMilliseconds >= 100) {
                _lastAuthAttemptAt = now;
                _authEngine.processAuth(
                  face,
                  _state,
                  image,
                  _getCameraRotation(),
                  activeDriverId: _driverId,
                );
                if (_state.authStatus == AuthStatus.unauthorized &&
                    _isDriverChangedActive()) {
                  final jpeg = _captureFaceJpeg(image, targetWidth: 240);
                  if (jpeg != null) {
                    _latestFrameJpeg = jpeg;
                  }
                  _handleAlertSounds(image);
                }
              }
              _monitoringEngine.processFrame(face);
            }

            // Object detection (phone / cigarette / seatbelt) every 5 frames.
            if (_frame % 5 == 0) {
              _objectDetector.processFrame(image, _state, _getCameraRotation());
              // Capture current frame for incident snapshot and video buffer
              final jpeg = _captureFaceJpeg(image, targetWidth: 240);
              if (jpeg != null) {
                _latestFrameJpeg = jpeg;
                _recentFrames.add(jpeg);
                if (_recentFrames.length > 30) {
                  _recentFrames.removeAt(0); // Maintain max 15 frames (~5s)
                }
              }
            }

            // Play an alert sound on new warnings.
            await _handleAlertSounds(image);
          } else {
            // No driver in view — start / continue the "gone" timer.
            _unauthorizedStart = null;
            _multiFace = 0;
            _monitoringEngine.processFrame(null);
            _noFaceSince ??= DateTime.now();
            if (!_tripCompleted &&
                DateTime.now().difference(_noFaceSince!).inSeconds >=
                    _kTripEndSeconds) {
              _tripCompleted = true;
              _tripCompletedAt = DateTime.now();
              _breakAlertTimer?.cancel();
              _dismissBreakAlert();
              _sendTripEnd();
              // Trip ended — safe point to check for updates.
              _checkForUpdateInBackground();
              // _showVerifyToast();
            }
          }
          break;
      }

      if (mounted) setState(() {});
    } catch (e) {
      // ML Kit may not be ready immediately after app start / hot restart.
      // Suppress the spam and wait briefly before accepting more frames.
      if (e.toString().contains('MlKitContext has not been initialized')) {
        await Future.delayed(const Duration(milliseconds: 500));
      } else {
        debugPrint('[Flow] processImage error: $e');
      }
    } finally {
      _busy = false;
    }
  }

  void _showVerifyToast() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: const [
            Icon(Icons.face_retouching_natural, color: Colors.white),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Next driver — please look at the camera to verify',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2563EB),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _liveFaceCircle(double size) {
    final c = _camera;
    if (_camReady && c != null && c.value.previewSize != null) {
      final ps = c.value.previewSize!;
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
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
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFE5E7EB),
      ),
      child: Icon(
        Icons.person_rounded,
        size: size * 0.5,
        color: const Color(0xFF9CA3AF),
      ),
    );
  }

  Future<void> _onVerified({bool isMatched = true}) async {
    if (_phase != Phase.verifying) return;
    // ── Guard against re-entry ──────────────────────────────────────────────
    // Move to Phase.details immediately so concurrent camera frames that fire
    // _onVerified() while we're awaiting API calls see phase != verifying and
    // return early. Without this, multiple frames in the 1-2s window before
    // _phase was set later would each start a separate _sendTripStart() call.
    _phase = Phase.details;
    if (mounted) setState(() {});
    // ────────────────────────────────────────────────────────────────────────
    _unauthorizedStart = null;
    _unauthorizedTripStop = false;
    _tripCompletedAt = null;
    _tripNumber++; // trip 1 on first verify, trip 2 after a completed trip, ...

    String driverId = '—';
    String driverName = '';

    if (isMatched) {
      _state.isUnknownDriver = false;
      _authEngine.setActiveTripEmbedding(null);
      // Extract matched label ("driverId|driverName") from FaceAuthEngine
      final label = _authEngine.lastMatchedLabel;

      if (label != null && label.isNotEmpty) {
        if (label.contains('|')) {
          final parts = label.split('|');
          driverId = parts.isNotEmpty ? parts[0] : '—';
          driverName = parts.length > 1 ? parts.sublist(1).join('|') : '';
        } else {
          driverId = label;
        }
      }

      // Immediately resolve actual driver name from local cache prior to any UI render
      final cachedDriver = _driversService.getDriverById(driverId);
      if (cachedDriver != null && cachedDriver.isNotEmpty) {
        final rawCachedName =
            cachedDriver['fullName'] ??
                cachedDriver['name'] ??
                cachedDriver['driverName'] ??
                cachedDriver['nameEn'];
        if (rawCachedName != null &&
            rawCachedName.toString().trim().isNotEmpty) {
          driverName = rawCachedName.toString().trim();
        }
      }

      _driverId = driverId;
      _driverName = driverName;

      try {
        // Fetch live API data for the licence check.
        Map<String, dynamic>? driver;
        final deviceId = _settings.getDeviceId();
        if (deviceId != null && deviceId.isNotEmpty) {
          final liveDrivers = await _driversService.fetchDriversFromApiOnly(
            deviceId,
          );
          if (liveDrivers != null) {
            final match = liveDrivers.firstWhere(
                  (d) => d['id']?.toString() == driverId,
              orElse: () => <String, dynamic>{},
            );
            if (match.isNotEmpty) driver = match;
          } else {
            debugPrint(
              '[Flow] API unavailable — licence check skipped, using cache for other fields.',
            );
          }
        }
        // Fall back to cache only for non-licence fields (name, language, vehicleId).
        driver ??= _driversService.getDriverById(driverId);
        if (driver != null && driver.isNotEmpty) {
          debugPrint('[Flow][DriverFields] ALL KEYS: ${driver.keys.toList()}');
          debugPrint('[Flow][DriverFields] ALL VALUES: $driver');

          final rawApiName =
              driver['fullName'] ??
                  driver['name'] ??
                  driver['driverName'] ??
                  driver['nameEn'];
          if (rawApiName != null && rawApiName.toString().trim().isNotEmpty) {
            driverName = rawApiName.toString().trim();
          }
          final assignedVehiclesList =
          driver['assignedVehicles'] as List<dynamic>?;
          if (assignedVehiclesList != null && assignedVehiclesList.isNotEmpty) {
            final firstVehicle =
            assignedVehiclesList.first as Map<String, dynamic>;
            _vehicleId = firstVehicle['vehicleId'] as String?;
            _vehicleRegNo =
            firstVehicle['vehicleRegistrationNumber'] as String?;
            // Parse overspeed threshold from API
            final threshold = firstVehicle['overspeedThreshold'];
            if (threshold != null) {
              _overspeedThreshold = (threshold is num)
                  ? threshold.toDouble()
                  : (double.tryParse(threshold.toString()) ?? 0);
            }
            debugPrint(
              '[Flow] Overspeed threshold set to: $_overspeedThreshold km/h',
            );
          } else {
            _vehicleId = driver['assignedVehicleId'] as String?;
            _vehicleRegNo = driver['vehicleRegistrationNumber'] as String?;
          }

          // Resolve preferred language from API response
          final String? langStr =
          (driver['preferredLanguage'] ??
              driver['alertLanguage'] ??
              driver['language'] ??
              driver['lang'])
          as String?;
          AlertLang preferred = AlertLang.english;
          if (langStr != null) {
            final cleanLang = langStr.toLowerCase().trim();
            if (cleanLang.contains('malayalam') || cleanLang == 'ml') {
              preferred = AlertLang.malayalam;
            } else if (cleanLang.contains('hindi') || cleanLang == 'hi') {
              preferred = AlertLang.hindi;
            } else if (cleanLang.contains('tamil') || cleanLang == 'ta') {
              preferred = AlertLang.tamil;
            } else if (cleanLang.contains('kannada') || cleanLang == 'kn') {
              preferred = AlertLang.kannada;
            }
          }
          debugPrint(
            '[Flow] Setting voice alert language to: $preferred (from API: $langStr)',
          );
          await _tts.setLanguage(preferred);

          // ── Licence expiry check ────────
          final String? licenseNum = driver['licenseNumber'] as String?;
          final String? licenseExpiryStr = driver['licenseExpiry'] as String?;
          if (licenseExpiryStr != null) {
            final expiry = DateTime.tryParse(licenseExpiryStr);
            if (expiry != null) {
              final today = DateTime.now();
              final expiryDate = DateTime(
                expiry.year,
                expiry.month,
                expiry.day,
              );
              final todayDate = DateTime(today.year, today.month, today.day);
              final daysLeft = expiryDate.difference(todayDate).inDays;

              if (daysLeft < 0) {
                _tripNumber--; // undo trip increment — no trip started
                _driverId = driverId;
                _driverName = driverName;
                await _showLicenseExpiredDialog(licenseNum ?? '—', expiry);
                if (!mounted) return;
                _authEngine.clearEnrollment();
                _lastDriversRefreshAt = null;
                setState(() {
                  _phase = Phase.verifying;
                  _state.authStatus = AuthStatus.scanning;
                });
                _refreshDriversOnFaceDetection();
                return;
              } else if (daysLeft <= 10) {
                _driverId = driverId;
                _driverName = driverName;
                await _showLicenseExpiryWarningDialog(
                  licenseNum ?? '—',
                  expiry,
                  daysLeft,
                );
                if (!mounted) return;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[Flow] Error resolving driver vehicle details: $e');
      }

      // Voice alert welcome message for authorized driver
      _tts.speak(AlertMessages.welcome(_tts.currentLang, driverName));
    } else {
      _state.isUnknownDriver = true;
      driverId = '—';
      driverName = 'Unknown Driver';
    }

    _driverId = driverId;
    _driverName = driverName;

    _state.resetCalibration();
    _state.isUnknownDriver = !isMatched;
    _state.authStatus = AuthStatus.authenticated;

    if (isMatched) {
      // Show clean "Identity Verified! Welcome back, <Driver Name>" screen
      // Note: _phase was already set to Phase.details at the top of this function.
      if (mounted) setState(() {});

      // Announce welcome message with driver name
      _tts.speak(AlertMessages.welcome(_tts.currentLang, driverName));

      // Hold on the confirmation screen for 2.5 seconds so driver sees their name & verification success
      await Future.delayed(const Duration(milliseconds: 2500));
      if (!mounted) return;
    }

    // Proceed to Monitoring screen
    _phase = Phase.monitoring;
    _monitoringStartedAt = DateTime.now();
    _sendTripStart();

    _breakAlertTimer?.cancel();
    _breakAlertTimer = Timer.periodic(_kBreakAlertInterval, (_) {
      _triggerBreakAlert();
    });

    if (mounted) {
      setState(() {});
    }
  }

  /// Trip ended and a driver re-appeared — go back to the verify screen so the
  /// new driver is authenticated before the next trip's monitoring begins.
  Future<void> _startReverification() async {
    _tripCompleted = false;
    _unauthorizedStart = null;
    _unauthorizedTripStop = false;
    _tripCompletedAt = null;
    _capturedFace = null;
    _multiFace = 0;
    _noFaceSince = null;
    _state.authStatus = AuthStatus.scanning;
    _state.authDistance = -1.0;
    _state.authenticatedTrackingId = null;
    _authEngine.resetLiveAuthState();
    _authEngine.lastMatchedLabel = null;
    _driverId = '—';
    _driverName = 'Driver';
    _phase = Phase.verifying;
    _faceWasPresentLastFrame = false;
    _lastDriversRefreshAt = null;
    if (mounted) setState(() {});

    try {
      debugPrint('[Flow] Trip completed. Fetching new drivers list...');
      await _fetchAndDownloadDrivers();
      debugPrint('[Flow] Re-enrolling drivers in auth engine...');
      await _authEngine.resetAndReenroll();
    } catch (e) {
      debugPrint('[Flow] Reverification refresh error: $e');
    }
  }

  Future<void> _refreshDriversOnFaceDetection() async {
    _lastDriversRefreshAt = DateTime.now();
    if (!_isOnline) {
      debugPrint('[Flow] Device is offline. Skipping API driver list refresh.');
      if (!_authEngine.isEnrolled) {
        debugPrint(
          '[Flow] Auth engine not enrolled. Initializing from local storage/cache...',
        );
        try {
          setState(() {
            _isRefreshingDrivers = true;
            _state.authStatus = AuthStatus.scanning;
          });
          await _authEngine.initialize();
        } catch (e) {
          debugPrint('[Flow] Error initializing auth engine offline: $e');
        } finally {
          if (mounted) {
            setState(() => _isRefreshingDrivers = false);
          }
        }
      }
      return;
    }

    try {
      setState(() {
        _isRefreshingDrivers = true;
        _state.authStatus = AuthStatus.scanning;
      });
      debugPrint(
        '[Flow] Face detected. Fetching latest drivers list from API...',
      );
      await _fetchAndDownloadDrivers();
      debugPrint('[Flow] Re-enrolling drivers in auth engine...');
      await _authEngine.resetAndReenroll();
    } catch (e) {
      debugPrint('[Flow] Error refreshing drivers on face detection: $e');
    } finally {
      if (mounted) {
        setState(() => _isRefreshingDrivers = false);
      }
    }
  }

  // Future<void> _sendTripStart() async {
  //   try {
  //     final deviceId = _settings.getDeviceId();
  //     if (deviceId == null || deviceId.isEmpty) return;
  //
  //     await _tripService.startTrip(
  //       deviceTabletId: deviceId,
  //       driverId: _driverId == '—' ? null : _driverId,
  //       gpsLatitude: _state.gpsLat,
  //       gpsLongitude: _state.gpsLng,
  //       startedAt: DateTime.now().toUtc(),
  //     );
  //   } catch (e) {
  //     debugPrint('[Flow] Failed to send trip start: $e');
  //   }
  // }

  Future<void> _sendTripStart() async {
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) return;
    try {
      final trip = await _tripService.startTrip(
        deviceTabletId: deviceId,
        driverId: _driverId == '—' ? null : _driverId,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        startedAt: DateTime.now().toUtc(),
        appVersion: _appVersion.replaceFirst('v', ''),
      );

      if (trip != null) {
        // Online success — use response data
        _tripId = trip.id;
        _vehicleId ??= trip.vehicleId;
        if (trip.geofenceCenterLatitude != null &&
            trip.geofenceCenterLongitude != null &&
            trip.geofenceRadiusMeters != null) {
          _boundaryLat = trip.geofenceCenterLatitude;
          _boundaryLng = trip.geofenceCenterLongitude;
          _boundaryRadiusM = trip.geofenceRadiusMeters!.toDouble();
          _geofenceId = trip.geofenceId;
          _vehicleId ??= trip.vehicleId;
          _boundaryViolationReported = false;
          debugPrint(
            '[Boundary] Geofence set: ($_boundaryLat, $_boundaryLng) '
                'r=${_boundaryRadiusM}m id=$_geofenceId',
          );
        } else {
          _boundaryLat = null;
          _boundaryLng = null;
          _boundaryRadiusM = null;
          _geofenceId = null;
          debugPrint('[Boundary] No geofence in trip-start response.');
        }
      } else {
        // API returned null (offline or server error) — queue for retry
        debugPrint('[Flow] Trip start API failed — queuing for offline sync');
        _tripService.queueTripStart(
          deviceTabletId: deviceId,
          driverId: _driverId == '—' ? null : _driverId,
          gpsLatitude: _state.gpsLat,
          gpsLongitude: _state.gpsLng,
          startedAt: DateTime.now().toUtc(),
          appVersion: _appVersion.replaceFirst('v', ''),
        );
      }
    } catch (e) {
      debugPrint(
        '[Flow] Failed to send trip start: $e — queuing for offline sync',
      );
      _tripService.queueTripStart(
        deviceTabletId: deviceId,
        driverId: _driverId == '—' ? null : _driverId,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        startedAt: DateTime.now().toUtc(),
        appVersion: _appVersion.replaceFirst('v', ''),
      );
    }
  }

  // ─────────────────────────────────────────────────────────
  // INCIDENT REPORTING
  // ─────────────────────────────────────────────────────────
  Future<void> _reportIncident(
      String eventType,
      String riskLevel,
      double confidence,
      ) async {
    try {
      final deviceId = _settings.getDeviceId();
      if (deviceId == null || deviceId.isEmpty) return;

      // Ella alert-inum screenshot effect kaanikkuka (this happens every 30s locally).
      _showScreenshotFlash();

      // Trigger high-resolution streaming mode for 15 seconds for evidence capture
      _highResUntil = DateTime.now().add(const Duration(seconds: 15));
      debugPrint(
        '[Stream] Incident triggered! Boosting resolution to 0.7x for 15 seconds.',
      );
      _streamService.sendAlertMessage(eventType);

      // Check severity-based API cooldown
      // Critical: 30s | High: 60s | Medium: 3 min
      final now = DateTime.now();
      final lastApiReport = _settings.getLastApiReportTime(eventType);
      final int apiCooldownSeconds = _getCooldownForLabel(eventType);
      if (lastApiReport != null &&
          now.difference(lastApiReport).inSeconds < apiCooldownSeconds) {
        debugPrint(
          '[Flow] API report throttled for ${apiCooldownSeconds}s: $eventType',
        );
        return;
      }
      _settings.setLastApiReportTime(eventType, now);

      // Save the CURRENT camera frame directly as the incident snapshot.
      // This avoids the race condition where the evidence folder from the
      // isolate hasn't been created yet, causing old/wrong images to upload.
      String snapshotPath = '';
      if (_latestFrameJpeg != null && _state.documentsDirectoryPath != null) {
        try {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filePath =
              '${_state.documentsDirectoryPath}/incident_${eventType}_$timestamp.jpg';
          final file = File(filePath);
          // Stamp CCTV-style timestamp on snapshot
          final stampedBytes = _stampTimestamp(_latestFrameJpeg!, now);
          await file.writeAsBytes(stampedBytes);
          snapshotPath = filePath;
          debugPrint('[Flow] Incident snapshot saved: $filePath');
        } catch (e) {
          debugPrint('[Flow] Failed to save incident snapshot: $e');
          // Fallback to evidence folder if direct save fails.
          snapshotPath = await _findLatestEvidenceFolder() ?? '';
        }
      } else {
        // Fallback to evidence folder if no frame available.
        snapshotPath = await _findLatestEvidenceFolder() ?? '';
      }

      // Generate 3-second incident video if frames are available
      String videoPath = '';
      if (_recentFrames.isNotEmpty && _state.documentsDirectoryPath != null) {
        final vPath = await _generateIncidentVideo(_recentFrames, eventType);
        if (vPath != null) {
          videoPath = vPath;
          debugPrint('[Flow] Incident video generated: $videoPath');
        }
      }

      // Allow incidents to be recorded during active monitoring.
      if (_phase != Phase.monitoring && eventType != 'Unverified Driver') {
        debugPrint(
          '[Flow] Skipping incident "$eventType" — driver not verified (phase=$_phase, id=$_driverId).',
        );
        return;
      }

      // Never skip Driver Changed incident even if snapshot image path is missing
      if (snapshotPath.isEmpty && eventType != 'Driver Changed') {
        debugPrint(
          '[Flow] Skipping incident "$eventType" — no valid snapshot available.',
        );
        return;
      }

      final String? effectiveDriverId =
      (_state.authStatus == AuthStatus.unauthorized ||
          _driverId == '—' ||
          _driverId.isEmpty ||
          _state.isUnknownDriver)
          ? null
          : _driverId;
      final effectiveDriverName =
      (_state.authStatus == AuthStatus.unauthorized ||
          _driverName == 'Driver' ||
          _driverName == 'Unknown Person' ||
          _driverName == 'Unknown Driver' ||
          _driverName.isEmpty ||
          _state.isUnknownDriver)
          ? 'Unknown Driver'
          : _driverName;

      _incidentsService.queueIncident(
        deviceTabletId: deviceId,
        eventType: eventType,
        riskLevel: riskLevel,
        aiConfidence: confidence,
        vehicleSpeed: _state.vehicleSpeed,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        driverId: effectiveDriverId,
        driverName: effectiveDriverName,
        vehicleId: _vehicleId,
        vehicleRegistrationNumber: _vehicleRegNo,
        snapshotUrl: '',
        snapshotPath: snapshotPath,
        videoClipUrl: '',
        videoPath: videoPath,
        isOnline: _isOnline,
      );

      // Upload evidence and sync incident sequentially (not in parallel)
      // This prevents race conditions where evidence URLs get swapped
      if (_isOnline) {
        // Small delay to ensure file writes are flushed
        await Future.delayed(const Duration(milliseconds: 100));
        await _syncIncidentsTask();
      }
    } catch (e) {
      debugPrint('[Flow] Error queueing incident: $e');
    }
  }

  Future<void> _sendTripEnd() async {
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) return;

    // Always queue first — guarantees trip end is never lost even if offline
    _tripService.queueTripEnd(
      deviceTabletId: deviceId,
      gpsLatitude: _state.gpsLat,
      gpsLongitude: _state.gpsLng,
      distanceKm: 0,
      endedAt: DateTime.now().toUtc(),
    );
    _tripId = null;

    // Attempt immediate sync if online
    if (_isOnline) {
      await _tripService.syncPendingTrips();
    } else {
      debugPrint(
        '[Flow] Trip end queued — device offline, will sync when back online',
      );
    }
  }

  Future<String?> _generateIncidentVideo(
      List<Uint8List> frames,
      String eventType,
      ) async {
    if (frames.isEmpty || _state.documentsDirectoryPath == null) return null;
    try {
      final docsDir = _state.documentsDirectoryPath!;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempDir = Directory('$docsDir/temp_vid_$timestamp');
      await tempDir.create();

      // Write frames to disk with CCTV timestamp overlay
      final videoTime = DateTime.now();
      for (int i = 0; i < frames.length; i++) {
        final file = File(
          '${tempDir.path}/img${i.toString().padLeft(3, '0')}.jpg',
        );
        final stampedFrame = _stampTimestamp(frames[i], videoTime);
        await file.writeAsBytes(stampedFrame);
      }

      final outputPath = '$docsDir/incident_video_${eventType}_$timestamp.mp4';
      // FFmpeg: framerate 3, 15 frames = 5 seconds
      // -c:v libx264 -pix_fmt yuv420p for wide compatibility
      final command =
          '-y -framerate 3 -i "${tempDir.path}/img%03d.jpg" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      // Clean up temp dir
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}

      if (ReturnCode.isSuccess(returnCode)) {
        return outputPath;
      }
    } catch (e) {
      debugPrint('[Flow] Error generating incident video: $e');
    }
    return null;
  }

  Future<String?> _findLatestEvidenceFolder() async {
    try {
      final docsPath = _state.documentsDirectoryPath;
      if (docsPath == null || docsPath.isEmpty) return null;
      final dir = Directory(docsPath);
      if (!dir.existsSync()) return null;

      final folders = dir
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('SafeDrive_Evidence_'))
          .toList();
      if (folders.isEmpty) return null;

      folders.sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      final latest = folders.first.path;
      debugPrint('[Flow] Latest evidence folder for incident: $latest');
      return latest;
    } catch (e) {
      debugPrint('[Flow] find evidence folder error: $e');
      return null;
    }
  }

  /// Alert varumbol normal screenshot effect (quick shrink + border + dim).
  void _showScreenshotFlash() {
    if (!mounted) return;
    // 2 second cooldown — alerts vegathil varumbol flash spam ozhivakkan.
    final now = DateTime.now();
    if (_lastFlashAt != null &&
        now.difference(_lastFlashAt!).inMilliseconds < 2000) {
      return;
    }
    _lastFlashAt = now;

    setState(() => _flashScreenshot = true);
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _flashScreenshot = false);
    });
  }

  // ─────────────────────────────────────────────────────────
  // BREAK ALERT
  // ─────────────────────────────────────────────────────────

  void _triggerBreakAlert() {
    if (!mounted) return;
    if (_phase != Phase.monitoring) {
      debugPrint('[BreakAlert] SKIP: not monitoring');
      return;
    }
    if (_tripCompleted) {
      debugPrint('[BreakAlert] SKIP: trip completed');
      return;
    }
    if (_getMonitorBannerKey(_state.hasPhone, _state.hasCigarette) != null) {
      debugPrint(
        '[BreakAlert] SKIP: active banner (${_getMonitorBannerKey(_state.hasPhone, _state.hasCigarette)})',
      );
      return;
    }
    if (!_state.seatbeltBuckled && _activeBannerKey != null) {
      debugPrint('[BreakAlert] SKIP: seatbelt banner');
      return;
    }
    if (_state.drowsinessLevel == DrowsinessLevel.drowsy ||
        _state.drowsinessLevel == DrowsinessLevel.asleep) {
      debugPrint('[BreakAlert] SKIP: drowsy/asleep');
      return;
    }
    if (_state.distractionStatus == DistractionStatus.distracted) {
      debugPrint('[BreakAlert] SKIP: distracted');
      return;
    }
    // if (_state.vehicleSpeed > _kSpeedLimitKmh) {
    //   debugPrint('[BreakAlert] SKIP: overspeed');
    //   return;
    // }
    if (_state.authStatus == AuthStatus.unauthorized) {
      debugPrint('[BreakAlert] SKIP: unauthorized');
      return;
    }
    if (_camDetectionAlert != null &&
        _camDetectionAlertAt != null &&
        DateTime.now().difference(_camDetectionAlertAt!).inSeconds < 3) {
      debugPrint('[BreakAlert] SKIP: cam detection alert');
      return;
    }

    debugPrint('[BreakAlert] ✓ SHOWING alert index=$_breakAlertIndex');

    setState(() => _showBreakAlert = true);
    _currentBreakMsg =
    _kBreakMessages[_breakAlertIndex % _kBreakMessages.length];
    // Speak in the driver's preferred language.
    _tts.speak(AlertMessages.breakReminder(_tts.currentLang, _breakAlertIndex));
    _breakAlertIndex++;
    _breakAlertDismissTimer?.cancel();
    _breakAlertDismissTimer = Timer(_kBreakAlertDisplayDuration, () {
      if (mounted) setState(() => _showBreakAlert = false);
    });
  }

  void _dismissBreakAlert() {
    _breakAlertDismissTimer?.cancel();
    if (mounted) setState(() => _showBreakAlert = false);
  }

  /// Bottom-center break alert toast — no container, just emoji + text with glance pulse.
  Widget _breakAlertOverlay() {
    // Guard: never render outside the active monitoring phase.
    // The overlay sits in the root Stack so without this it can bleed over
    // the verifying / details / trip-completed screens on slower devices.
    if (_phase != Phase.monitoring ||
        _tripCompleted ||
        _camMode != CamMode.driverMonitoring) {
      if (_showBreakAlert) {
        WidgetsBinding.instance.addPostFrameCallback(
              (_) => _dismissBreakAlert(),
        );
      }
      return const SizedBox.shrink();
    }
    // Auto-dismiss if any real alert becomes active while toast is showing.
    if (_showBreakAlert) {
      final anyAlertActive =
          _getMonitorBannerKey(_state.hasPhone, _state.hasCigarette) != null ||
              !_state.seatbeltBuckled ||
              _state.drowsinessLevel == DrowsinessLevel.drowsy ||
              _state.drowsinessLevel == DrowsinessLevel.asleep ||
              _state.distractionStatus == DistractionStatus.distracted ||
              // _state.vehicleSpeed > _kSpeedLimitKmh ||
              _state.authStatus == AuthStatus.unauthorized;
      if (anyAlertActive) {
        WidgetsBinding.instance.addPostFrameCallback(
              (_) => _dismissBreakAlert(),
        );
        return const SizedBox.shrink();
      }
    }
    if (!_showBreakAlert) return const SizedBox.shrink();
    final msg = _currentBreakMsg ?? _kBreakMessages[0];
    return Positioned(
      bottom: 56,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: _dismissBreakAlert,
        behavior: HitTestBehavior.translucent,
        child: _BreakToastWidget(msg: msg),
      ),
    );
  }

  Future<void> _syncIncidentsTask() async {
    if (!mounted) return;
    if (!_isOnline) {
      debugPrint('[Flow] Skipping incident sync because device is OFFLINE.');
      return;
    }
    debugPrint(
      '[Flow] Triggering sync of pending incidents (connection: ONLINE)...',
    );
    await _incidentsService.syncPendingIncidents();
  }

  void _syncTripsTask() {
    if (!_isOnline || _tripService.pendingCount == 0) return;
    debugPrint(
      '[Flow] Syncing ${_tripService.pendingCount} pending trip event(s)...',
    );
    _tripService.syncPendingTrips();
  }

  Future<void> _sendTelemetryTask() async {
    if (!mounted) return;
    // _state.vehicleSpeed = 10; // TODO: Remove after testing unverified driver

    // Boundary check runs every tick, even offline — it detects the crossing.
    _checkBoundary();

    // ── Unverified driver moving detection ──────────────────────
    // If face not verified and vehicle is moving, report incident
    // Only when verifying screen is active (not during system initialization)
    // Wait for camera to have captured a frame (snapshot available)
    // Require consecutive high-speed readings to avoid GPS drift false triggers
    if (_phase == Phase.verifying &&
        !_initializing &&
        _camReady &&
        _latestFrameJpeg != null &&
        _state.vehicleSpeed > 25) {
      _consecutiveHighSpeedCount++;
      if (_consecutiveHighSpeedCount >= _kHighSpeedConsecutiveRequired) {
        if (_checkCooldown('Unverified Driver')) {
          _reportIncident('Unverified Driver', 'High', 1.0);
          _tts.speak(AlertMessages.unverifiedDriver(_tts.currentLang));
          debugPrint(
            '[Flow] Vehicle moving at ${_state.vehicleSpeed.toStringAsFixed(1)} km/h without driver verification! (consecutive: $_consecutiveHighSpeedCount)',
          );
        }
      }
    } else {
      _consecutiveHighSpeedCount = 0;
    }

    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }
    // Only attempt to send telemetry if online
    if (!_isOnline) {
      debugPrint('[Telemetry] Skipping location telemetry (Device is offline)');
      return;
    }

    // Send telemetry (queues locally if offline)
    await _telemetryService.sendLocationTelemetry(
      deviceTabletId: deviceId,
      latitude: _state.gpsLat,
      longitude: _state.gpsLng,
      speed: _state.vehicleSpeed,
      isOnline: _isOnline,
    );

    // Sync queued telemetry when back online
    if (_isOnline && _telemetryService.pendingCount > 0) {
      _telemetryService.syncPendingTelemetry();
    }
  }

  // ─────────────────────────────────────────────────────────
  // ALERT AUDIO & INCIDENTS
  // ─────────────────────────────────────────────────────────

  // ── Severity-based cooldowns ──
  // Critical: 30s | High: 60s | Medium: 180s
  static const Map<String, int> _kIncidentCooldownSeconds = {
    // Critical (every 30 seconds)
    'Drowsiness': 30, // asleep/drowsy both use this key
    // 'Medical Emergency': 30,
    // High (every 1 minute)
    'Distraction': 60,
    // 'Unauthorized Driver': 60,
    'Unverified Driver': 60,
    'Overspeeding': 60,
    // Medium (every 3 minutes)
    'seatbelt': 180,
    'Phone Usage': 180,
    'Smoking': 180,
    'Eating': 180,
    'Drinking': 180,
    // 'Cable Unplugged': 180,
  };

  // Voice alert intervals match severity
  static const Map<String, int> _kVoiceCooldownSeconds = {
    // Critical
    'asleep': 5,
    'drowsy': 10,
    // High
    'distracted': 30,
    // 'unauthorized': 30,
    'overspeed': 15,
    'phone': 30,
    'smoke': 30,
    // Medium
    'seatbelt': 60,
    'eating': 60,
    'drinking': 60,
  };

  int _getCooldownForLabel(String label) {
    return _apiCooldownSeconds[label] ?? _kIncidentCooldownSeconds[label] ?? 60;
    // return _kIncidentCooldownSeconds[label] ?? 60; // default 60s
  }

  bool _checkCooldown(String label) {
    final now = DateTime.now();
    final lastTime = _lastIncidentReportAt[label];
    final int cooldownDuration = _getCooldownForLabel(label);

    if (lastTime == null) {
      _lastIncidentReportAt[label] = now;
      debugPrint(
        '[IncidentCooldown] $label first trigger. Reporting allowed. (cooldown: ${cooldownDuration}s)',
      );
      return true;
    }

    final elapsed = now.difference(lastTime).inSeconds;
    if (elapsed >= cooldownDuration) {
      _lastIncidentReportAt[label] = now;
      debugPrint(
        '[IncidentCooldown] Cooldown expired for $label ($elapsed s elapsed, limit: ${cooldownDuration}s). Reporting allowed.',
      );
      return true;
    }

    final remainingSeconds = cooldownDuration - elapsed;
    final remainingMinutes = (remainingSeconds / 60).floor();
    final remSecs = remainingSeconds % 60;

    // Throttle logs to once every 10 seconds to avoid spamming the console
    final lastLogTime = _lastCooldownLogAt[label];
    if (lastLogTime == null || now.difference(lastLogTime).inSeconds >= 10) {
      _lastCooldownLogAt[label] = now;
      final String timeStr = remainingMinutes > 0
          ? '$remainingMinutes min $remSecs sec'
          : '$remainingSeconds sec';
      debugPrint(
        '[IncidentCooldown] $label API report blocked (Cooldown active). '
            'Remaining time: $timeStr ($elapsed s elapsed since last report).',
      );
    }
    return false;
  }

  bool _checkVoiceCooldown(String label, Duration duration) {
    final now = DateTime.now();
    final lastTime = _lastVoiceAlertAt[label];
    if (lastTime == null || now.difference(lastTime) >= duration) {
      _lastVoiceAlertAt[label] = now;
      return true;
    }
    return false;
  }

  Future<void> _handleAlertSounds(CameraImage? currentImage) async {
    final now = DateTime.now();
    final phone = _state.hasPhone;
    final smoke = _state.hasCigarette;

    bool loud = false;
    bool soft = false;

    // ── DRIVER CHANGED ALERT ─────────────────────────────────────────
    if (_state.authStatus == AuthStatus.unauthorized &&
        _phase == Phase.monitoring &&
        !_tripCompleted) {
      if (_isDriverChangedActive()) {
        if (currentImage != null) {
          final jpeg = _captureFaceJpeg(currentImage, targetWidth: 240);
          if (jpeg != null) {
            _latestFrameJpeg = jpeg;
          }
        }

        // Report driver changed incident to API immediately upon detection
        _reportIncident('Driver Changed', 'High', 1.0);
        _tts.speak(AlertMessages.unauthorized(_tts.currentLang));
        _playAlert('audio/alert_loud.mp3');

        // Start 5-minute (300s) cooldown after reporting
        _lastDriverChangedReportAt = now;
        _unauthorizedStart = null;
      }
    } else {
      _unauthorizedStart = null;
      if (_state.authStatus == AuthStatus.authenticated) {
        _lastDriverChangedReportAt = null;
      }
    }

    // ── SEATBELT CYCLIC ALERT ──────────────────────────────────────
    // Grace period: skip seatbelt alert for first 10 seconds after trip start
    final bool seatbeltGraceActive =
        _monitoringStartedAt != null &&
            now.difference(_monitoringStartedAt!).inSeconds <
                _kSeatbeltGraceSeconds;
    if (!_state.seatbeltBuckled &&
        _phase == Phase.monitoring &&
        !_tripCompleted &&
        !seatbeltGraceActive) {
      // Start cycle if not already started
      if (_seatbeltAlertStart == null) {
        _seatbeltAlertStart = now;
        _seatbeltPhaseStart = now;
        _seatbeltInBeepPhase = true;
      }

      // Determine current phase
      final phaseElapsed = now.difference(_seatbeltPhaseStart!).inSeconds;
      if (_seatbeltInBeepPhase && phaseElapsed >= _kSeatbeltBeepDuration) {
        // Switch to silence phase
        _seatbeltInBeepPhase = false;
        _seatbeltPhaseStart = now;
      } else if (!_seatbeltInBeepPhase &&
          phaseElapsed >= _kSeatbeltSilenceDuration) {
        // Switch back to beep phase
        _seatbeltInBeepPhase = true;
        _seatbeltPhaseStart = now;
      }

      // Play beep during beep phase (uses global 3s cooldown below)
      if (_seatbeltInBeepPhase) {
        soft = true;
      }

      // Report incident with Medium severity
      if (_checkCooldown('seatbelt')) {
        _reportIncident('Seatbelt Not Worn', 'Medium', 1.0);
      }

      // Speak warning once immediately, then once every 1 minute if still unbuckled
      if (_checkVoiceCooldown('seatbelt', const Duration(minutes: 1))) {
        _tts.speak(AlertMessages.seatbelt(_tts.currentLang));
      }
    } else {
      // Seatbelt is buckled — reset cycle
      _seatbeltAlertStart = null;
      _seatbeltPhaseStart = null;
      _seatbeltInBeepPhase = true;
      _lastVoiceAlertAt.remove('seatbelt');
    }
    if (_state.drowsinessLevel == DrowsinessLevel.asleep) {
      loud = true;

      // Use 'Drowsiness' for both asleep and drowsy so they share the cooldown
      if (_checkCooldown('Drowsiness')) {
        _reportIncident('Drowsiness', 'Critical', 1.0);
      }
    } else if (_state.drowsinessLevel == DrowsinessLevel.drowsy) {
      soft = true;

      if (_checkCooldown('Drowsiness')) {
        _reportIncident('Drowsiness', 'Critical', 0.8);
      }
    }
    if (_state.distractionStatus == DistractionStatus.distracted) {
      soft = true;
      if (_checkCooldown('Distraction')) {
        _reportIncident('Distraction', 'High', 0.8);
      }
    }

    // ── OVERSPEED ALERT ──────────────────────────────────────
    if (_overspeedThreshold > 0 && _state.vehicleSpeed > _overspeedThreshold) {
      loud = true;
      if (_checkCooldown('Overspeeding')) {
        _reportIncident('Overspeeding', 'High', 1.0);
      }
      if (_checkVoiceCooldown('overspeed', const Duration(seconds: 15))) {
        _tts.speak(AlertMessages.overspeed(_tts.currentLang));
      }
    }

    // 2. Object detections (phone, cigarette, eating, drinking)
    const reportThresholds = {
      'phone': 0.5,
      'cigarette': 0.5,
      'eating': 0.5,
      'drinking': 0.5,
    };

    for (final obj in _state.detectedObjects) {
      final label = obj.label;
      final threshold = reportThresholds[label];
      if (threshold == null || obj.confidence <= threshold) continue;
      if (label == 'seatbelt') continue;
      loud = true;

      String eventType = label;
      if (label == 'phone') eventType = 'Phone Usage';
      if (label == 'cigarette') eventType = 'Smoking';
      if (label == 'eating') eventType = 'Eating';
      if (label == 'drinking') eventType = 'Drinking';

      // Severity: Phone/Smoking/Eating/Drinking = Medium
      if (_checkCooldown(eventType)) {
        _reportIncident(eventType, 'Medium', obj.confidence);
      }
    }

    final currentBannerKey = _getMonitorBannerKey(phone, smoke);
    if (currentBannerKey != null) {
      if (currentBannerKey != _activeBannerKey || _activeBannerAt == null) {
        _activeBannerKey = currentBannerKey;
        _activeBannerAt = now;
      }
    } else {
      _activeBannerKey = null;
      _activeBannerAt = null;
    }

    // --- Unified TTS Logic based on Banner Priority ---
    if (currentBannerKey != null && currentBannerKey != 'harsh') {
      final int cooldownSeconds =
          _kVoiceCooldownSeconds[currentBannerKey] ?? 30;

      if (_checkVoiceCooldown(
        currentBannerKey,
        Duration(seconds: cooldownSeconds),
      )) {
        String voice = '';
        if (currentBannerKey == 'phone') {
          voice = AlertMessages.phone(_tts.currentLang);
        } else if (currentBannerKey == 'smoke') {
          voice = AlertMessages.cigarette(_tts.currentLang);
        } else if (currentBannerKey == 'eating') {
          voice = AlertMessages.eating(_tts.currentLang);
        } else if (currentBannerKey == 'drinking') {
          voice = AlertMessages.drinking(_tts.currentLang);
        } else if (currentBannerKey == 'multiple' ||
            currentBannerKey == 'distracted') {
          voice = AlertMessages.distraction(_tts.currentLang);
        } else if (currentBannerKey == 'asleep' ||
            currentBannerKey == 'drowsy') {
          voice = AlertMessages.drowsy(_tts.currentLang);
        } else if (currentBannerKey == 'unauthorized') {
          voice = AlertMessages.unauthorized(_tts.currentLang);
        }

        if (voice.isNotEmpty) {
          _tts.speak(voice);
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

  /// Called by front/rear cam overlay when YOLO detects objects.
  /// Shows an on-screen alert banner + plays sound. Does NOT report to API.
  void _onCamObjectDetected(List<dynamic> detections) {
    if (detections.isEmpty) return;
    final now = DateTime.now();

    // Build alert text from detected labels
    final labels = detections.map((d) => d.label as String).toSet();
    final alertText = labels.map((l) => l.toUpperCase()).join(', ');

    // Update banner
    _camDetectionAlert = '⚠️  $alertText DETECTED';
    _camDetectionAlertAt = now;
    if (mounted) setState(() {});

    // Play sound with 3-second cooldown
    if (_lastCamAlertSoundAt == null ||
        now.difference(_lastCamAlertSoundAt!).inMilliseconds >= 3000) {
      _lastCamAlertSoundAt = now;
      _playAlert('audio/alert_loud.mp3');

      // TTS for detected objects in driver's language
      if (labels.contains('person')) {
        _tts.speak(AlertMessages.personDetected(_tts.currentLang));
      } else if (labels.contains('vehicle')) {
        _tts.speak(AlertMessages.vehicleDetected(_tts.currentLang));
      } else if (labels.contains('motorcycle')) {
        _tts.speak(AlertMessages.motorcycleDetected(_tts.currentLang));
      } else if (labels.contains('bus')) {
        _tts.speak(AlertMessages.busDetected(_tts.currentLang));
      } else if (labels.contains('truck')) {
        _tts.speak(AlertMessages.truckDetected(_tts.currentLang));
      } else if (labels.contains('bicycle')) {
        _tts.speak(AlertMessages.bicycleDetected(_tts.currentLang));
      } else if (labels.contains('car')) {
        _tts.speak(AlertMessages.vehicleDetected(_tts.currentLang));
      }
    }
  }

  /// Overlays a CCTV-style timestamp at the bottom of a JPEG image.
  Uint8List _stampTimestamp(Uint8List jpegBytes, DateTime time) {
    try {
      final decoded = img.decodeJpg(jpegBytes);
      if (decoded == null) return jpegBytes;

      final hour12 = time.hour == 0
          ? 12
          : (time.hour > 12 ? time.hour - 12 : time.hour);
      final amPm = time.hour >= 12 ? 'PM' : 'AM';
      final timeStr =
          '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')}/${time.year} '
          '${hour12.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} $amPm';

      // Draw a semi-transparent black bar at the bottom
      final barHeight = 20;
      final yStart = decoded.height - barHeight;
      for (int y = yStart; y < decoded.height; y++) {
        for (int x = 0; x < decoded.width; x++) {
          final pixel = decoded.getPixel(x, y);
          final r = (pixel.r * 0.4).toInt();
          final g = (pixel.g * 0.4).toInt();
          final b = (pixel.b * 0.4).toInt();
          decoded.setPixelRgb(x, y, r, g, b);
        }
      }

      // Draw timestamp text on the bar
      img.drawString(
        decoded,
        timeStr,
        font: img.arial14,
        x: 4,
        y: yStart + 3,
        color: img.ColorRgba8(255, 255, 255, 255),
      );

      return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
    } catch (e) {
      debugPrint('[Flow] Timestamp stamp error: $e');
      return jpegBytes;
    }
  }

  /// Converts the current YUV camera frame to an upright (mirrored for the
  /// front camera) JPEG — used as the captured still on the verified screen.
  Uint8List? _captureFaceJpeg(CameraImage image, {int targetWidth = 360}) {
    try {
      if (image.planes.length < 3) return null;
      final int srcW = image.width;
      final int srcH = image.height;

      // Determine downscaling factor
      final double scale = srcW > targetWidth ? targetWidth / srcW : 1.0;
      final int w = (srcW * scale).toInt();
      final int h = (srcH * scale).toInt();

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
        final int sy = (y / scale).toInt().clamp(0, srcH - 1);
        for (int x = 0; x < w; x++) {
          final int sx = (x / scale).toInt().clamp(0, srcW - 1);

          final int yi = sy * yRow + sx;
          final int uvi = (sy >> 1) * uvRow + (sx >> 1) * uvPix;
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

      return Uint8List.fromList(img.encodeJpg(fixed, quality: 80));
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
      // Only restart the phone cam if we're in driver monitoring mode.
      if (!_streaming && _camReady && _camMode == CamMode.driverMonitoring) {
        c.startImageStream(_processImage);
        _streaming = true;
      }
      // Verify WebSocket is still alive — Doze mode can silently kill it.
      _streamService.onAppResumed();
    }
  }

  // ─────────────────────────────────────────────────────────
  // HIDDEN ADMIN EXIT (top-right corner double-tapped -> PIN)
  // ─────────────────────────────────────────────────────────
  void _onCornerTap() {
    final now = DateTime.now();
    if (_firstExitTapAt == null ||
        now.difference(_firstExitTapAt!).inMilliseconds > 2000) {
      _firstExitTapAt = now;
      _exitTaps = 1;
    } else {
      _exitTaps++;
    }
    if (_exitTaps >= 2) {
      _exitTaps = 0;
      _firstExitTapAt = null;
      _showExitPinDialog();
    }
  }

  // ─────────────────────────────────────────────────────────
  // LICENSE EXPIRY DIALOGS
  // ─────────────────────────────────────────────────────────

  String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  Future<void> _showLicenseExpiredDialog(
      String licenseNumber,
      DateTime expiry,
      ) async {
    if (!mounted) return;
    bool _ttsStarted = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialogState) {
          if (!_ttsStarted) {
            _ttsStarted = true;
            // Speak in driver's preferred language; dismiss when TTS finishes.
            // A 3-second minimum ensures the dialog is readable even for short phrases.
            Future.wait([
              _tts.speakImmediately(
                AlertMessages.licenseExpired(_tts.currentLang),
              ),
              Future.delayed(const Duration(seconds: 3)),
            ]).then((_) {
              if (mounted) Navigator.of(context, rootNavigator: true).pop();
            });
          }

          return Dialog(
            backgroundColor: const Color(0xFF1C1F2E),
            surfaceTintColor: Colors.transparent,
            elevation: 24,
            shadowColor: Colors.black54,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 52,
              vertical: 40,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF252839),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFF5C5C).withOpacity(0.15),
                      border: Border.all(
                        color: const Color(0xFFFF5C5C).withOpacity(0.35),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFFF5C5C),
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'License Expired!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This driver\'s license has expired.\nTrip cannot be started.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFABB4C8),
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      height: 1.6,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.badge_outlined,
                              size: 14,
                              color: Color(0xFFFF5C5C),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'License No: $licenseNumber',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFFF5C5C),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_outlined,
                              size: 14,
                              color: Color(0xFFABB4C8),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Expired: ${_formatDate(expiry)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFABB4C8),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Please wait...',
                    style: TextStyle(
                      color: Color(0xFFABB4C8),
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showLicenseExpiryWarningDialog(
      String licenseNumber,
      DateTime expiry,
      int daysLeft,
      ) async {
    if (!mounted) return;
    bool _ttsStarted = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialogState) {
          if (!_ttsStarted) {
            _ttsStarted = true;
            // Speak in driver's preferred language; dismiss when TTS finishes.
            // A 3-second minimum ensures the dialog is readable even for short phrases.
            Future.wait([
              _tts.speakImmediately(
                AlertMessages.licenseExpiringSoon(_tts.currentLang, daysLeft),
              ),
              Future.delayed(const Duration(seconds: 3)),
            ]).then((_) {
              if (mounted) Navigator.of(context, rootNavigator: true).pop();
            });
          }

          return Dialog(
            backgroundColor: const Color(0xFF1C1F2E),
            surfaceTintColor: Colors.transparent,
            elevation: 24,
            shadowColor: Colors.black54,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 52,
              vertical: 40,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF252839),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFBBF24).withOpacity(0.15),
                      border: Border.all(
                        color: const Color(0xFFFBBF24).withOpacity(0.35),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Color(0xFFFBBF24),
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'License Expiring Soon!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    daysLeft == 0
                        ? 'License expires today! Please renew immediately.'
                        : 'License expires in $daysLeft day${daysLeft == 1 ? '' : 's'}. Please renew soon.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFABB4C8),
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      height: 1.6,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.badge_outlined,
                              size: 14,
                              color: Color(0xFFFBBF24),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'License No: $licenseNumber',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFFBBF24),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_outlined,
                              size: 14,
                              color: Color(0xFFABB4C8),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Expires: ${_formatDate(expiry)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFABB4C8),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Please wait...',
                    style: TextStyle(
                      color: Color(0xFFABB4C8),
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showExitPinDialog() {
    final controller = TextEditingController();
    String? errorMessage;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void verifyAndSubmit(String pin) {
              if (pin == kAdminPin) {
                Navigator.pop(ctx);
                Kiosk.stop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Admin exit successful. Kiosk mode disabled.',
                      ),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } else if (pin == '0000') {
                Navigator.pop(ctx);
                _openEspScannerScreen();
              } else if (pin == '1111') {
                Navigator.pop(ctx);
                _openTtsInstall();
              } else {
                setDialogState(() {
                  errorMessage = 'Incorrect 4-digit PIN';
                });
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Row(
                children: [
                  Icon(Icons.admin_panel_settings, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Text('Admin Exit'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter 4-digit admin PIN:',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    autofocus: true,
                    maxLength: 4,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      letterSpacing: 8,
                      fontWeight: FontWeight.bold,
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      hintText: '••••',
                      counterText: '',
                      errorText: errorMessage,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      if (errorMessage != null) {
                        setDialogState(() {
                          errorMessage = null;
                        });
                      }
                      if (val.length == 4) {
                        verifyAndSubmit(val);
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => verifyAndSubmit(controller.text),
                  child: const Text('Exit'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openTtsInstall() async {
    try {
      const intent = AndroidIntent(
        action: 'android.speech.tts.engine.INSTALL_TTS_DATA',
      );
      await intent.launch();
    } catch (e) {
      debugPrint('[TTS] Install intent failed: $e');
    }
  }

  void _openEspScannerScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _EspScannerScreen(
          onDeviceAssigned: (String ip, String slot) {
            setState(() {
              switch (slot) {
                case 'Left':
                  _leftCamIp = ip;
                  break;
                case 'Right':
                  _rightCamIp = ip;
                  break;
                case 'Front':
                  _frontCamIp = ip;
                  break;
                case 'Rear':
                  _esp32StreamUrl = 'http://$ip:82/';
                  break;
              }
            });
            debugPrint('[EspScanner] Assigned $ip to $slot');
            _checkCamConnections();
          },
        ),
      ),
    );
  }

  void _checkBoundary() {
    if (_boundaryLat == null ||
        _boundaryLng == null ||
        _boundaryRadiusM == null) {
      return; // no geofence for this trip
    }

    final distance = Geolocator.distanceBetween(
      _boundaryLat!,
      _boundaryLng!,
      _state.gpsLat,
      _state.gpsLng,
    );

    final outside = distance > _boundaryRadiusM!;

    //final outside = distance > 5;

    // Log every check, regardless of in/out state.
    debugPrint(
      '[Boundary] distance=${distance.toStringAsFixed(1)} m | '
          'limit=${_boundaryRadiusM!.toStringAsFixed(0)} m | '
          '${outside ? "OUTSIDE" : "inside"}',
    );

    if (outside) {
      final beyond = distance - _boundaryRadiusM!; // meters past the boundary

      // Update the on-screen banner (only rebuild when something changed).
      if (!_outsideBoundary || (beyond - _boundaryBeyondM).abs() > 1) {
        if (mounted) {
          setState(() {
            _outsideBoundary = true;
            _boundaryBeyondM = beyond;
          });
        }
      }

      // Report to server only once per exit.
      if (!_boundaryViolationReported) {
        _boundaryViolationReported = true;
        debugPrint(
          '[Boundary] VIOLATION — ${distance.toStringAsFixed(1)} m '
              'from center, ${beyond.toStringAsFixed(1)} m beyond limit.',
        );
        _reportBoundaryViolation(beyond);
        _tts.speak(AlertMessages.boundaryViolation(_tts.currentLang));
      }
    } else {
      // Back inside — clear banner and re-arm.
      if (_outsideBoundary && mounted) {
        setState(() {
          _outsideBoundary = false;
          _boundaryBeyondM = 0;
        });
      }
      if (_boundaryViolationReported) {
        _boundaryViolationReported = false; // re-arm for next exit
        debugPrint('[Boundary] Back inside boundary.');
      }
    }
  }

  // void _startHarshDetection() {
  //   _accelSub =
  //       userAccelerometerEventStream(
  //         samplingPeriod:
  //             SensorInterval.gameInterval, // ~20ms, responsive but not extreme
  //       ).listen(
  //         _onAccelerometer,
  //         onError: (e) {
  //           debugPrint('[Harsh] accelerometer error: $e');
  //         },
  //       );
  // }

  // void _onAccelerometer(UserAccelerometerEvent event) {
  //   final now = DateTime.now();

  //   // Only monitor while actually driving-monitoring, not during verify/details.
  //   if (_phase != Phase.monitoring || _tripCompleted) return;

  //   final speedKmh = _state.vehicleSpeed;
  //   final speedMs = speedKmh / 3.6;

  //   // Keep a rolling ~2.5s speed history (sampled here, throttled to 250ms).
  //   if (_speedHistory.isEmpty ||
  //       now.difference(_speedHistory.last.key).inMilliseconds >= 250) {
  //     _speedHistory.add(MapEntry(now, speedMs));
  //     _speedHistory.removeWhere(
  //       (e) => now.difference(e.key) > const Duration(milliseconds: 2500),
  //     );
  //   }

  //   // 1) Magnitude — orientation-independent total force.
  //   final magnitude = sqrt(
  //     event.x * event.x + event.y * event.y + event.z * event.z,
  //   );
  //   if (magnitude < _kHarshMagnitude) return;

  //   // 2) Guards: minimum speed + local debounce.
  //   if (speedKmh < _kMinHarshSpeedKmh) return;
  //   if (_lastHarshAt != null &&
  //       now.difference(_lastHarshAt!) < _kHarshDebounce) {
  //     return;
  //   }

  //   // 3) Classify using GPS speed change over the last ~1–2s.
  //   final past = _speedHistory.firstWhere(
  //     (e) => now.difference(e.key).inMilliseconds >= 800,
  //     orElse: () => _speedHistory.isNotEmpty
  //         ? _speedHistory.first
  //         : MapEntry(now, speedMs),
  //   );
  //   final delta = speedMs - past.value; // + = speeding up, − = slowing down

  //   debugPrint(
  //     '[Harsh] mag=${magnitude.toStringAsFixed(2)} m/s² | '
  //     'speed=${speedKmh.toStringAsFixed(1)} km/h | '
  //     'Δspeed=${delta.toStringAsFixed(2)} m/s',
  //   );

  //   if (delta >= _kSpeedDeltaMs) {
  //     _lastHarshAt = now;
  //     if (_harshCooldown('HarshAcceleration')) {
  //       _harshBannerText = ' HARSH ACCELERATION';
  //       _harshEventAt = now;
  //       _reportIncident('Harsh Acceleration', 'Medium', 0.9);
  //       _tts.speak(AlertMessages.harshAcceleration(_tts.currentLang));
  //     }
  //   } else if (delta <= -_kSpeedDeltaMs) {
  //     _lastHarshAt = now;
  //     if (_harshCooldown('HarshBraking')) {
  //       _harshBannerText = 'HARSH BRAKING';
  //       _harshEventAt = now;
  //       _reportIncident('Harsh Braking', 'High', 0.9);
  //       _tts.speak(AlertMessages.harshBraking(_tts.currentLang));
  //     }
  //   }
  //   // else: strong force but speed barely changed → likely a turn or pothole.
  //   // Intentionally ignored.
  // }

  // /// Debounce for harsh-driving reports.
  // bool _harshCooldown(String key) {
  //   final now = DateTime.now();
  //   final last = _lastHarshReportAt[key];
  //   if (last == null ||
  //       now.difference(last).inSeconds >= _kHarshCooldownSeconds) {
  //     _lastHarshReportAt[key] = now;
  //     return true;
  //   }
  //   return false;
  // }

  // ─────────────────────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: RepaintBoundary(
        key: _screenBoundaryKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _cameraLayer(),

            if (_phase == Phase.verifying) _verifyingOverlay(),
            // Status banner on verifying screen (network, wifi, ws)
            if (_phase == Phase.verifying && !_initializing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(child: _verifyStatusBanner()),
              ),
            if (_phase == Phase.details) _detailsOverlay(),
            if (_phase == Phase.monitoring)
              (_tripCompleted ? _tripCompletedOverlay() : _monitoringOverlay()),
            if (_phase == Phase.monitoring &&
                !_tripCompleted &&
                _camMode == CamMode.rear)
              ReversingCameraOverlay(
                key: const ValueKey('rear_camera_overlay'),
                streamUrl: _esp32StreamUrl,
                speed: _state.vehicleSpeed,
                latitude: _state.gpsLat,
                longitude: _state.gpsLng,
                isPreviewMode: _rearManualOverride,
                onClosePreview: () {
                  _rearManualOverride = false;
                  _setCamMode(CamMode.driverMonitoring);
                },
                enableYolo: true,
                symbol: 'B',
                label: 'REAR CAM ACTIVE',
                onDetection: _onCamObjectDetected,
              ),

            // Invisible admin-exit hotspot (top-right corner). Double tap -> PIN.
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _showExitPinDialog,
                onTap: _onCornerTap,
                child: const SizedBox(width: 90, height: 90),
              ),
            ),

            // ── Side cam overlays (monitoring phase) — full-screen ──
            // if (_phase == Phase.monitoring &&
            //     !_tripCompleted &&
            //     _camMode == CamMode.left &&
            //     _leftCamIp != null)
            //   Positioned.fill(
            //     child: CamDetectionPanel(
            //       streamUrl: 'http://$_leftCamIp:86/',
            //       label: 'LEFT CAM',
            //       width: double.infinity,
            //       height: double.infinity,
            //       fullScreen: true,
            //       onClose: () => _setCamMode(CamMode.driverMonitoring),
            //     ),
            //   ),
            if (_phase == Phase.monitoring &&
                !_tripCompleted &&
                _camMode == CamMode.left &&
                _leftCamIp != null)
              ReversingCameraOverlay(
                key: const ValueKey('left_camera_overlay'),
                streamUrl: 'http://$_leftCamIp:86/',
                speed: _state.vehicleSpeed,
                latitude: _state.gpsLat,
                longitude: _state.gpsLng,
                isPreviewMode: _leftManualOverride,
                onClosePreview: () {
                  _leftManualOverride = false;
                  _setCamMode(CamMode.driverMonitoring);
                },
                label: 'LEFT CAM ACTIVE',
                symbol: 'L',
                themeColor: Colors.redAccent,
                enableYolo: false,
              ),

            // if (_phase == Phase.monitoring &&
            //     !_tripCompleted &&
            //     _camMode == CamMode.right &&
            //     _rightCamIp != null)
            //   Positioned.fill(
            //     child: CamDetectionPanel(
            //       streamUrl: 'http://$_rightCamIp:80/',
            //       label: 'RIGHT CAM',
            //       width: double.infinity,
            //       height: double.infinity,
            //       fullScreen: true,
            //       onClose: () => _setCamMode(CamMode.driverMonitoring),
            //     ),
            //   ),
            if (_phase == Phase.monitoring &&
                !_tripCompleted &&
                _camMode == CamMode.right &&
                _rightCamIp != null)
              ReversingCameraOverlay(
                key: const ValueKey('right_camera_overlay'),
                streamUrl: 'http://$_rightCamIp:80/',
                speed: _state.vehicleSpeed,
                latitude: _state.gpsLat,
                longitude: _state.gpsLng,
                isPreviewMode: _rightManualOverride,
                onClosePreview: () {
                  _rightManualOverride = false;
                  _setCamMode(CamMode.driverMonitoring);
                },
                label: 'RIGHT CAM ACTIVE',
                symbol: 'R',
                themeColor: Colors.redAccent,
                enableYolo: false,
              ),
            if (_phase == Phase.monitoring &&
                !_tripCompleted &&
                _camMode == CamMode.front &&
                _frontCamIp != null)
              ReversingCameraOverlay(
                key: const ValueKey('front_camera_overlay'),
                streamUrl: 'http://$_frontCamIp:84/',
                speed: _state.vehicleSpeed,
                latitude: _state.gpsLat,
                longitude: _state.gpsLng,
                isPreviewMode: _frontManualOverride,
                onClosePreview: () {
                  _frontManualOverride = false;
                  _setCamMode(CamMode.driverMonitoring);
                },
                label: 'FRONT CAM ACTIVE',
                symbol: 'F',
                themeColor: Colors.orange,
                enableYolo: true,
                onDetection: _onCamObjectDetected,
              ),

            // ── Side cam toggle buttons (monitoring + verifying phase) ──
            if ((_phase == Phase.monitoring && !_tripCompleted) ||
                (_phase == Phase.verifying && !_initializing))
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      if (_camMode == CamMode.left) {
                        _leftManualOverride = false;
                        _setCamMode(CamMode.driverMonitoring);
                      } else {
                        _leftManualOverride = true;
                        _setCamMode(CamMode.left);
                      }
                    },
                    child: Container(
                      width: 36,
                      height: 64,
                      decoration: BoxDecoration(
                        color: _camMode == CamMode.left
                            ? Colors.redAccent.withValues(alpha: 0.85)
                            : Colors.black54,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(10),
                          bottomRight: Radius.circular(10),
                        ),
                        border: Border.all(
                          color: _camMode == CamMode.left
                              ? Colors.redAccent
                              : Colors.white24,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(
                            Icons.chevron_left_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          Icon(
                            Icons.videocam_rounded,
                            color: Colors.white,
                            size: 14,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if ((_phase == Phase.monitoring && !_tripCompleted) ||
                (_phase == Phase.verifying && !_initializing))
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      if (_camMode == CamMode.right) {
                        _rightManualOverride = false;
                        _setCamMode(CamMode.driverMonitoring);
                      } else {
                        _rightManualOverride = true;
                        _setCamMode(CamMode.right);
                      }
                    },
                    child: Container(
                      width: 36,
                      height: 64,
                      decoration: BoxDecoration(
                        color: _camMode == CamMode.right
                            ? Colors.redAccent.withValues(alpha: 0.85)
                            : Colors.black54,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(10),
                          bottomLeft: Radius.circular(10),
                        ),
                        border: Border.all(
                          color: _camMode == CamMode.right
                              ? Colors.redAccent
                              : Colors.white24,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(
                            Icons.videocam_rounded,
                            color: Colors.white,
                            size: 14,
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 👇 ESP CAM DETECTION ALERT banner — shows for 3 seconds
            if (_camDetectionAlert != null &&
                _camDetectionAlertAt != null &&
                DateTime.now().difference(_camDetectionAlertAt!).inSeconds < 3)
              Positioned(
                bottom: 80,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _camDetectionAlert!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),

            // 👇 CABLE UNPLUGGED banner — shows for 5 seconds only.
            // if (_showCableBanner)
            //   Positioned(
            //   top: 0,
            //   left: 0,
            //   right: 0,
            //   child: SafeArea(
            //     child: Padding(
            //       padding: const EdgeInsets.all(12),
            //       child: Container(
            //         padding: const EdgeInsets.symmetric(
            //           horizontal: 14,
            //           vertical: 12,
            //         ),
            //         decoration: BoxDecoration(
            //           color: const Color(0xFFB91C1C),
            //           borderRadius: BorderRadius.circular(12),
            //         ),
            //         child: Row(
            //           children: const [
            //             Icon(
            //               Icons.power_off_rounded,
            //               color: Colors.white,
            //               size: 22,
            //             ),
            //             SizedBox(width: 10),
            //             Expanded(
            //               child: Text(
            //                 '🔌 CHARGING CABLE UNPLUGGED  Reported to admin',
            //                 style: TextStyle(
            //                   color: Colors.white,
            //                   fontSize: 14,
            //                   fontWeight: FontWeight.w700,
            //                 ),
            //               ),
            //             ),
            //           ],
            //         ),
            //       ),
            //     ),
            //   ),
            // ),
            _breakAlertOverlay(),

            // Screenshot effect — alert varumbol screen quick shrink + border + dim
            if (_flashScreenshot)
              Positioned.fill(
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 1.0, end: 0.92),
                    duration: const Duration(milliseconds: 110),
                    curve: Curves.easeOut,
                    builder: (context, scale, child) {
                      return Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        alignment: Alignment.center,
                        child: Transform.scale(
                          scale: scale,
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white, width: 3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

            // ── Floating PTT mic button ──────────────────────────────────
            ValueListenableBuilder<bool>(
              valueListenable: _streamService.isConnected,
              builder: (context, connected, _) {
                if (!connected) return const SizedBox.shrink();
                return Positioned(
                  bottom: 20,
                  right: 16,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _streamService.isSpeaking,
                    builder: (context, speaking, _) {
                      return GestureDetector(
                        onLongPressStart: (_) => _streamService.startSpeaking(),
                        onLongPressEnd: (_) => _streamService.stopSpeaking(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: speaking
                                ? const Color(0xFF22C55E)
                                : Colors.black.withValues(alpha: 0.65),
                            border: Border.all(
                              color: speaking
                                  ? const Color(0xFF22C55E)
                                  : Colors.white30,
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: speaking
                                    ? const Color(
                                  0xFF22C55E,
                                ).withValues(alpha: 0.5)
                                    : Colors.black45,
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Icon(
                            speaking
                                ? Icons.mic_rounded
                                : Icons.mic_none_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // SINGLE-MODE CAMERA SWITCHING
  // ─────────────────────────────────────────────────────────

  /// Switches to [mode], stopping the phone camera image stream when leaving
  /// driver monitoring and resuming it when returning.
  /// This is the ONLY place [_camMode] is written — never set it directly.
  Future<void> _setCamMode(CamMode mode) async {
    if (_camMode == mode) return;
    final wasMonitoring = _camMode == CamMode.driverMonitoring;
    final nowMonitoring = mode == CamMode.driverMonitoring;
    _camMode = mode;

    // Stop recording whenever switching to any ESP cam overlay view.
    // ESP32-CAM only supports ONE HTTP client at a time — the FFmpeg recorder
    // holds the connection, so the MjpegStreamWidget would get stuck if we
    // don't release it first.
    if (!nowMonitoring && _ffmpegRecorderService.isRecording) {
      await _ffmpegRecorderService.stopRecording();
      debugPrint(
        '[CamMode] Recorder STOPPED — releasing ESP cam stream for overlay ($mode)',
      );
    } else if (nowMonitoring &&
        _phase == Phase.monitoring &&
        !_ffmpegRecorderService.isRecording) {
      // Restart recording on whichever cam is available, preferring front cam.
      if (_frontCamConnected && _frontCamStreamUrl.isNotEmpty) {
        _ffmpegRecorderService.startRecording(_frontCamStreamUrl);
        debugPrint('[CamMode] Recorder RESTARTED — front cam monitoring');
      } else if (_esp32StreamUrl.isNotEmpty) {
        _ffmpegRecorderService.startRecording(_esp32StreamUrl);
        debugPrint('[CamMode] Recorder RESTARTED — rear cam monitoring');
      }
    }

    // While in ESP cam mode the phone camera is paused, so _processImage never
    // fires and the live stream goes silent. Drive screen captures with a timer
    // so the admin dashboard still sees the ESP cam view.
    if (!nowMonitoring) {
      _espCamStreamTimer?.cancel();
      _espCamStreamTimer = Timer.periodic(
        const Duration(
          milliseconds: 40,
        ), // ~25 FPS — matches screen capture throttle
            (_) => _captureAndSendScreen(),
      );
      debugPrint('[CamMode] ESP cam stream timer STARTED for live stream');
    } else {
      _espCamStreamTimer?.cancel();
      _espCamStreamTimer = null;
      debugPrint('[CamMode] ESP cam stream timer STOPPED — phone cam resumes');
    }
    final c = _camera;
    if (c != null && c.value.isInitialized) {
      if (wasMonitoring && _streaming) {
        c.stopImageStream().catchError((_) {});
        _streaming = false;
        // Reset no-face timer when switching away — camera is paused,
        // so no face detection happens. Don't let old timer cause trip end.
        _noFaceSince = null;
        debugPrint('[CamMode] → $mode | phone cam PAUSED');
      } else if (nowMonitoring && !_streaming && _camReady) {
        c.startImageStream(_processImage).catchError((_) {});
        _streaming = true;
        debugPrint('[CamMode] → driverMonitoring | phone cam RESUMED');
      }
    }
    if (nowMonitoring) {
      _noFaceSince = null;
    }
    if (mounted) setState(() {});
  }

  // ─────────────────────────────────────────────────────────
  // BLIND SPOT — IP resolution + sensor polling
  // ─────────────────────────────────────────────────────────

  bool _isDiscoveringRear = false;

  /// Auto-discovers rear cam (port 82) on the current subnet.
  Future<void> _autoDiscoverRearCam() async {
    if (_esp32StreamUrl.isNotEmpty) return; // already found
    if (_isDiscoveringRear) return; // already scanning
    _isDiscoveringRear = true;

    try {
      String? subnet;
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer wlan/wifi interface over mobile data
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('ap') ||
            name.contains('softap')) {
          for (final addr in iface.addresses) {
            final parts = addr.address.split('.');
            if (parts.length == 4 && parts[0] != '127') {
              subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
              break;
            }
          }
        }
        if (subnet != null) break;
      }
      // Fallback: skip 100.x.x.x (mobile data CGNAT)
      if (subnet == null) {
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            final parts = addr.address.split('.');
            if (parts.length == 4 && parts[0] != '127' && parts[0] != '100') {
              subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
              break;
            }
          }
          if (subnet != null) break;
        }
      }

      if (subnet == null) return;

      // Try known static IP first (instant connection)
      debugPrint('[AutoDiscover] Scanning $subnet.* for rear cam (port 82)...');

      for (int start = 1; start <= 254; start += 50) {
        final end = (start + 49).clamp(1, 254);
        final probes = <Future<String?>>[];
        for (int i = start; i <= end; i++) {
          final ip = '$subnet.$i';
          probes.add(() async {
            try {
              final socket = await Socket.connect(
                ip,
                82,
              ).timeout(const Duration(milliseconds: 600));
              await socket.close();
              return ip;
            } catch (_) {
              return null;
            }
          }());
        }
        final results = await Future.wait(probes);
        final found = results.firstWhere((r) => r != null, orElse: () => null);
        if (found != null) {
          _esp32StreamUrl = 'http://$found:82/';
          debugPrint('[AutoDiscover] ✓ Rear cam found at $found:82');
          if (mounted) {
            setState(() {
              _isConnectedToEsp32 = true;
            });
            if (!_ffmpegRecorderService.isRecording &&
                _camMode == CamMode.driverMonitoring &&
                _phase == Phase.monitoring) {
              _ffmpegRecorderService.startRecording(_esp32StreamUrl);
            }
          }
          break;
        }
      }
    } catch (e) {
      debugPrint('[AutoDiscover] Rear cam scan error: $e');
    } finally {
      _isDiscoveringRear = false;
    }
  }

  /// Scans the local subnet to resolve direct IPs for all three ESP32 cams.
  /// Left sensor: port 87 | Right sensor: port 81 | Front sensor: port 85
  /// Direct IPs are used because .local mDNS is unreliable on Android.
  Future<void> _resolveSideCamIps() async {
    if (_leftCamIp != null && _rightCamIp != null && _frontCamIp != null)
      return;

    // Throttle: never scan more than once every 15 seconds.
    final now = DateTime.now();
    if (_lastSideCamScanAt != null &&
        now.difference(_lastSideCamScanAt!) < const Duration(seconds: 15))
      return;
    _lastSideCamScanAt = now;

    // If rear cam already found, use its subnet (guaranteed correct)
    String? subnet;
    if (_esp32StreamUrl.isNotEmpty) {
      try {
        final rearIp = Uri.parse(_esp32StreamUrl).host;
        final parts = rearIp.split('.');
        if (parts.length == 4) {
          subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          debugPrint('[SideCam] Using rear cam subnet: $subnet.*');
        }
      } catch (_) {}
    }

    // Otherwise discover subnet from network interfaces
    if (subnet == null) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        // First pass: look for wlan/wifi/ap interface (where ESPs live)
        for (final iface in interfaces) {
          final name = iface.name.toLowerCase();
          if (name.contains('wlan') ||
              name.contains('wifi') ||
              name.contains('ap') ||
              name.contains('softap')) {
            for (final addr in iface.addresses) {
              final parts = addr.address.split('.');
              if (parts.length == 4 && parts[0] != '127') {
                subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
                debugPrint(
                  '[SideCam] Using WiFi interface ${iface.name}: ${addr.address}',
                );
                break;
              }
            }
          }
          if (subnet != null) break;
        }
        // Fallback: any private IP (skip 100.x.x.x which is mobile data CGNAT)
        if (subnet == null) {
          for (final iface in interfaces) {
            for (final addr in iface.addresses) {
              final parts = addr.address.split('.');
              if (parts.length == 4 && parts[0] != '127' && parts[0] != '100') {
                subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
                debugPrint(
                  '[SideCam] Using fallback interface ${iface.name}: ${addr.address}',
                );
                break;
              }
            }
            if (subnet != null) break;
          }
        }
      } catch (e) {
        debugPrint('[SideCam] Cannot get local IP: $e');
        return;
      }
    }
    if (subnet == null) {
      debugPrint('[SideCam] No suitable subnet found (only mobile data?)');
      return;
    }
    debugPrint(
      '[SideCam] Scanning $subnet.1-254 — left(87/86), right(81/80), front(85/84)',
    );

    final String sub = subnet;

    // Exclude already-known IPs to avoid assigning the same ESP to multiple slots
    final Set<String> excludeIps = {};
    if (_esp32StreamUrl.isNotEmpty) {
      try {
        excludeIps.add(Uri.parse(_esp32StreamUrl).host);
      } catch (_) {}
    }
    if (_leftCamIp != null) excludeIps.add(_leftCamIp!);
    if (_rightCamIp != null) excludeIps.add(_rightCamIp!);
    if (_frontCamIp != null) excludeIps.add(_frontCamIp!);

    Future<String?> scanForPort(int sensorPort, int videoPort) async {
      // Strategy 1: Try sensor endpoint (returns JSON with distance_cm)
      Future<String?> probeSensor(String ip) async {
        if (excludeIps.contains(ip)) return null;
        try {
          final res = await http
              .get(Uri.parse('http://$ip:$sensorPort/sensor'))
              .timeout(const Duration(milliseconds: 800));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            if (data.containsKey('distance_cm')) return ip;
          }
        } catch (_) {}
        return null;
      }

      // Strategy 2: Try video port — verify it's an MJPEG stream (not a random HTTP server)
      Future<String?> probeVideo(String ip) async {
        if (excludeIps.contains(ip)) return null;
        try {
          // HTTP GET and check for multipart content-type (MJPEG signature)
          final req = http.Request('GET', Uri.parse('http://$ip:$videoPort/'));
          final client = http.Client();
          final response = await client
              .send(req)
              .timeout(const Duration(milliseconds: 1200));
          final contentType = response.headers['content-type'] ?? '';
          client.close();
          if (contentType.contains('multipart') ||
              contentType.contains('image/jpeg')) {
            return ip;
          }
          debugPrint(
            '[SideCam] $ip:$videoPort responded but not MJPEG (content-type: $contentType)',
          );
        } catch (_) {}
        return null;
      }

      for (int start = 1; start <= 254; start += 50) {
        final end = (start + 49).clamp(1, 254);
        // Try sensor first
        final sensorBatch = [
          for (int i = start; i <= end; i++) probeSensor('$sub.$i'),
        ];
        final sensorResults = await Future.wait(sensorBatch);
        final found = sensorResults.firstWhere(
              (r) => r != null,
          orElse: () => null,
        );
        if (found != null) return found;
        // Fallback: try video port TCP
        final videoBatch = [
          for (int i = start; i <= end; i++) probeVideo('$sub.$i'),
        ];
        final videoResults = await Future.wait(videoBatch);
        final vFound = videoResults.firstWhere(
              (r) => r != null,
          orElse: () => null,
        );
        if (vFound != null) return vFound;
      }
      return null;
    }

    final leftResult = _leftCamIp == null
        ? await scanForPort(87, 86)
        : _leftCamIp;
    if (_leftCamIp == null && leftResult != null) {
      _leftCamIp = leftResult;
      excludeIps.add(leftResult);
      debugPrint('[SideCam] Left cam IP → $_leftCamIp');
    }

    final rightResult = _rightCamIp == null
        ? await scanForPort(81, 80)
        : _rightCamIp;
    if (_rightCamIp == null && rightResult != null) {
      _rightCamIp = rightResult;
      excludeIps.add(rightResult);
      debugPrint('[SideCam] Right cam IP → $_rightCamIp');
    }

    final frontResult = _frontCamIp == null
        ? await scanForPort(85, 84)
        : _frontCamIp;
    if (_frontCamIp == null && frontResult != null) {
      _frontCamIp = frontResult;
      excludeIps.add(frontResult);
      debugPrint('[SideCam] Front cam IP → $_frontCamIp');
    }
    if (_frontCamIp != null) {
      _frontCamStreamUrl = 'http://$_frontCamIp:84/';
      if (!_ffmpegRecorderService.isRecording &&
          _camMode == CamMode.driverMonitoring &&
          _phase == Phase.monitoring) {
        debugPrint(
          '[SideCam] Starting Front camera background recording: $_frontCamStreamUrl',
        );
        _ffmpegRecorderService.startRecording(_frontCamStreamUrl);
      }
    }
  }

  /// Polls both ultrasonic sensor endpoints every 500 ms.
  /// Opens the side cam automatically when an object is closer than 50 cm,
  /// and closes it when the path is clear beyond 60 cm.
  Future<void> _pollBlindSpotSensors() async {
    if (!mounted || _phase != Phase.monitoring || _tripCompleted) return;
    if (_isPollingBlindSpot) return; // skip if previous poll still running
    _isPollingBlindSpot = true;

    // Trigger IP resolution in the background if left or right cam is unknown.
    // Non-blocking: polls continue with whatever IPs are already resolved.
    if (_leftCamIp == null || _rightCamIp == null || _frontCamIp == null) {
      _resolveSideCamIps(); // fire-and-forget
    }

    Future<double?> fetch(String? url) async {
      if (url == null) return null; // IP not yet resolved — skip silently
      try {
        final res = await http
            .get(Uri.parse(url))
            .timeout(const Duration(milliseconds: 1500));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final dist = (data['distance_cm'] as num?)?.toDouble();
          debugPrint('[BlindSpot] $url → ${dist?.toStringAsFixed(1)} cm');
          return dist;
        } else {
          debugPrint('[BlindSpot] $url → HTTP ${res.statusCode}');
        }
      } catch (e) {
        debugPrint('[BlindSpot] $url → ERROR: $e');
      }
      return null;
    }

    // Only poll sensors for which we have a resolved IP.
    // .local mDNS fallback is intentionally removed — it doesn't work on Android.
    // final leftUrl = _leftCamIp != null ? 'http://$_leftCamIp:87/sensor' : null;
    // final rightUrl = _rightCamIp != null
    //     ? 'http://$_rightCamIp:81/sensor'
    //     : null;

    // final results = await Future.wait([fetch(leftUrl), fetch(rightUrl)]);
    // if (!mounted) {
    //   _isPollingBlindSpot = false;
    //   return;
    // }

    // final double? left = results[0];
    // final double? right = results[1];

    // // Priority: rear > left > right. Rear is handled by the reversing detector.
    // // Never override rear mode or a manual rear override from the REAR button.
    // if (_camMode != CamMode.rear && !_rearManualOverride) {
    //   if (left != null && left < 50.0) {
    //     _setCamMode(CamMode.left);
    //   } else if (right != null && right < 50.0) {
    //     _setCamMode(CamMode.right);
    //   } else {
    //     final bool leftClear = left == null || left > 60.0;
    //     final bool rightClear = right == null || right > 60.0;
    //     if (leftClear &&
    //         rightClear &&
    //         (_camMode == CamMode.left || _camMode == CamMode.right)) {
    //       _setCamMode(CamMode.driverMonitoring);
    //     }
    //   }
    // }

    final leftUrl = _leftCamIp != null ? 'http://$_leftCamIp:87/sensor' : null;
    final rightUrl = _rightCamIp != null
        ? 'http://$_rightCamIp:81/sensor'
        : null;
    // Front and rear cams have no sensor — skip polling them

    final results = await Future.wait([fetch(leftUrl), fetch(rightUrl)]);
    if (!mounted) {
      _isPollingBlindSpot = false;
      return;
    }

    final double? left = results[0];
    final double? right = results[1];

    if (_camMode != CamMode.rear && !_rearManualOverride) {
      final bool objectNearby =
          (left != null && left < 50.0) || (right != null && right < 50.0);

      if (objectNearby) {
        _blindSpotObjectLastSeenAt = DateTime.now();
        if (left != null && left < 50.0) {
          // Save current mode before switching (only if not already in auto-side-cam)
          if (_camMode != CamMode.left && _camMode != CamMode.right) {
            _camModeBeforeBlindSpot = _camMode;
          }
          _leftManualOverride = false;
          _setCamMode(CamMode.left);
        } else if (right != null && right < 50.0) {
          if (_camMode != CamMode.left && _camMode != CamMode.right) {
            _camModeBeforeBlindSpot = _camMode;
          }
          _rightManualOverride = false;
          _setCamMode(CamMode.right);
        }
      } else {
        // Object cleared — keep cam open for 5 more seconds
        final bool leftClear = left == null || left > 60.0;
        final bool rightClear = right == null || right > 60.0;
        final bool isAutoSideCam =
            (_camMode == CamMode.left && !_leftManualOverride) ||
                (_camMode == CamMode.right && !_rightManualOverride);
        if (leftClear && rightClear && isAutoSideCam) {
          final bool lingerExpired =
              _blindSpotObjectLastSeenAt == null ||
                  DateTime.now()
                      .difference(_blindSpotObjectLastSeenAt!)
                      .inSeconds >=
                      _kBlindSpotLingerSec;
          if (lingerExpired) {
            _blindSpotObjectLastSeenAt = null;
            // Restore previous cam mode (front/rear/driver) instead of always going to driverMonitoring
            final restoreTo =
                _camModeBeforeBlindSpot ?? CamMode.driverMonitoring;
            _camModeBeforeBlindSpot = null;
            _setCamMode(restoreTo);
          }
        }
      }
    }
    _isPollingBlindSpot = false;
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

  // ── Brightness control widget ──
  Widget _brightnessControl() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _brightness < 0.5 ? Icons.brightness_low : Icons.brightness_high,
          color: Colors.white,
          size: 14,
        ),
        SizedBox(
          width: 60,
          height: 14,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: const Color(0xFF22C55E),
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
            child: Slider(
              value: _brightness,
              min: 0.05,
              max: 1.0,
              onChanged: (v) {
                setState(() => _brightness = v);
                _setScreenBrightness(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  void _setScreenBrightness(double value) {
    const MethodChannel(
      'kiosk',
    ).invokeMethod('setBrightness', {'brightness': value});
  }

  // Status banner for verifying screen (network, wifi, ws live)
  Widget _verifyStatusBanner() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // if (_vehicleRegNo != null && _vehicleRegNo!.isNotEmpty)
        //   Padding(
        //     padding: const EdgeInsets.only(left: 14, bottom: 1),
        //     child: Text(
        //       _vehicleRegNo!,
        //       style: const TextStyle(
        //         color: Colors.white,
        //         fontSize: 10,
        //         fontWeight: FontWeight.w800,
        //         letterSpacing: 0.5,
        //         shadows: [Shadow(color: Colors.black, blurRadius: 4)],
        //       ),
        //     ),
        //   ),

        // ── Reg number (left) + app version (right) on the same top line ──
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 14, bottom: 1),
          child: Row(
            children: [
              if (_vehicleRegNo != null && _vehicleRegNo!.isNotEmpty)
                Text(
                  _vehicleRegNo!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              const Spacer(),
              if (_appVersion.isNotEmpty)
                Text(
                  _appVersion,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // ONLINE / OFFLINE
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.language_rounded,
                    color: _isOnline ? const Color(0xFF22C55E) : Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _isOnline ? 'ONLINE' : 'OFFLINE',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              Container(height: 12, width: 1, color: Colors.white24),
              // WIFI
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isWifi ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                    color: _isWifi ? const Color(0xFF22C55E) : Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 3),
                  const Text(
                    'WIFI',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              Container(height: 12, width: 1, color: Colors.white24),
              // WS LIVE
              ValueListenableBuilder<bool>(
                valueListenable: _streamService.isConnected,
                builder: (context, isLiveConnected, child) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isLiveConnected
                            ? Icons.videocam_rounded
                            : Icons.videocam_off_rounded,
                        color: isLiveConnected
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFEF4444),
                        size: 14,
                      ),
                      const SizedBox(width: 3),
                      const Text(
                        'LIVE STREAM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  );
                },
              ),
              Container(height: 12, width: 1, color: Colors.white24),
              // BRIGHTNESS
              _brightnessControl(),
            ],
          ),
        ),
        _esp32StatusBanner(),
      ],
    );
  }

  Widget _verifyingOverlay() {
    // if (!_initializing && !_authEngine.isEnrolled && !_isRefreshingDrivers) {
    //   final bool noInternet = !_isOnline;
    //   return Container(
    //     color: Colors.black.withValues(alpha: 0.85),
    //     child: Center(
    //       child: Column(
    //         mainAxisAlignment: MainAxisAlignment.center,
    //         children: [
    //           Icon(
    //             noInternet ? Icons.wifi_off_rounded : Icons.people_outlined,
    //             color: noInternet ? Colors.orangeAccent : Colors.redAccent,
    //             size: 64,
    //           ),
    //           const SizedBox(height: 24),
    //           Text(
    //             noInternet ? 'No Internet Connected' : 'No Drivers Assigned',
    //             style: const TextStyle(
    //               color: Colors.white,
    //               fontSize: 20,
    //               fontWeight: FontWeight.w600,
    //             ),
    //           ),
    //           const SizedBox(height: 8),
    //           Text(
    //             noInternet
    //                 ? 'Please connect to the internet to fetch driver data.'
    //                 : 'No registered/authorized drivers found for this device.',
    //             style: const TextStyle(color: Colors.white70, fontSize: 14),
    //             textAlign: TextAlign.center,
    //           ),
    //         ],
    //       ),
    //     ),
    //   );
    // }

    final isUnverified =
        _state.authStatus == AuthStatus.unauthorized && _state.faceCount > 0;
    final isAuthenticating =
        _state.authStatus == AuthStatus.scanning && _state.faceCount > 0;
    final Color themeColor = isUnverified
        ? Colors.redAccent
        : const Color(0xFF3B82F6);

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Centered Status Info Header
                Text(
                  _initializing
                      ? 'Initializing systems…'
                      : (isUnverified
                      ? 'Unverified'
                      : (isAuthenticating
                      ? 'Authenticating...'
                      : 'Verifying your face…')),
                  style: TextStyle(
                    color: isUnverified ? Colors.redAccent : Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _state.faceCount == 0
                      ? 'Look at the camera'
                      : (isUnverified
                      ? 'Face not recognised — keep looking'
                      : (isAuthenticating
                      ? 'Processing your face, please wait...'
                      : 'Hold still…')),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 32),
                // Loader shown during initialization
                if (_initializing)
                  const SizedBox(
                    width: 260,
                    height: 260,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF3B82F6),
                        strokeWidth: 3,
                      ),
                    ),
                  )
                // High-Tech Scanner scope in the center (only during verify/monitor and NOT initializing)
                else if (_phase == Phase.verifying ||
                    _phase == Phase.monitoring)
                  SizedBox(
                    width: 260,
                    height: 260,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 260,
                          height: 260,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: themeColor.withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Stack(
                              children: [_FaceScannerLine(color: themeColor)],
                            ),
                          ),
                        ),
                        // Left-Top Corner
                        Positioned(
                          left: -4,
                          top: -4,
                          child: _ScannerCorner(
                            isTop: true,
                            isLeft: true,
                            color: themeColor,
                          ),
                        ),
                        // Right-Top Corner
                        Positioned(
                          right: -4,
                          top: -4,
                          child: _ScannerCorner(
                            isTop: true,
                            isLeft: false,
                            color: themeColor,
                          ),
                        ),
                        // Left-Bottom Corner
                        Positioned(
                          left: -4,
                          bottom: -4,
                          child: _ScannerCorner(
                            isTop: false,
                            isLeft: true,
                            color: themeColor,
                          ),
                        ),
                        // Right-Bottom Corner
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: _ScannerCorner(
                            isTop: false,
                            isLeft: false,
                            color: themeColor,
                          ),
                        ),

                        // Small circular progress spinner or error icon at the center
                        Align(
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: 54,
                            height: 54,
                            child: isUnverified
                                ? const Icon(
                              Icons.error_outline,
                              color: Colors.redAccent,
                              size: 54,
                            )
                                : CircularProgressIndicator(
                              strokeWidth: 3,
                              color: themeColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Centered feedback card below scanner (only when a face is detected)
                if (_state.faceCount > 0 &&
                    _state.authDistance >= 0 &&
                    !_initializing) ...[
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12, width: 1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Match Distance: ${_state.authDistance.toStringAsFixed(2)}  (Target: <${FaceAuthEngine.kAuthThreshold.toStringAsFixed(2)})',
                          style: TextStyle(
                            color:
                            _state.authDistance <
                                FaceAuthEngine.kAuthThreshold
                                ? Colors.greenAccent
                                : Colors.orangeAccent,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Position face 30–40 cm from phone for faster verification',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

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
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                // const SizedBox(height: 14),
                // Container(
                //   padding: const EdgeInsets.symmetric(
                //     horizontal: 18,
                //     vertical: 8,
                //   ),
                //   decoration: BoxDecoration(
                //     color: const Color(0xFF3B82F6).withValues(alpha: 0.10),
                //     borderRadius: BorderRadius.circular(20),
                //   ),
                //   child: Text(
                //     'Driver ID: $_driverId',
                //     style: const TextStyle(
                //       color: Color(0xFF2563EB),
                //       fontSize: 14,
                //       fontWeight: FontWeight.w600,
                //     ),
                //   ),
                // ),
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
      top: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Align(
          //   alignment: Alignment.centerLeft,
          //   child: Padding(
          //     padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
          //     child: _syncIconButton(),
          //   ),
          // ),
          // _cableUnpluggedBanner(),
          // _monitorStatusBar(),
          // _cableUnpluggedBanner(),
          // ── Vehicle registration number (same style as verifying screen) ──
          if (_vehicleRegNo != null && _vehicleRegNo!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 2, bottom: 0),
              child: Text(
                _vehicleRegNo!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  height: 1.0,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
          _monitorStatusBar(),
          _esp32StatusBanner(),
          // _deviceMotionCard(),
          const SizedBox(height: 10),
          if (_noFaceSince != null && !_tripCompleted) _noDriverCountdown(),
          if (_unauthorizedStart != null && !_tripCompleted)
            _unauthorizedDriverCountdown(),
          const Spacer(),
          _boundaryBanner(),
          _seatbeltIndicator(),
          _monitorBanner(),
          // _monitorDiag(),
        ],
      ),
    );
  }

  // Widget _cableUnpluggedBanner() {
  //   if (!_showCableBanner) return const SizedBox.shrink();
  //   return Container(
  //     margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
  //     padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  //     decoration: BoxDecoration(
  //       color: const Color(0xFFB91C1C).withValues(alpha: 0.95),
  //       borderRadius: BorderRadius.circular(12),
  //     ),
  //     child: Row(
  //       children: const [
  //         Icon(Icons.power_off_rounded, color: Colors.white, size: 20),
  //         SizedBox(width: 10),
  //         Expanded(
  //           child: Text(
  //             '🔌 CHARGING CABLE UNPLUGGED  Reported to admin',
  //             style: TextStyle(
  //               color: Colors.white,
  //               fontSize: 13,
  //               fontWeight: FontWeight.w700,
  //             ),
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  Widget _esp32StatusBanner() {
    Widget camDot(String label, bool connected) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
        decoration: BoxDecoration(
          color: connected
              ? const Color(0xFF22C55E).withValues(alpha: 0.15)
              : const Color(0xFFEF4444).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: connected
                ? const Color(0xFF22C55E).withValues(alpha: 0.4)
                : const Color(0xFFEF4444).withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: connected
                    ? const Color(0xFF22C55E)
                    : const Color(0xFFEF4444),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(left: 12, right: 12, top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          // ── L/R/F/B cam status ──
          camDot('L', _leftCamConnected),
          const SizedBox(width: 4),
          camDot('R', _rightCamConnected),
          const SizedBox(width: 4),
          camDot('F', _frontCamConnected),
          const SizedBox(width: 4),
          camDot('B', _rearCamConnected),
          const SizedBox(width: 10),
          // ── REAR button ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_camMode == CamMode.rear && _rearManualOverride) {
                _rearManualOverride = false;
                _setCamMode(CamMode.driverMonitoring);
              } else {
                _rearManualOverride = true;
                _setCamMode(CamMode.rear);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _camMode == CamMode.rear
                    ? Colors.redAccent.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _camMode == CamMode.rear
                      ? Colors.redAccent
                      : Colors.white30,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.videocam_rounded, color: Colors.white, size: 16),
                  SizedBox(width: 4),
                  Text(
                    'REAR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // ── FRONT button ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_camMode == CamMode.front) {
                _frontManualOverride = false;
                _setCamMode(CamMode.driverMonitoring);
              } else {
                _frontManualOverride = true;
                _setCamMode(CamMode.front);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _camMode == CamMode.front
                    ? Colors.orangeAccent.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _camMode == CamMode.front
                      ? Colors.orangeAccent
                      : Colors.white30,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.videocam_rounded, color: Colors.white, size: 16),
                  SizedBox(width: 4),
                  Text(
                    'FRONT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _camConnectionStatusBar() {
    Widget camChip(String label, bool connected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: connected
                  ? const Color(0xFF22C55E)
                  : const Color(0xFFEF4444),
              shape: BoxShape.circle,
            ),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          camChip('L', _leftCamConnected),
          camChip('R', _rightCamConnected),
          camChip('F', _frontCamConnected),
          camChip('B', _rearCamConnected),
        ],
      ),
    );
  }

  /// Shows offline/online status and pending incident count.
  Widget _syncIconButton() {
    return GestureDetector(
      onTap: () {
        _syncIncidentsTask();
      },
      child: const Icon(Icons.sync_rounded, color: Color(0xFF2563EB), size: 24),
    );
  }

  Future<void> _openHotspotSettings() async {
    try {
      const platform = MethodChannel('com.example.monitoring_driver/settings');
      await platform.invokeMethod('openHotspotSettings');
    } catch (e) {
      debugPrint('[Hotspot] Failed to open settings: $e');
    }
  }

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
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
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
    final mins = remaining ~/ 60;
    final secs = remaining % 60;
    final timeStr = mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFF59E0B), width: 2),
            ),
            child: Text(
              mins > 0 ? '${mins}m' : '${secs}s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'No driver detected',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Ending Trip $_tripNumber in $timeStr',
                  style: const TextStyle(
                    color: Color(0xFFFCD34D),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _unauthorizedDriverCountdown() {
    return const SizedBox.shrink();
  }

  // Top info bar (driving_hud_view style): version + net/esp icons + trip.
  Widget _monitorStatusBar() {
    final calText = _state.calibrated
        ? 'CAL ✓'
        : 'Calibrating ${_state.calibrationFrame}/${MonitoringEngine.kCalibrationFrames}';
    final calColor = _state.calibrated ? Colors.greenAccent : Colors.amber;

    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top row: green dot + version + cal + trip
          Row(
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
              Text(
                _appVersion.isNotEmpty ? _appVersion : 'MONITORING',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                calText,
                style: TextStyle(
                  color: calColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                'Trip $_tripNumber · $_driverName',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // ONLINE / OFFLINE
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.language_rounded,
                    color: _isOnline ? const Color(0xFF22C55E) : Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _isOnline ? 'ONLINE' : 'OFFLINE',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              Container(height: 12, width: 1, color: Colors.white24),
              // HOTSPOT OK / OFF
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isWifi ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                    color: _isWifi ? const Color(0xFF22C55E) : Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 3),
                  const Text(
                    'WIFI',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              Container(height: 12, width: 1, color: Colors.white24),
              // WS LIVE / OFF
              ValueListenableBuilder<bool>(
                valueListenable: _streamService.isConnected,
                builder: (context, isLiveConnected, child) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isLiveConnected
                            ? Icons.videocam_rounded
                            : Icons.videocam_off_rounded,
                        color: isLiveConnected
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFEF4444),
                        size: 14,
                      ),
                      const SizedBox(width: 3),
                      const Text(
                        'LIVE STREAM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  );
                },
              ),
              Container(height: 12, width: 1, color: Colors.white24),
              // BRIGHTNESS
              _brightnessControl(),
            ],
          ),
        ],
      ),
    );
  }

  /// NET + ESP status chips row — shown above the version banner.
  Widget _networkStatusRow() {
    final allCamConnected =
        _leftCamConnected &&
            _rightCamConnected &&
            _frontCamConnected &&
            _rearCamConnected;

    Widget chip({
      required IconData icon,
      required String label,
      required bool connected,
      required Color activeColor,
    }) {
      final color = connected ? activeColor : const Color(0xFFEF4444);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: connected ? activeColor : const Color(0xFFEF4444),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 12),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: chip(
              icon: _isOnline ? Icons.language_rounded : Icons.language_rounded,
              label: _isOnline ? 'Internet Connected' : 'Internet Disconnected',
              connected: _isOnline,
              activeColor: const Color(0xFF3B82F6),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: chip(
              icon: allCamConnected
                  ? Icons.wifi_rounded
                  : Icons.wifi_off_rounded,
              label: allCamConnected
                  ? 'Cameras Connected'
                  : 'Cameras Disconnected',
              connected: allCamConnected,
              activeColor: const Color(0xFF22C55E),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tripCompletedOverlay() {
    int remaining = 0;
    if (_tripCompletedAt != null) {
      remaining = 10 - DateTime.now().difference(_tripCompletedAt!).inSeconds;
      if (remaining < 0) remaining = 0;
    }

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0F172A), Color(0xFF020617)],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Frosted glass card containing the status
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                          (_unauthorizedTripStop
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF10B981))
                              .withValues(alpha: 0.15),
                          border: Border.all(
                            color: _unauthorizedTripStop
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF10B981),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                              (_unauthorizedTripStop
                                  ? const Color(0xFFEF4444)
                                  : const Color(0xFF10B981))
                                  .withValues(alpha: 0.3),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          _unauthorizedTripStop
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_outline_rounded,
                          color: _unauthorizedTripStop
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF10B981),
                          size: 44,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _unauthorizedTripStop
                            ? 'Trip $_tripNumber Stopped'
                            : 'Trip $_tripNumber Completed',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _unauthorizedTripStop
                            ? 'Someone not authorized was found. Please look at the camera to verify the driver.'
                            : 'Driver left the seat. The next driver must verify to start the next trip.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                      if (remaining > 0) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Re-verifying in $remaining seconds...',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF3B82F6),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 40),

                // Camera Scanner Circular Preview with neon blue ring
                _ScanningPulse(
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF3B82F6),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF3B82F6,
                          ).withValues(alpha: 0.25),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: _liveFaceCircle(140),
                  ),
                ),

                const SizedBox(height: 32),
                const Text(
                  'Look at the camera to verify',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF60A5FA), // Soft blue
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Waiting for authentication…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF94A3B8), // Soft slate
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),

                // ── DEBUG: manual update check trigger ──
                const SizedBox(height: 24),
                // GestureDetector(
                //   onTap: _checkForUpdateInBackground,
                //   child: Container(
                //     padding: const EdgeInsets.symmetric(
                //       horizontal: 16,
                //       vertical: 8,
                //     ),
                //     decoration: BoxDecoration(
                //       color: Colors.white.withValues(alpha: 0.07),
                //       borderRadius: BorderRadius.circular(20),
                //       border: Border.all(
                //         color: Colors.white.withValues(alpha: 0.15),
                //       ),
                //     ),
                //     child: const Text(
                //       'Check for Updates Test 20',
                //       style: TextStyle(
                //         color: Color(0xFF64748B),
                //         fontSize: 11,
                //         fontWeight: FontWeight.w500,
                //       ),
                //     ),
                //   ),
                // ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Big full-width detection banner (driving_hud_view style). Shows the most
  // important active state: unauthorized / multiple / asleep / phone /
  // cigarette / seatbelt / drowsy / distraction. Hidden when all is well.
  Widget _monitorBanner() {
    final phone = _state.hasPhone;
    final smoke = _state.hasCigarette;

    final currentKey = _getMonitorBannerKey(phone, smoke);
    if (currentKey == null) {
      _activeBannerKey = null;
      _activeBannerAt = null;
      return const SizedBox.shrink();
    }

    if (_activeBannerKey != currentKey || _activeBannerAt == null) {
      _activeBannerKey = currentKey;
      _activeBannerAt = DateTime.now();
    }

    final bannerStart = _activeBannerAt;
    if (bannerStart != null &&
        DateTime.now().difference(bannerStart) > _kBannerVisibleDuration) {
      return const SizedBox.shrink();
    }

    Color? bg;
    String? text;
    Color fg = Colors.white;

    if (_harshEventAt != null &&
        DateTime.now().difference(_harshEventAt!) <= _kBannerVisibleDuration &&
        _harshBannerText != null) {
      bg = const Color(0xFFB91C1C); // red
      text = _harshBannerText;
    } else if (phone) {
      bg = const Color(0xFF7E22CE);
      final percent = (_state.phoneConfidence * 100).toStringAsFixed(0);
      text = '📵  PHONE DETECTED ($percent%)';
    } else if (_state.drowsinessLevel == DrowsinessLevel.asleep) {
      bg = const Color(0xFFDC2626);

      // final avgEar = (_state.leftEar + _state.rightEar) / 2;
      // final thr = _state.earThreshold;
      // final asleepPct = thr > 0
      //     ? (((thr - avgEar) / thr) * 100).clamp(0, 100).toStringAsFixed(0)
      //     : '0';
      // text = '⚠  WAKE UP! ($asleepPct%)';
      text = '⚠  WAKE UP!  ⚠';
    } else if (smoke) {
      bg = const Color(0xFF7E22CE);
      final percent = (_state.cigaretteConfidence * 100).toStringAsFixed(0);
      text = '🚬  SMOKING DETECTED ($percent%)';
    } else if (_state.hasEating || _state.isChewing) {
      bg = const Color(0xFFDC2626);
      if (_state.eatingConfidence > 0) {
        final percent = (_state.eatingConfidence * 100).toStringAsFixed(0);
        text = '🍔  EATING DETECTED ($percent%)';
      } else {
        text = '🍔  EATING DETECTED';
      }
    } else if (_state.hasDrinking) {
      bg = const Color(0xFFEA580C);
      final percent = (_state.drinkingConfidence * 100).toStringAsFixed(0);
      text = '🥤  DRINKING DETECTED ($percent%)';
    } else if (_state.drowsinessLevel == DrowsinessLevel.drowsy) {
      bg = const Color(0xFFD97706);
      text = '⚠  DROWSINESS DETECTED';
    } else if (_state.distractionStatus == DistractionStatus.distracted) {
      bg = const Color(0xFFEAB308);
      fg = Colors.black;
      text = '⚠  DISTRACTION DETECTED EYES ON THE ROAD';
    } else if (_state.authStatus == AuthStatus.unauthorized) {
      bg = const Color(0xFF7F1D1D);
      text = '⚠  DRIVER CHANGED';
    } else if (_state.authStatus == AuthStatus.multipleFaces) {
      bg = const Color(0xFFEA580C);
      text = '⚠  MULTIPLE PEOPLE DETECTED ';
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

  String? _getMonitorBannerKey(bool phone, bool smoke) {
    // Harsh event within the banner-visible window?
    if (_harshEventAt != null &&
        DateTime.now().difference(_harshEventAt!) <= _kBannerVisibleDuration) {
      return 'harsh';
    }
    if (phone) return 'phone';
    if (_state.drowsinessLevel == DrowsinessLevel.asleep) return 'asleep';
    if (smoke) return 'smoke';
    if (_state.hasEating || _state.isChewing) return 'eating';
    if (_state.hasDrinking) return 'drinking';
    if (_state.drowsinessLevel == DrowsinessLevel.drowsy) return 'drowsy';
    if (_state.distractionStatus == DistractionStatus.distracted)
      return 'distracted';
    if (_state.authStatus == AuthStatus.unauthorized) return 'unauthorized';
    if (_state.authStatus == AuthStatus.multipleFaces) return 'multiple_faces';
    return null;
  }

  Widget _seatbeltIndicator() {
    final on = _state.seatbeltBuckled;
    if (on) return const SizedBox.shrink();
    final bg = on ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    // final icon = on ? Icons.check_circle_rounded : Icons.cancel_rounded;
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

  // Boundary violation banner — shows while the vehicle is outside the radius.
  Widget _boundaryBanner() {
    if (!_outsideBoundary) return const SizedBox.shrink();

    final text =
        '🚧  OUTSIDE BOUNDARY (${_boundaryBeyondM.toStringAsFixed(0)} m)';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFDC2626).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // Small live diagnostics strip (EAR / HEAD / STATUS) like driving_hud_view.
  // Widget _monitorDiag() {
  //   return Container(
  //     margin: const EdgeInsets.all(12),
  //     padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
  //     decoration: BoxDecoration(
  //       color: Colors.black.withValues(alpha: 0.75),
  //       borderRadius: BorderRadius.circular(14),
  //     ),
  //     child: Column(
  //       crossAxisAlignment: CrossAxisAlignment.start,
  //       mainAxisSize: MainAxisSize.min,
  //       children: [
  //         _diagRow(
  //           'EAR',
  //           'L:${_state.leftEar.toStringAsFixed(3)}  R:${_state.rightEar.toStringAsFixed(3)}  Thr:${_state.earThreshold.toStringAsFixed(3)}',
  //         ),
  //         _diagRow(
  //           'HEAD',
  //           'Yaw:${_state.yaw.toStringAsFixed(1)}°  Pitch:${_state.pitch.toStringAsFixed(1)}°',
  //         ),
  //         _diagRow(
  //           'STATUS',
  //           '${_state.drowsinessLevel.name.toUpperCase()} | ${_state.distractionStatus.name.toUpperCase()}',
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // Widget _diagRow(String label, String value) {
  //   return Padding(
  //     padding: const EdgeInsets.symmetric(vertical: 2),
  //     child: Row(
  //       children: [
  //         SizedBox(
  //           width: 56,
  //           child: Text(
  //             label,
  //             style: const TextStyle(
  //               color: Colors.cyanAccent,
  //               fontSize: 11,
  //               fontWeight: FontWeight.w700,
  //             ),
  //           ),
  //         ),
  //         Expanded(
  //           child: Text(
  //             value,
  //             style: const TextStyle(color: Colors.white70, fontSize: 11),
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  Widget _deviceMotionCard() {
    final detector = _reversingDetector;
    if (detector == null) return const SizedBox.shrink();

    // Determine state
    final isRev = detector.isReversing;
    final speed = detector.gpsSpeed; // m/s
    final speedKmH = speed * 3.6;
    final isMoving = speed > 0.3; // threshold for moving

    final Color stateColor;
    final String stateLabel;
    final IconData stateIcon;

    if (isRev) {
      stateColor = Colors.redAccent;
      stateLabel = "REVERSING";
      stateIcon = Icons.arrow_back_rounded;
    } else if (isMoving) {
      stateColor = Colors.greenAccent;
      stateLabel = "MOVING FORWARD";
      stateIcon = Icons.arrow_forward_rounded;
    } else {
      stateColor = Colors.blueAccent;
      stateLabel = "STATIONARY";
      stateIcon = Icons.pause_rounded;
    }

    final double rawZ = detector.currentZ;
    final double compass = detector.compassHeading;
    final double gpsHeading = detector.gpsHeading;
    final bool isCalib = detector.isCalibrated;

    return Container(
      margin: const EdgeInsets.only(left: 12, right: 12, top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: stateColor.withValues(alpha: 0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: stateColor.withValues(alpha: 0.1),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Header / Current State
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(stateIcon, color: stateColor, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    stateLabel,
                    style: TextStyle(
                      color: stateColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isCalib
                      ? Colors.green.withValues(alpha: 0.2)
                      : Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isCalib ? "COMPASS CALIBRATED" : "COMPASS UNCALIBRATED",
                  style: TextStyle(
                    color: isCalib ? Colors.greenAccent : Colors.amberAccent,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Row 2: Metrics Grid
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Z-Acceleration
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "IMU Z-ACCEL",
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${rawZ.toStringAsFixed(2)} m/s²",
                      style: TextStyle(
                        color: rawZ.abs() > 0.4
                            ? Colors.amberAccent
                            : Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

              // GPS Speed
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "GPS SPEED",
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${speedKmH.toStringAsFixed(1)} km/h",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

              // Direction Angles
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "COMPASS / GPS",
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${compass.toStringAsFixed(0)}° / ${gpsHeading.toStringAsFixed(0)}°",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _reportBoundaryViolation(
      double distanceFromBoundaryMeters,
      ) async {
    if (!_isOnline) {
      debugPrint('[Boundary] Offline — violation not sent.');
      return;
    }
    final deviceId = _settings.getDeviceId();
    if (deviceId == null || deviceId.isEmpty) return;

    await _geofenceService.reportViolation(
      vehicleId: _vehicleId,
      driverId: _driverId == '—' ? null : _driverId,
      geofenceId: _geofenceId,
      latitude: _state.gpsLat,
      longitude: _state.gpsLng,
      vehicleSpeed: _state.vehicleSpeed,
      distanceFromBoundaryMeters: distanceFromBoundaryMeters,
      deviceTabletId: deviceId,
      occurredAt: DateTime.now().toUtc(),
    );
  }
}

// ─────────────────────────────────────────────────────────
// BREAK ALERT TOAST
// ─────────────────────────────────────────────────────────

class _BreakToastWidget extends StatefulWidget {
  final Map<String, String> msg;
  const _BreakToastWidget({required this.msg});

  @override
  State<_BreakToastWidget> createState() => _BreakToastWidgetState();
}

class _BreakToastWidgetState extends State<_BreakToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glanceCtrl;
  late final Animation<double> _glance;

  @override
  void initState() {
    super.initState();
    _glanceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _glance = CurvedAnimation(parent: _glanceCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _glanceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOut,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(0, 20 * (1 - t)),
        child: Opacity(opacity: t, child: child),
      ),
      child: AnimatedBuilder(
        animation: _glance,
        builder: (context, child) =>
            Opacity(opacity: 0.70 + 0.30 * _glance.value, child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.msg['emoji']!, style: const TextStyle(fontSize: 30)),
            const SizedBox(height: 4),
            Text(
              widget.msg['title']!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                shadows: [
                  Shadow(color: Color(0xFF38BDF8), blurRadius: 10),
                  Shadow(color: Color(0xFF38BDF8), blurRadius: 22),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              widget.msg['sub']!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanningPulse extends StatefulWidget {
  const _ScanningPulse({required this.child});
  final Widget child;

  @override
  State<_ScanningPulse> createState() => _ScanningPulseState();
}

class _ScanningPulseState extends State<_ScanningPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Fixed size; scale + opacity maathram maaru -> paint only, relayout ILLA.
  Widget _ring(double t) {
    final scale = 1.0 + t * 0.6;
    final opacity = (1.0 - t).clamp(0.0, 1.0) * 0.55;
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF3B82F6).withValues(alpha: opacity),
            width: 3,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: 240,
        height: 240,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                final t = _c.value;
                return Stack(
                  alignment: Alignment.center,
                  children: [_ring(t), _ring((t + 0.5) % 1.0)],
                );
              },
            ),
            RepaintBoundary(child: widget.child),
          ],
        ),
      ),
    );
  }
}

class _FaceScannerLine extends StatefulWidget {
  final Color color;
  const _FaceScannerLine({required this.color});

  @override
  State<_FaceScannerLine> createState() => _FaceScannerLineState();
}

class _FaceScannerLineState extends State<_FaceScannerLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.0, end: 260.0).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Positioned(
          top: _animation.value,
          left: 0,
          right: 0,
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.8),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
              gradient: LinearGradient(
                colors: [
                  widget.color.withValues(alpha: 0.1),
                  widget.color,
                  widget.color.withValues(alpha: 0.1),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScannerCorner extends StatelessWidget {
  final bool isTop;
  final bool isLeft;
  final Color color;

  const _ScannerCorner({
    required this.isTop,
    required this.isLeft,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    const double length = 20.0;
    const double thickness = 4.0;
    return SizedBox(
      width: length,
      height: length,
      child: Stack(
        children: [
          Positioned(
            left: isLeft ? 0 : null,
            right: !isLeft ? 0 : null,
            top: isTop ? 0 : null,
            bottom: !isTop ? 0 : null,
            child: Container(
              width: length,
              height: thickness,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Positioned(
            left: isLeft ? 0 : null,
            right: !isLeft ? 0 : null,
            top: isTop ? 0 : null,
            bottom: !isTop ? 0 : null,
            child: Container(
              width: thickness,
              height: length,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ESP CAMERA SCANNER SCREEN (opened via PIN "0000")
// ═══════════════════════════════════════════════════════════════════════════════

class _EspFoundDevice {
  final String ip;
  final int port;
  final String label;
  _EspFoundDevice({required this.ip, required this.port, required this.label});
}

class _EspScannerScreen extends StatefulWidget {
  final void Function(String ip, String slot) onDeviceAssigned;
  const _EspScannerScreen({required this.onDeviceAssigned});

  @override
  State<_EspScannerScreen> createState() => _EspScannerScreenState();
}

class _EspScannerScreenState extends State<_EspScannerScreen> {
  bool _scanning = false;
  List<_EspFoundDevice> _devices = [];
  String? _error;

  // IPs that have been Allowed + successfully connected. The row button shows
  // "Connected" for these instead of "Connect".
  final Set<String> _connectedIps = {};

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _devices = [];
      _error = null;
    });

    try {
      final results = await _scanSubnetForEsp();
      if (mounted) {
        setState(() {
          _devices = results;
          _scanning = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _scanning = false;
        });
      }
    }
  }

  Future<List<_EspFoundDevice>> _scanSubnetForEsp() async {
    // Collect EVERY IPv4 subnet the phone is on. When the phone is the HOTSPOT
    // HOST, it has TWO interfaces: its own Wi-Fi (e.g. 10.57.5.x) AND the
    // hotspot interface where the ESPs actually live (usually 192.168.x.x).
    // Scanning only the first subnet misses the ESPs — so scan them all.
    final Set<String> subnets = {};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4 && parts[0] != '127') {
            final sub = '${parts[0]}.${parts[1]}.${parts[2]}';
            subnets.add(sub);
            debugPrint(
              '[EspScan] Interface ${iface.name} → ${addr.address} (subnet $sub.*)',
            );
          }
        }
      }
    } catch (e) {
      throw 'Cannot determine local subnet: $e';
    }

    if (subnets.isEmpty) throw 'No local network found';
    debugPrint('[EspScan] Scanning ${subnets.length} subnet(s): $subnets');

    // Ports to probe for ESP32 cameras / sensors.
    const probePorts = [80, 81, 82, 83, 84, 85, 86, 87, 90, 91, 92, 93];

    final List<_EspFoundDevice> found = [];

    // Scan EVERY discovered subnet.
    for (final sub in subnets) {
      for (int start = 1; start <= 254; start += 50) {
        final end = (start + 49).clamp(1, 254);
        final futures = <Future<_EspFoundDevice?>>[];
        for (int i = start; i <= end; i++) {
          final ip = '$sub.$i';
          futures.add(_probeIp(ip, probePorts));
        }
        final results = await Future.wait(futures);
        for (final device in results) {
          if (device != null) found.add(device);
        }
      }
    }

    debugPrint('[EspScan] Total ESP devices found: ${found.length}');
    return found;
  }

  Future<_EspFoundDevice?> _probeIp(String ip, List<int> ports) async {
    for (final port in ports) {
      try {
        final socket = await Socket.connect(
          ip,
          port,
        ).timeout(const Duration(milliseconds: 600));
        await socket.close();

        // Try to get a label from sensor endpoint
        String label = 'ESP32 @ port $port';
        try {
          final res = await http
              .get(Uri.parse('http://$ip:$port/sensor'))
              .timeout(const Duration(milliseconds: 800));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            if (data.containsKey('device')) {
              label = data['device'].toString();
            } else if (data.containsKey('distance_cm')) {
              label = 'Sensor @ port $port (${data['distance_cm']} cm)';
            }
          }
        } catch (_) {}

        return _EspFoundDevice(ip: ip, port: port, label: label);
      } catch (_) {}
    }
    return null;
  }

  // Quick reachability test so we can confirm the device is really connected.
  Future<bool> _testReachable(String ip, int port) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
      ).timeout(const Duration(seconds: 2));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  // // Maps the port a device answered on to its camera slot.
  // String _slotForPort(int port) {
  //   switch (port) {
  //     case 86:
  //       return 'Left';
  //     case 80:
  //       return 'Right';
  //     case 84:
  //       return 'Front';
  //     case 82:
  //     default:
  //       return 'Rear';
  //   }
  // }

  // Maps the port a device answered on to its camera slot (video OR sensor port).
  String _slotForPort(int port) {
    switch (port) {
      case 86: // left video
      case 87: // left sensor
        return 'Left';
      case 80: // right video
      case 81: // right sensor
        return 'Right';
      case 84: // front video
      case 85: // front sensor
        return 'Front';
      case 82: // rear video
      case 83: // rear sensor
      default:
        return 'Rear';
    }
  }

  void _showAllowDialog(_EspFoundDevice device) {
    bool allowChecked = false;
    bool connecting = false;
    String selectedSlot = _slotForPort(device.port); // auto-detect from port

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: const Text(
                'Allow Device',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${device.ip} : ${device.port}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 12),
                  // ── Slot selector (auto-detected from port; change if wrong) ──
                  Row(
                    children: [
                      const Text(
                        'Position: ',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: selectedSlot,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(color: Colors.white),
                        items: const ['Rear', 'Left', 'Right', 'Front']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                        )
                            .toList(),
                        onChanged: connecting
                            ? null
                            : (v) => setDialogState(
                              () => selectedSlot = v ?? selectedSlot,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // ── Checkbox ──
                  CheckboxListTile(
                    value: allowChecked,
                    activeColor: const Color(0xFF22C55E),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'Allow this camera to connect',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    onChanged: connecting
                        ? null
                        : (v) =>
                        setDialogState(() => allowChecked = v ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: connecting ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: (!allowChecked || connecting)
                      ? null
                      : () async {
                    setDialogState(() => connecting = true);
                    // Assign to the CHOSEN slot (not always Rear).
                    widget.onDeviceAssigned(device.ip, selectedSlot);
                    final ok = await _testReachable(
                      device.ip,
                      device.port,
                    );
                    if (ok) _connectedIps.add(device.ip);
                    if (mounted) setState(() {});
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Connected ${device.ip} as $selectedSlot'
                                : 'Allowed ${device.ip} ($selectedSlot) — not reachable yet',
                          ),
                          backgroundColor: ok
                              ? const Color(0xFF16A34A)
                              : const Color(0xFFD97706),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF334155),
                  ),
                  child: connecting
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                      : const Text('Allow'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // // Connect button -> shows a dialog box with a CHECKBOX + "Allow" button.
  // // Tick the checkbox, tap Allow -> connect the device. If it becomes
  // // reachable, the row button switches to "Connected".
  // void _showAllowDialog(_EspFoundDevice device) {
  //   bool allowChecked = false;
  //   bool connecting = false;

  //   showDialog<void>(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (ctx) {
  //       return StatefulBuilder(
  //         builder: (ctx, setDialogState) {
  //           return AlertDialog(
  //             backgroundColor: const Color(0xFF1E293B),
  //             title: const Text(
  //               'Allow Device',
  //               style: TextStyle(color: Colors.white),
  //             ),
  //             content: Column(
  //               mainAxisSize: MainAxisSize.min,
  //               crossAxisAlignment: CrossAxisAlignment.start,
  //               children: [
  //                 Text(
  //                   device.label,
  //                   style: const TextStyle(
  //                     color: Colors.white,
  //                     fontWeight: FontWeight.w700,
  //                   ),
  //                 ),
  //                 const SizedBox(height: 4),
  //                 Text(
  //                   device.ip,
  //                   style: const TextStyle(color: Colors.white54),
  //                 ),
  //                 const SizedBox(height: 12),
  //                 // ── Checkbox ──
  //                 CheckboxListTile(
  //                   value: allowChecked,
  //                   activeColor: const Color(0xFF22C55E),
  //                   contentPadding: EdgeInsets.zero,
  //                   controlAffinity: ListTileControlAffinity.leading,
  //                   title: const Text(
  //                     'Allow this camera to connect',
  //                     style: TextStyle(color: Colors.white70, fontSize: 14),
  //                   ),
  //                   onChanged: connecting
  //                       ? null
  //                       : (v) {
  //                           setDialogState(() => allowChecked = v ?? false);
  //                         },
  //                 ),
  //               ],
  //             ),
  //             actions: [
  //               TextButton(
  //                 onPressed: connecting ? null : () => Navigator.pop(ctx),
  //                 child: const Text('Cancel'),
  //               ),
  //               // ── Allow button (enabled only when checkbox ticked) ──
  //               ElevatedButton(
  //                 onPressed: (!allowChecked || connecting)
  //                     ? null
  //                     : () async {
  //                         setDialogState(() => connecting = true);

  //                         // Notify parent -> connects this ESP as the rear stream.
  //                         widget.onDeviceAssigned(device.ip, 'Rear');

  //                         // Confirm it's actually reachable.
  //                         final ok = await _testReachable(
  //                           device.ip,
  //                           device.port,
  //                         );
  //                         if (ok) {
  //                           _connectedIps.add(device.ip);
  //                         }
  //                         if (mounted) setState(() {});

  //                         if (ctx.mounted) Navigator.pop(ctx);
  //                         if (mounted) {
  //                           ScaffoldMessenger.of(context).showSnackBar(
  //                             SnackBar(
  //                               content: Text(
  //                                 ok
  //                                     ? 'Connected ${device.ip}'
  //                                     : 'Allowed ${device.ip} — not reachable yet',
  //                               ),
  //                               backgroundColor: ok
  //                                   ? const Color(0xFF16A34A)
  //                                   : const Color(0xFFD97706),
  //                               duration: const Duration(seconds: 2),
  //                             ),
  //                           );
  //                         }
  //                       },
  //                 style: ElevatedButton.styleFrom(
  //                   backgroundColor: const Color(0xFF22C55E),
  //                   foregroundColor: Colors.white,
  //                   disabledBackgroundColor: const Color(0xFF334155),
  //                 ),
  //                 child: connecting
  //                     ? const SizedBox(
  //                         width: 18,
  //                         height: 18,
  //                         child: CircularProgressIndicator(
  //                           strokeWidth: 2,
  //                           color: Colors.white,
  //                         ),
  //                       )
  //                     : const Text('Allow'),
  //               ),
  //             ],
  //           );
  //         },
  //       );
  //     },
  //   );
  // }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'ESP32 Camera Scanner',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        // actions: [
        //   if (!_scanning)
        //     IconButton(
        //       icon: const Icon(Icons.refresh_rounded),
        //       onPressed: _startScan,
        //       tooltip: 'Rescan',
        //     ),
        // ],
      ),
      body: _scanning
          ? const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF3B82F6)),
            SizedBox(height: 20),
            Text(
              'Scanning for ESP cameras...',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Probing local subnet (1-254)',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      )
          : _error != null
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.redAccent,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      )
          : _devices.isEmpty
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.wifi_find_rounded,
              color: Colors.white38,
              size: 64,
            ),
            const SizedBox(height: 16),
            const Text(
              'No ESP cameras found on this network',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Rescan'),
            ),
          ],
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _devices.length,
        itemBuilder: (context, index) {
          final device = _devices[index];
          final connected = _connectedIps.contains(device.ip);
          return Card(
            color: const Color(0xFF1E293B),
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: connected
                  ? const BorderSide(color: Color(0xFF22C55E), width: 1.5)
                  : BorderSide.none,
            ),
            child: ListTile(
              leading: Icon(
                connected
                    ? Icons.check_circle_rounded
                    : Icons.videocam_rounded,
                color: const Color(0xFF22C55E),
                size: 32,
              ),
              title: Text(
                device.ip,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                device.label,
                style: const TextStyle(color: Colors.white54),
              ),
              trailing: connected
              // ── After connect: show "Connected" button (green) ──
                  ? ElevatedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.check_circle, size: 18),
                label: const Text('Connected'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF22C55E),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF22C55E),
                  disabledForegroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              )
              // ── Before connect: "Connect" button opens the dialog ──
                  : ElevatedButton(
                onPressed: () => _showAllowDialog(device),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Connect'),
              ),
            ),
          );
        },
      ),
    );
  }
}

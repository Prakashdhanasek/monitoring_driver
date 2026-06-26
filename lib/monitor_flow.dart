import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image/image.dart' as img;
import 'package:battery_plus/battery_plus.dart';
import 'package:monitoring_driver/kiosk.dart';
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

import 'services/reversing_detector_service.dart';
import 'views/reversing_camera_overlay.dart';
import 'views/cam_detection_panel.dart';

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

  // ── Connectivity tracking ──
  bool _isOnline = true;
  Timer? _connectivityTimer;
  Timer? _telemetryTimer;
  Timer? _sensorUiTimer;

  bool _isConnectingToEsp32 = false;
  bool _isConnectedToEsp32 = false;
  // True when REAR was opened via the REAR button (manual). Reverting clears this.
  bool _rearManualOverride = false;
  // True when FRONT was opened manually (top button or banner button). Prevents
  // _pollBlindSpotSensors from auto-closing the panel when the sensor reads clear.
  bool _frontManualOverride = false;

  ReversingDetectorService? _reversingDetector;
  // ── Single active camera mode ─────────────────────────────────────────────
  // Only one of these runs at a time. Switching away from driverMonitoring
  // stops the phone image stream so face/object detection is fully paused.
  CamMode _camMode = CamMode.driverMonitoring;
  // String _esp32StreamUrl = 'http://10.119.135.95:82/';

  String _esp32StreamUrl = 'http://192.168.1.131:82/';

  // ── Side cameras (blind spot)
  // Left cam  — video :86,  sensor :87
  // Right cam  — video :80,  sensor :81
  // Front cam  — video :84,  sensor :85
  // Rear cam   — video :82,  sensor :83
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

  String? _leftCamIp = '192.168.1.61'; // video :86  sensor :87
  String? _rightCamIp = '192.168.1.129'; // video :80  sensor :81
  String? _frontCamIp = '192.168.1.130'; // video :84  sensor :85
  // (resolved by scanner, not shown in strict mode)
  DateTime? _lastSideCamScanAt; // throttle scanner to once per 60 s
  Timer? _blindSpotTimer;
  bool _isPollingBlindSpot = false;

  // Flow
  Phase _phase = Phase.verifying;
  bool _initializing = true;
  bool _camReady = false;
  bool _busy = false;
  bool _streaming = false;
  int _frame = 0;

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
  String? _activeBannerKey;
  DateTime? _activeBannerAt;
  static const Duration _kBannerVisibleDuration = Duration(seconds: 5);

  // Still face image captured at the moment of successful verification.
  Uint8List? _capturedFace;

  // Latest camera frame as JPEG — updated every object detection frame.
  // Used for incident snapshots so the correct detection-time image is uploaded.
  Uint8List? _latestFrameJpeg;

  // Rolling buffer of the last 15 JPEG frames (~5 seconds at 3 fps) for incident video.
  final List<Uint8List> _recentFrames = [];

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

  // ── Cable / charging monitor ──
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySub;
  bool _cableUnplugged = false;
  bool _showCableBanner = false;
  Timer? _cableBannerTimer;
  DateTime? _lastCableReportAt;

  // ── Screenshot flash (alert varumbol screenshot effect) ──
  bool _flashScreenshot = false;
  DateTime? _lastFlashAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitoringEngine = MonitoringEngine(_state);
    _tts.init();
    WakelockPlus.enable();
    _init();

    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _syncIncidentsTask();
      _maybeReReportCable();
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

    // Refresh UI every 200 ms for real-time sensor/direction telemetry.
    _sensorUiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _phase == Phase.monitoring) {
        setState(() {});
      }
    });

    _initBatteryMonitor();

    // Resolve cam IPs after 10 s so app startup isn't flooded with 150+
    // concurrent subnet probe requests the moment the app opens.
    // Future.delayed(const Duration(seconds: 10), _resolveSideCamIps);

    // Blind spot sensor polling every 500 ms
    _blindSpotTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _pollBlindSpotSensors();
    });
  }

  Future<void> _checkConnectivity() async {
    try {
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
          _triggerSftpUpload();
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

  // ─────────────────────────────────────────────────────────
  // CABLE / CHARGING MONITOR
  // ─────────────────────────────────────────────────────────
  Future<void> _initBatteryMonitor() async {
    // Set up listener first — even if initial state check fails
    try {
      _batterySub = _battery.onBatteryStateChanged.listen(
        _onBatteryStateChanged,
      );
    } catch (e) {
      debugPrint('[Flow] battery listener setup error: $e');
    }

    // Then check initial state
    try {
      final initial = await _battery.batteryState;
      debugPrint('[Flow] 🔋 Initial battery state: $initial');
      _cableUnplugged = _isUnplugged(initial);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[Flow] battery initial state error: $e');
    }
  }

  bool _isUnplugged(BatteryState state) {
    // Charging or full means cable is connected
    if (state == BatteryState.charging || state == BatteryState.full) {
      return false;
    }
    // Discharging or unknown means cable is NOT connected
    // (some devices report unknown instead of discharging on unplug)
    return true;
  }

  void _onBatteryStateChanged(BatteryState state) {
    debugPrint('[Flow] 🔋 Battery state changed: $state');

    final nowUnplugged = _isUnplugged(state);

    if (nowUnplugged && !_cableUnplugged) {
      _cableUnplugged = true;
      debugPrint('[Flow] ⚠️ Charging cable UNPLUGGED.');

      // FIX: Only report cable-unplug incident if a driver is verified.
      // Before face verification, we have no confirmed driver — sending an
      // incident would attach a blank image and possibly a stale driver name.
      if (_phase == Phase.monitoring && _driverId != '—') {
        _reportIncident('Cable Unplugged', 'High', 1.0);
        _lastCableReportAt = DateTime.now();
      } else {
        debugPrint(
          '[Flow] Skipping cable-unplug incident — no verified driver yet.',
        );
      }

      // Show banner for 5 seconds only
      _showCableBanner = true;
      _cableBannerTimer?.cancel();
      _cableBannerTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _showCableBanner = false);
      });

      _playAlert('audio/alert_loud.mp3');
      _tts.speak('Warning. Charging cable unplugged.');
      if (mounted) setState(() {});
    } else if (!nowUnplugged && _cableUnplugged) {
      _cableUnplugged = false;
      _showCableBanner = false;
      _cableBannerTimer?.cancel();
      _lastCableReportAt = null;
      debugPrint('[Flow] Charging cable reconnected.');
      if (mounted) setState(() {});
    }
  }

  void _maybeReReportCable() {
    if (!_cableUnplugged) return;
    // FIX: Don't re-report cable unplug unless driver is verified and monitoring
    if (_phase != Phase.monitoring || _driverId == '—') return;
    final last = _lastCableReportAt;
    if (last == null || DateTime.now().difference(last).inSeconds >= 30) {
      _lastCableReportAt = DateTime.now();
      _reportIncident('Cable Unplugged', 'High', 1.0);
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _connectivityTimer?.cancel();
    _telemetryTimer?.cancel();
    _sensorUiTimer?.cancel();
    _countdownTimer?.cancel();
    _cableBannerTimer?.cancel();
    _batterySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _detector?.close();
    _objectDetector.dispose();
    _player.dispose();
    _tts.dispose();
    WakelockPlus.disable();
    _ffmpegRecorderService.stopRecording();
    _espWifiService.disconnectFromEsp32();
    _reversingDetector?.dispose();
    _blindSpotTimer?.cancel();
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

    const String targetSsid = 'BB SF ASIANET-2.4G';
    // String streamUrl = 'http://10.119.135.95:82/';
    // String esp32Host = '10.119.135.95';
    // const int esp32Port = 82;

    String streamUrl = 'http://192.168.1.131:82/';
    String esp32Host = '192.168.1.131';
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
      final apConnected = await _espWifiService.connectToEsp32(targetSsid);
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
      '[Esp32Wifi] ✓ On Wi-Fi: $currentSsid. Testing ESP32 camera reachability...',
    );

    // Step 3: Resolve mDNS (.local) natively since Android doesn't support it
    if (esp32Host.endsWith('.local')) {
      if (Platform.isAndroid) {
        debugPrint(
          '[ESP32] Platform is Android. Resolving via ARP table lookup...',
        );
        final arpIp = await _findEsp32IpFromArpTable();
        if (arpIp != null) {
          esp32Host = arpIp;
          streamUrl = 'http://$esp32Host:82/';
          debugPrint('[ESP32] ✓ Resolved via ARP table to IP: $esp32Host');
        } else {
          debugPrint('[ESP32] ✗ ARP table lookup did not find ESP32.');
        }
      } else {
        debugPrint('[ESP32] Resolving mDNS for $esp32Host...');
        try {
          final MDnsClient client = MDnsClient();
          await client.start();
          await for (final IPAddressResourceRecord record
              in client
                  .lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(esp32Host),
                  )
                  .timeout(const Duration(seconds: 4))) {
            esp32Host = record.address.address;
            streamUrl = 'http://$esp32Host:82/';
            debugPrint('[ESP32] ✓ Resolved mDNS to IP: $esp32Host');
            break;
          }
          client.stop();
        } catch (e) {
          debugPrint('[ESP32] ✗ mDNS resolution failed: $e');
        }
      }
    }

    // Step 4: TCP test — verify ESP32-CAM host is reachable on port 80
    bool cameraReachable = false;
    try {
      final socket = await Socket.connect(
        esp32Host,
        esp32Port,
      ).timeout(const Duration(seconds: 3));
      await socket.close();
      cameraReachable = true;
      debugPrint('[ESP32] ✓ Camera reachable at $esp32Host:$esp32Port');
      debugPrint('==================================================');
    } catch (e) {
      debugPrint(
        '[ESP32] ✗ Initial camera check failed at $esp32Host:$esp32Port: $e',
      );
      if (Platform.isAndroid) {
        debugPrint(
          '[ESP32] Scanning ARP table as fallback to find responsive ESP32 IP...',
        );
        final arpIp = await _findEsp32IpFromArpTable();
        if (arpIp != null && arpIp != esp32Host) {
          debugPrint(
            '[ESP32] Found potential fallback IP in ARP: $arpIp. Verifying reachability...',
          );
          try {
            final socket = await Socket.connect(
              arpIp,
              esp32Port,
            ).timeout(const Duration(seconds: 3));
            await socket.close();
            esp32Host = arpIp;
            streamUrl = 'http://$esp32Host:82/';
            cameraReachable = true;
            debugPrint(
              '[ESP32] ✓ Fallback camera reachable at $esp32Host:$esp32Port',
            );
          } catch (fallbackErr) {
            debugPrint(
              '[ESP32] ✗ Fallback camera check failed at $arpIp:$esp32Port: $fallbackErr',
            );
          }
        }
      }
      if (!cameraReachable) {
        cameraReachable = false;
        debugPrint('==================================================');
        debugPrint(
          '[ESP32] ✗ Camera check failed/timeout at $esp32Host:$esp32Port: $e',
        );
        debugPrint('==================================================');
      }
    }

    if (mounted) {
      setState(() {
        _isConnectingToEsp32 = false;
        // Mark as connected/attempting so UI reflects status
        _isConnectedToEsp32 = cameraReachable;
        _esp32StreamUrl = streamUrl;
      });
    }
  }

  Future<void> _triggerSftpUpload() async {
    debugPrint('[Flow] Online. Starting SFTP background upload...');
    await _sftpUploadService.uploadPendingFiles('/var/www/uploads/videos');
  }

  Future<void> _init() async {
    // Clear old queued incidents to start fresh with new schema/details
    try {
      await _incidentsService.clearAll();
      debugPrint('[Flow] Cleared old queued incidents for new schema.');
    } catch (e) {
      debugPrint('[Flow] Error clearing incidents queue: $e');
    }

    // ── FIX: Clear all cached driver data on every app start (login) ──
    // This prevents stale driver names from a previous session showing up.
    try {
      await _driversService.clearCache();
      debugPrint('[Flow] Cleared stale driver cache on init.');
    } catch (e) {
      debugPrint('[Flow] Error clearing driver cache: $e');
    }
    // Reset in-memory driver state to defaults
    _driverId = '—';
    _driverName = 'Driver';
    _vehicleId = null;
    _vehicleRegNo = null;

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
    _connectToEsp32Wifi();

    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _requestPermissions() async {
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
  Future<void> _processImage(CameraImage image) async {
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
              // Capture current frame for incident snapshot and video buffer
              final jpeg = _captureFaceJpeg(image);
              if (jpeg != null) {
                _latestFrameJpeg = jpeg;
                _recentFrames.add(jpeg);
                if (_recentFrames.length > 15) {
                  _recentFrames.removeAt(0); // Maintain max 15 frames (~5s)
                }
              }
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
              _sendTripEnd();
              // _showVerifyToast();
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

  void _onVerified() {
    if (_phase != Phase.verifying) return;
    _tripNumber++; // trip 1 on first verify, trip 2 after a completed trip, ...

    // API-driven identity only. FaceAuthEngine returns the matched label as
    // "driverId|driverName" (built from the downloaded photo filename).
    // Prefer the live API driver name from cache when available.
    final label = _authEngine.lastMatchedLabel;
    String driverId = '—';
    String driverName = 'Driver';

    if (label != null && label.isNotEmpty) {
      if (label.contains('|')) {
        final parts = label.split('|');
        driverId = parts.isNotEmpty ? parts[0] : '—';
        driverName = parts.length > 1 ? parts.sublist(1).join('|') : 'Driver';
      } else {
        driverId = label;
      }
    }

    try {
      final driver = _driversService.getDriverById(driverId);
      if (driver != null && driver.isNotEmpty) {
        final apiName = driver['fullName'] as String?;
        if (apiName != null && apiName.isNotEmpty) {
          driverName = apiName;
        }
        _vehicleId = driver['assignedVehicleId'] as String?;
        _vehicleRegNo = driver['vehicleRegistrationNumber'] as String?;
      }
    } catch (e) {
      debugPrint('[Flow] Error resolving driver vehicle details: $e');
    }

    _driverId = driverId;
    _driverName = driverName;
    _phase = Phase.details;
    _countdown = 3;
    if (mounted) setState(() {});

    // Face verification voice alert.
    _tts.speak('Welcome $_driverName. Identity verified.');

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _countdown--;
      if (_countdown <= 0) {
        t.cancel();
        // Start fresh calibration for the monitoring session.
        _state.resetCalibration();
        _phase = Phase.monitoring;
        _sendTripStart();
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
    _authEngine.resetLiveAuthState();
    _authEngine.lastMatchedLabel = null;
    _driverId = '—';
    _driverName = 'Driver';
    _phase = Phase.verifying;
  }

  Future<void> _sendTripStart() async {
    try {
      final deviceId = _settings.getDeviceId();
      if (deviceId == null || deviceId.isEmpty) return;

      await _tripService.startTrip(
        deviceTabletId: deviceId,
        driverId: _driverId == '—' ? null : _driverId,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        startedAt: DateTime.now().toUtc(),
      );
    } catch (e) {
      debugPrint('[Flow] Failed to send trip start: $e');
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

      // Ella alert-inum screenshot effect kaanikkuka.
      _showScreenshotFlash();

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
          await file.writeAsBytes(_latestFrameJpeg!);
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

      // FIX: Never create an incident before face verification is complete.
      // This prevents blank images and stale/random driver names from being sent.
      if (_phase != Phase.monitoring || _driverId == '—') {
        debugPrint(
          '[Flow] Skipping incident "$eventType" — driver not verified (phase=$_phase, id=$_driverId).',
        );
        return;
      }

      // FIX: Never upload a blank/empty image as evidence.
      if (snapshotPath.isEmpty) {
        debugPrint(
          '[Flow] Skipping incident "$eventType" — no valid snapshot available.',
        );
        return;
      }

      _incidentsService.queueIncident(
        deviceTabletId: deviceId,
        eventType: eventType,
        riskLevel: riskLevel,
        aiConfidence: confidence,
        vehicleSpeed: _state.vehicleSpeed,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        driverId: _driverId,
        driverName: _driverName,
        vehicleId: _vehicleId,
        vehicleRegistrationNumber: _vehicleRegNo,
        snapshotUrl: '',
        snapshotPath: snapshotPath,
        videoClipUrl: '', // Let IncidentsService upload the file and fill this
        videoPath: videoPath, // Pass the path to the video file
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

  Future<void> _sendTripEnd() async {
    try {
      final deviceId = _settings.getDeviceId();
      if (deviceId == null || deviceId.isEmpty) return;

      await _tripService.endTrip(
        deviceTabletId: deviceId,
        gpsLatitude: _state.gpsLat,
        gpsLongitude: _state.gpsLng,
        distanceKm: 0,
        endedAt: DateTime.now().toUtc(),
      );
    } catch (e) {
      debugPrint('[Flow] Failed to send trip end: $e');
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

      // Write frames to disk
      for (int i = 0; i < frames.length; i++) {
        final file = File(
          '${tempDir.path}/img${i.toString().padLeft(3, '0')}.jpg',
        );
        await file.writeAsBytes(frames[i]);
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

  Future<void> _syncIncidentsTask() async {
    if (!mounted) return;
    debugPrint(
      '[Flow] Triggering sync of pending incidents (connection: ${_isOnline ? "ONLINE" : "OFFLINE"})...',
    );
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
  bool _checkCooldown(String label) {
    final now = DateTime.now();
    final lastTime = _lastIncidentReportAt[label];
    // 5 minutes cooldown for ALL distractions/incidents
    if (lastTime == null || now.difference(lastTime).inSeconds >= 5 * 60) {
      _lastIncidentReportAt[label] = now;
      return true;
    }
    return false;
  }

  void _handleAlertSounds() {
    final now = DateTime.now();
    final phone = _state.hasPhone;
    final smoke = _state.hasCigarette;

    bool loud = false;
    bool soft = false;

    // 1. Fire on state-based warnings (throttled by cooldown).
    if (_state.authStatus == AuthStatus.unauthorized) {
      if (_checkCooldown('UnauthorizedDriver')) {
        loud = true;
        _reportIncident('Unauthorized Driver', 'High', 1.0);
        _tts.speak('Unauthorized driver detected.');
      }
    }
    if (_state.drowsinessLevel == DrowsinessLevel.asleep) {
      if (_checkCooldown('Asleep')) {
        loud = true;
        _reportIncident('Drowsiness', 'High', 1.0);
        _tts.speak('Warning! Wake up. You are falling asleep.');
      }
    }
    if (_state.drowsinessLevel == DrowsinessLevel.drowsy) {
      if (_checkCooldown('Drowsiness')) {
        soft = true;
        _reportIncident('Drowsiness', 'Medium', 0.8);
        _tts.speak('You look drowsy. Stay alert.');
      }
    }
    if (_state.distractionStatus == DistractionStatus.distracted) {
      if (_checkCooldown('Distraction')) {
        soft = true;
        _reportIncident('Distraction', 'Medium', 0.8);
        _tts.speak('Keep your eyes on the road.');
      }
    }

    // 2. Report only high-confidence object detections at intervals.
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

      if (_checkCooldown(label)) {
        String eventType = label;
        String voice = '';
        if (label == 'phone') {
          eventType = 'Phone Usage';
          voice = 'Please put your phone down.';
        }
        if (label == 'cigarette') {
          eventType = 'Smoking';
          voice = 'No smoking while driving.';
        }
        if (label == 'eating') {
          eventType = 'Eating';
          voice = 'Please do not eat while driving.';
        }
        if (label == 'drinking') {
          eventType = 'Drinking';
          voice = 'Please do not drink while driving.';
        }

        _reportIncident(eventType, 'High', obj.confidence);
        if (voice.isNotEmpty) _tts.speak(voice);
        loud = true;
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
      // Only restart the phone cam if we're in driver monitoring mode.
      if (!_streaming && _camReady && _camMode == CamMode.driverMonitoring) {
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
          if (_phase == Phase.verifying) _verifyingOverlay(),
          if (_phase == Phase.details) _detailsOverlay(),
          if (_phase == Phase.monitoring)
            (_tripCompleted ? _tripCompletedOverlay() : _monitoringOverlay()),
          if (_phase == Phase.monitoring &&
              !_tripCompleted &&
              _camMode == CamMode.rear)
            ReversingCameraOverlay(
              streamUrl: _esp32StreamUrl,
              speed: _state.vehicleSpeed,
              latitude: _state.gpsLat,
              longitude: _state.gpsLng,
              isPreviewMode: _rearManualOverride,
              onClosePreview: () {
                _rearManualOverride = false;
                _setCamMode(CamMode.driverMonitoring);
              },
            ),

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

          // ── Side cam overlays (monitoring phase) — full-screen ──
          if (_phase == Phase.monitoring &&
              !_tripCompleted &&
              _camMode == CamMode.left)
            Positioned.fill(
              child: CamDetectionPanel(
                streamUrl: _leftCamIp != null
                    ? 'http://$_leftCamIp:86/'
                    : _kLeftCamStreamUrl,
                label: 'LEFT CAM',
                width: double.infinity,
                height: double.infinity,
                fullScreen: true,
                onClose: () => _setCamMode(CamMode.driverMonitoring),
              ),
            ),
          if (_phase == Phase.monitoring &&
              !_tripCompleted &&
              _camMode == CamMode.right)
            Positioned.fill(
              child: CamDetectionPanel(
                streamUrl: _rightCamIp != null
                    ? 'http://$_rightCamIp:80/'
                    : _kRightCamStreamUrl,
                label: 'RIGHT CAM',
                width: double.infinity,
                height: double.infinity,
                fullScreen: true,
                onClose: () => _setCamMode(CamMode.driverMonitoring),
              ),
            ),
          if (_phase == Phase.monitoring &&
              !_tripCompleted &&
              _camMode == CamMode.front)
            Positioned.fill(
              child: CamDetectionPanel(
                streamUrl: _frontCamIp != null
                    ? 'http://$_frontCamIp:84/'
                    : _kFrontCamStreamUrl,
                label: 'FRONT CAM',
                width: double.infinity,
                height: double.infinity,
                fullScreen: true,
                onClose: () {
                  _frontManualOverride = false;
                  _setCamMode(CamMode.driverMonitoring);
                },
              ),
            ),

          // ── Side cam toggle buttons (monitoring phase) ──
          if (_phase == Phase.monitoring && !_tripCompleted)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    if (_camMode == CamMode.left) {
                      _setCamMode(CamMode.driverMonitoring);
                    } else {
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
          if (_phase == Phase.monitoring && !_tripCompleted)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    if (_camMode == CamMode.right) {
                      _setCamMode(CamMode.driverMonitoring);
                    } else {
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

          // ── Front cam toggle button (top edge, centred, monitoring phase) ──
          if (_phase == Phase.monitoring && !_tripCompleted)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
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
                    width: 64,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _camMode == CamMode.front
                          ? Colors.orangeAccent.withValues(alpha: 0.85)
                          : Colors.black54,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(10),
                        bottomRight: Radius.circular(10),
                      ),
                      border: Border.all(
                        color: _camMode == CamMode.front
                            ? Colors.orangeAccent
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
                          Icons.expand_more_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 👇 CABLE UNPLUGGED banner — shows for 5 seconds only.
          if (_showCableBanner)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFB91C1C),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: const [
                        Icon(
                          Icons.power_off_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '🔌 CHARGING CABLE UNPLUGGED · Reported to admin',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Screenshot effect — alert varumbol screen quick shrink + border + dim
          // (phone-il screenshot edukkumbol pole).
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
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // SINGLE-MODE CAMERA SWITCHING
  // ─────────────────────────────────────────────────────────

  /// Switches to [mode], stopping the phone camera image stream when leaving
  /// driver monitoring and resuming it when returning.
  /// This is the ONLY place [_camMode] is written — never set it directly.
  void _setCamMode(CamMode mode) {
    if (_camMode == mode) return;
    final wasMonitoring = _camMode == CamMode.driverMonitoring;
    final nowMonitoring = mode == CamMode.driverMonitoring;
    _camMode = mode;
    final c = _camera;
    if (c != null && c.value.isInitialized) {
      if (wasMonitoring && _streaming) {
        c.stopImageStream().catchError((_) {});
        _streaming = false;
        debugPrint('[CamMode] → $mode | phone cam PAUSED');
      } else if (nowMonitoring && !_streaming && _camReady) {
        c.startImageStream(_processImage).catchError((_) {});
        _streaming = true;
        debugPrint('[CamMode] → driverMonitoring | phone cam RESUMED');
      }
    }
    if (mounted) setState(() {});
  }

  // ─────────────────────────────────────────────────────────
  // BLIND SPOT — IP resolution + sensor polling
  // ─────────────────────────────────────────────────────────

  /// Scans the local subnet to resolve direct IPs for all three ESP32 cams.
  /// Left sensor: port 87 | Right sensor: port 81 | Front sensor: port 85
  /// Direct IPs are used because .local mDNS is unreliable on Android.
  Future<void> _resolveSideCamIps() async {
    if (_leftCamIp != null && _rightCamIp != null && _frontCamIp != null)
      return;

    // Throttle: never scan more than once every 60 seconds.
    final now = DateTime.now();
    if (_lastSideCamScanAt != null &&
        now.difference(_lastSideCamScanAt!) < const Duration(seconds: 60))
      return;
    _lastSideCamScanAt = now;

    // Get local IPv4 subnet prefix (e.g. "10.119.135")
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
      debugPrint('[SideCam] Cannot get local IP: $e');
      return;
    }
    if (subnet == null) return;
    debugPrint(
      '[SideCam] Scanning $subnet.1-254 — left:87, right:81, front:85',
    );

    final String sub = subnet;

    Future<String?> scanForPort(int sensorPort) async {
      Future<String?> probe(String ip) async {
        try {
          final res = await http
              .get(Uri.parse('http://$ip:$sensorPort/sensor'))
              .timeout(const Duration(milliseconds: 500));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            if (data.containsKey('distance_cm')) return ip;
          }
        } catch (_) {}
        return null;
      }

      for (int start = 1; start <= 254; start += 50) {
        final end = (start + 49).clamp(1, 254);
        final batch = [for (int i = start; i <= end; i++) probe('$sub.$i')];
        final results = await Future.wait(batch);
        final found = results.firstWhere((r) => r != null, orElse: () => null);
        if (found != null) return found;
      }
      return null;
    }

    final leftFuture = _leftCamIp == null
        ? scanForPort(87)
        : Future.value(_leftCamIp);
    final rightFuture = _rightCamIp == null
        ? scanForPort(81)
        : Future.value(_rightCamIp);
    final frontFuture = _frontCamIp == null
        ? scanForPort(85)
        : Future.value(_frontCamIp);

    final results = await Future.wait([leftFuture, rightFuture, frontFuture]);

    if (_leftCamIp == null && results[0] != null) {
      _leftCamIp = results[0];
      debugPrint('[SideCam] Left cam IP → $_leftCamIp');
    }
    if (_rightCamIp == null && results[1] != null) {
      _rightCamIp = results[1];
      debugPrint('[SideCam] Right cam IP → $_rightCamIp');
    }
    if (_frontCamIp == null && results[2] != null) {
      _frontCamIp = results[2];
      debugPrint('[SideCam] Front cam IP → $_frontCamIp');
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
    if (_leftCamIp == null || _rightCamIp == null) {
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
    final frontUrl = _frontCamIp != null
        ? 'http://$_frontCamIp:85/sensor'
        : null;

    final results = await Future.wait([
      fetch(leftUrl),
      fetch(rightUrl),
      fetch(frontUrl),
    ]);
    if (!mounted) {
      _isPollingBlindSpot = false;
      return;
    }

    final double? left = results[0];
    final double? right = results[1];
    final double? front = results[2];

    if (_camMode != CamMode.rear && !_rearManualOverride) {
      if (left != null && left < 50.0) {
        _setCamMode(CamMode.left);
      } else if (right != null && right < 50.0) {
        _setCamMode(CamMode.right);
      } else if (front != null && front < 50.0) {
        // Sensor triggered — not a manual open, so override is off.
        _frontManualOverride = false;
        _setCamMode(CamMode.front);
      } else {
        final bool leftClear = left == null || left > 60.0;
        final bool rightClear = right == null || right > 60.0;
        final bool frontClear = front == null || front > 60.0;
        if (leftClear &&
            rightClear &&
            frontClear &&
            (_camMode == CamMode.left ||
                _camMode == CamMode.right ||
                // Only auto-close front cam if it was NOT manually opened.
                (_camMode == CamMode.front && !_frontManualOverride))) {
          _setCamMode(CamMode.driverMonitoring);
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

  // ── VERIFYING ──
  Widget _verifyingOverlay() {
    if (!_initializing && !_authEngine.isEnrolled) {
      return Container(
        color: Colors.black.withOpacity(0.85),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.people_outlined, color: Colors.redAccent, size: 64),
              SizedBox(height: 24),
              Text(
                'No Drivers Assigned',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'No registered/authorized drivers found for this device.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final isUnverified =
        _state.authStatus == AuthStatus.unauthorized && _state.faceCount > 0;
    final isAuthenticating =
        _state.authStatus == AuthStatus.scanning && _state.faceCount > 0;

    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: isUnverified
                ? const Icon(
                    Icons.error_outline,
                    color: Colors.redAccent,
                    size: 64,
                  )
                : const CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Color(0xFF3B82F6),
                  ),
          ),
          const SizedBox(height: 24),
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
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _state.faceCount == 0
                ? 'Look at the camera'
                : (isUnverified
                      ? 'Face not recognised — keep looking'
                      : (isAuthenticating
                            ? 'Processing your face, please wait...'
                            : 'Hold still…')),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
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
          _cableUnpluggedBanner(),
          _connectivityBanner(),
          _monitorStatusBar(),
          _esp32StatusBanner(),
          // _deviceMotionCard(),
          if (_noFaceSince != null && !_tripCompleted) _noDriverCountdown(),
          const Spacer(),
          _seatbeltIndicator(),
          _monitorBanner(),
          _monitorDiag(),
        ],
      ),
    );
  }

  Widget _cableUnpluggedBanner() {
    if (!_showCableBanner) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFB91C1C).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: const [
          Icon(Icons.power_off_rounded, color: Colors.white, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '🔌 CHARGING CABLE UNPLUGGED · Reported to admin',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _esp32StatusBanner() {
    final bool isRecording = _ffmpegRecorderService.isRecording;

    final Color bgColor;
    final IconData icon;
    final String text;

    if (_isConnectingToEsp32) {
      bgColor = const Color(0xFFD97706);
      icon = Icons.wifi_protected_setup_rounded;
      text = 'Connecting to ESP32-CAM WiFi...';
    } else if (_isConnectedToEsp32) {
      if (isRecording) {
        bgColor = const Color(0xFF16A34A);
        icon = Icons.videocam_rounded;
        text = 'ESP32-CAM: Connected & Recording (1-min segments)';
      } else {
        bgColor = const Color(0xFF2563EB);
        icon = Icons.wifi_rounded;
        text = 'ESP32-CAM: Connected (Idle)';
      }
    } else {
      bgColor = const Color(0xFF475569);
      icon = Icons.videocam_off_rounded;
      text = 'ESP32-CAM: Disconnected (Tap to connect)';
    }

    return GestureDetector(
      onTap: _connectToEsp32Wifi,
      child: Container(
        margin: const EdgeInsets.only(left: 12, right: 12, top: 8),
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
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            GestureDetector(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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
            // ── FRONT cam toggle button ──
            const SizedBox(width: 6),
            GestureDetector(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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

  Widget _tripCompletedOverlay() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.white,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF16A34A),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Trip $_tripNumber Completed',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'Driver left the seat. The next driver must verify to start the next trip.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 34),

                // Live camera + scanning pulse.
                _ScanningPulse(child: _liveFaceCircle(150)),

                const SizedBox(height: 28),
                const Text(
                  'Look at the camera to verify',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF2563EB),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Waiting for authentication…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
      text = '⚠  DISTRACTION DETECTED EYES ON THE ROAD ⚠';
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
    if (_state.authStatus == AuthStatus.unauthorized) return 'unauthorized';
    if (_state.authStatus == AuthStatus.multipleFaces) return 'multiple_faces';
    if (_state.drowsinessLevel == DrowsinessLevel.asleep) return 'asleep';
    if (phone) return 'phone';
    if (smoke) return 'smoke';
    if (_state.hasEating || _state.isChewing) return 'eating';
    if (_state.hasDrinking) return 'drinking';
    if (_state.drowsinessLevel == DrowsinessLevel.drowsy) return 'drowsy';
    if (_state.distractionStatus == DistractionStatus.distracted)
      return 'distracted';
    return null;
  }

  // Seatbelt status: red alert kaanikkum (off aanenkil). Buckled aanenkil hide.
  Widget _seatbeltIndicator() {
    final on = _state.seatbeltBuckled;
    if (on) return const SizedBox.shrink();
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

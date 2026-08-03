import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class LiveStreamService {
  WebSocketChannel? _channel;
  bool _isStreaming = false;
  DateTime? _lastFrameTime;
  DateTime? _lastScreenFrameTime;
  bool _isProcessing = false;
  bool _isSending = false; // Guards against queuing frames faster than the network can send them
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  Timer? _keepAliveTimer;
  Timer? _qualityTimer;
  int _framesSent = 0;
  DateTime? _streamingStartedAt;
  String _deviceTabletId = '';

  // ─── Adaptive JPEG quality + frame rate ─────────────────
  // Tracks dropped frames (blocked by _isSending) vs total attempts every 3s.
  // Drop rate > 60% → quality 20, 2 FPS  (extreme congestion)
  // Drop rate > 30% → quality 40, 10 FPS (poor network)
  // Drop rate > 10% → quality 60, 10 FPS (medium network)
  // Drop rate < 10% → quality 80, 10 FPS (good network)
  int _jpegQuality = 80;
  int _frameIntervalMs = 100; // adaptive: 100 ms (10 FPS) or 500 ms (2 FPS)
  int _frameAttempts = 0;
  int _droppedFrames = 0;

  // ─── Keepalive ────────────────────────────────────────────
  // Allow up to 2 consecutive missed PONGs before declaring a zombie.
  // This tolerates a single delayed PONG on a congested network.
  int _missedPongs = 0;
  static const int _kMaxMissedPongs = 2;
  

  // ─── Audio ───────────────────────────────────────────
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isSpeaking = false;
  // Buffer for incoming WebM chunks — assembled and played once stream ends
  final List<Uint8List> _audioBuffer = [];
  Timer? _audioFlushTimer;
  bool _waitingForPong = false; // true after PING sent; false once PONG received

  // ─── Alert dedup ─────────────────────────────────────
  // Tracks the last time each alert type was sent. Prevents any duplicate
  // alert message from reaching the backend within a 5-second window, even
  // if the caller fires sendAlertMessage more than once due to edge cases.
  final Map<String, DateTime> _lastAlertSentAt = {};

  // ─── Fleet GPS WebSocket ─────────────────────────────
  WebSocketChannel? _fleetChannel;
  bool _fleetIsReconnecting = false;
  Timer? _fleetReconnectTimer;
  Timer? _fleetKeepAliveTimer;
  bool _fleetWaitingForPong = false;

  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isSpeaking = ValueNotifier<bool>(false);

  bool get isStreaming => _isStreaming;

  void _startReconnectTimer() {
    if (_isReconnecting) return;
    _isReconnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _isReconnecting = false;
      if (!isConnected.value) {
        debugPrint('[Stream] Reconnecting...');
        connect(_deviceTabletId);
      }
    });
  }

  /// Establishes the WebSocket connection with the backend server
  void connect(String deviceTabletId) {
    if (deviceTabletId.isEmpty) {
      debugPrint('[Stream] Device ID is empty. Cannot connect WebSocket.');
      return;
    }

    // Guard: skip if already connected OR a reconnect attempt is in progress
    if (isConnected.value || _isReconnecting) {
      debugPrint('[Stream] Already connected/reconnecting. Skipping connect request.');
      return;
    }

    _deviceTabletId = deviceTabletId;
    _reconnectTimer?.cancel();

    // Fix: close old channel before creating a new one to prevent zombie connections
    _channel?.sink.close();
    _channel = null;
    _isProcessing = false; // reset in case isolate was mid-flight
    _isSending = false;

    final cleanId = deviceTabletId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final wsUrl =
        'wss://proximity-driver-api.prod-app.in:443/ws/stream/$cleanId?role=sender';
    debugPrint('[Stream] Connecting to WebSocket: $wsUrl');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Check when connection handshake successfully completes
      _channel!.ready.then((_) {
        isConnected.value = true;
        _isReconnecting = false;
        _jpegQuality = 80;
        _frameIntervalMs = 100;
        _frameAttempts = 0;
        _droppedFrames = 0;
        _startKeepAlive();
        _startQualityTimer();
        _initAudioPlayer();
        debugPrint('[Stream] WebSocket connection successfully established!');
      }).catchError((err) {
        debugPrint('[Stream] WebSocket connection failed: $err');
        isConnected.value = false;
        _startReconnectTimer();
      });

      _channel!.stream.listen(
            (message) {
          _handleCommand(message);
        },
        onDone: () {
          debugPrint('[Stream] WebSocket connection closed by server.');
          _isStreaming = false;
          isConnected.value = false;
          _keepAliveTimer?.cancel();
          _qualityTimer?.cancel();
          _startReconnectTimer();
        },
        onError: (error) {
          debugPrint('[Stream] WebSocket error: $error');
          _isStreaming = false;
          isConnected.value = false;
          _keepAliveTimer?.cancel();
          _qualityTimer?.cancel();
          _startReconnectTimer();
        },
      );
    } catch (e) {
      debugPrint('[Stream] Error establishing connection: $e');
      isConnected.value = false;
      _startReconnectTimer();
    }
  }

  /// Call this when the app resumes from background / screen-on.
  /// Android Doze mode can silently kill the WebSocket while the app is frozen.
  void onAppResumed() {
    if (!isConnected.value) {
      if (!_isReconnecting && _deviceTabletId.isNotEmpty) {
        debugPrint('[Stream] App resumed — was disconnected, reconnecting...');
        connect(_deviceTabletId);
      }
    } else {
      // Connection appears live — send immediate ping to verify.
      // If socket is actually dead, sink.add() will trigger onError → reconnect.
      try {
        _channel?.sink.add('PING');
        debugPrint('[Stream] App resumed — ping sent to verify connection');
      } catch (_) {}
      // Restart keepalive from now so next ping is 30s from resume, not sooner.
      _startKeepAlive();
    }
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _waitingForPong = false;
    _missedPongs = 0;
    // Send an immediate PING so the server's idle timer resets right away.
    // Without this, the first periodic PING arrives exactly when the server's
    // ~30-second idle timeout fires — a race the device always loses.
    try {
      _channel?.sink.add('PING');
      _waitingForPong = true;
      debugPrint('[Stream] ♥ Initial ping sent on connect');
    } catch (_) {}
    // 10-second interval keeps the server's idle timer well within its ~30-second
    // threshold. Two consecutive missed PONGs (20 s of silence) trigger reconnect.
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!isConnected.value || _channel == null) return;
      if (_waitingForPong) {
        _missedPongs++;
        debugPrint('[Stream] \u2717 No PONG received (missed: $_missedPongs / $_kMaxMissedPongs)');
        if (_missedPongs >= _kMaxMissedPongs) {
          debugPrint('[Stream] \u2717 $_kMaxMissedPongs consecutive PONGs missed \u2014 zombie connection, forcing reconnect');
          _forceReconnect();
        }
        return;
      }
      try {
        _channel!.sink.add('PING');
        _waitingForPong = true;
        debugPrint('[Stream] \u2665 Keepalive ping sent');
      } catch (_) {}
    });
  }

  void _startQualityTimer() {
    _qualityTimer?.cancel();
    _qualityTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_frameAttempts == 0) return;
      final dropRate = _droppedFrames / _frameAttempts;
      final int newQuality;
      final int newIntervalMs;
      if (dropRate > 0.60) {
        newQuality = 20;  // extreme congestion — bare-minimum quality
        newIntervalMs = 500; // 2 FPS — frees bandwidth for PONG/control messages
      } else if (dropRate > 0.30) {
        newQuality = 40;  // poor network
        newIntervalMs = 100; // 10 FPS
      } else if (dropRate > 0.10) {
        newQuality = 60;  // medium network
        newIntervalMs = 100;
      } else {
        newQuality = 80;  // good network
        newIntervalMs = 100;
      }
      if (newQuality != _jpegQuality || newIntervalMs != _frameIntervalMs) {
        debugPrint(
          '[Stream] Quality: $_jpegQuality → $newQuality, '
          'FPS: ${(1000 ~/ _frameIntervalMs)} → ${1000 ~/ newIntervalMs} '
          '(drop rate: ${(dropRate * 100).toStringAsFixed(0)}% '
          'over $_frameAttempts frames)',
        );
        _jpegQuality = newQuality;
        _frameIntervalMs = newIntervalMs;
      }
      // Reset window counters
      _frameAttempts = 0;
      _droppedFrames = 0;
    });
  }

  /// Handles commands from the backend.
  /// Binary: 0x03 prefix = admin audio (WebM/Opus). Text: START / STOP / PONG.
  void _handleCommand(dynamic message) {
    // ── RAW SOCKET LOG ──────────────────────────────────────────────────────
    if (message is Uint8List) {
      debugPrint('[Socket RAW] binary (${message.length} bytes) '
          'first4=${message.take(4).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
    } else {
      debugPrint('[Socket RAW] text → "${message.toString()}" '
          'codeUnits=${message.toString().codeUnits.take(8).toList()}');
    }
    // ────────────────────────────────────────────────────────────────────────

    // Binary message: admin audio has 0x03 prefix
    if (message is Uint8List) {
      if (message.isNotEmpty && message[0] == 0x03) {
        final audio = message.sublist(1);
        if (audio.isEmpty) {
          // End-of-transmission signal from backend — flush immediately
          _audioFlushTimer?.cancel();
          _flushAudioBuffer();
        } else {
          _playIncomingAudio(audio);
        }
      }
      return;
    }

    // Plain-text commands
    final raw = message.toString().trim();
    debugPrint('[Stream] ← Command: "$raw"');
    if (raw == 'START') {
      _isStreaming = true;
      _framesSent = 0;
      _streamingStartedAt = DateTime.now();
      debugPrint('[Stream] ▶ STREAMING STARTED');
    } else if (raw == 'STOP') {
      _isStreaming = false;
      final duration = _streamingStartedAt != null
          ? DateTime.now().difference(_streamingStartedAt!).inSeconds
          : 0;
      debugPrint('[Stream] ■ STREAMING STOPPED — sent $_framesSent frames in ${duration}s');
      _framesSent = 0;
      _streamingStartedAt = null;
    } else if (raw.toUpperCase() == 'PONG') {
      _waitingForPong = false;
      _missedPongs = 0; // reset streak on successful PONG
      debugPrint('[Stream] ♥ PONG received — connection confirmed alive');
    } else if (raw.toUpperCase() == 'PING') {
      // Server is doing its own keepalive check — reply immediately.
      // Without this the server gets no PONG and closes the connection at ~25-30 s.
      try {
        _channel?.sink.add('PONG');
        debugPrint('[Stream] ← Server PING → replied PONG');
      } catch (_) {}
    }
  }

  // ─── Audio: Init player ──────────────────────────────────────────────────
  void _initAudioPlayer() {
    // Force loudspeaker + max volume so admin voice is loud even when
    // VOICE_COMMUNICATION source is active (which normally routes to earpiece).
    _audioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.gain,
      ),
    ));
    _audioPlayer.setVolume(1.0);
    debugPrint('[Audio] AudioPlayer ready — loudspeaker forced');
  }

  // ─── Audio: Buffer incoming WebM/Opus chunks, play once stream ends ──────
  // Backend sends WebM as a stream of chunks (header + clusters).
  // We accumulate all chunks and play the assembled file 300ms after the last chunk.
  void _playIncomingAudio(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _audioBuffer.add(bytes);
    debugPrint('[Audio] ▶ Buffered chunk (${bytes.length} bytes, total: ${_audioBuffer.length})');
    // Reset flush timer — play 2s after last chunk arrives (chunks can be ~1s apart)
    _audioFlushTimer?.cancel();
    _audioFlushTimer = Timer(const Duration(milliseconds: 2000), _flushAudioBuffer);
  }

  Future<void> _flushAudioBuffer() async {
    if (_audioBuffer.isEmpty) return;
    // Concatenate all chunks into one WebM file
    final totalBytes = _audioBuffer.fold<int>(0, (sum, c) => sum + c.length);
    final assembled = Uint8List(totalBytes);
    int offset = 0;
    for (final chunk in _audioBuffer) {
      assembled.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _audioBuffer.clear();
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/admin_audio_${DateTime.now().millisecondsSinceEpoch}.webm');
      await tempFile.writeAsBytes(assembled);
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.play(DeviceFileSource(tempFile.path));
      debugPrint('[Audio] ✅ Playing assembled admin audio ($totalBytes bytes)');
      // Clean up temp file after a delay (give player time to read it)
      Future.delayed(const Duration(seconds: 30), () {
        tempFile.delete().catchError((_) => tempFile);
      });
    } catch (e) {
      debugPrint('[Audio] Playback error: $e');
    }
  }

  // ─── Audio: Send driver voice ──────────────────────────
  // Protocol: binary frame — [0x02][complete AAC/M4A bytes]
  // aacLc used (opus requires Android API 29+; aacLc works on all versions).
  String? _recordingPath;

  /// Start recording driver mic to a temp file.
  Future<void> startSpeaking() async {
    if (_isSpeaking || !isConnected.value) return;
    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        debugPrint('[Audio] Mic permission denied');
        return;
      }
      final tempDir = await getTemporaryDirectory();
      _recordingPath = '${tempDir.path}/driver_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
          ),
        ),
        path: _recordingPath!,
      );
      _isSpeaking = true;
      isSpeaking.value = true;
      debugPrint('[Audio] 🎙 Driver speaking started — recording to file');
    } catch (e) {
      debugPrint('[Audio] startSpeaking error: $e');
    }
  }

  /// Stop recording and send the complete audio file as one binary frame.
  Future<void> stopSpeaking() async {
    if (!_isSpeaking) return;
    _isSpeaking = false;
    isSpeaking.value = false;
    try {
      final path = await _recorder.stop();
      debugPrint('[Audio] 🎙 Driver speaking stopped');
      if (path == null || !isConnected.value || _channel == null) return;
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) return;
      final frame = Uint8List(bytes.length + 1);
      frame[0] = 0x02;
      frame.setRange(1, frame.length, bytes);
      _channel!.sink.add(frame);
      debugPrint('[Audio] 📤 Sent complete audio — ${bytes.length} bytes');
      // Clean up temp file
      try { await File(path).delete(); } catch (_) {}
    } catch (e) {
      debugPrint('[Audio] stopSpeaking error: $e');
    }
  }

  /// Feeds a raw camera frame for background compression and transmission
  void feedFrame(CameraImage image, int rotation, bool isFront) async {
    // NEW: also skip while a previous frame is still being flushed to the socket.
    // Without this, slow network conditions cause frames to pile up in the
    // sink's internal buffer, which is the classic cause of *growing* lag
    // (every subsequent frame is delayed a little more than the last).
    if (!_isStreaming || _channel == null || _isProcessing || _isSending) return;

    final now = DateTime.now();
    // Throttle to adaptive FPS (100 ms = 10 FPS normal, 500 ms = 2 FPS under extreme congestion)
    if (_lastFrameTime != null && now.difference(_lastFrameTime!).inMilliseconds < _frameIntervalMs) {
      return;
    }

    if (image.planes.length < 3) return;

    _lastFrameTime = now;
    _isProcessing = true;

    try {
      // Package planes and metadata to send to the background thread
      final Map<String, dynamic> params = {
        'yBytes': image.planes[0].bytes,
        'uBytes': image.planes[1].bytes,
        'vBytes': image.planes[2].bytes,
        'yRow': image.planes[0].bytesPerRow,
        'uvRow': image.planes[1].bytesPerRow,
        'uvPix': image.planes[1].bytesPerPixel ?? 1,
        'srcW': image.width,
        'srcH': image.height,
        'targetWidth': 1280,
        'rotation': rotation,
        'isFront': isFront,
        'quality': _jpegQuality,
      };

      // Offload YUV-to-JPEG conversion to an Isolate
      final jpegBytes = await compute(_compressFrameIsolate, params);

      if (jpegBytes != null && _isStreaming && _channel != null) {
        _isSending = true;
        try {
          _channel!.sink.add(jpegBytes);
          _framesSent++;
          if (_framesSent % 25 == 1) {
            debugPrint('[Stream] ↑ Frame #$_framesSent sent (${jpegBytes.length} bytes)');
          }
        } finally {
          // sink.add() on WebSocketChannel doesn't expose a flush/ack future,
          // so this mainly protects against re-entrancy from this same
          // isolate call chain. If you switch to IOWebSocketChannel or add
          // server-side ACKs later, await the actual send here instead.
          _isSending = false;
        }
      }
    } catch (e) {
      debugPrint('[Stream] feedFrame processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Feeds a raw screen frame (RGBA bytes) for background compression and transmission.
  /// JPEG quality is auto-adjusted based on network drop rate (80 / 60 / 40).
  void feedScreenFrame(Uint8List rgbaBytes, int width, int height) async {
    if (!_isStreaming || _channel == null) return; // not streaming — don't count

    // Internal 40ms throttle (~25 FPS) — guards against direct callers flooding
    final now = DateTime.now();
    if (_lastScreenFrameTime != null &&
        now.difference(_lastScreenFrameTime!).inMilliseconds < 40) {
      return;
    }

    _frameAttempts++;
    if (_isProcessing || _isSending) {
      _droppedFrames++;
      return;
    }
    _lastScreenFrameTime = now;

    _isProcessing = true;

    try {
      final Map<String, dynamic> params = {
        'rgbaBytes': rgbaBytes,
        'width': width,
        'height': height,
        'targetWidth': 1280,
        'quality': _jpegQuality,
      };

      // Offload RGBA-to-JPEG conversion to an Isolate
      final jpegBytes = await compute(_compressScreenIsolate, params);

      if (jpegBytes != null && _isStreaming && _channel != null) {
        _isSending = true;
        try {
          _channel!.sink.add(jpegBytes);
          _framesSent++;
          if (_framesSent % 25 == 1) {
            debugPrint('[Stream] ↑ Frame #$_framesSent sent (${jpegBytes.length} bytes) quality=$_jpegQuality');
          }
        } finally {
          _isSending = false;
        }
      }
    } catch (e) {
      debugPrint('[Stream] feedScreenFrame processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Sends a text-based alert message over the WebSocket to notify web dashboard.
  /// Has a built-in 5-second per-type debounce so the same alert can never
  /// reach the backend twice in quick succession regardless of caller behaviour.
  void sendAlertMessage(String alertType) {
    if (_channel == null || !_isStreaming) return;
    final now = DateTime.now();
    final last = _lastAlertSentAt[alertType];
    if (last != null && now.difference(last).inSeconds < 5) {
      debugPrint('[Stream] Alert "$alertType" debounced (${now.difference(last).inMilliseconds} ms since last send)');
      return;
    }
    _lastAlertSentAt[alertType] = now;
    final jsonMsg = '{"event": "alert", "type": "$alertType", "timestamp": "${now.toIso8601String()}"}';
    _channel!.sink.add(jsonMsg);
    debugPrint('[Stream] Sent alert metadata over WebSocket: $jsonMsg');
  }

  /// Force-closes a zombie connection and immediately triggers a reconnect.
  /// Called when a keepalive tick detects no PONG since the last PING.
  void _forceReconnect() {
    debugPrint('[Stream] _forceReconnect() called \u2014 clearing stale state');
    _isStreaming = false;
    _waitingForPong = false;
    _keepAliveTimer?.cancel();
    _qualityTimer?.cancel();
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    isConnected.value = false;
    _isReconnecting = false; // clear so reconnect timer is allowed to fire
    _startReconnectTimer();
  }

  /// Closes the connection and stops streaming
  // ─── Fleet GPS WebSocket ──────────────────────────────────────────────────

  /// Connects to the fleet GPS WebSocket.
  /// Separate from the stream socket — used only to send periodic GPS updates.
  void connectFleet(String deviceTabletId) {
    if (deviceTabletId.isEmpty || _fleetIsReconnecting) return;
    if (_fleetChannel != null) return; // already connected

    _fleetIsReconnecting = true;
    final wsUrl =
        'wss://proximity-driver-api.prod-app.in/ws/fleet?role=sender&deviceId=$deviceTabletId';
    debugPrint('[Fleet] Connecting to fleet WebSocket: $wsUrl');

    try {
      _fleetChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _fleetChannel!.ready.then((_) {
        _fleetIsReconnecting = false;
        _fleetWaitingForPong = false;
        _startFleetKeepAlive();
        debugPrint('[Fleet] Fleet WebSocket connected.');
      }).catchError((err) {
        debugPrint('[Fleet] Fleet connect failed: $err');
        _fleetChannel = null;
        _fleetIsReconnecting = false;
        _scheduleFleetReconnect(deviceTabletId);
      });

      _fleetChannel!.stream.listen(
        (message) {
          // Handle PONG from server
          if (message is String && message.trim().toUpperCase() == 'PONG') {
            _fleetWaitingForPong = false;
            debugPrint('[Fleet] ♥ PONG received — fleet connection alive');
          }
        },
        onDone: () {
          debugPrint('[Fleet] Fleet WebSocket closed.');
          _fleetKeepAliveTimer?.cancel();
          _fleetChannel = null;
          _fleetIsReconnecting = false;
          _scheduleFleetReconnect(deviceTabletId);
        },
        onError: (e) {
          debugPrint('[Fleet] Fleet WebSocket error: $e');
          _fleetKeepAliveTimer?.cancel();
          _fleetChannel = null;
          _fleetIsReconnecting = false;
          _scheduleFleetReconnect(deviceTabletId);
        },
      );
    } catch (e) {
      debugPrint('[Fleet] Fleet connect exception: $e');
      _fleetChannel = null;
      _fleetIsReconnecting = false;
      _scheduleFleetReconnect(deviceTabletId);
    }
  }

  void _startFleetKeepAlive() {
    _fleetKeepAliveTimer?.cancel();
    _fleetWaitingForPong = false;
    _fleetKeepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_fleetChannel == null) return;
      if (_fleetWaitingForPong) {
        debugPrint('[Fleet] ✗ No PONG since last PING — zombie fleet connection, reconnecting');
        _fleetKeepAliveTimer?.cancel();
        try { _fleetChannel?.sink.close(); } catch (_) {}
        _fleetChannel = null;
        _fleetIsReconnecting = false;
        _scheduleFleetReconnect(_deviceTabletId);
        return;
      }
      try {
        _fleetChannel!.sink.add('PING');
        _fleetWaitingForPong = true;
        debugPrint('[Fleet] ♥ Fleet keepalive ping sent');
      } catch (_) {}
    });
  }

  void _scheduleFleetReconnect(String deviceTabletId) {
    _fleetReconnectTimer?.cancel();
    _fleetReconnectTimer = Timer(const Duration(seconds: 5), () {
      connectFleet(deviceTabletId);
    });
  }

  /// Sends a GPS update as a JSON text frame over the fleet WebSocket.
  /// Called from _sendTelemetryTask() every 3 seconds.
  void sendGpsUpdate(double latitude, double longitude, double speed) {
    if (_fleetChannel == null) return;
    try {
      final json =
          '{"latitude":$latitude,"longitude":$longitude,"speed":${speed.toStringAsFixed(1)}}';
      _fleetChannel!.sink.add(json);
      debugPrint('[Fleet] GPS sent: $json');
    } catch (e) {
      debugPrint('[Fleet] sendGpsUpdate error: $e');
      _fleetChannel = null;
      _scheduleFleetReconnect(_deviceTabletId); // reconnect using stored deviceId
    }
  }

  /// Call when app resumes to reconnect fleet socket if dropped.
  void onFleetAppResumed(String deviceTabletId) {
    if (_fleetChannel == null && !_fleetIsReconnecting) {
      connectFleet(deviceTabletId);
    }
  }

  void dispose() {
    _isStreaming = false;
    _waitingForPong = false;
    _reconnectTimer?.cancel();
    _keepAliveTimer?.cancel();
    _qualityTimer?.cancel();
    _audioFlushTimer?.cancel();
    _audioBuffer.clear();
    _recorder.dispose();
    _audioPlayer.dispose();
    _channel?.sink.close();
    _channel = null;
    isConnected.value = false;
    isSpeaking.value = false;
    _fleetReconnectTimer?.cancel();
    _fleetKeepAliveTimer?.cancel();
    try { _fleetChannel?.sink.close(); } catch (_) {}
    _fleetChannel = null;
    debugPrint('[Stream] Disposed.');
  }
}

/// Standalone top-level function that runs inside a background isolate.
/// Converts YUV420 camera image planes to a rotated and mirrored JPEG byte array.
Uint8List? _compressFrameIsolate(Map<String, dynamic> params) {
  try {
    final Uint8List yBytes = params['yBytes'];
    final Uint8List uBytes = params['uBytes'];
    final Uint8List vBytes = params['vBytes'];
    final int yRow = params['yRow'];
    final int uvRow = params['uvRow'];
    final int uvPix = params['uvPix'];
    final int srcW = params['srcW'];
    final int srcH = params['srcH'];
    final int targetWidth = params['targetWidth'];
    final int rotation = params['rotation'];
    final bool isFront = params['isFront'];

    final double scale = srcW > targetWidth ? targetWidth / srcW : 1.0;
    final int w = (srcW * scale).toInt();
    final int h = (srcH * scale).toInt();

    // Direct RGB byte buffer (3 bytes per pixel), filled manually.
    final Uint8List rgbBuffer = Uint8List(w * h * 3);
    int outIdx = 0;

    for (int y = 0; y < h; y++) {
      final int sy = (y / scale).toInt().clamp(0, srcH - 1);
      final int yRowOffset = sy * yRow;
      final int uvRowOffset = (sy >> 1) * uvRow;

      for (int x = 0; x < w; x++) {
        final int sx = (x / scale).toInt().clamp(0, srcW - 1);

        final int yi = yRowOffset + sx;
        final int uvi = uvRowOffset + (sx >> 1) * uvPix;

        final int Y = yi < yBytes.length ? yBytes[yi] : 0;
        final int U = uvi < uBytes.length ? uBytes[uvi] - 128 : 0;
        final int V = uvi < vBytes.length ? vBytes[uvi] - 128 : 0;

        // Integer BT.601 conversion (fixed-point, >>8 instead of float math).
        int r = Y + ((91881 * V) >> 16);
        int g = Y - ((22554 * U + 46802 * V) >> 16);
        int b = Y + ((116130 * U) >> 16);

        // Manual clamp (branch is cheaper than calling num.clamp()).
        if (r < 0) r = 0; else if (r > 255) r = 255;
        if (g < 0) g = 0; else if (g > 255) g = 255;
        if (b < 0) b = 0; else if (b > 255) b = 255;

        rgbBuffer[outIdx] = r;
        rgbBuffer[outIdx + 1] = g;
        rgbBuffer[outIdx + 2] = b;
        outIdx += 3;
      }
    }

    img.Image out = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgbBuffer.buffer,
      order: img.ChannelOrder.rgb,
    );

    img.Image fixed = out;
    if (rotation == 90) {
      fixed = img.copyRotate(out, angle: 90);
    } else if (rotation == 180) {
      fixed = img.copyRotate(out, angle: 180);
    } else if (rotation == 270) {
      fixed = img.copyRotate(out, angle: 270);
    }

    if (isFront) {
      fixed = img.flipHorizontal(fixed);
    }

    return Uint8List.fromList(img.encodeJpg(fixed, quality: params['quality'] as int? ?? 80));
  } catch (e) {
    return null;
  }
}

/// Converts raw RGBA bytes of the widget screen into a compressed JPEG byte array.
/// Accepts a [quality] parameter (1–100) for adaptive network quality control.
Uint8List? _compressScreenIsolate(Map<String, dynamic> params) {
  try {
    final Uint8List rgbaBytes = params['rgbaBytes'];
    final int width = params['width'];
    final int height = params['height'];
    final int targetWidth = params['targetWidth'];
    final int quality = (params['quality'] as int?) ?? 80;

    img.Image image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgbaBytes.buffer,
      order: img.ChannelOrder.rgba,
    );

    if (image.width > targetWidth) {
      image = img.copyResize(image, width: targetWidth);
    }

    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  } catch (e) {
    debugPrint('[Isolate] Screen compression error: $e');
    return null;
  }
}

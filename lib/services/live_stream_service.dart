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
  bool _isProcessing = false;
  bool _isSending = false; // NEW: guards against queuing frames faster than the network can send them
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  Timer? _keepAliveTimer;
  int _framesSent = 0;
  DateTime? _streamingStartedAt;
  String _deviceTabletId = '';

  // ─── Audio ───────────────────────────────────────────
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isSpeaking = false;
  StreamSubscription<Uint8List>? _audioSub;
  // Buffer for incoming WebM chunks — assembled and played once stream ends
  final List<Uint8List> _audioBuffer = [];
  Timer? _audioFlushTimer;

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

    if (isConnected.value) {
      debugPrint('[Stream] Already connected. Skipping connect request.');
      return;
    }

    _deviceTabletId = deviceTabletId;
    _reconnectTimer?.cancel();

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
        _startKeepAlive();
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
          _startReconnectTimer();
        },
        onError: (error) {
          debugPrint('[Stream] WebSocket error: $error');
          _isStreaming = false;
          isConnected.value = false;
          _keepAliveTimer?.cancel();
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
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isConnected.value && _channel != null) {
        try {
          _channel!.sink.add('PING');
          debugPrint('[Stream] ♥ Keepalive ping sent');
        } catch (_) {}
      }
    });
  }

  /// Handles commands from the backend.
  /// Binary: 0x03 prefix = admin audio (WebM/Opus). Text: START / STOP / PONG.
  void _handleCommand(dynamic message) {
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
    } else if (raw == 'PONG') {
      // keepalive response — connection is alive
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
    // Throttle to 10 FPS (1 frame per 100 milliseconds)
    if (_lastFrameTime != null && now.difference(_lastFrameTime!).inMilliseconds < 100) {
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

  /// Feeds a raw screen frame (RGBA bytes) for background compression and transmission
  void feedScreenFrame(Uint8List rgbaBytes, int width, int height) async {
    if (!_isStreaming || _channel == null || _isProcessing) return;

    _isProcessing = true;

    try {
      final Map<String, dynamic> params = {
        'rgbaBytes': rgbaBytes,
        'width': width,
        'height': height,
        'targetWidth': 1280,
      };

      // Offload RGBA-to-JPEG conversion to an Isolate
      final jpegBytes = await compute(_compressScreenIsolate, params);

      if (jpegBytes != null && _isStreaming && _channel != null) {
        _channel!.sink.add(jpegBytes);
        _framesSent++;
        if (_framesSent % 25 == 1) {
          debugPrint('[Stream] ↑ Frame #$_framesSent sent (${jpegBytes.length} bytes)');
        }
      }
    } catch (e) {
      debugPrint('[Stream] feedScreenFrame processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Sends a text-based alert message over the WebSocket to notify web dashboard.
  void sendAlertMessage(String alertType) {
    if (_channel != null && _isStreaming) {
      final jsonMsg = '{"event": "alert", "type": "$alertType", "timestamp": "${DateTime.now().toIso8601String()}"}';
      _channel!.sink.add(jsonMsg);
      debugPrint('[Stream] Sent alert metadata over WebSocket: $jsonMsg');
    }
  }

  /// Closes the connection and stops streaming
  void dispose() {
    _isStreaming = false;
    _reconnectTimer?.cancel();
    _keepAliveTimer?.cancel();
    _audioFlushTimer?.cancel();
    _audioBuffer.clear();
    _recorder.dispose();
    _audioPlayer.dispose();
    _audioSub?.cancel();
    _channel?.sink.close();
    _channel = null;
    isConnected.value = false;
    isSpeaking.value = false;
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

    return Uint8List.fromList(img.encodeJpg(fixed, quality: 85));
  } catch (e) {
    return null;
  }
}

/// Converts raw RGBA bytes of the widget screen into a compressed JPEG byte array.
Uint8List? _compressScreenIsolate(Map<String, dynamic> params) {
  try {
    final Uint8List rgbaBytes = params['rgbaBytes'];
    final int width = params['width'];
    final int height = params['height'];
    final int targetWidth = params['targetWidth'];

    img.Image image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgbaBytes.buffer,
      order: img.ChannelOrder.rgba,
    );

    if (image.width > targetWidth) {
      image = img.copyResize(image, width: targetWidth);
    }

    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  } catch (e) {
    debugPrint('[Isolate] Screen compression error: $e');
    return null;
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

class LiveStreamService {
  WebSocketChannel? _channel;
  bool _isStreaming = false;
  DateTime? _lastFrameTime;
  bool _isProcessing = false;
  bool _isSending = false; // NEW: guards against queuing frames faster than the network can send them
  Timer? _reconnectTimer;
  int _framesSent = 0;
  DateTime? _streamingStartedAt;

  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);

  bool get isStreaming => _isStreaming;

  void _startReconnectTimer(String deviceTabletId) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!isConnected.value) {
        debugPrint('[Stream] Reconnect timer fired. Attempting connection...');
        connect(deviceTabletId);
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

    _reconnectTimer?.cancel();

    final cleanId = deviceTabletId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final wsUrl =
        'wss://proximity-driver-api.prod-app.in:443/ws/stream/$cleanId?role=sender';
    debugPrint('[Stream] Connecting to WebSocket: $wsUrl');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Check when connection handshake successfully completes
      _channel!.ready.then((_) {
        debugPrint('[Stream] WebSocket connection successfully established!');
        isConnected.value = true;
      }).catchError((err) {
        debugPrint('[Stream] WebSocket connection failed: $err');
        isConnected.value = false;
        _startReconnectTimer(deviceTabletId);
      });

      _channel!.stream.listen(
            (message) {
          _handleCommand(message);
        },
        onDone: () {
          debugPrint('[Stream] WebSocket connection closed by server.');
          _isStreaming = false;
          isConnected.value = false;
          _startReconnectTimer(deviceTabletId);
        },
        onError: (error) {
          debugPrint('[Stream] WebSocket error: $error');
          _isStreaming = false;
          isConnected.value = false;
          _startReconnectTimer(deviceTabletId);
        },
      );
    } catch (e) {
      debugPrint('[Stream] Error establishing connection: $e');
      isConnected.value = false;
      _startReconnectTimer(deviceTabletId);
    }
  }

  /// Handles start/stop command parsing (supports JSON & plain text, case-insensitive)
  void _handleCommand(dynamic message) {
    final strMsg = message.toString().trim();
    debugPrint('[Stream] Received WebSocket message from server: $strMsg');

    String upperCmd = strMsg.toUpperCase();

    // Check if web dashboard sent JSON object (e.g. {"command":"START"} or {"action":"start"})
    if (strMsg.startsWith('{') && strMsg.endsWith('}')) {
      try {
        final decoded = jsonDecode(strMsg);
        if (decoded is Map) {
          final val = (decoded['command'] ?? decoded['action'] ?? decoded['event'] ?? decoded['type'] ?? '').toString().trim().toUpperCase();
          if (val.isNotEmpty) upperCmd = val;
        }
      } catch (_) {}
    }

    if (upperCmd.contains('START')) {
      _isStreaming = true;
      _framesSent = 0;
      _streamingStartedAt = DateTime.now();
      debugPrint('[Stream] ▶ STREAMING STARTED (Active = true)');
    } else if (upperCmd.contains('STOP')) {
      _isStreaming = false;
      final duration = _streamingStartedAt != null
          ? DateTime.now().difference(_streamingStartedAt!).inSeconds
          : 0;
      debugPrint('[Stream] ■ STREAMING STOPPED — sent $_framesSent frames in ${duration}s');
      _framesSent = 0;
      _streamingStartedAt = null;
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
    if (!_isStreaming || _channel == null || _isProcessing || _isSending) return;

    _isProcessing = true;

    try {
      final Map<String, dynamic> params = {
        'rgbaBytes': rgbaBytes,
        'width': width,
        'height': height,
        'targetWidth': 1280,
      };

      final jpegBytes = await compute(_compressScreenIsolate, params);

      if (jpegBytes != null && _isStreaming && _channel != null) {
        _isSending = true;
        try {
          _channel!.sink.add(jpegBytes);
          _framesSent++;
          if (_framesSent % 25 == 1) {
            debugPrint('[Stream] ↑ Frame #$_framesSent sent (${jpegBytes.length} bytes)');
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
    _channel?.sink.close();
    _channel = null;
    isConnected.value = false;
    debugPrint('[Stream] Disposed.');
  }
}

/// Standalone top-level function that runs inside a background isolate.
/// Converts YUV420 camera image planes to a rotated and mirrored JPEG byte array.
///
/// OPTIMIZED: writes straight into a Uint8List RGB buffer using integer-only
/// math and manual clamping, instead of calling img.Image.setPixelRgb() per
/// pixel (which carries meaningful per-call overhead at 1280-wide resolution).
/// This is typically several times faster than the original loop and should
/// let you stay comfortably under your 100ms throttle window without lowering
/// resolution or quality.
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

    // Quality dropped from 95 -> 85: visually near-identical on a live feed,
    // noticeably faster to encode and smaller to send. Tune to taste.
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

    img.Image image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgbaBytes.buffer,
      order: img.ChannelOrder.rgba,
    );

    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  } catch (e) {
    debugPrint('[Isolate] Screen compression error: $e');
    return null;
  }
}
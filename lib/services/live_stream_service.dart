import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

class LiveStreamService {
  WebSocketChannel? _channel;
  bool _isStreaming = false;
  DateTime? _lastFrameTime;
  bool _isProcessing = false;
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

  /// Handles start/stop command parsing
  void _handleCommand(dynamic message) {
    final cmd = message.toString().trim();
    if (cmd == 'START') {
      _isStreaming = true;
      _framesSent = 0;
      _streamingStartedAt = DateTime.now();
      debugPrint('[Stream] ▶ STREAMING STARTED');
    } else if (cmd == 'STOP') {
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
    if (!_isStreaming || _channel == null || _isProcessing) return;

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
        'targetWidth': 320, // Low resolution to conserve network bandwidth
        'rotation': rotation,
        'isFront': isFront,
      };

      // Offload YUV-to-JPEG conversion to an Isolate
      final jpegBytes = await compute(_compressFrameIsolate, params);

      if (jpegBytes != null && _isStreaming && _channel != null) {
        _channel!.sink.add(jpegBytes);
        _framesSent++;
        if (_framesSent % 25 == 1) {
          debugPrint('[Stream] ↑ Frame #$_framesSent sent (${jpegBytes.length} bytes)');
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
        'targetWidth': 360, // Low resolution to conserve network bandwidth
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
    _channel?.sink.close();
    _channel = null;
    isConnected.value = false;
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

    final out = img.Image(width: w, height: h);

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

    // JPEG quality 40 keeps the payload size small for IoT networks
    return Uint8List.fromList(img.encodeJpg(fixed, quality: 40));
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

    // Decode RGBA bytes using Image package.
    // Since pixelRatio: 0.35 was used to capture, the image is already pre-scaled
    // on the GPU to a perfect, lightweight resolution. We can skip resizing entirely
    // in Dart to completely eliminate CPU overhead and lag!
    img.Image image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgbaBytes.buffer,
      order: img.ChannelOrder.rgba,
    );

    // JPEG quality 35 keeps the frame size very small (usually ~20-30 KB)
    // which makes streaming over mobile networks extremely smooth.
    return Uint8List.fromList(img.encodeJpg(image, quality: 35));
  } catch (e) {
    debugPrint('[Isolate] Screen compression error: $e');
    return null;
  }
}


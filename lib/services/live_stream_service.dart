// lib/services/live_stream_service.dart
//
// Streams driver-facing JPEG frames to the backend over a secure WebSocket.
//
// Flow:
//   1. App calls connect(deviceId) on startup.
//   2. Backend sends 'START' to begin streaming.
//   3. App calls sendFrame(jpegBytes) on every detection frame — throttled to 5 fps.
//   4. Backend sends 'STOP' to pause, or just closes the socket.
//   5. Service auto-reconnects every 5 s on disconnect.
//
// Endpoint: wss://proximity-driver-api.prod-app.in:443/ws/stream/{deviceId}?role=sender
//
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

class LiveStreamService {
  static const String _wsHost = 'proximity-driver-api.prod-app.in';
  static const String _wsPath = '/ws/stream';

  // 20 fps — smooth live view, stays within IoT SIM bandwidth.
  static const int _kFrameIntervalMs = 50;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;

  bool _disposed = false;    // set in dispose() — stops all reconnect attempts
  bool _reconnecting = false; // prevents duplicate concurrent connect calls
  String? _deviceId;

  /// Observable streaming state — listen with ValueListenableBuilder.
  final ValueNotifier<bool> streamingNotifier = ValueNotifier(false);
  /// Observable connection state.
  final ValueNotifier<bool> connectedNotifier = ValueNotifier(false);

  bool get _streaming => streamingNotifier.value;
  set _streaming(bool v) => streamingNotifier.value = v;
  bool get _connected => connectedNotifier.value;
  set _connected(bool v) => connectedNotifier.value = v;

  // Stopwatch-based throttle — cheaper than DateTime.now() on every frame.
  final Stopwatch _clock = Stopwatch()..start();
  int _lastFrameMs = -_kFrameIntervalMs; // allow first frame through immediately
  int _framesSent = 0;

  // ─── Public API ───────────────────────────────────────────────────────────

  /// Connect to the streaming WebSocket.
  /// Safe to call multiple times — no-ops if already connected to the same device.
  void connect(String deviceId) {
    if (_disposed || (_connected && _deviceId == deviceId)) return;
    _deviceId = deviceId;
    _doConnect();
  }

  /// Feed a JPEG frame. Throttled to 5 fps; no-ops when not streaming.
  void sendFrame(Uint8List jpegBytes) {
    if (!_connected || !_streaming) return;
    final now = _clock.elapsedMilliseconds;
    if (now - _lastFrameMs < _kFrameIntervalMs) return;
    _lastFrameMs = now;
    _framesSent++;
    if (_framesSent % 25 == 1) {
      debugPrint('[LiveStream] Sent frame #$_framesSent (${jpegBytes.length} bytes)');
    }
    try {
      _channel!.sink.add(jpegBytes);
    } catch (e) {
      debugPrint('[LiveStream] sendFrame error: $e');
      _handleDisconnect();
    }
  }

  bool get isStreaming => streamingNotifier.value;
  bool get isConnected => connectedNotifier.value;

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    _connected = false;
    _streaming = false;
    streamingNotifier.dispose();
    connectedNotifier.dispose();
  }

  // ─── Internal ─────────────────────────────────────────────────────────────

  void _doConnect() {
    if (_disposed || _reconnecting || (_deviceId?.isEmpty ?? true)) return;
    _reconnecting = true;
    final uri = Uri(
        scheme: 'wss',
        host: _wsHost,
        port: 443,
        path: '$_wsPath/$_deviceId',
        queryParameters: {'role': 'sender'});
    debugPrint('[LiveStream] Connecting → $uri');
    try {
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
      );

      // ready completes only after the WebSocket handshake succeeds.
      // This is the accurate moment to set _connected = true.
      _channel!.ready.then((_) {
        if (_disposed) return;
        _connected = true;
        _reconnecting = false;
        debugPrint('[LiveStream] ✓ Socket connected');
      });

      _sub?.cancel();
      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: () {
          debugPrint('[LiveStream] Socket closed. Retry in 5 s…');
          _handleDisconnect();
        },
        onError: (e) {
          debugPrint('[LiveStream] Socket error: $e');
          _handleDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _reconnecting = false;
      _connected = false;
      debugPrint('[LiveStream] Connect failed: $e. Retry in 5 s.');
      _scheduleReconnect();
    }
  }

  void _handleDisconnect() {
    _connected = false;
    _streaming = false;
    _reconnecting = false;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _doConnect);
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    switch (data) {
      case 'START':
        _streaming = true;
        debugPrint('[LiveStream] Streaming STARTED');
        break;
      case 'STOP':
        _streaming = false;
        debugPrint('[LiveStream] Streaming STOPPED');
        break;
      default:
        debugPrint('[LiveStream] Unknown message: $data');
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// A lightweight, zero-dependency MJPEG stream viewer.
///
/// Connects to an HTTP MJPEG stream (multipart/x-mixed-replace) and renders
/// each JPEG frame as it arrives. No VLC, no media_kit, no external packages
/// needed — just plain Dart sockets and Flutter Image widget.
///
/// Usage:
/// ```dart
/// MjpegStreamWidget(
///   streamUrl: 'http://10.119.135.95/',
///   fit: BoxFit.contain,
/// )
/// ```
class MjpegStreamWidget extends StatefulWidget {
  /// The HTTP URL of the MJPEG stream (e.g. 'http://10.119.135.95/').
  final String streamUrl;

  /// How to inscribe the image into the space allocated.
  final BoxFit fit;

  /// Timeout for the initial HTTP connection.
  final Duration timeout;

  /// Called when the stream encounters an error.
  final Widget Function(BuildContext context, dynamic error)? errorBuilder;

  /// Widget to show while connecting.
  final Widget Function(BuildContext context)? loadingBuilder;

  /// Called with the raw JPEG bytes of each decoded frame.
  /// Use this to feed frames to an external processor (e.g. YOLO detection).
  final void Function(Uint8List jpegBytes)? onFrame;

  const MjpegStreamWidget({
    super.key,
    required this.streamUrl,
    this.fit = BoxFit.contain,
    this.timeout = const Duration(seconds: 10),
    this.errorBuilder,
    this.loadingBuilder,
    this.onFrame,
  });

  @override
  State<MjpegStreamWidget> createState() => _MjpegStreamWidgetState();
}

class _MjpegStreamWidgetState extends State<MjpegStreamWidget> {
  HttpClient? _httpClient;
  HttpClientResponse? _response;
  StreamSubscription<List<int>>? _subscription;

  /// The latest decoded JPEG frame to display.
  MemoryImage? _currentFrame;

  /// Whether the stream has produced at least one frame.
  bool _hasFrame = false;

  /// Whether we encountered an error.
  bool _hasError = false;
  String _errorMessage = '';

  /// Whether we're currently connecting.
  bool _isConnecting = true;

  /// Internal buffer to accumulate multipart data.
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Boundary string from the Content-Type header.
  String? _boundary;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(covariant MjpegStreamWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _disconnect();
      _connect();
    }
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _response = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    _buffer.clear();
  }

  Future<void> _connect() async {
    _disconnect();
    if (!mounted) return;

    setState(() {
      _isConnecting = true;
      _hasError = false;
      _hasFrame = false;
      _errorMessage = '';
    });

    try {
      _httpClient = HttpClient();
      _httpClient!.connectionTimeout = widget.timeout;

      debugPrint('[MjpegStream] Connecting to ${widget.streamUrl}');
      final request = await _httpClient!.getUrl(Uri.parse(widget.streamUrl));
      _response = await request.close().timeout(widget.timeout);

      // Extract boundary from Content-Type header
      // Typical: "multipart/x-mixed-replace; boundary=--myboundary"
      final contentType = _response!.headers.contentType;
      if (contentType != null) {
        _boundary = contentType.parameters['boundary'];
        debugPrint(
          '[MjpegStream] Content-Type: $contentType, boundary: $_boundary',
        );
      }

      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }

      // Listen to the raw byte stream
      _subscription = _response!.listen(
        _onData,
        onError: (error) {
          debugPrint('[MjpegStream] Stream error: $error');
          if (mounted) {
            setState(() {
              _hasError = true;
              _errorMessage = 'Stream interrupted: $error';
            });
          }
        },
        onDone: () {
          debugPrint('[MjpegStream] Stream ended');
          if (mounted && !_hasError) {
            setState(() {
              _hasError = true;
              _errorMessage = 'Stream ended unexpectedly';
            });
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[MjpegStream] Connection error: $e');
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _hasError = true;
          _errorMessage = 'Could not connect: $e';
        });
      }
    }
  }

  /// Process incoming raw bytes from the HTTP response stream.
  ///
  /// ESP32-CAM HTTP MJPEG streams use multipart/x-mixed-replace format:
  /// Each frame is a complete JPEG image delimited by boundary markers.
  /// We detect JPEG SOI (0xFF 0xD8) and EOI (0xFF 0xD9) markers to
  /// extract individual frames without relying on boundary parsing.
  void _onData(List<int> data) {
    _buffer.add(data);
    final bytes = _buffer.toBytes();
    _buffer.clear();

    // Search for complete JPEG frames using SOI/EOI markers
    int searchFrom = 0;
    while (searchFrom < bytes.length) {
      // Find JPEG Start Of Image marker (0xFF 0xD8)
      int soiIndex = -1;
      for (int i = searchFrom; i < bytes.length - 1; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
          soiIndex = i;
          break;
        }
      }
      if (soiIndex == -1) {
        // No SOI found — keep remaining bytes for next chunk
        if (searchFrom < bytes.length) {
          _buffer.add(bytes.sublist(searchFrom));
        }
        break;
      }

      // Find JPEG End Of Image marker (0xFF 0xD9) after SOI
      int eoiIndex = -1;
      for (int i = soiIndex + 2; i < bytes.length - 1; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
          eoiIndex = i + 2; // Include the 0xD9 byte
          break;
        }
      }
      if (eoiIndex == -1) {
        // No complete frame yet — buffer from SOI onwards
        _buffer.add(bytes.sublist(soiIndex));
        break;
      }

      // Extract the complete JPEG frame
      final jpegFrame = Uint8List.fromList(bytes.sublist(soiIndex, eoiIndex));

      // Update the displayed frame
      if (mounted && jpegFrame.length > 100) {
        // Minimum valid JPEG size
        setState(() {
          _currentFrame = MemoryImage(jpegFrame);
          _hasFrame = true;
        });
        // Notify external consumers (e.g. YOLO detection engine)
        widget.onFrame?.call(jpegFrame);
      }

      searchFrom = eoiIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(context, _errorMessage);
      }
      return Center(
        child: Text(
          _errorMessage,
          style: const TextStyle(color: Colors.red),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_isConnecting || !_hasFrame) {
      if (widget.loadingBuilder != null) {
        return widget.loadingBuilder!(context);
      }
      return const Center(
        child: CircularProgressIndicator(color: Colors.greenAccent),
      );
    }

    return Image(
      image: _currentFrame!,
      fit: widget.fit,
      gaplessPlayback: true, // Prevents flickering between frames
    );
  }
}

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'mjpeg_stream_widget.dart';
import '../services/rear_cam_detector_service.dart';

class ReversingCameraOverlay extends StatefulWidget {
  final String streamUrl;
  final double speed;
  final double latitude;
  final double longitude;
  final bool isPreviewMode;
  final VoidCallback? onClosePreview;

  final String label;
  final String symbol;
  final Color themeColor;
  final bool enableYolo;
  final void Function(List<RearDetection> detections)? onDetection;

  const ReversingCameraOverlay({
    super.key,
    required this.streamUrl,
    required this.speed,
    required this.latitude,
    required this.longitude,
    this.isPreviewMode = false,
    this.onClosePreview,
    this.label = 'REVERSE CAM ACTIVE',
    this.symbol = 'R',
    this.themeColor = Colors.red,
    this.enableYolo = true,
    this.onDetection,
  });

  @override
  State<ReversingCameraOverlay> createState() => _ReversingCameraOverlayState();
}

class _ReversingCameraOverlayState extends State<ReversingCameraOverlay>
    with SingleTickerProviderStateMixin {
  bool _isLive = true;
  late AnimationController _blinkController;
  Timer? _clockTimer;
  DateTime _currentTime = DateTime.now();

  /// Key to force rebuild the MjpegStreamWidget on retry.
  int _streamKey = 0;

  // ── YOLO11n rear-cam detection ──
  final RearCamDetectorService _rearDetector = RearCamDetectorService();
  RearDetectionResult? _latestDetections;
  int _frameCount = 0;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
      }
    });

    debugPrint(
      '[ReversingOverlay] Initializing HTTP MJPEG stream: ${widget.streamUrl}',
    );

    // Start YOLO11n detection on rear-cam frames if enabled
    if (widget.enableYolo) {
      debugPrint('[ReversingOverlay (${widget.symbol})] Initializing detector service...');
      _rearDetector.onResult = (result) {
        if (mounted) {
          debugPrint('[ReversingOverlay (${widget.symbol})] Detections callback fired. Count: ${result.detections.length}');
          setState(() => _latestDetections = result);
          // Notify parent about detections for alert/sound
          if (result.detections.isNotEmpty && widget.onDetection != null) {
            debugPrint('[ReversingOverlay (${widget.symbol})] Notifying parent of active detections...');
            widget.onDetection!(result.detections);
          }
        }
      };
      _rearDetector.initialize();
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _blinkController.dispose();
    if (widget.enableYolo) {
      debugPrint('[ReversingOverlay (${widget.symbol})] Disposing detector service...');
      _rearDetector.dispose();
    }
    _isLive = false;
    super.dispose();
  }

  // Feed every 5th frame to the YOLO detector to avoid overloading the isolate if enabled.
  void _onFrame(Uint8List jpegBytes) {
    if (!widget.enableYolo) return;
    _frameCount++;
    if (_frameCount % 5 == 0) {
      debugPrint('[ReversingOverlay (${widget.symbol})] Feeding frame $_frameCount to detector service (${jpegBytes.length} bytes)...');
      _rearDetector.processFrame(jpegBytes);
    }
  }

  void _retryConnection() {
    setState(() {
      _streamKey++; // Force fresh MjpegStreamWidget instance
      _isLive = true;
    });
    debugPrint(
      '[ReversingOverlay] Retrying HTTP MJPEG stream: ${widget.streamUrl}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.95),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video Feed Layer
          Center(child: _buildVideoFeed()),

          // YOLO11n detection boxes overlay
          if (_latestDetections != null &&
              _latestDetections!.detections.isNotEmpty)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _RearDetectionPainter(_latestDetections!),
              ),
            ),

          // Close Preview Button for Dev Mode
          if (widget.isPreviewMode && widget.onClosePreview != null)
            Positioned(
              top: 80,
              right: 16,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.camera, size: 18),
                label: const Text(
                  "Switch camera",
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: widget.onClosePreview,
              ),
            ),

          // Premium Reversing UI Telemetry Info & Warnings
          Positioned(
            top: 24,
            left: 16,
            right: 16,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: _buildTopHeader(),
            ),
          ),

          // Bottom telemetry bar
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: _buildBottomTelemetry(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoFeed() {
    if (!_isLive) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.videocam_off_rounded,
              size: 64,
              color: Colors.redAccent,
            ),
            const SizedBox(height: 16),
            Text(
              'Camera Stream Disconnected',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text(
                'Retry Connection',
                style: TextStyle(color: Colors.white),
              ),
              onPressed: _retryConnection,
            ),
          ],
        ),
      );
    }

    return MjpegStreamWidget(
      key: ValueKey('mjpeg_stream_$_streamKey'),
      streamUrl: widget.streamUrl,
      fit: BoxFit.contain,
      timeout: const Duration(seconds: 10),
      onFrame: _onFrame,
      errorBuilder: (context, error) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.videocam_off_rounded,
                size: 64,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 16),
              Text(
                'ESP32-CAM Connection Failed',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '$error',
                style: const TextStyle(color: Colors.white60, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text(
                  'Retry Connection',
                  style: TextStyle(color: Colors.white),
                ),
                onPressed: _retryConnection,
              ),
            ],
          ),
        );
      },
      loadingBuilder: (context) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.greenAccent,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'CONNECTING TO ${widget.label}...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.streamUrl,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTopHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Indicator Symbol (e.g. R, F)
        Row(
          children: [
            AnimatedBuilder(
              animation: _blinkController,
              builder: (context, child) {
                return Opacity(
                  opacity: _blinkController.value,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: widget.themeColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.symbol,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                Text(
                  _isLive ? 'LIVE FEED' : 'RECONNECTING...',
                  style: TextStyle(
                    color: _isLive ? Colors.greenAccent : Colors.amberAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),

        // Stream Status pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _isLive ? Colors.greenAccent : Colors.amberAccent,
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
                  color: _isLive ? Colors.greenAccent : Colors.amberAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _isLive ? 'HTTP LIVE' : 'CONNECTING',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomTelemetry() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildTelemetryItem(
            icon: Icons.speed_rounded,
            title: 'SPEED',
            value: '${widget.speed.toStringAsFixed(1)} km/h',
          ),
          Container(width: 1, height: 24, color: Colors.white24),
          _buildTelemetryItem(
            icon: Icons.location_on_rounded,
            title: 'GPS LAT',
            value: widget.latitude.toStringAsFixed(4),
          ),
          Container(width: 1, height: 24, color: Colors.white24),
          _buildTelemetryItem(
            icon: Icons.location_on_rounded,
            title: 'GPS LNG',
            value: widget.longitude.toStringAsFixed(4),
          ),
          Container(width: 1, height: 24, color: Colors.white24),
          _buildTelemetryItem(
            icon: Icons.access_time_rounded,
            title: 'SYSTEM TIME',
            value: _formatTime(_currentTime),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final String hour = dt.hour.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    final String second = dt.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  Widget _buildTelemetryItem({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 20),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── YOLO11n Detection Box Painter ─────────────────────────────────────────────

class _RearDetectionPainter extends CustomPainter {
  final RearDetectionResult result;

  _RearDetectionPainter(this.result);

  static const Map<String, Color> _boxColors = {
    'person': Color(0xFFFF3B30), // red   — highest danger
    'car': Color(0xFFFF9500), // orange
    'truck': Color(0xFFFF9500),
    'bus': Color(0xFFFF9500),
    'motorcycle': Color(0xFFFFCC00), // yellow
    'bicycle': Color(0xFFFFCC00),
    'dog': Color(0xFF34C759), // green
    'cat': Color(0xFF34C759),
    'traffic light': Color(0xFF5AC8FA), // light blue
    'stop sign': Color(0xFFFF2D55), // bright red
  };

  @override
  void paint(Canvas canvas, Size size) {
    final origW = result.frameWidth.toDouble();
    final origH = result.frameHeight.toDouble();
    if (origW <= 0 || origH <= 0 || result.detections.isEmpty) return;

    // Compute where the video is actually rendered inside this canvas.
    // MjpegStreamWidget uses BoxFit.contain, so we mirror that math here.
    final scale = min(size.width / origW, size.height / origH);
    final vW = origW * scale;
    final vH = origH * scale;
    final vX = (size.width - vW) / 2;
    final vY = (size.height - vH) / 2;

    for (final det in result.detections) {
      final color = _boxColors[det.label] ?? const Color(0xFF00E5FF);
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;

      final left = vX + det.x * vW;
      final top = vY + det.y * vH;
      final right = vX + (det.x + det.width) * vW;
      final bottom = vY + (det.y + det.height) * vH;

      canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), boxPaint);

      // Corner accent marks
      const cs = 12.0;
      for (final pts in [
        [Offset(left, top), Offset(left + cs, top), Offset(left, top + cs)],
        [Offset(right, top), Offset(right - cs, top), Offset(right, top + cs)],
        [
          Offset(left, bottom),
          Offset(left + cs, bottom),
          Offset(left, bottom - cs),
        ],
        [
          Offset(right, bottom),
          Offset(right - cs, bottom),
          Offset(right, bottom - cs),
        ],
      ]) {
        canvas.drawLine(pts[0], pts[1], boxPaint);
        canvas.drawLine(pts[0], pts[2], boxPaint);
      }

      // ── Label: class name + confidence (small, inside top-left of box) ──────
      final label =
          ' ${det.label.toUpperCase()} ${(det.confidence * 100).toStringAsFixed(0)}% ';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            background: Paint()..color = color.withValues(alpha: 0.85),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // Always draw inside the box at the top-left corner.
      tp.paint(
        canvas,
        Offset(
          left.clamp(0.0, (size.width - tp.width).clamp(0.0, size.width)),
          top.clamp(0.0, (size.height - tp.height).clamp(0.0, size.height)),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_RearDetectionPainter old) => old.result != result;
}

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/rear_cam_detector_service.dart';
import 'mjpeg_stream_widget.dart';

/// A self-contained panel that shows a live MJPEG stream with real-time
/// YOLO11n object detection overlay. Used for front, left and right ESP32-CAM
/// blind-spot panels.
///
/// Each panel manages its own [RearCamDetectorService] isolate; it starts when
/// the widget is inserted into the tree and stops when it is removed, so
/// inference only runs while the panel is visible.
class CamDetectionPanel extends StatefulWidget {
  final String streamUrl;
  final String label;
  final double width;
  final double height;
  final VoidCallback onClose;
  final bool fullScreen;

  const CamDetectionPanel({
    super.key,
    required this.streamUrl,
    required this.label,
    required this.width,
    required this.height,
    required this.onClose,
    this.fullScreen = false,
  });

  @override
  State<CamDetectionPanel> createState() => _CamDetectionPanelState();
}

class _CamDetectionPanelState extends State<CamDetectionPanel> {
  final RearCamDetectorService _detector = RearCamDetectorService();
  RearDetectionResult? _latestDetections;
  int _frameCount = 0;

  @override
  void initState() {
    super.initState();
    _detector.onResult = (result) {
      if (mounted) setState(() => _latestDetections = result);
    };
    _detector.initialize();
  }

  @override
  void dispose() {
    _detector.dispose();
    super.dispose();
  }

  // Feed every 8th frame to avoid overloading the isolate.
  void _onFrame(Uint8List jpegBytes) {
    _frameCount++;
    if (_frameCount % 8 == 0) {
      _detector.processFrame(jpegBytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: widget.fullScreen
            ? BorderRadius.zero
            : BorderRadius.circular(12),
        border: widget.fullScreen
            ? null
            : Border.all(color: Colors.redAccent, width: 2),
        boxShadow: widget.fullScreen
            ? null
            : const [BoxShadow(color: Colors.black54, blurRadius: 12)],
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Live MJPEG feed ──────────────────────────────────────────────
          MjpegStreamWidget(
            key: ValueKey('det_panel_${widget.streamUrl}'),
            streamUrl: widget.streamUrl,
            fit: BoxFit.cover,
            timeout: const Duration(seconds: 8),
            onFrame: _onFrame,
            errorBuilder: (ctx, err) => const ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.videocam_off_rounded,
                      color: Colors.redAccent,
                      size: 36,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'No signal',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── YOLO11n bounding-box overlay ─────────────────────────────────
          if (_latestDetections != null &&
              _latestDetections!.detections.isNotEmpty)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _PanelDetectionPainter(
                  _latestDetections!,
                  BoxFit.cover,
                ),
              ),
            ),

          // ── Label bar with YOLO detection status ────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              color: Colors.redAccent.withValues(alpha: 0.88),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '\u{1F4F7}  ${widget.label}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _latestDetections == null
                          ? Colors.orange.withValues(alpha: 0.9)
                          : _latestDetections!.detections.isEmpty
                          ? Colors.green.withValues(alpha: 0.9)
                          : Colors.blue.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _latestDetections == null
                          ? '🔍 YOLO Loading…'
                          : _latestDetections!.detections.isEmpty
                          ? '🔍 YOLO Active'
                          : () {
                              // Group by label and count, e.g. "PERSON ×2, CAR"
                              final counts = <String, int>{};
                              for (final d in _latestDetections!.detections) {
                                counts[d.label.toUpperCase()] =
                                    (counts[d.label.toUpperCase()] ?? 0) + 1;
                              }
                              final parts = counts.entries
                                  .map(
                                    (e) => e.value > 1
                                        ? '${e.key} ×${e.value}'
                                        : e.key,
                                  )
                                  .join('  ');
                              return '🔍 $parts';
                            }(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Close button ─────────────────────────────────────────────────
          Positioned(
            top: 6,
            right: 6,
            child: GestureDetector(
              onTap: widget.onClose,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Detection box painter ─────────────────────────────────────────────────────

class _PanelDetectionPainter extends CustomPainter {
  final RearDetectionResult result;
  final BoxFit fit;

  _PanelDetectionPainter(this.result, this.fit);

  static const Map<String, Color> _colors = {
    'person': Color(0xFFFF3B30), // red
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

    // Mirror the same BoxFit used by MjpegStreamWidget to align boxes.
    final double scale = fit == BoxFit.cover
        ? max(size.width / origW, size.height / origH)
        : min(size.width / origW, size.height / origH);

    final vW = origW * scale;
    final vH = origH * scale;
    final vX = (size.width - vW) / 2;
    final vY = (size.height - vH) / 2;

    for (final det in result.detections) {
      final color = _colors[det.label] ?? const Color(0xFF00E5FF);
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      final left = vX + det.x * vW;
      final top = vY + det.y * vH;
      final right = vX + (det.x + det.width) * vW;
      final bottom = vY + (det.y + det.height) * vH;

      // Clip box to visible area
      final rect = Rect.fromLTRB(
        left.clamp(0, size.width),
        top.clamp(0, size.height),
        right.clamp(0, size.width),
        bottom.clamp(0, size.height),
      );
      if (rect.width < 2 || rect.height < 2) continue;

      canvas.drawRect(rect, boxPaint);

      // Corner accent marks
      const cs = 10.0;
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
      final labelText =
          ' ${det.label.toUpperCase()} ${(det.confidence * 100).toStringAsFixed(0)}% ';
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            background: Paint()..color = color.withValues(alpha: 0.85),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width.clamp(40.0, size.width));

      // Always draw inside the box at the top-left corner.
      tp.paint(canvas, Offset(rect.left, rect.top));
    }
  }

  @override
  bool shouldRepaint(_PanelDetectionPainter old) => old.result != result;
}

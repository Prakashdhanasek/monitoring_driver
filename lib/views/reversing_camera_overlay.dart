import 'dart:async';
import 'package:flutter/material.dart';
import 'mjpeg_stream_widget.dart';

class ReversingCameraOverlay extends StatefulWidget {
  final String streamUrl;
  final double speed;
  final double latitude;
  final double longitude;
  final bool isPreviewMode;
  final VoidCallback? onClosePreview;

  const ReversingCameraOverlay({
    super.key,
    required this.streamUrl,
    required this.speed,
    required this.latitude,
    required this.longitude,
    this.isPreviewMode = false,
    this.onClosePreview,
  });

  @override
  State<ReversingCameraOverlay> createState() => _ReversingCameraOverlayState();
}

class _ReversingCameraOverlayState extends State<ReversingCameraOverlay> with SingleTickerProviderStateMixin {
  bool _isLive = true;
  late AnimationController _blinkController;
  Timer? _clockTimer;
  DateTime _currentTime = DateTime.now();

  /// Key to force rebuild the MjpegStreamWidget on retry.
  int _streamKey = 0;

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

    debugPrint('[ReversingOverlay] Initializing HTTP MJPEG stream: ${widget.streamUrl}');
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _blinkController.dispose();
    _isLive = false;
    super.dispose();
  }

  void _retryConnection() {
    setState(() {
      _streamKey++; // Force fresh MjpegStreamWidget instance
      _isLive = true;
    });
    debugPrint('[ReversingOverlay] Retrying HTTP MJPEG stream: ${widget.streamUrl}');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.95),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video Feed Layer
          Center(
            child: _buildVideoFeed(),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.close, size: 18),
                label: const Text("CLOSE PREVIEW", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
            const Icon(Icons.videocam_off_rounded, size: 64, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              'Camera Stream Disconnected',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Retry Connection', style: TextStyle(color: Colors.white)),
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
      errorBuilder: (context, error) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.videocam_off_rounded, size: 64, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                'ESP32-CAM Connection Failed',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text('Retry Connection', style: TextStyle(color: Colors.white)),
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
              child: CircularProgressIndicator(strokeWidth: 3, color: Colors.greenAccent),
            ),
            const SizedBox(height: 24),
            const Text(
              'CONNECTING TO REAR ESP32-CAM...',
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
        // R Indicator
        Row(
          children: [
            AnimatedBuilder(
              animation: _blinkController,
              builder: (context, child) {
                return Opacity(
                  opacity: _blinkController.value,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'R',
                      style: TextStyle(
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
                const Text(
                  'REVERSE CAM ACTIVE',
                  style: TextStyle(
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
            border: Border.all(color: _isLive ? Colors.greenAccent : Colors.amberAccent, width: 1),
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
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
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

  Widget _buildTelemetryItem({required IconData icon, required String title, required String value}) {
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
              style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold),
            ),
            Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ],
    );
  }
}

// lib/views/app_update_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/app_update_service.dart';

class AppUpdateScreen extends StatefulWidget {
  final AppUpdateInfo updateInfo;
  const AppUpdateScreen({super.key, required this.updateInfo});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  final AppUpdateService _service = AppUpdateService();

  bool _isDeviceOwner = false;
  bool _isDownloading = false;
  bool _isInstalling  = false;
  bool _updateStarted = false;
  double _progress    = 0.0;
  String? _error;

  static const _bg       = Color(0xFF1C1F2E);
  static const _card     = Color(0xFF252839);
  static const _blue     = Color(0xFF4F8EF7);
  static const _white    = Colors.white;
  static const _sub      = Color(0xFFABB4C8);
  static const _red      = Color(0xFFFF5C5C);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final isDO = await _service.isDeviceOwner();
    if (!mounted) return;
    setState(() => _isDeviceOwner = isDO);
    if (isDO) _startUpdate();
  }

  Future<void> _startUpdate() async {
    if (_updateStarted) return;
    _updateStarted = true;

    setState(() {
      _isDownloading = true;
      _isInstalling  = false;
      _error         = null;
      _progress      = 0.0;
    });

    try {
      await for (final p in _service.downloadApk(widget.updateInfo.downloadUrl)) {
        if (!mounted) return;
        // Only rebuild UI every 1% to avoid hundreds of unnecessary setState calls.
        if ((p - _progress) >= 0.01 || p >= 1.0) {
          setState(() => _progress = p);
        }
      }

      if (!mounted) return;
      setState(() { _isDownloading = false; _isInstalling = true; });

      final path = await _service.getApkPath();

      // Guard: ensure the file actually has content before installing.
      final fileSize = await File(path).length();
      if (fileSize == 0) {
        throw Exception('Downloaded file is 0 bytes — install aborted.');
      }
      debugPrint('[AppUpdate] Installing $path ($fileSize bytes)');

      await _service.installApkSilently(path);

      if (!mounted) return;
      Navigator.of(context).pop();

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updateStarted = false;
        _isDownloading = false;
        _isInstalling  = false;
        _error         = 'Update failed. Please check your connection.';
      });
    }
  }

  String get _title {
    if (_isDownloading) return 'Downloading Update!';
    if (_isInstalling)  return 'Installing Update!';
    if (_error != null) return 'Update Failed!';
    return 'Update Available!';
  }

  String get _subtitle {
    final info = widget.updateInfo;
    if (_isDownloading) return 'Please wait while the update is being downloaded to your device.';
    if (_isInstalling)  return 'Installing the update. The app will restart automatically.';
    if (_error != null) return _error!;
    return 'Version ${info.versionName} (Build ${info.versionCode}) is ready to install on your device.';
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.updateInfo;
    final busy = _isDownloading || _isInstalling;

    return PopScope(
      canPop: !info.forceUpdate && !busy,
      child: Dialog(
        backgroundColor: _bg,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 52, vertical: 40),
        child: Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Top graphic ──
              if (_isDownloading)
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: _progress,
                        strokeWidth: 4,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation<Color>(_blue),
                      ),
                      Text(
                        '${(_progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: _white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                )
              else if (_isInstalling)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(_blue),
                  ),
                )
              else if (_error != null)
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _red.withOpacity(0.15),
                  ),
                  child: const Icon(Icons.error_outline_rounded, color: _red, size: 22),
                )
              else
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _blue.withOpacity(0.15),
                    border: Border.all(color: _blue.withOpacity(0.35), width: 1.5),
                  ),
                  child: const Icon(
                    Icons.system_update_alt_rounded,
                    color: _blue,
                    size: 20,
                  ),
                ),

              const SizedBox(height: 16),

              // ── Title ──
              Text(
                _title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                  height: 1.2,
                ),
              ),

              const SizedBox(height: 8),

              // ── Subtitle ──
              Text(
                _subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _sub,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  height: 1.6,
                  letterSpacing: 0.1,
                ),
              ),

              const SizedBox(height: 20),

              // ── Buttons: non-Device-Owner, idle ──
              if (!_isDeviceOwner && !busy) ...[
                SizedBox(
                  height: 44,
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _startUpdate,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _blue,
                      foregroundColor: _white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    child: const Text('Update Now'),
                  ),
                ),
                if (!info.forceUpdate) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: _sub,
                    ),
                    child: const Text('Skip for now', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ],

              // ── Retry: Device Owner after failure ──
              if (_isDeviceOwner && !busy && _error != null)
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _startUpdate,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _blue,
                      foregroundColor: _white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Retry'),
                  ),
                ),

              // ── Force-update notice ──
              if (info.forceUpdate && !_isDeviceOwner && !busy && _error == null)
                const Text(
                  'This update is required to continue using the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: _sub,
                    height: 1.5,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

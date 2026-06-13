import 'package:flutter/services.dart';

/// Talks to the native Android side (MainActivity) to turn Lock Task /
/// kiosk mode on and off. No-ops safely on non-Android or if the device
/// isn't a device owner (then it falls back to screen-pinning).
class Kiosk {
  static const MethodChannel _channel = MethodChannel('kiosk');

  /// Pin the app to the screen. If the app is a Device Owner this is a
  /// true lock (no exit). Otherwise it's screen-pinning (user can exit).
  static Future<void> start() async {
    try {
      await _channel.invokeMethod('startKiosk');
    } catch (_) {
      // Ignore — e.g. on iOS or if not supported.
    }
  }

  /// Release the lock (call this from a hidden admin gesture if you ever
  /// need to exit).
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopKiosk');
    } catch (_) {}
  }
}

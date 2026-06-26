import 'package:flutter/foundation.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:permission_handler/permission_handler.dart';

class Esp32WifiService {
  /// Connects programmatically to the ESP32-CAM Wi-Fi Access Point.
  Future<bool> connectToEsp32(String ssid, {String? password}) async {
    try {
      debugPrint('[Esp32Wifi] Requesting Location permission for Wi-Fi connection...');
      final status = await Permission.location.request();
      if (!status.isGranted) {
        debugPrint('[Esp32Wifi] Location permission denied. Cannot connect to Wi-Fi.');
        return false;
      }

      debugPrint('[Esp32Wifi] Connecting to Wi-Fi SSID: $ssid...');
      final isConnected = await WiFiForIoTPlugin.connect(
        ssid,
        password: password,
        security: password != null ? NetworkSecurity.WPA : NetworkSecurity.NONE,
        joinOnce: true,
      );

      if (isConnected) {
        debugPrint('[Esp32Wifi] ✓ Connected to ESP32 Wi-Fi AP: $ssid');
        // Force routing app traffic through Wi-Fi network to avoid mobile carrier bypass
        await WiFiForIoTPlugin.forceWifiUsage(true);
      } else {
        debugPrint('[Esp32Wifi] ✗ Failed to connect to $ssid.');
      }
      return isConnected;
    } catch (e) {
      debugPrint('[Esp32Wifi] ✗ Connection Error: $e');
      return false;
    }
  }

  /// Disconnects from ESP32 AP and restores default network routing.
  Future<void> disconnectFromEsp32() async {
    try {
      debugPrint('[Esp32Wifi] Disconnecting from ESP32 AP...');
      await WiFiForIoTPlugin.forceWifiUsage(false);
      await WiFiForIoTPlugin.disconnect();
      debugPrint('[Esp32Wifi] ✓ Disconnected and restored default network routing.');
    } catch (e) {
      debugPrint('[Esp32Wifi] ✗ Error disconnecting: $e');
    }
  }

  /// Gets current Wi-Fi SSID.
  Future<String?> getCurrentSsid() async {
    try {
      return await WiFiForIoTPlugin.getSSID();
    } catch (e) {
      debugPrint('[Esp32Wifi] Error getting SSID: $e');
      return null;
    }
  }
}

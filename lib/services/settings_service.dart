// lib/services/settings_service.dart
// Handles device IMEI and app settings persistence via Hive.

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class SettingsService {
  static const String _boxName = 'settingsBox';
  static const String _keyDeviceId = 'device_id';
  static const String _keyDeviceModel = 'device_model';
  static const String _keyOsVersion = 'os_version';
  static const String _keyIsRegistered = 'is_registered';

  Box get _box => Hive.box(_boxName);

  // ── Device ID (IMEI) ─────────────────────────────────────

  /// Get the stored device ID (IMEI). Returns null if not set.
  String? getDeviceId() {
    return _box.get(_keyDeviceId);
  }

  /// Save the device ID (IMEI) to Hive.
  void saveDeviceId(String deviceId) {
    _box.put(_keyDeviceId, deviceId);
    debugPrint('[SettingsService] Saved device_id: $deviceId');
  }

  /// Check if a valid 15-digit IMEI is already stored.
  bool hasValidImei() {
    final id = getDeviceId();
    return id != null && id.length == 15 && RegExp(r'^\d+$').hasMatch(id);
  }

  // ── Device Info ───────────────────────────────────────────

  /// Save device model and OS version for offline reference.
  void saveDeviceInfo({required String model, required String osVersion}) {
    _box.put(_keyDeviceModel, model);
    _box.put(_keyOsVersion, osVersion);
  }

  String? getDeviceModel() => _box.get(_keyDeviceModel);
  String? getOsVersion() => _box.get(_keyOsVersion);

  // ── Registration Status ───────────────────────────────────

  /// Mark the device as registered with the backend.
  void markRegistered() {
    _box.put(_keyIsRegistered, true);
  }

  /// Check if the device has been registered.
  bool get isRegistered => _box.get(_keyIsRegistered, defaultValue: false);

  // ── Cooldowns ─────────────────────────────────────────────

  /// Get the last time an event type was reported to the API.
  DateTime? getLastApiReportTime(String eventType) {
    final int? timestamp = _box.get('cooldown_$eventType');
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  /// Save the last time an event type was reported to the API.
  void setLastApiReportTime(String eventType, DateTime time) {
    _box.put('cooldown_$eventType', time.millisecondsSinceEpoch);
  }

  // ── Location Persistence ───────────────────────────────────

  /// Save last known valid GPS location to Hive.
  void saveLastLocation(double lat, double lng) {
    if (lat != 0.0 && lng != 0.0) {
      _box.put('last_valid_lat', lat);
      _box.put('last_valid_lng', lng);
    }
  }

  /// Get last known valid GPS location from Hive.
  Map<String, double>? getLastLocation() {
    final lat = _box.get('last_valid_lat');
    final lng = _box.get('last_valid_lng');
    if (lat is double && lng is double && lat != 0.0 && lng != 0.0) {
      return {'lat': lat, 'lng': lng};
    }
    return null;
  }

  // ── Clear ─────────────────────────────────────────────────

  /// Clear all settings (used for factory reset / debugging).
  Future<void> clearAll() async {
    await _box.clear();
    debugPrint('[SettingsService] All settings cleared.');
  }
}

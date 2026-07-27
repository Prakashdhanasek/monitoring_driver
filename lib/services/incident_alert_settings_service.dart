import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Data model for an incident alert setting from API.
class IncidentAlertSetting {
  final String id;
  final String incidentType;
  final int intervalSecs;
  final double? speedThresholdKmh;

  IncidentAlertSetting({
    required this.id,
    required this.incidentType,
    required this.intervalSecs,
    this.speedThresholdKmh,
  });

  factory IncidentAlertSetting.fromJson(Map<String, dynamic> json) {
    final speed = json['speedThresholdKmh'];
    return IncidentAlertSetting(
      id: json['id']?.toString() ?? '',
      incidentType: json['incidentType']?.toString() ?? '',
      intervalSecs: (json['intervalSecs'] as num?)?.toInt() ?? 60,
      speedThresholdKmh: speed != null ? (speed as num).toDouble() : null,
    );
  }
}

/// Service to manage dynamic incident alert settings (intervalSecs & speedThresholdKmh)
/// fetched from GET /api/settings/incident-alerts.
class IncidentAlertSettingsService {
  static final IncidentAlertSettingsService _instance =
      IncidentAlertSettingsService._internal();
  factory IncidentAlertSettingsService() => _instance;
  IncidentAlertSettingsService._internal();

  final Map<String, IncidentAlertSetting> _settingsMap = {};

  Map<String, IncidentAlertSetting> get settingsMap => _settingsMap;

  /// Fetches incident alert settings from API
  Future<void> fetchSettings(String baseUrl) async {
    try {
      final cleanBaseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final uri = Uri.parse('$cleanBaseUrl/api/settings/incident-alerts');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final List<dynamic> list = json.decode(res.body);
        _settingsMap.clear();
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final setting = IncidentAlertSetting.fromJson(item);
            if (setting.incidentType.isNotEmpty) {
              _settingsMap[setting.incidentType] = setting;
              _settingsMap[setting.incidentType.toLowerCase()] = setting;
              _mapAliases(setting);
            }
          }
        }
        debugPrint('===========================================================');
        debugPrint(
          '[IncidentAlertSettings] Successfully loaded dynamic alert settings from API:',
        );
        final printed = <String>{};
        _settingsMap.forEach((key, setting) {
          if (!printed.contains(setting.incidentType)) {
            printed.add(setting.incidentType);
            debugPrint(
              '   • ${setting.incidentType}: interval = ${setting.intervalSecs}s | speedThreshold = ${setting.speedThresholdKmh ?? "None"} km/h',
            );
          }
        });
        debugPrint('===========================================================');
      } else {
        debugPrint(
          '[IncidentAlertSettings] API returned status ${res.statusCode}',
        );
      }
    } catch (e) {
      debugPrint(
        '[IncidentAlertSettings] Error fetching incident alert settings: $e',
      );
    }
  }

  /// Maps internal incident event aliases to API incidentType
  void _mapAliases(IncidentAlertSetting setting) {
    final type = setting.incidentType.toLowerCase();
    if (type.contains('phone')) {
      _settingsMap['phone'] = setting;
      _settingsMap['phone usage'] = setting;
    } else if (type.contains('overspeed')) {
      _settingsMap['overspeeding'] = setting;
    } else if (type.contains('seatbelt')) {
      _settingsMap['seatbelt'] = setting;
    } else if (type.contains('smoke') || type.contains('smoking')) {
      _settingsMap['smoking'] = setting;
      _settingsMap['smoke'] = setting;
    } else if (type.contains('driver changed')) {
      _settingsMap['driver changed'] = setting;
    }
  }

  /// Gets configured interval in seconds for an incident type (default 60s)
  int getIntervalSecs(String incidentType) {
    final setting = _settingsMap[incidentType] ??
        _settingsMap[incidentType.toLowerCase()];
    return setting?.intervalSecs ?? 60;
  }

  /// Gets configured speed threshold in km/h for an incident type
  double? getSpeedThresholdKmh(String incidentType) {
    final setting = _settingsMap[incidentType] ??
        _settingsMap[incidentType.toLowerCase()];
    return setting?.speedThresholdKmh;
  }

  /// Evaluates whether an API report call should be executed based on speed threshold and interval cooldown.
  bool shouldReportApi({
    required String eventType,
    required double currentSpeedKmh,
    required DateTime? lastReportTime,
  }) {
    final setting = _settingsMap[eventType] ??
        _settingsMap[eventType.toLowerCase()];

    final int interval = setting?.intervalSecs ?? 60;
    final double? minSpeed = setting?.speedThresholdKmh;

    // 1. Speed Threshold Check (e.g. Distraction speedThresholdKmh: 20)
    if (minSpeed != null && currentSpeedKmh < minSpeed) {
      debugPrint(
        '[IncidentAlertSettings] ❌ BLOCKED API CALL for "$eventType" | Reason: Speed (${currentSpeedKmh.toStringAsFixed(1)} km/h) < Required Threshold ($minSpeed km/h)',
      );
      return false;
    }

    // 2. Interval Cooldown Check (e.g. intervalSecs: 60)
    if (lastReportTime != null) {
      final elapsedSecs = DateTime.now().difference(lastReportTime).inSeconds;
      if (elapsedSecs < interval) {
        debugPrint(
          '[IncidentAlertSettings] ❌ BLOCKED API CALL for "$eventType" | Reason: Cooldown Active ($elapsedSecs s elapsed / $interval s required)',
        );
        return false;
      }
    }

    debugPrint(
      '[IncidentAlertSettings] ✅ ALLOWED API CALL for "$eventType" | Speed: ${currentSpeedKmh.toStringAsFixed(1)} km/h | Cooldown Passed ($interval s interval)',
    );
    return true;
  }
}

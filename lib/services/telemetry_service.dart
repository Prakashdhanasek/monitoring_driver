// lib/services/telemetry_service.dart
// Handles sending location telemetry updates to the API every 3 seconds.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class TelemetryService {
  static const String _apiUrl =
      'https://proximity-driver-api.prod-app.in/api/telemetry/location';

  /// Sends the current location and speed telemetry to the API.
  Future<void> sendLocationTelemetry({
    required String deviceTabletId,
    required double latitude,
    required double longitude,
    required double speed,
  }) async {
    final url = Uri.parse(_apiUrl);
    final body = {
      'deviceTabletId': deviceTabletId,
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed.toInt(), // API expects speed as integer
    };

    try {
      debugPrint('--------------------------------------------------');
      debugPrint('[TELEMETRY REQUEST] POST -> $url');
      debugPrint('[TELEMETRY REQUEST] PAYLOAD: ${jsonEncode(body)}');
      debugPrint('--------------------------------------------------');

      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'accept': '*/*',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('--------------------------------------------------');
      debugPrint('[TELEMETRY RESPONSE] Status Code: ${response.statusCode}');
      debugPrint('[TELEMETRY RESPONSE] Body: ${response.body}');
      debugPrint('--------------------------------------------------');
    } catch (e) {
      debugPrint('[TELEMETRY ERROR] Failed to send telemetry: $e');
    }
  }
}

// lib/services/geofence_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class GeofenceService {
  static const String _url =
      'https://proximity-driver-api.prod-app.in/api/geofences/violation';

  Future<void> reportViolation({
    String? vehicleId,
    String? driverId,
    String? geofenceId,
    required double latitude,
    required double longitude,
    required double vehicleSpeed,
    required double distanceFromBoundaryMeters,
    required String deviceTabletId,
    required DateTime occurredAt,
  }) async {
    final url = Uri.parse(_url);
    final body = {
      if (vehicleId != null) 'vehicleId': vehicleId,
      if (driverId != null) 'driverId': driverId,
      if (geofenceId != null) 'geofenceId': geofenceId,
      'latitude': latitude,
      'longitude': longitude,
      'vehicleSpeed': vehicleSpeed.toInt(),
      'distanceFromBoundaryMeters': distanceFromBoundaryMeters.toInt(),
      'deviceTabletId': deviceTabletId,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
    };

    try {
      debugPrint('--------------------------------------------------');
      debugPrint('[Geofence] VIOLATION POST -> $url');
      debugPrint('[Geofence] PAYLOAD: ${jsonEncode(body)}');
      debugPrint('--------------------------------------------------');

      final response = await http
          .post(
        url,
        headers: {'Content-Type': 'application/json', 'accept': '*/*'},
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15));

      debugPrint('[Geofence] VIOLATION RESPONSE: ${response.statusCode}');
      debugPrint('[Geofence] VIOLATION BODY: ${response.body}');
    } catch (e) {
      debugPrint('[Geofence] VIOLATION ERROR: $e');
    }
  }
}
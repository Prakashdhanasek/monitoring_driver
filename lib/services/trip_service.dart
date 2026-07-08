// lib/services/trip_service.dart
// Handles starting and ending trips via the backend trip APIs.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/trip_start_response_model.dart';

class TripService {
  static const String _baseUrl = 'https://proximity-driver-api.prod-app.in';
  static const String _startTripPath = '/api/trips/start';
  static const String _endTripPath = '/api/trips/end';

  // Future<void> startTrip({
  //   required String deviceTabletId,
  //   String? driverId,
  //   required double gpsLatitude,
  //   required double gpsLongitude,
  //   required DateTime startedAt,
  // }) async {
  //   final url = Uri.parse('$_baseUrl$_startTripPath');
  //   final body = {
  //     'deviceTabletId': deviceTabletId,
  //     if (driverId != null && driverId.isNotEmpty) 'driverId': driverId,
  //     'gpsLatitude': gpsLatitude,
  //     'gpsLongitude': gpsLongitude,
  //     'startedAt': startedAt.toUtc().toIso8601String(),
  //   };
  //
  //   try {
  //     debugPrint('--------------------------------------------------');
  //     debugPrint('[TripService] START TRIP POST -> $url');
  //     debugPrint('[TripService] PAYLOAD: ${jsonEncode(body)}');
  //     debugPrint('--------------------------------------------------');
  //
  //     final response = await http
  //         .post(
  //           url,
  //           headers: {'Content-Type': 'application/json', 'accept': '*/*'},
  //           body: jsonEncode(body),
  //         )
  //         .timeout(const Duration(seconds: 15));
  //
  //     debugPrint('--------------------------------------------------');
  //     debugPrint('[TripService] START RESPONSE: ${response.statusCode}');
  //     debugPrint('[TripService] START BODY: ${response.body}');
  //     debugPrint('--------------------------------------------------');
  //   } catch (e) {
  //     debugPrint('[TripService] START ERROR: $e');
  //   }
  // }

  Future<TripStartResponseModel?> startTrip({
    required String deviceTabletId,
    String? driverId,
    required double gpsLatitude,
    required double gpsLongitude,
    required DateTime startedAt,
  }) async {
    final url = Uri.parse('$_baseUrl$_startTripPath');
    final body = {
      'deviceTabletId': deviceTabletId,
      if (driverId != null && driverId.isNotEmpty) 'driverId': driverId,
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'startedAt': startedAt.toUtc().toIso8601String(),
    };

    try {
      debugPrint('--------------------------------------------------');
      debugPrint('[TripService] START TRIP POST -> $url');
      debugPrint('[TripService] PAYLOAD: ${jsonEncode(body)}');
      debugPrint('--------------------------------------------------');

      final response = await http
          .post(
        url,
        headers: {'Content-Type': 'application/json', 'accept': '*/*'},
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15));

      debugPrint('--------------------------------------------------');
      debugPrint('[TripService] START RESPONSE: ${response.statusCode}');
      debugPrint('[TripService] START BODY: ${response.body}');
      debugPrint('--------------------------------------------------');

      // Only parse on a successful status with a non-empty body.
      if (response.statusCode >= 200 &&
          response.statusCode < 300 &&
          response.body.isNotEmpty) {
        return tripStartResponseModelFromJson(response.body);
      }
      return null;
    } catch (e) {
      debugPrint('[TripService] START ERROR: $e');
      return null;
    }
  }

  Future<void> endTrip({
    required String deviceTabletId,
    required double gpsLatitude,
    required double gpsLongitude,
    required double distanceKm,
    required DateTime endedAt,
  }) async {
    final url = Uri.parse('$_baseUrl$_endTripPath');
    final body = {
      'deviceTabletId': deviceTabletId,
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'distanceKm': distanceKm,
      'endedAt': endedAt.toUtc().toIso8601String(),
    };

    try {
      debugPrint('--------------------------------------------------');
      debugPrint('[TripService] END TRIP POST -> $url');
      debugPrint('[TripService] PAYLOAD: ${jsonEncode(body)}');
      debugPrint('--------------------------------------------------');

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json', 'accept': '*/*'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('--------------------------------------------------');
      debugPrint('[TripService] END RESPONSE: ${response.statusCode}');
      debugPrint('[TripService] END BODY: ${response.body}');
      debugPrint('--------------------------------------------------');
    } catch (e) {
      debugPrint('[TripService] END ERROR: $e');
    }
  }
}

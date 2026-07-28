// lib/services/trip_service.dart
// Handles starting and ending trips via the backend trip APIs.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

import '../models/trip_start_response_model.dart';

class TripService {
  static const String _baseUrl = 'https://proximity-driver-api.prod-app.in';
  static const String _startTripPath = '/api/trips/start';
  static const String _endTripPath = '/api/trips/end';
  static const String _boxName = 'trips_queue';

  Box get _box => Hive.box(_boxName);
  bool _isSyncing = false;

  int get pendingCount => _box.length;

  // ── Queue trip start locally (called when API is offline / fails) ─────────
  void queueTripStart({
    required String deviceTabletId,
    String? driverId,
    required double gpsLatitude,
    required double gpsLongitude,
    required DateTime startedAt,
  }) {
    final body = <String, dynamic>{
      'type': 'start',
      'deviceTabletId': deviceTabletId,
      if (driverId != null && driverId.isNotEmpty) 'driverId': driverId,
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'startedAt': startedAt.toUtc().toIso8601String(),
    };
    final key = 'trip_${DateTime.now().microsecondsSinceEpoch}';
    _box.put(key, jsonEncode(body));
    debugPrint('[TripService] Trip START queued offline (key=$key)');
  }

  // ── Queue trip end locally (called when API is offline / fails) ───────────
  void queueTripEnd({
    required String deviceTabletId,
    required double gpsLatitude,
    required double gpsLongitude,
    required double distanceKm,
    required DateTime endedAt,
  }) {
    final body = <String, dynamic>{
      'type': 'end',
      'deviceTabletId': deviceTabletId,
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'distanceKm': distanceKm,
      'endedAt': endedAt.toUtc().toIso8601String(),
    };
    final key = 'trip_${DateTime.now().microsecondsSinceEpoch}';
    _box.put(key, jsonEncode(body));
    debugPrint('[TripService] Trip END queued offline (key=$key)');
  }

  // ── Sync all pending queued trip events to API ────────────────────────────
  /// Processes start/end events in chronological order.
  /// Stops on first network error so partial sends don't create gaps.
  Future<void> syncPendingTrips() async {
    if (_isSyncing || _box.isEmpty) return;
    _isSyncing = true;
    try {
      final keys = _box.keys.toList()..sort(); // chronological order
      debugPrint('[TripService] Syncing ${keys.length} pending trip event(s)...');
      for (final key in keys) {
        final String? jsonBody = _box.get(key);
        if (jsonBody == null) {
          await _box.delete(key);
          continue;
        }
        try {
          final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;
          final type = decoded['type'] as String?;
          final payload = Map<String, dynamic>.from(decoded)..remove('type');
          final url = Uri.parse(
            type == 'start' ? '$_baseUrl$_startTripPath' : '$_baseUrl$_endTripPath',
          );
          debugPrint('[TripService] Syncing trip $type → $url');
          final response = await http
              .post(
                url,
                headers: {'Content-Type': 'application/json', 'accept': '*/*'},
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 15));
          debugPrint('[TripService] Sync $type → ${response.statusCode}');
          if (response.statusCode >= 200 && response.statusCode < 300) {
            await _box.delete(key);
            debugPrint('[TripService] ✓ Trip $type synced and removed from queue');
          } else if (response.statusCode == 404) {
            // Trip not found on server — already closed/timed-out or start was lost.
            // Discard so it doesn't block the queue forever.
            await _box.delete(key);
            debugPrint('[TripService] 404 trip $type — stale event discarded from queue');
          } else if (response.statusCode >= 500) {
            // Server crash — stop and retry next cycle
            debugPrint('[TripService] Server error ${response.statusCode} — will retry later');
            break;
          } else {
            // Other client error (400, 422, etc.) — discard, retrying won't help
            await _box.delete(key);
            debugPrint('[TripService] Client error ${response.statusCode} for trip $type — discarded');
          }
        } catch (e) {
          debugPrint('[TripService] Network error during sync: $e — stopping');
          break;
        }
      }
    } finally {
      _isSyncing = false;
    }
  }

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

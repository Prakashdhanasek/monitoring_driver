// lib/services/incidents_service.dart
// Handles offline queuing and background syncing of incident reports via Hive.
// Incidents are saved locally first, then uploaded to the API in batches.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

class IncidentsService {
  static const String _boxName = 'incidentsBox';
  static const String _apiUrl =
      'https://proximity-driver-api.prod-app.in/api/incidents';

  Box get _box => Hive.box(_boxName);

  // ── Queue an Incident Locally ─────────────────────────────

  /// Saves an incident to the local Hive queue.
  /// The incident will be uploaded by [syncPendingIncidents] later.
  void queueIncident({
    required String deviceTabletId,
    required String eventType,
    required String riskLevel,
    required double aiConfidence,
    required double vehicleSpeed,
    required double gpsLatitude,
    required double gpsLongitude,
    String? vehicleId,
    String? vehicleRegistrationNumber,
    String? driverId,
    String? driverName,
    String snapshotUrl = 'string',
    String videoClipUrl = 'string',
    bool isOnline = true,
  }) {
    final body = {
      'deviceTabletId': deviceTabletId,
      'eventType': eventType,
      'riskLevel': riskLevel,
      'aiConfidence': (aiConfidence * 100).toInt(),
      'vehicleSpeed': vehicleSpeed.toInt(),
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'snapshotUrl': snapshotUrl.isEmpty ? 'string' : snapshotUrl,
      'videoClipUrl': videoClipUrl.isEmpty ? 'string' : videoClipUrl,
      'status': 'Open',
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      if (vehicleId != null) 'vehicleId': vehicleId,
      if (vehicleRegistrationNumber != null) 'vehicleRegistrationNumber': vehicleRegistrationNumber,
      if (driverId != null) 'driverId': driverId,
      if (driverName != null) 'driverName': driverName,
    };

    final key = DateTime.now().millisecondsSinceEpoch.toString();
    _box.put(key, jsonEncode(body));

    debugPrint('==================================================');
    if (isOnline) {
      debugPrint('[ONLINE QUEUE] Device is ONLINE. Queueing incident for immediate sync.');
    } else {
      debugPrint('[OFFLINE QUEUE] Device is OFFLINE. Incident saved locally in Hive.');
    }
    debugPrint('[IncidentsService] EVENT TYPE: $eventType');
    debugPrint('[IncidentsService] BODY: ${jsonEncode(body)}');
    debugPrint('==================================================');
  }

  // ── Sync Pending Incidents to API ─────────────────────────

  /// Attempts to upload all pending incidents to the API.
  /// Successfully uploaded incidents are removed from the local queue.
  /// Stops on the first network error to avoid spamming failed requests.
  Future<void> syncPendingIncidents() async {
    if (_box.isEmpty) return;

    final url = Uri.parse(_apiUrl);
    final keys = _box.keys.toList();

    debugPrint('==================================================');
    debugPrint('[SYNC START] Moving ${keys.length} offline events to online server...');
    debugPrint('==================================================');

    // Upload in parallel batches of 10 requests to optimize throughput and response times
    const int batchSize = 10;
    bool networkFailed = false;

    for (int i = 0; i < keys.length; i += batchSize) {
      if (networkFailed) {
        debugPrint('[SYNC ABORTED] Sync aborted due to network connectivity issues.');
        break;
      }

      final end = (i + batchSize < keys.length) ? i + batchSize : keys.length;
      final batchKeys = keys.sublist(i, end);

      final futures = batchKeys.map((key) async {
        final String? jsonBody = _box.get(key);
        if (jsonBody == null) return;

        String eventType = 'Unknown';
        try {
          final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;
          eventType = decoded['eventType'] ?? 'Unknown';
        } catch (_) {}

        try {
          debugPrint('--------------------------------------------------');
          debugPrint('[API REQUEST] POST -> $url');
          debugPrint('[API REQUEST] PAYLOAD: $jsonBody');
          debugPrint('--------------------------------------------------');

          final response = await http
              .post(
                url,
                headers: {'Content-Type': 'application/json'},
                body: jsonBody,
              )
              .timeout(const Duration(seconds: 10));

          debugPrint('--------------------------------------------------');
          debugPrint('[API RESPONSE] Status Code: ${response.statusCode}');
          debugPrint('[API RESPONSE] Body: ${response.body}');
          debugPrint('--------------------------------------------------');

          if (response.statusCode == 200 || response.statusCode == 201) {
            debugPrint('[EVENT SYNC SUCCESS] ✓ Successfully moved offline event to online server: $key ($eventType)');
            _box.delete(key);
          } else {
            debugPrint(
              '[EVENT SYNC FAILURE] ✗ Failed to move offline event $key ($eventType) online. Status: ${response.statusCode}',
            );
          }
        } catch (e) {
          debugPrint('[EVENT SYNC ERROR] ✗ Error moving offline event $key ($eventType) online: $e');
          networkFailed = true;
        }
      });

      await Future.wait(futures);
    }

    debugPrint('==================================================');
    debugPrint('[SYNC COMPLETE] Finished moving offline events. Remaining pending: ${_box.length}');
    debugPrint('==================================================');
  }

  // ── Diagnostics ───────────────────────────────────────────

  /// Number of incidents waiting to be uploaded.
  int get pendingCount => _box.length;

  /// Clear all queued incidents (use with caution).
  Future<void> clearAll() async {
    await _box.clear();
    debugPrint('[IncidentsService] All pending incidents cleared.');
  }
}

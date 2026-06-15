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
    String snapshotUrl = '',
    String videoClipUrl = '',
  }) {
    final body = {
      'deviceTabletId': deviceTabletId,
      'eventType': eventType,
      'riskLevel': riskLevel,
      'aiConfidence': aiConfidence,
      'vehicleSpeed': vehicleSpeed,
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'snapshotUrl': snapshotUrl,
      'videoClipUrl': videoClipUrl,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    };

    final key = DateTime.now().millisecondsSinceEpoch.toString();
    _box.put(key, jsonEncode(body));

    debugPrint('==================================================');
    debugPrint('[IncidentsService] QUEUED: $eventType');
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

    debugPrint('[IncidentsService] Syncing ${keys.length} pending incidents...');

    for (final key in keys) {
      final String? jsonBody = _box.get(key);
      if (jsonBody == null) continue;

      try {
        final response = await http
            .post(
              url,
              headers: {'Content-Type': 'application/json'},
              body: jsonBody,
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200 || response.statusCode == 201) {
          debugPrint('[IncidentsService] ✓ Uploaded incident: $key');
          _box.delete(key);
        } else {
          debugPrint(
            '[IncidentsService] ✗ Failed $key (status: ${response.statusCode})',
          );
        }
      } catch (e) {
        debugPrint('[IncidentsService] ✗ Offline/Error for $key: $e');
        break; // Stop syncing; will retry on next timer tick
      }
    }
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

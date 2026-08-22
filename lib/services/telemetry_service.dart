// lib/services/telemetry_service.dart
// Handles sending location telemetry updates to the API every 3 seconds.
// Queues telemetry locally when offline and syncs when back online.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

class TelemetryService {
  static const String _apiUrl =
      'https://proximity-driver-api.prod-app.in/api/telemetry/location';
  static const String _boxName = 'telemetry_queue';
  static const String _keyQueue = 'pending_telemetry';
  static const int _maxQueueSize = 200; // Cap to prevent excessive storage

  bool _isSyncing = false;

  Box get _box => Hive.box(_boxName);

  /// Sends the current location and speed telemetry to the API.
  /// If offline or if the API call fails, queues it locally for later sync.
  Future<void> sendLocationTelemetry({
    required String deviceTabletId,
    String? tripId,
    required double latitude,
    required double longitude,
    required double speed,
    double heading = 0.0,
    double accuracy = 0.0,
    bool isOnline = true,
  }) async {
    final body = {
      'deviceTabletId': deviceTabletId,
      'tripId': tripId,
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed
          .toInt(), // wait, the API example says `speed: 0` float or int? Let's keep toInt() or let it strictly be double if needed, wait.
      'heading': heading,
      'accuracy': accuracy,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    if (!isOnline) {
      _queueTelemetry(body);
      return;
    }

    // Online: send directly
    final success = await _postTelemetry(body);
    if (!success) {
      // API failed even though online — queue for retry when connection restores
      _queueTelemetry(body);
    } else {
      // Direct post succeeded — if there are pending offline telemetry items, sync them now
      if (pendingCount > 0) {
        syncPendingTelemetry();
      }
    }
  }

  /// Syncs all pending offline telemetry to the API.
  /// Called when device comes back online.
  /// After each GPS item is sent to the backend, it is immediately cleared from offline storage.
  Future<void> syncPendingTelemetry() async {
    if (_isSyncing) return;
    if (!Hive.isBoxOpen(_boxName)) return;
    _isSyncing = true;

    try {
      final List<dynamic> queue = List.from(
        _box.get(_keyQueue, defaultValue: []) as List,
      );
      if (queue.isEmpty) {
        _isSyncing = false;
        return;
      }

      debugPrint(
        '[Telemetry] Syncing ${queue.length} queued offline telemetry entries to backend...',
      );

      // Group points by tripId. Points without tripId or null tripId fallback to old API.
      final Map<String, List<Map<String, dynamic>>> byTrip = {};
      final List<Map<String, dynamic>> noTrip = [];

      for (var entry in queue) {
        final map = Map<String, dynamic>.from(entry as Map);
        final tripId = map['tripId'] as String?;
        if (tripId != null && tripId.isNotEmpty) {
          byTrip.putIfAbsent(tripId, () => []).add(map);
        } else {
          noTrip.add(map);
        }
      }

      final List<dynamic> newRemaining = [];

      // 1. Process batch points for each tripId
      for (final tripId in byTrip.keys) {
        final points = byTrip[tripId]!;
        if (points.isEmpty) continue;

        final deviceTabletId = points.first['deviceTabletId']?.toString() ?? '';
        final pointsPayload = points
            .map(
              (p) => {
                'latitude': p['latitude'],
                'longitude': p['longitude'],
                'speed': p['speed'],
                'heading': p['heading'] ?? 0.0,
                'accuracy': p['accuracy'] ?? 0.0,
                'recordedAt': p['timestamp'],
              },
            )
            .toList();

        final batchBody = {
          'deviceTabletId': deviceTabletId,
          'points': pointsPayload,
        };

        final url = Uri.parse(
          'https://proximity-driver-api.prod-app.in/api/trips/$tripId/sync-locations',
        );
        try {
          final res = await http
              .post(
                url,
                headers: {'Content-Type': 'application/json', 'accept': '*/*'},
                body: jsonEncode(batchBody),
              )
              .timeout(const Duration(seconds: 8));

          if (res.statusCode >= 200 && res.statusCode < 300) {
            debugPrint(
              '[Telemetry] Synced ${points.length} points for trip $tripId.',
            );
          } else {
            debugPrint(
              '[Telemetry] Batch sync failed for trip $tripId (status ${res.statusCode}).',
            );
            newRemaining.addAll(points);
          }
        } catch (e) {
          debugPrint('[Telemetry] Batch sync exception: $e');
          newRemaining.addAll(points);
        }
      }

      // 2. Process old-style points (no tripId)
      for (var map in noTrip) {
        final success = await _postTelemetry(map);
        if (!success) {
          newRemaining.add(map);
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }

      await _box.put(_keyQueue, newRemaining);
      if (newRemaining.isEmpty) {
        debugPrint(
          '[Telemetry] All offline telemetry synced and queue completely cleared.',
        );
      } else {
        debugPrint(
          '[Telemetry] ${newRemaining.length} offline entries failed to sync. Kept in queue for retry.',
        );
      }
    } catch (e) {
      debugPrint('[Telemetry] Sync error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  int get pendingCount {
    if (!Hive.isBoxOpen(_boxName)) return 0;
    final queue = _box.get(_keyQueue, defaultValue: []) as List;
    return queue.length;
  }

  void _queueTelemetry(Map<String, dynamic> body) {
    if (!Hive.isBoxOpen(_boxName)) return;
    final List<dynamic> queue = List.from(
      _box.get(_keyQueue, defaultValue: []) as List,
    );
    queue.add(body);
    // Trim old entries if queue gets too large (keep latest)
    while (queue.length > _maxQueueSize) {
      queue.removeAt(0);
    }
    _box.put(_keyQueue, queue);
    debugPrint(
      '[Telemetry] Saved telemetry offline (${queue.length} pending): lat=${body['latitude']}, lng=${body['longitude']}',
    );
  }

  Future<bool> _postTelemetry(Map<String, dynamic> body) async {
    final url = Uri.parse(_apiUrl);
    // Remove timestamp before sending (API expects standard payload)
    final sendBody = Map<String, dynamic>.from(body);
    sendBody.remove('timestamp');
    sendBody.remove('tripId');
    sendBody.remove('heading');
    sendBody.remove('accuracy');

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json', 'accept': '*/*'},
            body: jsonEncode(sendBody),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      debugPrint('[Telemetry] API returned status ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[Telemetry] POST failed: $e');
      return false;
    }
  }
}

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
  /// If offline, queues it locally for later sync.
  Future<void> sendLocationTelemetry({
    required String deviceTabletId,
    required double latitude,
    required double longitude,
    required double speed,
    bool isOnline = true,
  }) async {
    final body = {
      'deviceTabletId': deviceTabletId,
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed.toInt(),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    if (!isOnline) {
      _queueTelemetry(body);
      return;
    }

    // Online: send directly
    final success = await _postTelemetry(body);
    if (!success) {
      // API failed even though online — queue for retry
      _queueTelemetry(body);
    }
  }

  /// Syncs all pending offline telemetry to the API.
  /// Called when device comes back online.
  Future<void> syncPendingTelemetry() async {
    if (_isSyncing) return;
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
        '[Telemetry] Syncing ${queue.length} queued telemetry entries...',
      );

      final List<dynamic> failed = [];
      for (final entry in queue) {
        final map = Map<String, dynamic>.from(entry as Map);
        final success = await _postTelemetry(map);
        if (!success) {
          failed.add(entry);
        }
        // Small delay to avoid flooding the API
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Keep only failed ones
      await _box.put(_keyQueue, failed);
      final synced = queue.length - failed.length;
      debugPrint(
        '[Telemetry] Sync complete: $synced sent, ${failed.length} remaining',
      );
    } catch (e) {
      debugPrint('[Telemetry] Sync error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  int get pendingCount {
    final queue = _box.get(_keyQueue, defaultValue: []) as List;
    return queue.length;
  }

  void _queueTelemetry(Map<String, dynamic> body) {
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
      '[Telemetry] Queued offline (${queue.length} pending): lat=${body['latitude']}, lng=${body['longitude']}',
    );
  }

  Future<bool> _postTelemetry(Map<String, dynamic> body) async {
    final url = Uri.parse(_apiUrl);
    // Remove timestamp before sending (API may not expect it)
    final sendBody = Map<String, dynamic>.from(body);
    sendBody.remove('timestamp');

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
      debugPrint('[Telemetry] API returned ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[Telemetry] POST failed: $e');
      return false;
    }
  }
}

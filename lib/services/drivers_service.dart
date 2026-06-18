// lib/services/drivers_service.dart
// Handles caching the driver list from the API into Hive.
// When online: fetches fresh data, replaces old cache, downloads new photos.
// When offline: returns the last cached driver list.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class DriversService {
  static const String _boxName = 'driversBox';
  static const String _keyDriversJson = 'offline_drivers';
  static const String _baseUrl = 'https://proximity-driver-api.prod-app.in';
  static const String _embeddingKey = 'safe_drive_mobilefacenet_v10';
  static const String _legacyEmbeddingKey = 'safe_drive_mobilefacenet_v9';

  Box get _box => Hive.box(_boxName);

  // ── Fetch Drivers from API ────────────────────────────────

  /// Fetches the driver list from the API for the given [deviceId].
  /// On success: caches the response in Hive, downloads photos, clears old embeddings.
  /// On failure: logs the error and falls back to the cached data.
  /// Returns the list of driver maps (may be empty).
  Future<List<Map<String, dynamic>>> fetchAndCacheDrivers(
    String deviceId,
  ) async {
    try {
      final url = Uri.parse('$_baseUrl/api/drivers/by-device/$deviceId');

      debugPrint('==================================================');
      debugPrint('[DriversService] FETCH DRIVERS FOR IMEI: $deviceId');
      debugPrint('[DriversService] API URL: $url');
      debugPrint('==================================================');

      final response = await http.get(url).timeout(const Duration(seconds: 15));

      debugPrint('[DriversService] STATUS: ${response.statusCode}');
      debugPrint('[DriversService] BODY: ${response.body}');

      if (response.statusCode == 200) {
        final List<dynamic> rawList = jsonDecode(response.body);

        if (rawList.isNotEmpty) {
          // ── Online + Drivers Found ──
          // 1. Remove old cached JSON
          _box.delete(_keyDriversJson);

          // 2. Store fresh JSON
          _box.put(_keyDriversJson, response.body);
          debugPrint(
            '[DriversService] Cached ${rawList.length} drivers in Hive.',
          );

          // 3. Download fresh photos (deletes old folder first)
          await _downloadPhotos(rawList);

          // 4. Clear old face embeddings so the auth engine re-enrolls
          await _clearEmbeddings();

          return rawList.cast<Map<String, dynamic>>();
        } else {
          // ── Online + Empty List ──
          debugPrint(
            '[DriversService] API returned 0 drivers. Clearing old cache.',
          );
          await clearCache();
          return [];
        }
      } else {
        debugPrint(
          '[DriversService] API error ${response.statusCode}. Using cache.',
        );
        return getCachedDrivers();
      }
    } catch (e) {
      debugPrint('[DriversService] Offline/error: $e. Using cache.');
      return getCachedDrivers();
    }
  }

  // ── Cached Drivers ────────────────────────────────────────

  /// Returns the locally cached driver list from Hive.
  /// Returns an empty list if no cache exists.
  List<Map<String, dynamic>> getCachedDrivers() {
    final cached = _box.get(_keyDriversJson);
    if (cached == null) {
      debugPrint('[DriversService] No cached drivers found.');
      return [];
    }
    try {
      final List<dynamic> list = jsonDecode(cached);
      debugPrint(
        '[DriversService] Loaded ${list.length} drivers from Hive cache.',
      );
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[DriversService] Error parsing cached drivers: $e');
      return [];
    }
  }

  /// Returns the cached driver record matching [id], comparing by string.
  Map<String, dynamic>? getDriverById(String id) {
    if (id.isEmpty || id == '—') return null;

    final drivers = getCachedDrivers();
    final result = drivers.firstWhere((driver) {
      final driverId = driver['id'];
      return driverId != null && driverId.toString() == id;
    }, orElse: () => <String, dynamic>{});
    return result.isNotEmpty ? result.cast<String, dynamic>() : null;
  }

  /// Check if there are any cached drivers available.
  bool get hasCachedDrivers => _box.containsKey(_keyDriversJson);

  // ── Photo Downloading ─────────────────────────────────────

  /// Downloads face photos for all drivers.
  /// Always deletes the old photos folder first to ensure fresh data.
  Future<void> _downloadPhotos(List<dynamic> drivers) async {
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/downloaded_faces');

    // Always wipe old photos first
    if (await photosDir.exists()) {
      await photosDir.delete(recursive: true);
      debugPrint('[DriversService] Deleted old photos folder.');
    }
    await photosDir.create(recursive: true);

    for (final driver in drivers) {
      final facePhotos = driver['facePhotos'] as List<dynamic>?;
      if (facePhotos == null || facePhotos.isEmpty) continue;

      for (final photo in facePhotos) {
        final photoPath = photo['photoPath'] as String?;
        final driverId = driver['id'] as String? ?? 'unknown';
        final driverName = driver['fullName'] as String? ?? 'Driver';

        if (photoPath == null) continue;

        try {
          final imgUrl = Uri.parse('$_baseUrl$photoPath');
          final res = await http.get(imgUrl);
          if (res.statusCode == 200) {
            final fileName =
                '${driverId}__${driverName.replaceAll(' ', '_')}__${DateTime.now().millisecondsSinceEpoch}.jpg';
            final file = File('${photosDir.path}/$fileName');
            await file.writeAsBytes(res.bodyBytes);
            debugPrint('[DriversService] Downloaded photo for $driverName');
          }
        } catch (e) {
          debugPrint('[DriversService] Error downloading $photoPath: $e');
        }
      }
    }
  }

  // ── Clear Cache ───────────────────────────────────────────

  /// Wipes all cached driver data: Hive JSON, photos folder, face embeddings.
  Future<void> clearCache() async {
    _box.delete(_keyDriversJson);

    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/downloaded_faces');
    if (await photosDir.exists()) {
      await photosDir.delete(recursive: true);
    }

    await _clearEmbeddings();
    debugPrint('[DriversService] All driver caches cleared.');
  }

  Future<void> _clearEmbeddings() async {
    const storage = FlutterSecureStorage();
    await storage.delete(key: _embeddingKey);
    await storage.delete(key: _legacyEmbeddingKey);
  }
}

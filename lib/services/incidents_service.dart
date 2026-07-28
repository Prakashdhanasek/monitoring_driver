import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

class IncidentsService {
  static const String _boxName = 'incidentsBox';
  static const String _apiBase = 'https://proximity-driver-api.prod-app.in';
  static const String _apiUrl = '$_apiBase/api/incidents';
  static const String _evidenceUrl = '$_apiBase/api/incidents/evidence';

  // Give up on an incident after this many rejections from the server
  // (e.g. repeated evidence-verification failures) instead of retrying forever.
  static const int _maxSyncAttempts = 2;

  Box get _box => Hive.box(_boxName);

  // Sync concurrency guard
  bool _isSyncing = false;

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
    String snapshotPath = '',
    String videoClipUrl = 'string',
    String videoPath = '',
    bool isOnline = true,
  }) {
    // IMPORTANT FIX:
    // Earlier we stored the evidence folder path directly.
    // During sync, the code was again taking the latest image from that folder.
    // So multiple incidents could upload the same latest image.
    //
    // Now we resolve the exact image file path at the moment the incident is queued.
    // This keeps each incident connected to the image that existed at that time.
    final String exactSnapshotPath = _resolveSnapshotPathAtQueueTime(
      snapshotPath,
    );

    final body = {
      'deviceTabletId': deviceTabletId,
      'eventType': eventType,
      'riskLevel': riskLevel,
      'aiConfidence': (aiConfidence * 100).toInt(),
      'vehicleSpeed': vehicleSpeed.toInt(),
      'gpsLatitude': gpsLatitude,
      'gpsLongitude': gpsLongitude,
      'snapshotUrl': (snapshotUrl.isNotEmpty && snapshotUrl != 'string') ? snapshotUrl : null,

      // snapshotPath = exact on-device image file path.
      // Sync-il upload cheyt URL aakum.
      if (exactSnapshotPath.isNotEmpty) 'snapshotPath': exactSnapshotPath,

      'videoClipUrl': (videoClipUrl.isNotEmpty && videoClipUrl != 'string') ? videoClipUrl : null,
      if (videoPath.isNotEmpty) 'videoPath': videoPath,
      'status': 'Open',
      'occurredAt': DateTime.now().toUtc().toIso8601String(),

      'vehicleId': (vehicleId != null && vehicleId.trim().isNotEmpty) ? vehicleId : null,
      'vehicleRegistrationNumber': (vehicleRegistrationNumber != null && vehicleRegistrationNumber.trim().isNotEmpty) ? vehicleRegistrationNumber : null,
      'driverId': (driverId != null && driverId.trim().isNotEmpty) ? driverId : null,
      'driverName': (driverName != null && driverName.trim().isNotEmpty) ? driverName : null,
    };

    final key = DateTime.now().microsecondsSinceEpoch.toString();
    _box.put(key, jsonEncode(body));

    debugPrint('==================================================');
    if (isOnline) {
      debugPrint(
        '[ONLINE QUEUE] Device is ONLINE. Queueing incident for immediate sync.',
      );
    } else {
      debugPrint(
        '[OFFLINE QUEUE] Device is OFFLINE. Incident saved locally in Hive.',
      );
    }
    debugPrint('[IncidentsService] EVENT TYPE: $eventType');
    debugPrint('[IncidentsService] SNAPSHOT PATH: $exactSnapshotPath');
    debugPrint('[IncidentsService] BODY: ${jsonEncode(body)}');
    debugPrint('==================================================');
  }

  // ── Sync Pending Incidents to API ─────────────────────────

  /// Attempts to upload all pending incidents to the API.
  /// Successfully uploaded incidents are removed from the local queue.
  /// Stops on the first network error to avoid spamming failed requests.
  Future<void> syncPendingIncidents() async {
    if (_isSyncing) {
      debugPrint('[IncidentsService] Sync already in progress. Skipping.');
      return;
    }
    if (_box.isEmpty) return;

    _isSyncing = true;
    try {
      final url = Uri.parse(_apiUrl);
      final keys = _box.keys.toList();

      debugPrint('==================================================');
      debugPrint(
        '[SYNC START] Moving ${keys.length} offline events to online server...',
      );
      debugPrint('==================================================');

      const int batchSize = 10;
      bool networkFailed = false;

      for (int i = 0; i < keys.length; i += batchSize) {
        if (networkFailed) {
          debugPrint(
            '[SYNC ABORTED] Sync aborted due to network connectivity issues.',
          );
          break;
        }

        final end = (i + batchSize < keys.length) ? i + batchSize : keys.length;
        final batchKeys = keys.sublist(i, end);

        final futures = batchKeys.map((key) async {
          final String? jsonBody = _box.get(key);
          if (jsonBody == null) return;

          String eventType = 'Unknown';

          try {
            final d = jsonDecode(jsonBody) as Map<String, dynamic>;
            eventType = d['eventType'] ?? 'Unknown';
          } catch (_) {}

          try {
            final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;

             // ── STEP 1: snapshotPath undenkil, image evidence endpoint-il
             // upload cheyt server URL vaanguka. Aa URL snapshotUrl aakkuka. ──
             final String? snapshotPath = decoded['snapshotPath'] as String?;
 
             if (snapshotPath != null && snapshotPath.isNotEmpty) {
               final File? snapshotFile = _findLatestSnapshotFile(snapshotPath);
 
               if (snapshotFile != null && await snapshotFile.exists()) {
                 debugPrint(
                   '[IncidentsService] Uploading exact evidence file: ${snapshotFile.path}',
                 );
 
                 final uploadedUrl = await _uploadEvidence(snapshotFile);
 
                 if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
                   decoded['snapshotUrl'] = uploadedUrl;
                   decoded.remove('snapshotPath');
                   _box.put(key, jsonEncode(decoded)); // Save URL to avoid re-upload on retry
 
                   debugPrint(
                     '[IncidentsService] Evidence uploaded -> $uploadedUrl',
                   );
                 } else {
                   debugPrint(
                     '[IncidentsService] Evidence upload failed; will retry later.',
                   );
                   throw Exception('Snapshot image evidence upload failed; aborting sync of this incident.');
                 }
               } else {
                 debugPrint(
                   '[IncidentsService] Snapshot file not found: $snapshotPath',
                 );
                 // Only remove if file doesn't exist, to prevent infinite retries for a missing file
                 decoded.remove('snapshotPath');
                 _box.put(key, jsonEncode(decoded));
               }
             }
 
             // ── STEP 1.5: videoPath ──
             final String? videoPath = decoded['videoPath'] as String?;
             if (videoPath != null && videoPath.isNotEmpty) {
               final File videoFile = File(videoPath);
               if (await videoFile.exists()) {
                 debugPrint(
                   '[IncidentsService] Uploading video evidence file: ${videoFile.path}',
                 );
 
                 final uploadedUrl = await _uploadEvidence(videoFile);
 
                 if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
                   decoded['videoClipUrl'] = uploadedUrl;
                   decoded.remove('videoPath');
                   _box.put(key, jsonEncode(decoded)); // Save URL to avoid re-upload on retry
 
                   debugPrint(
                     '[IncidentsService] Video uploaded -> $uploadedUrl',
                   );
 
                   // Clean up the local temporary video file ONLY after successful upload
                   try {
                     await videoFile.delete();
                   } catch (_) {}
                 } else {
                   debugPrint(
                     '[IncidentsService] Video upload failed; will retry later.',
                   );
                   throw Exception('Video evidence upload failed; aborting sync of this incident.');
                 }
               } else {
                 debugPrint(
                   '[IncidentsService] Video file not found: $videoPath',
                 );
                 // Only remove if file doesn't exist, to prevent infinite retries for a missing file
                 decoded.remove('videoPath');
                 _box.put(key, jsonEncode(decoded));
               }
             }

            // Clean up payload: replace empty string or 'string' placeholder with null
            decoded.forEach((mapKey, value) {
              if (value is String) {
                final clean = value.trim();
                if (clean.isEmpty || clean.toLowerCase() == 'string') {
                  decoded[mapKey] = null;
                }
              }
            });

            // _syncAttempts is bookkeeping local to this device; never send it upstream.
            final Map<String, dynamic> outgoing = Map.of(decoded)
              ..remove('_syncAttempts');
            final String finalBody = jsonEncode(outgoing);

            debugPrint('--------------------------------------------------');
            debugPrint('[API REQUEST] POST -> $url');
            debugPrint('[API REQUEST] PAYLOAD: $finalBody');
            debugPrint('--------------------------------------------------');

            // ── STEP 2: incident JSON POST, always application/json ──
            final response = await http
                .post(
                  url,
                  headers: {'Content-Type': 'application/json'},
                  body: finalBody,
                )
                .timeout(const Duration(seconds: 60));

            debugPrint('--------------------------------------------------');
            debugPrint('[API RESPONSE] Status Code: ${response.statusCode}');
            debugPrint('[API RESPONSE] Body: ${response.body}');
            debugPrint('--------------------------------------------------');

            if (response.statusCode == 200 || response.statusCode == 201) {
              debugPrint(
                '[EVENT SYNC SUCCESS] ✓ Successfully moved offline event to online server: $key ($eventType)',
              );
              _box.delete(key);
            } else {
              // The server responded (as opposed to a network/timeout error below),
              // so this is a real rejection, e.g. evidence-verification failure.
              // Count attempts and give up after _maxSyncAttempts so a permanently
              // rejected incident doesn't get retried forever on every sync cycle.
              final int attempts = (decoded['_syncAttempts'] as int? ?? 0) + 1;
              if (attempts >= _maxSyncAttempts) {
                debugPrint(
                  '[EVENT SYNC DROPPED] ✗ Giving up on offline event $key ($eventType) '
                  'after $attempts failed attempts. Status: ${response.statusCode}. '
                  'Body: ${response.body}',
                );
                _box.delete(key);
              } else {
                decoded['_syncAttempts'] = attempts;
                _box.put(key, jsonEncode(decoded));
                debugPrint(
                  '[EVENT SYNC FAILURE] ✗ Failed to move offline event $key ($eventType) '
                  'online. Status: ${response.statusCode}. Attempt $attempts/$_maxSyncAttempts.',
                );
              }
            }
          } catch (e) {
            debugPrint(
              '[EVENT SYNC ERROR] ✗ Error moving offline event $key ($eventType) online: $e',
            );
            networkFailed = true;
          }
        });

        await Future.wait(futures);
      }

      debugPrint('==================================================');
      debugPrint(
        '[SYNC COMPLETE] Finished moving offline events. Remaining pending: ${_box.length}',
      );
      debugPrint('==================================================');
    } finally {
      _isSyncing = false;
    }
  }

  /// Evidence image-ne POST /api/incidents/evidence multipart-il upload cheyt,
  /// server tharunna URL return cheyyunnu. Endpoint illenkil null.
  Future<String?> _uploadEvidence(File imageFile) async {
    try {
      final request = http.MultipartRequest('POST', Uri.parse(_evidenceUrl));

      request.files.add(
        await http.MultipartFile.fromPath('file', imageFile.path),
      );

      debugPrint('[IncidentsService] Uploading evidence -> $_evidenceUrl');
      debugPrint('[IncidentsService] Evidence file path -> ${imageFile.path}');

      final streamed = await request.send().timeout(
        const Duration(seconds: 60),
      );

      final response = await http.Response.fromStream(streamed);

      debugPrint(
        '[IncidentsService] Evidence upload status: ${response.statusCode}',
      );
      debugPrint('[IncidentsService] Evidence upload body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;

        final dynamic url =
            decoded['url'] ??
            decoded['fileUrl'] ??
            decoded['snapshotUrl'] ??
            decoded['path'];

        return url?.toString();
      }

      return null;
    } catch (e) {
      debugPrint('[IncidentsService] Evidence upload error: $e');
      return null;
    }
  }

  // ── Diagnostics ───────────────────────────────────────────

  /// Number of incidents waiting to be uploaded.
  int get pendingCount => _box.length;

  /// Clear all queued incidents.
  Future<void> clearAll() async {
    await _box.clear();
    debugPrint('[IncidentsService] All pending incidents cleared.');
  }

  /// Resolve exact snapshot image file path when incident is queued.
  ///
  /// If snapshotPath is already a file, return that file path.
  /// If snapshotPath is a folder, pick the latest image inside it immediately.
  /// This prevents all queued incidents from later using the same latest image.
  String _resolveSnapshotPathAtQueueTime(String snapshotPath) {
    try {
      if (snapshotPath.isEmpty) return '';

      final snapshotFile = _findLatestSnapshotFile(snapshotPath);

      if (snapshotFile != null && snapshotFile.existsSync()) {
        return snapshotFile.path;
      }

      return snapshotPath;
    } catch (e) {
      debugPrint('[IncidentsService] resolve snapshot path error: $e');
      return snapshotPath;
    }
  }

  /// If the snapshot path points to a folder, return the newest image file inside it.
  /// If the snapshot path points to a file, return that file directly.
  File? _findLatestSnapshotFile(String snapshotPath) {
    final file = File(snapshotPath);

    if (file.existsSync()) {
      return file;
    }

    final directory = Directory(snapshotPath);

    if (!directory.existsSync()) {
      return null;
    }

    final imageFiles = directory
        .listSync(recursive: false)
        .whereType<File>()
        .where((candidate) {
          final extension = candidate.path.split('.').last.toLowerCase();

          return extension == 'jpg' ||
              extension == 'jpeg' ||
              extension == 'png';
        })
        .toList();

    if (imageFiles.isEmpty) {
      return null;
    }

    imageFiles.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );

    return imageFiles.first;
  }
}

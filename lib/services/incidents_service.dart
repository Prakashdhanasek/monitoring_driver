// // // lib/services/incidents_service.dart
// // // Handles offline queuing and background syncing of incident reports via Hive.
// // // Incidents are saved locally first, then uploaded to the API in batches.

// // import 'dart:convert';
// // import 'dart:io';

// // import 'package:flutter/foundation.dart';
// // import 'package:hive/hive.dart';
// // import 'package:http/http.dart' as http;

// // class IncidentsService {
// //   static const String _boxName = 'incidentsBox';
// //   static const String _apiUrl =
// //       'https://proximity-driver-api.prod-app.in/api/incidents';

// //   Box get _box => Hive.box(_boxName);

// //   // ── Queue an Incident Locally ─────────────────────────────

// //   /// Saves an incident to the local Hive queue.
// //   /// The incident will be uploaded by [syncPendingIncidents] later.
// //   void queueIncident({
// //     required String deviceTabletId,
// //     required String eventType,
// //     required String riskLevel,
// //     required double aiConfidence,
// //     required double vehicleSpeed,
// //     required double gpsLatitude,
// //     required double gpsLongitude,
// //     String? vehicleId,
// //     String? vehicleRegistrationNumber,
// //     String? driverId,
// //     String? driverName,
// //     String snapshotUrl = 'string',
// //     String snapshotPath = '',
// //     String videoClipUrl = 'string',
// //     bool isOnline = true,
// //   }) {
// //     final body = {
// //       'deviceTabletId': deviceTabletId,
// //       'eventType': eventType,
// //       'riskLevel': riskLevel,
// //       'aiConfidence': (aiConfidence * 100).toInt(),
// //       'vehicleSpeed': vehicleSpeed.toInt(),
// //       'gpsLatitude': gpsLatitude,
// //       'gpsLongitude': gpsLongitude,
// //       'snapshotUrl': snapshotUrl.isEmpty ? 'string' : snapshotUrl,
// //       if (snapshotPath.isNotEmpty) 'snapshotPath': snapshotPath,
// //       'videoClipUrl': videoClipUrl.isEmpty ? 'string' : videoClipUrl,
// //       'status': 'Open',
// //       'occurredAt': DateTime.now().toUtc().toIso8601String(),
// //       if (vehicleId != null) 'vehicleId': vehicleId,
// //       if (vehicleRegistrationNumber != null)
// //         'vehicleRegistrationNumber': vehicleRegistrationNumber,
// //       if (driverId != null) 'driverId': driverId,
// //       if (driverName != null) 'driverName': driverName,
// //     };

// //     final key = DateTime.now().millisecondsSinceEpoch.toString();
// //     _box.put(key, jsonEncode(body));

// //     debugPrint('==================================================');
// //     if (isOnline) {
// //       debugPrint(
// //         '[ONLINE QUEUE] Device is ONLINE. Queueing incident for immediate sync.',
// //       );
// //     } else {
// //       debugPrint(
// //         '[OFFLINE QUEUE] Device is OFFLINE. Incident saved locally in Hive.',
// //       );
// //     }
// //     debugPrint('[IncidentsService] EVENT TYPE: $eventType');
// //     debugPrint('[IncidentsService] BODY: ${jsonEncode(body)}');
// //     debugPrint('==================================================');
// //   }

// //   // ── Sync Pending Incidents to API ─────────────────────────

// //   /// Attempts to upload all pending incidents to the API.
// //   /// Successfully uploaded incidents are removed from the local queue.
// //   /// Stops on the first network error to avoid spamming failed requests.
// //   Future<void> syncPendingIncidents() async {
// //     if (_box.isEmpty) return;

// //     final url = Uri.parse(_apiUrl);
// //     final keys = _box.keys.toList();

// //     debugPrint('==================================================');
// //     debugPrint(
// //       '[SYNC START] Moving ${keys.length} offline events to online server...',
// //     );
// //     debugPrint('==================================================');

// //     // Upload in parallel batches of 10 requests to optimize throughput and response times
// //     const int batchSize = 10;
// //     bool networkFailed = false;

// //     for (int i = 0; i < keys.length; i += batchSize) {
// //       if (networkFailed) {
// //         debugPrint(
// //           '[SYNC ABORTED] Sync aborted due to network connectivity issues.',
// //         );
// //         break;
// //       }

// //       final end = (i + batchSize < keys.length) ? i + batchSize : keys.length;
// //       final batchKeys = keys.sublist(i, end);

// //       final futures = batchKeys.map((key) async {
// //         final String? jsonBody = _box.get(key);
// //         if (jsonBody == null) return;

// //         String eventType = 'Unknown';
// //         try {
// //           final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;
// //           eventType = decoded['eventType'] ?? 'Unknown';
// //         } catch (_) {}

// //         try {
// //           debugPrint('--------------------------------------------------');
// //           debugPrint('[API REQUEST] POST -> $url');
// //           debugPrint('[API REQUEST] PAYLOAD: $jsonBody');
// //           debugPrint('--------------------------------------------------');

// //           final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;
// //           final String? snapshotPath = decoded['snapshotPath'] as String?;
// //           final File? snapshotFile =
// //               snapshotPath != null && snapshotPath.isNotEmpty
// //               ? _findLatestSnapshotFile(snapshotPath)
// //               : null;

// //           late http.Response response;
// //           if (snapshotFile != null && await snapshotFile.exists()) {
// //             final request = http.MultipartRequest('POST', url);
// //             decoded.forEach((key, value) {
// //               if (key == 'snapshotPath') return;
// //               request.fields[key] = value?.toString() ?? '';
// //             });
// //             request.files.add(
// //               await http.MultipartFile.fromPath('snapshot', snapshotFile.path),
// //             );
// //             final streamed = await request.send().timeout(
// //               const Duration(seconds: 15),
// //             );
// //             response = await http.Response.fromStream(streamed);
// //           } else {
// //             response = await http
// //                 .post(
// //                   url,
// //                   headers: {'Content-Type': 'application/json'},
// //                   body: jsonBody,
// //                 )
// //                 .timeout(const Duration(seconds: 10));
// //           }

// //           debugPrint('--------------------------------------------------');
// //           debugPrint('[API RESPONSE] Status Code: ${response.statusCode}');
// //           debugPrint('[API RESPONSE] Body: ${response.body}');
// //           debugPrint('--------------------------------------------------');

// //           if (response.statusCode == 200 || response.statusCode == 201) {
// //             debugPrint(
// //               '[EVENT SYNC SUCCESS] ✓ Successfully moved offline event to online server: $key ($eventType)',
// //             );
// //             _box.delete(key);
// //           } else {
// //             debugPrint(
// //               '[EVENT SYNC FAILURE] ✗ Failed to move offline event $key ($eventType) online. Status: ${response.statusCode}',
// //             );
// //           }
// //         } catch (e) {
// //           debugPrint(
// //             '[EVENT SYNC ERROR] ✗ Error moving offline event $key ($eventType) online: $e',
// //           );
// //           networkFailed = true;
// //         }
// //       });

// //       await Future.wait(futures);
// //     }

// //     debugPrint('==================================================');
// //     debugPrint(
// //       '[SYNC COMPLETE] Finished moving offline events. Remaining pending: ${_box.length}',
// //     );
// //     debugPrint('==================================================');
// //   }

// //   // ── Diagnostics ───────────────────────────────────────────

// //   /// Number of incidents waiting to be uploaded.
// //   int get pendingCount => _box.length;

// //   /// Clear all queued incidents (use with caution).
// //   Future<void> clearAll() async {
// //     await _box.clear();
// //     debugPrint('[IncidentsService] All pending incidents cleared.');
// //   }

// //   /// If the snapshot path points to a folder, return the newest image file inside it.
// //   File? _findLatestSnapshotFile(String snapshotPath) {
// //     final file = File(snapshotPath);
// //     if (file.existsSync()) {
// //       return file;
// //     }

// //     final directory = Directory(snapshotPath);
// //     if (!directory.existsSync()) {
// //       return null;
// //     }

// //     final imageFiles = directory
// //         .listSync(recursive: false)
// //         .whereType<File>()
// //         .where((candidate) {
// //           final extension = candidate.path.split('.').last.toLowerCase();
// //           return extension == 'jpg' ||
// //               extension == 'jpeg' ||
// //               extension == 'png';
// //         })
// //         .toList();

// //     if (imageFiles.isEmpty) {
// //       return null;
// //     }

// //     imageFiles.sort(
// //       (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
// //     );
// //     return imageFiles.first;
// //   }
// // }



// // lib/services/incidents_service.dart
// // Handles offline queuing and background syncing of incident reports via Hive.
// // Incidents are saved locally first, then uploaded to the API in batches.

// import 'dart:convert';
// import 'dart:io';

// import 'package:flutter/foundation.dart';
// import 'package:hive/hive.dart';
// import 'package:http/http.dart' as http;

// class IncidentsService {
//   static const String _boxName = 'incidentsBox';
//   static const String _apiBase = 'https://proximity-driver-api.prod-app.in';
//   static const String _apiUrl = '$_apiBase/api/incidents';
//   static const String _evidenceUrl = '$_apiBase/api/incidents/evidence';

//   Box get _box => Hive.box(_boxName);

//   // ── Queue an Incident Locally ─────────────────────────────

//   /// Saves an incident to the local Hive queue.
//   /// The incident will be uploaded by [syncPendingIncidents] later.
//   void queueIncident({
//     required String deviceTabletId,
//     required String eventType,
//     required String riskLevel,
//     required double aiConfidence,
//     required double vehicleSpeed,
//     required double gpsLatitude,
//     required double gpsLongitude,
//     String? vehicleId,
//     String? vehicleRegistrationNumber,
//     String? driverId,
//     String? driverName,
//     String snapshotUrl = 'string',
//     String snapshotPath = '',
//     String videoClipUrl = 'string',
//     bool isOnline = true,
//   }) {
//     final body = {
//       'deviceTabletId': deviceTabletId,
//       'eventType': eventType,
//       'riskLevel': riskLevel,
//       'aiConfidence': (aiConfidence * 100).toInt(),
//       'vehicleSpeed': vehicleSpeed.toInt(),
//       'gpsLatitude': gpsLatitude,
//       'gpsLongitude': gpsLongitude,
//       'snapshotUrl': snapshotUrl.isEmpty ? 'string' : snapshotUrl,
//       // snapshotPath = on-device evidence folder. Sync-il upload cheyt URL aakum.
//       if (snapshotPath.isNotEmpty) 'snapshotPath': snapshotPath,
//       'videoClipUrl': videoClipUrl.isEmpty ? 'string' : videoClipUrl,
//       'status': 'Open',
//       'occurredAt': DateTime.now().toUtc().toIso8601String(),
//       if (vehicleId != null) 'vehicleId': vehicleId,
//       if (vehicleRegistrationNumber != null)
//         'vehicleRegistrationNumber': vehicleRegistrationNumber,
//       if (driverId != null) 'driverId': driverId,
//       if (driverName != null) 'driverName': driverName,
//     };

//     final key = DateTime.now().millisecondsSinceEpoch.toString();
//     _box.put(key, jsonEncode(body));

//     debugPrint('==================================================');
//     if (isOnline) {
//       debugPrint(
//         '[ONLINE QUEUE] Device is ONLINE. Queueing incident for immediate sync.',
//       );
//     } else {
//       debugPrint(
//         '[OFFLINE QUEUE] Device is OFFLINE. Incident saved locally in Hive.',
//       );
//     }
//     debugPrint('[IncidentsService] EVENT TYPE: $eventType');
//     debugPrint('[IncidentsService] BODY: ${jsonEncode(body)}');
//     debugPrint('==================================================');
//   }

//   // ── Sync Pending Incidents to API ─────────────────────────

//   /// Attempts to upload all pending incidents to the API.
//   /// Successfully uploaded incidents are removed from the local queue.
//   /// Stops on the first network error to avoid spamming failed requests.
//   Future<void> syncPendingIncidents() async {
//     if (_box.isEmpty) return;

//     final url = Uri.parse(_apiUrl);
//     final keys = _box.keys.toList();

//     debugPrint('==================================================');
//     debugPrint(
//       '[SYNC START] Moving ${keys.length} offline events to online server...',
//     );
//     debugPrint('==================================================');

//     const int batchSize = 10;
//     bool networkFailed = false;

//     for (int i = 0; i < keys.length; i += batchSize) {
//       if (networkFailed) {
//         debugPrint(
//           '[SYNC ABORTED] Sync aborted due to network connectivity issues.',
//         );
//         break;
//       }

//       final end = (i + batchSize < keys.length) ? i + batchSize : keys.length;
//       final batchKeys = keys.sublist(i, end);

//       final futures = batchKeys.map((key) async {
//         final String? jsonBody = _box.get(key);
//         if (jsonBody == null) return;

//         String eventType = 'Unknown';
//         try {
//           final d = jsonDecode(jsonBody) as Map<String, dynamic>;
//           eventType = d['eventType'] ?? 'Unknown';
//         } catch (_) {}

//         try {
//           final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;

//           // ── STEP 1: snapshotPath undenkil, image evidence endpoint-il
//           //    upload cheyt server URL vaanguka. Aa URL snapshotUrl aakkuka. ──
//           final String? snapshotPath = decoded['snapshotPath'] as String?;
//           if (snapshotPath != null && snapshotPath.isNotEmpty) {
//             final File? snapshotFile = _findLatestSnapshotFile(snapshotPath);
//             if (snapshotFile != null && await snapshotFile.exists()) {
//               final uploadedUrl = await _uploadEvidence(snapshotFile);
//               if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
//                 decoded['snapshotUrl'] = uploadedUrl;
//                 debugPrint(
//                   '[IncidentsService] Evidence uploaded -> $uploadedUrl',
//                 );
//               } else {
//                 debugPrint(
//                   '[IncidentsService] Evidence upload failed; sending without snapshot.',
//                 );
//               }
//             }
//             // Device path API-il ayakkenda — neekkuka.
//             decoded.remove('snapshotPath');
//           }

//           final String finalBody = jsonEncode(decoded);

//           debugPrint('--------------------------------------------------');
//           debugPrint('[API REQUEST] POST -> $url');
//           debugPrint('[API REQUEST] PAYLOAD: $finalBody');
//           debugPrint('--------------------------------------------------');

//           // ── STEP 2: incident JSON POST (eppozhum application/json) ──
//           final response = await http
//               .post(
//                 url,
//                 headers: {'Content-Type': 'application/json'},
//                 body: finalBody,
//               )
//               .timeout(const Duration(seconds: 15));

//           debugPrint('--------------------------------------------------');
//           debugPrint('[API RESPONSE] Status Code: ${response.statusCode}');
//           debugPrint('[API RESPONSE] Body: ${response.body}');
//           debugPrint('--------------------------------------------------');

//           if (response.statusCode == 200 || response.statusCode == 201) {
//             debugPrint(
//               '[EVENT SYNC SUCCESS] ✓ Successfully moved offline event to online server: $key ($eventType)',
//             );
//             _box.delete(key);
//           } else {
//             debugPrint(
//               '[EVENT SYNC FAILURE] ✗ Failed to move offline event $key ($eventType) online. Status: ${response.statusCode}',
//             );
//           }
//         } catch (e) {
//           debugPrint(
//             '[EVENT SYNC ERROR] ✗ Error moving offline event $key ($eventType) online: $e',
//           );
//           networkFailed = true;
//         }
//       });

//       await Future.wait(futures);
//     }

//     debugPrint('==================================================');
//     debugPrint(
//       '[SYNC COMPLETE] Finished moving offline events. Remaining pending: ${_box.length}',
//     );
//     debugPrint('==================================================');
//   }

//   /// Evidence image-ne POST /api/incidents/evidence (multipart) il upload cheyt,
//   /// server tharunna URL return cheyyunnu. Endpoint illenkil (404) null.
//   Future<String?> _uploadEvidence(File imageFile) async {
//     try {
//       final request = http.MultipartRequest('POST', Uri.parse(_evidenceUrl));
//       request.files.add(
//         await http.MultipartFile.fromPath('file', imageFile.path),
//       );

//       debugPrint('[IncidentsService] Uploading evidence -> $_evidenceUrl');
//       final streamed =
//           await request.send().timeout(const Duration(seconds: 20));
//       final response = await http.Response.fromStream(streamed);

//       debugPrint(
//         '[IncidentsService] Evidence upload status: ${response.statusCode}',
//       );
//       debugPrint('[IncidentsService] Evidence upload body: ${response.body}');

//       if (response.statusCode == 200 || response.statusCode == 201) {
//         final decoded = jsonDecode(response.body) as Map<String, dynamic>;
//         return decoded['url'] as String?;
//       }
//       return null;
//     } catch (e) {
//       debugPrint('[IncidentsService] Evidence upload error: $e');
//       return null;
//     }
//   }

//   // ── Diagnostics ───────────────────────────────────────────

//   /// Number of incidents waiting to be uploaded.
//   int get pendingCount => _box.length;

//   /// Clear all queued incidents (use with caution).
//   Future<void> clearAll() async {
//     await _box.clear();
//     debugPrint('[IncidentsService] All pending incidents cleared.');
//   }

//   /// If the snapshot path points to a folder, return the newest image file inside it.
//   File? _findLatestSnapshotFile(String snapshotPath) {
//     final file = File(snapshotPath);
//     if (file.existsSync()) {
//       return file;
//     }

//     final directory = Directory(snapshotPath);
//     if (!directory.existsSync()) {
//       return null;
//     }

//     final imageFiles = directory
//         .listSync(recursive: false)
//         .whereType<File>()
//         .where((candidate) {
//           final extension = candidate.path.split('.').last.toLowerCase();
//           return extension == 'jpg' ||
//               extension == 'jpeg' ||
//               extension == 'png';
//         })
//         .toList();

//     if (imageFiles.isEmpty) {
//       return null;
//     }

//     imageFiles.sort(
//       (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
//     );
//     return imageFiles.first;
//   }
// }



// lib/services/incidents_service.dart
// Handles offline queuing and background syncing of incident reports via Hive.
// Incidents are saved locally first, then uploaded to the API in batches.

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
                  debugPrint(
                    '[IncidentsService] Evidence uploaded -> $uploadedUrl',
                  );
                } else {
                  debugPrint(
                    '[IncidentsService] Evidence upload failed; sending without snapshot.',
                  );
                }
              } else {
                debugPrint(
                  '[IncidentsService] Snapshot file not found: $snapshotPath',
                );
              }

              // Device path API-il ayakkenda — neekkuka.
              decoded.remove('snapshotPath');
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
                  debugPrint(
                    '[IncidentsService] Video uploaded -> $uploadedUrl',
                  );
                } else {
                  debugPrint(
                    '[IncidentsService] Video upload failed; sending without video clip.',
                  );
                }
                
                // Clean up the local temporary video file after attempting upload
                try {
                  await videoFile.delete();
                } catch (_) {}
              } else {
                debugPrint(
                  '[IncidentsService] Video file not found: $videoPath',
                );
              }

              // Remove device path from payload
              decoded.remove('videoPath');
            }

            // Clean up payload: replace empty string or 'string' placeholder with null
            decoded.forEach((key, value) {
              if (value is String) {
                final clean = value.trim();
                if (clean.isEmpty || clean.toLowerCase() == 'string') {
                  decoded[key] = null;
                }
              }
            });

            final String finalBody = jsonEncode(decoded);

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
                .timeout(const Duration(seconds: 15));

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
              debugPrint(
                '[EVENT SYNC FAILURE] ✗ Failed to move offline event $key ($eventType) online. Status: ${response.statusCode}',
              );
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

        final dynamic url = decoded['url'] ??
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
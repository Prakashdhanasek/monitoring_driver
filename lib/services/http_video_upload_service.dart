import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class HttpVideoUploadService {
  /// Scans the local upload queue folder and uploads any pending video files to the HTTP API.
  /// Successfully uploaded files are deleted from the local disk.
  /// 
  /// [uploadUrl] is the REST API endpoint (e.g., 'https://api.yourdomain.com/v1/trips/upload-video')
  /// [bearerToken] is an optional auth token for authorization headers.
  Future<void> uploadPendingFiles({
    required String uploadUrl,
    required String vehicleId,
    String? driverId,
    String? tripId,
    String? cameraType = 'front',
    String? bearerToken,
    String fileParamName = 'File',
  }) async {
    final docDir = await _getVisibleDirectory();
    final queueDir = Directory(p.join(docDir.path, 'esp32_upload_queue'));

    if (!await queueDir.exists()) {
      debugPrint('[HTTP Upload] Queue directory does not exist. Nothing to upload.');
      return;
    }

    final files = queueDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.mp4'))
        .toList();

    if (files.isEmpty) {
      debugPrint('[HTTP Upload] No pending files found in upload queue.');
      return;
    }

    debugPrint('==================================================');
    debugPrint('[HTTP Upload START] Uploading ${files.length} video chunks to $uploadUrl...');
    debugPrint('==================================================');

    for (final file in files) {
      final fileName = p.basename(file.path);
      debugPrint('[HTTP Uploading] Sending: $fileName...');

      try {
        final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

        // Add headers
        if (bearerToken != null) {
          request.headers['Authorization'] = 'Bearer $bearerToken';
        }
        
        // Add required/optional fields matching backend specification
        request.fields['VehicleId'] = vehicleId;
        if (driverId != null && driverId.isNotEmpty) {
          request.fields['DriverId'] = driverId;
        }
        if (tripId != null && tripId.isNotEmpty) {
          request.fields['TripId'] = tripId;
        }
        if (cameraType != null && cameraType.isNotEmpty) {
          request.fields['CameraType'] = cameraType;
        }
        
        final lastModified = await file.lastModified();
        request.fields['OccurredDateTime'] = lastModified.toUtc().toIso8601String();

        // Attach video file
        request.files.add(
          await http.MultipartFile.fromPath(
            fileParamName,
            file.path,
          ),
        );

        debugPrint('--- HTTP MULTIPART REQUEST DETAILS ---');
        debugPrint('URL: $uploadUrl');
        debugPrint('Headers: ${request.headers}');
        debugPrint('Fields: ${request.fields}');
        debugPrint('File Parameter Name: $fileParamName');
        debugPrint('File Path: ${file.path}');
        debugPrint('File Size: ${await file.length()} bytes');
        debugPrint('--------------------------------------');

        final responseStream = await request.send().timeout(
          const Duration(minutes: 5), // Videos can be large, give it time
        );

        final response = await http.Response.fromStream(responseStream);

        debugPrint('--- HTTP MULTIPART RESPONSE DETAILS ---');
        debugPrint('Status Code: ${response.statusCode}');
        debugPrint('Response Body: ${response.body}');
        debugPrint('---------------------------------------');

        if (response.statusCode == 200 || response.statusCode == 201) {
          debugPrint('[HTTP Upload SUCCESS] ✓ Uploaded: $fileName (Status: ${response.statusCode})');
          
          // Delete local file to free space
          await file.delete();
          debugPrint('[HTTP Upload] Deleted local chunk: $fileName');
        } else {
          debugPrint('[HTTP Upload ERROR] ✗ Failed uploading $fileName — Status: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('[HTTP Upload ERROR] Exception uploading $fileName: $e');
      }
      debugPrint('--------------------------------------------------');
    }

    debugPrint('==================================================');
    debugPrint('[HTTP Upload COMPLETE] Upload run finished.');
    debugPrint('==================================================');
  }

  Future<Directory> _getVisibleDirectory() async {
    if (Platform.isAndroid) {
      final downloadDir = Directory('/storage/emulated/0/Download/monitoring_driver');
      if (!await downloadDir.exists()) {
        try {
          await downloadDir.create(recursive: true);
        } catch (_) {
          final extDir = await getExternalStorageDirectory();
          return extDir!;
        }
      }
      return downloadDir;
    } else {
      return await getApplicationDocumentsDirectory();
    }
  }
}

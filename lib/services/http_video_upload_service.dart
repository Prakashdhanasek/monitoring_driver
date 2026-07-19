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
  Future<int> uploadPendingFiles({
    required String uploadUrl,
    required String vehicleId,
    required String deviceTabletId,
    String? driverId,
    String? tripId,
    String? cameraType = 'FrontCam',
    String? bearerToken,
    String fileParamName = 'File',
  }) async {
    final docDir = await _getVisibleDirectory();
    final queueDir = Directory(p.join(docDir.path, 'esp32_upload_queue'));

    final List<File> files = [];

    if (await queueDir.exists()) {
      final queueFiles = queueDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList();
      files.addAll(queueFiles);
    }



    int successCount = 0;

    if (files.isEmpty) {
      debugPrint('[HTTP Upload] No pending or saved videos found in local storage.');
      return successCount;
    }

    debugPrint('==================================================');
    debugPrint('[HTTP Upload START] Uploading ${files.length} video files to $uploadUrl...');
    debugPrint('==================================================');

    for (final file in files) {
      final fileName = p.basename(file.path);
      debugPrint('[HTTP Uploading] Processing file: $fileName...');

      try {
        final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

        // Add headers
        if (bearerToken != null) {
          request.headers['Authorization'] = 'Bearer $bearerToken';
        }
        request.headers['accept'] = '*/*';
        
        // Add required/optional fields matching backend specification
        request.fields['VehicleId'] = vehicleId;
        request.fields['DeviceTabletId'] = deviceTabletId;
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
        request.fields['OccurredDateTime'] = "";

        // Print request details for debugging
        debugPrint('==================================================');
        debugPrint('[HTTP  ] POST -> $uploadUrl');
        debugPrint('[HTTP Upload Request] Headers: ${request.headers}');
        debugPrint('[HTTP Upload Request] Fields: ${request.fields}');
        debugPrint('[HTTP Upload Request] File Parameter: $fileParamName');
        debugPrint('[HTTP Upload Request] File Name: $fileName');
        debugPrint('[HTTP Upload Request] Source Path: ${file.path}');
        debugPrint('==================================================');

        // Copy permanent video to a temporary directory if it's in the permanent esp32_videos folder
        final isPermanentVideo = file.path.contains('esp32_videos');
        File uploadTargetFile = file;
        if (isPermanentVideo) {
          final tempDir = await getTemporaryDirectory();
          final tempPath = p.join(tempDir.path, 'temp_upload_$fileName');
          uploadTargetFile = await file.copy(tempPath);
          debugPrint('[HTTP Upload] Copied permanent video to temp path: $tempPath');
        }

        // Attach video file
        request.files.add(
          await http.MultipartFile.fromPath(
            fileParamName,
            uploadTargetFile.path,
          ),
        );

        final responseStream = await request.send().timeout(
          const Duration(minutes: 5), // Videos can be large, give it time
        );

        final response = await http.Response.fromStream(responseStream);

        debugPrint('==================================================');
        debugPrint('[HTTP Upload Response] STATUS: ${response.statusCode}');
        debugPrint('[HTTP Upload Response] BODY: ${response.body}');
        debugPrint('==================================================');

        // Clean up temporary files
        if (isPermanentVideo) {
          try {
            await uploadTargetFile.delete();
            debugPrint('[HTTP Upload] Cleaned up temp upload copy.');
          } catch (e) {
            debugPrint('[HTTP Upload] Failed to delete temp copy: $e');
          }
        } else if (response.statusCode == 200 || response.statusCode == 201) {
          // Delete from upload queue folder on success
          await file.delete();
          successCount++;
          debugPrint('[HTTP Upload] Deleted local chunk: $fileName');
        }
      } catch (e) {
        debugPrint('[HTTP Upload ERROR] Exception uploading $fileName: $e');
      }
      debugPrint('--------------------------------------------------');
    }

    debugPrint('==================================================');
    debugPrint('[HTTP Upload COMPLETE] Upload run finished.');
    debugPrint('==================================================');
    return successCount;
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

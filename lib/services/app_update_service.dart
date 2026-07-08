// lib/services/app_update_service.dart
// Checks the server for a newer APK version and downloads it with progress.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  final String versionName;
  final int versionCode;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;

  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.forceUpdate,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) => AppUpdateInfo(
        versionName: json['versionName'] as String,
        versionCode: json['versionCode'] as int,
        downloadUrl: json['downloadUrl'] as String,
        releaseNotes: json['releaseNotes'] as String? ?? '',
        forceUpdate: json['forceUpdate'] as bool? ?? false,
      );
}

class AppUpdateService {
  static const String _latestUrl =
      'https://proximity-driver-api.prod-app.in/api/app-version/latest';
  static const String _apkFileName = 'proximity_update.apk';

  /// Returns [AppUpdateInfo] if the server has a newer versionCode, else null.
  /// Returns null silently on any network error so startup is never blocked.
  Future<AppUpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      // Use the raw versionCode as-is. Server APKs are built without
      // --split-per-abi so their versionCode matches pubspec's build number
      // directly, and we keep it monotonically increasing (10021, 10022, ...).
      final currentCode = int.tryParse(packageInfo.buildNumber) ?? 0;

      debugPrint('==================================================');
      debugPrint('[APP UPDATE] CHECK STARTED');
      debugPrint('[APP UPDATE] Current version : ${packageInfo.version}');
      debugPrint('[APP UPDATE] Current versionCode : $currentCode');
      debugPrint('[APP UPDATE] Request URL : $_latestUrl');
      debugPrint('==================================================');

      final response = await http
          .get(Uri.parse(_latestUrl))
          .timeout(const Duration(seconds: 10));

      debugPrint('==================================================');
      debugPrint('[APP UPDATE] RESPONSE STATUS : ${response.statusCode}');
      debugPrint('[APP UPDATE] RESPONSE BODY   : ${response.body}');
      debugPrint('==================================================');

      if (response.statusCode == 200) {
        final info = AppUpdateInfo.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);

        debugPrint('==================================================');
        debugPrint('[APP UPDATE] Server versionName : ${info.versionName}');
        debugPrint('[APP UPDATE] Server versionCode : ${info.versionCode}');
        debugPrint('[APP UPDATE] forceUpdate        : ${info.forceUpdate}');
        debugPrint('[APP UPDATE] downloadUrl        : ${info.downloadUrl}');

        if (info.versionCode > currentCode) {
          debugPrint('[APP UPDATE] ✓ UPDATE AVAILABLE ($currentCode → ${info.versionCode})');
          debugPrint('==================================================');
          return info;
        }
        debugPrint('[APP UPDATE] ✓ App is up to date ($currentCode >= ${info.versionCode}).');
        debugPrint('==================================================');
        return null;
      }

      if (response.statusCode == 404) {
        debugPrint('[APP UPDATE] ✓ No APK published yet (404). Skipping.');
        debugPrint('==================================================');
      } else {
        debugPrint('[APP UPDATE] ✗ Unexpected status ${response.statusCode}. Skipping.');
        debugPrint('==================================================');
      }

      return null;
    } catch (e) {
      debugPrint('==================================================');
      debugPrint('[APP UPDATE] ✗ Check failed (non-fatal): $e');
      debugPrint('==================================================');
      return null;
    }
  }

  /// Streams download progress [0.0 → 1.0].
  /// Throws on network/IO error so the caller can show an error state.
  Stream<double> downloadApk(String downloadUrl) async* {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_apkFileName');

    // Delete any stale/partial file first.
    if (await file.exists()) await file.delete();

    // dart:io HttpClient follows redirects automatically and streams the body,
    // so it is safe for large files on low-RAM devices.
    final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await httpClient
          .getUrl(Uri.parse(downloadUrl))
          .timeout(const Duration(minutes: 15));
      final response = await request.close();

      debugPrint('[AppUpdate] Download status: ${response.statusCode}, '
          'content-length: ${response.contentLength}');

      if (response.statusCode != 200) {
        throw Exception('Download failed with HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength; // -1 if unknown
      int downloaded = 0;

      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          downloaded += chunk.length;
          if (contentLength > 0) {
            yield downloaded / contentLength;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      debugPrint('[AppUpdate] APK saved: $downloaded bytes → ${file.path}');

      if (downloaded == 0) {
        throw Exception('Downloaded APK is empty (0 bytes)');
      }
    } finally {
      httpClient.close();
    }
    yield 1.0;
  }

  /// Local path of the downloaded APK file.
  Future<String> getApkPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_apkFileName';
  }

  /// Returns true if this app is the active Device Owner.
  Future<bool> isDeviceOwner() async {
    try {
      const channel = MethodChannel('kiosk');
      return await channel.invokeMethod<bool>('isDeviceOwner') ?? false;
    } catch (e) {
      debugPrint('[AppUpdate] isDeviceOwner check failed: $e');
      return false;
    }
  }

  /// Installs the APK at [apkPath] via the native PackageInstaller.Session.
  /// Silent (no user prompt) when the app is Device Owner.
  /// Falls back to system installer UI when not Device Owner.
  Future<void> installApkSilently(String apkPath) async {
    const channel = MethodChannel('kiosk');
    try {
      await channel.invokeMethod<bool>('installApk', {'path': apkPath});
      debugPrint('[AppUpdate] Native installApk invoked successfully.');
    } catch (e) {
      debugPrint('[AppUpdate] Native install error: $e');
      rethrow;
    }
  }
}

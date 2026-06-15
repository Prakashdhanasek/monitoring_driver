import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../monitor_flow.dart';

class DeviceEnrollmentScreen extends StatefulWidget {
  const DeviceEnrollmentScreen({super.key});

  @override
  State<DeviceEnrollmentScreen> createState() => _DeviceEnrollmentScreenState();
}

class _DeviceEnrollmentScreenState extends State<DeviceEnrollmentScreen> {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  bool _isLoading = true;
  String _statusMessage = "Initializing device details...";
  String? _errorMessage;
  
  @override
  void initState() {
    super.initState();
    _autoRegisterDevice();
  }

  void _navigateToMonitor() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MonitorFlow()),
    );
  }

  Future<String> _getDeviceImei() async {
    // 1. Try to read a previously registered/stored 15-digit IMEI from secure storage
    String? storedImei = await _storage.read(key: 'device_id');
    if (storedImei != null && storedImei.length == 15 && RegExp(r'^\d+$').hasMatch(storedImei)) {
      debugPrint('[Enroll] Found existing valid 15-digit IMEI in storage: $storedImei');
      return storedImei;
    }

    String? hardwareImei;

    // 2. Request phone permission on mobile platforms
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final status = await Permission.phone.request();
        if (status.isGranted) {
          if (Platform.isAndroid) {
            const channel = MethodChannel('com.proximity.driver/device_info');
            hardwareImei = await channel.invokeMethod<String>('getImei');
          }
        } else {
          debugPrint('[Enroll] Phone permission not granted.');
        }
      } catch (e) {
        debugPrint('[Enroll] Error querying hardware IMEI: $e');
      }
    }

    // Validate the retrieved hardware IMEI (must be exactly 15 digits)
    if (hardwareImei != null && hardwareImei.length == 15 && RegExp(r'^\d+$').hasMatch(hardwareImei)) {
      debugPrint('[Enroll] Successfully retrieved hardware IMEI: $hardwareImei');
      // Save it to secure storage
      await _storage.write(key: 'device_id', value: hardwareImei);
      return hardwareImei;
    }

    // 3. Fallback: Generate a persistent 15-digit mock IMEI (using TAC '35' prefix)
    debugPrint('[Enroll] Hardware IMEI blocked, invalid, or permission denied. Generating persistent mock IMEI...');
    final random = Random();
    final buffer = StringBuffer('35'); // standard TAC prefix for smartphones
    for (int i = 0; i < 13; i++) {
      buffer.write(random.nextInt(10));
    }
    final mockImei = buffer.toString();
    
    // Save it to secure storage as the device ID so it remains consistent
    await _storage.write(key: 'device_id', value: mockImei);
    debugPrint('[Enroll] Generated persistent mock IMEI: $mockImei');
    return mockImei;
  }

  Future<void> _autoRegisterDevice() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _statusMessage = "Registering device...";
    });

    try {
      final deviceInfo = DeviceInfoPlugin();
      String deviceId = '';
      String deviceModel = '';
      String osVersion = '';

      // Get 15-digit IMEI (real or persistent mock fallback)
      deviceId = await _getDeviceImei();

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        deviceModel = androidInfo.model;
        osVersion = 'Android ${androidInfo.version.release} (SDK ${androidInfo.version.sdkInt})';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceModel = iosInfo.utsname.machine;
        osVersion = 'iOS ${iosInfo.systemVersion}';
      } else {
        deviceModel = Platform.operatingSystem;
        osVersion = Platform.operatingSystemVersion;
      }

      if (deviceModel.isEmpty) deviceModel = Platform.operatingSystem;
      if (osVersion.isEmpty) osVersion = Platform.operatingSystemVersion;

      // Call POST to register
      final url = Uri.parse('https://proximity-driver-api.prod-app.in/api/devices/register');
      final body = jsonEncode({
        "deviceId": deviceId,
        "deviceModel": deviceModel,
        "osVersion": osVersion,
      });

      debugPrint('==================================================');
      debugPrint('[Enroll] DEVICE IMEI/ID TO REGISTER: $deviceId');
      debugPrint('[Enroll] API REQUEST URL: $url');
      debugPrint('[Enroll] API REQUEST BODY: $body');
      debugPrint('==================================================');
      
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: body,
      ).timeout(const Duration(seconds: 15));

      debugPrint('==================================================');
      debugPrint('[Enroll] API RESPONSE STATUS CODE: ${response.statusCode}');
      debugPrint('[Enroll] API RESPONSE BODY: ${response.body}');
      debugPrint('==================================================');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final Map<String, dynamic> resData = jsonDecode(response.body);
        final registeredId = resData['deviceId'] as String? ?? deviceId;
        
        await _storage.write(key: 'device_id', value: registeredId);
        debugPrint('[Enroll] Device registered successfully. ID: $registeredId');
      } else {
        debugPrint('[Enroll] Registration returned status code: ${response.statusCode}');
        // Store our deviceId as fallback
        await _storage.write(key: 'device_id', value: deviceId);
      }
    } catch (e) {
      debugPrint('[Enroll] Registration connection error: $e');
      // If offline, ensure there's at least a fallback ID in storage
      String? storedId = await _storage.read(key: 'device_id');
      if (storedId == null) {
        storedId = 'device_${DateTime.now().millisecondsSinceEpoch}';
        await _storage.write(key: 'device_id', value: storedId);
      }
    } finally {
      if (mounted) {
        setState(() {
          _statusMessage = "Launching monitor session...";
          _isLoading = false;
        });
      }
      // Navigate to main monitor flow
      _navigateToMonitor();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Premium dark theme background
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [
              Color(0xFF1E293B),
              Color(0xFF0F172A),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Premium pulsing radar setup icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF3B82F6).withOpacity(0.1),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B82F6).withOpacity(0.2),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.sensors_rounded,
                  size: 50,
                  color: Color(0xFF3B82F6),
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                'SYSTEM INITIALIZATION',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _statusMessage,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 32),
              if (_isLoading)
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

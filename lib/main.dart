import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'views/device_enrollment_screen.dart';

Future<String> getDeviceId() async {
  const storage = FlutterSecureStorage();
  String? deviceId = await storage.read(key: 'device_id');
  if (deviceId == null) {
    deviceId = 'device_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}';
    await storage.write(key: 'device_id', value: deviceId);
  }
  return deviceId;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Call method to get device id
  String deviceId = await getDeviceId();
  debugPrint('Device ID initialized: $deviceId');

  // Driver-facing: portrait only, keep it simple.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const DriverMonitorApp());
}

class DriverMonitorApp extends StatelessWidget {
  const DriverMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Driver Monitor',
      debugShowCheckedModeBanner: false,
      home: DeviceEnrollmentScreen(),
    );
  }
}
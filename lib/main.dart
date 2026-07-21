import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:hive_flutter/hive_flutter.dart';

import 'views/device_enrollment_screen.dart';
import 'kiosk.dart';
import 'services/background_telemetry_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive and open boxes
  await Hive.initFlutter();
  await Hive.openBox('settingsBox');
  await Hive.openBox('driversBox');
  await Hive.openBox('incidentsBox');

  // Start GPS tracking and telemetry immediately (before driver auth)
  await BackgroundTelemetryService.instance.start();

  // Driver-facing: portrait only, keep it simple.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Turn on kiosk / lock-task mode as soon as the app starts.
  Kiosk.start();
  WakelockPlus.enable();

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

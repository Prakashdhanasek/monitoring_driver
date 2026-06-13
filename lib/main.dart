import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'monitor_flow.dart';
import 'kiosk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Driver-facing: portrait only, keep it simple.
  SystemChrome.setPreferredOrientations([
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
      // App opens straight into the camera -> verify -> monitoring flow.
      home: MonitorFlow(),
    );
  }
}

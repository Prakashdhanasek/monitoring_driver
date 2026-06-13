import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'views/device_enrollment_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../monitor_flow.dart';

class DeviceEnrollmentScreen extends StatefulWidget {
  const DeviceEnrollmentScreen({super.key});

  @override
  State<DeviceEnrollmentScreen> createState() => _DeviceEnrollmentScreenState();
}

class _DeviceEnrollmentScreenState extends State<DeviceEnrollmentScreen> {
  final TextEditingController _imeController = TextEditingController();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  bool _isLoading = false;
  String? _errorMessage;
  
  @override
  void initState() {
    super.initState();
    _checkOfflineData();
  }

  Future<void> _checkOfflineData() async {
    final data = await _storage.read(key: 'offline_drivers');
    if (data != null && data.isNotEmpty) {
      // Offline data exists, we can proceed to MonitorFlow
      _navigateToMonitor();
    }
  }

  void _navigateToMonitor() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MonitorFlow()),
    );
  }

  Future<void> _fetchAndEnroll() async {
    final ime = _imeController.text.trim();
    if (ime.isEmpty) {
      setState(() => _errorMessage = "Please enter an IME number");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final url = Uri.parse('https://proximity-driver-api.prod-app.in/api/drivers/by-device/$ime');
      final response = await http.get(url).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final List<dynamic> driversList = jsonDecode(response.body);
        
        if (driversList.isEmpty) {
          setState(() => _errorMessage = "No drivers found for this device.");
          return;
        }

        // Save the raw JSON for offline usage
        await _storage.write(key: 'offline_drivers', value: response.body);
        
        // Also save the device ID
        await _storage.write(key: 'device_id', value: ime);

        // Download photos
        await _downloadPhotos(driversList);

        // Clear the old face embeddings cache so the engine is forced to re-enroll the newly downloaded photos
        await _storage.delete(key: 'safe_drive_mobilefacenet_v9');

        // Success
        _navigateToMonitor();
      } else {
        setState(() => _errorMessage = "API Error: ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _errorMessage = "Network or parsing error: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _downloadPhotos(List<dynamic> drivers) async {
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/downloaded_faces');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    } else {
      // Clear old photos
      await photosDir.delete(recursive: true);
      await photosDir.create(recursive: true);
    }

    const baseUrl = 'https://proximity-driver-api.prod-app.in';

    for (final driver in drivers) {
      final facePhotos = driver['facePhotos'] as List<dynamic>?;
      if (facePhotos != null && facePhotos.isNotEmpty) {
        for (final photo in facePhotos) {
          final photoPath = photo['photoPath'] as String?;
          final driverId = driver['id'] as String? ?? 'unknown';
          final driverName = driver['fullName'] as String? ?? 'Driver';
          
          if (photoPath != null) {
            try {
              final imgUrl = Uri.parse('$baseUrl$photoPath');
              final res = await http.get(imgUrl);
              if (res.statusCode == 200) {
                // Save it locally, encoding the driver info in the filename so FaceAuthEngine can read it
                final fileName = '${driverId}_${driverName.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.jpg';
                final file = File('${photosDir.path}/$fileName');
                await file.writeAsBytes(res.bodyBytes);
                debugPrint('Downloaded photo for $driverName');
              }
            } catch (e) {
              debugPrint('Error downloading photo $photoPath: $e');
            }
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  spreadRadius: 5,
                )
              ]
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.settings_cell_rounded, size: 64, color: Color(0xFF3B82F6)),
                const SizedBox(height: 16),
                const Text(
                  'Device Setup',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Enter the device IME number to fetch authorized drivers for this vehicle.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF6B7280)),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _imeController,
                  decoration: const InputDecoration(
                    labelText: 'IME / Device ID',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.tag),
                  ),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _fetchAndEnroll,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _isLoading 
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Confirm & Download', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

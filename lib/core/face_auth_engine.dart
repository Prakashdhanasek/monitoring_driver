import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'monitor_state.dart';

class FaceAuthEngine {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // v8: forces fresh enrollment from newly added reference images.
  static const String _keyEmbedding = 'safe_drive_mobilefacenet_v10';

  // MobileFaceNet: 112x112 RGB input → 192D embedding
  Interpreter? _faceNetInterpreter;
  bool _modelLoaded = false;

  List<List<double>> _referenceEmbeddings = [];

  List<String> _referenceLabels = [];

  // Session-scoped embedding for Unknown Driver (or active trip baseline)
  List<double>? activeTripEmbedding;

  bool isEnrolled = false;

  // Last successfully matched folder label.
  // Used by FaceAuthView to show correct driver name.
  String? lastMatchedLabel;

  // Balanced threshold:
  // 0.72 was too strict and caused all faces to fail.
  // 0.85 allows valid reference drivers while still blocking many unknown faces.
  static const double kAuthThreshold = 0.95;

  int _consecutiveMatch = 0;
  int _consecutiveMiss = 0;
  static const int kMatchFrames = 3;
  static const int kMissFrames = 5;

  // ── Public API ─────────────────────────────────────────────────────────────

  void setActiveTripEmbedding(List<double>? embedding) {
    activeTripEmbedding = embedding;
  }

  List<double>? extractLiveEmbedding(
      CameraImage image,
      int rotation,
      Rect boundingBox,
      ) {
    return _embedFaceFromCameraImage(image, rotation, boundingBox);
  }

  Future<void> initialize() async {
    await _loadFaceNetModel();

    // Check if new photos were downloaded from API that haven't been enrolled yet
    bool shouldEnrollDownloaded = false;
    try {
      final appDir = await _getVisibleDirectory();
      final downloadedDir = Directory('${appDir.path}/downloaded_faces');
      if (await downloadedDir.exists()) {
        final count = downloadedDir.listSync().whereType<File>().length;
        if (count > 0) {
          shouldEnrollDownloaded = true;
        }
      }
    } catch (_) {}

    if (!shouldEnrollDownloaded) {
      try {
        final stored = await _storage.read(key: _keyEmbedding);
        if (stored != null) {
          final decoded = jsonDecode(stored);

          if (decoded is Map) {
            _referenceEmbeddings = (decoded['embeddings'] as List)
                .map<List<double>>((e) => List<double>.from(e as List))
                .toList();

            _referenceLabels = (decoded['labels'] as List)
                .map<String>((e) => e.toString())
                .toList();
          } else if (decoded is List) {
            _referenceEmbeddings = decoded
                .map<List<double>>((e) => List<double>.from(e as List))
                .toList();

            _referenceLabels = List<String>.filled(
              _referenceEmbeddings.length,
              'unknown',
            );
          }

          if (_referenceEmbeddings.isNotEmpty) {
            isEnrolled = true;
            print(
              '[Auth] MobileFaceNet embeddings loaded from secure storage '
              '(${_referenceEmbeddings.length} faces).',
            );
            return;
          }
        }
      } catch (e) {
        print('[Auth] Storage read error: $e');
      }
    }

    await _enrollFromReferencePhotos();
  }

  /// Called every N frames with the live MLKit face and raw camera YUV bytes
  void processAuth(
      Face face,
      MonitorState state,
      CameraImage image,
      int rotation, {
        String? activeDriverId,
      }) {
    // Model still loading -> keep scanning.
    if (!_modelLoaded) {
      state.authStatus = AuthStatus.scanning;
      state.authDistance = -1.0;
      return;
    }

    final bool hasUnknownTripEmbedding = (activeTripEmbedding != null);

    // Model is ready but NO drivers enrolled AND no unknown trip embedding active.
    if ((!isEnrolled || _referenceEmbeddings.isEmpty) &&
        !hasUnknownTripEmbedding) {
      state.authStatus = AuthStatus.unauthorized;
      state.authDistance = -1.0;
      return;
    }

    // ── HEAD ANGLE LENIENCY FOR AUTHENTICATED DRIVER ─────────────────────────
    // If the driver is already authenticated, skip FaceNet for head turns (yaw, pitch, roll > 22°)
    // so checking mirrors or turning head never triggers false unauthorized states.
    if (state.authStatus == AuthStatus.authenticated) {
      final yaw = face.headEulerAngleY ?? 0.0;
      final pitch = face.headEulerAngleX ?? 0.0;
      final roll = face.headEulerAngleZ ?? 0.0;

      if (yaw.abs() > 22.0 || pitch.abs() > 22.0 || roll.abs() > 22.0) {
        return;
      }
    }

    final liveEmbedding = _embedFaceFromCameraImage(
      image,
      rotation,
      face.boundingBox,
    );

    if (liveEmbedding == null) {
      state.authStatus = AuthStatus.scanning;
      state.authDistance = -1.0;
      return;
    }

    // Find minimum distance across enrolled reference faces or active unknown trip embedding
    double minDist = double.infinity;
    int bestIdx = -1;
    String? bestLabel;

    if (activeTripEmbedding != null) {
      minDist = _euclidean(activeTripEmbedding!, liveEmbedding);
      bestLabel = '—|Unknown Driver';
    } else {
      for (int i = 0; i < _referenceEmbeddings.length; i++) {
        final label = _referenceLabels[i];
        if (activeDriverId != null &&
            activeDriverId.isNotEmpty &&
            activeDriverId != '—') {
          final parts = label.split('|');
          final refId = parts.isNotEmpty ? parts[0] : '';
          if (refId != activeDriverId) {
            continue; // Skip templates belonging to other drivers
          }
        }

        final d = _euclidean(_referenceEmbeddings[i], liveEmbedding);
        if (d < minDist) {
          minDist = d;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0 && bestIdx < _referenceLabels.length) {
        bestLabel = _referenceLabels[bestIdx];
      }
    }

    state.authDistance = minDist;

    print(
      '[AuthDBG] minDist=$minDist bestLabel=$bestLabel '
          'threshold=$kAuthThreshold',
    );

    // Instant driver swap detection threshold
    final double effectiveThreshold =
        (state.authStatus == AuthStatus.authenticated)
        ? kAuthThreshold + 0.05 // 0.95 + 0.05 = 1.00
        : kAuthThreshold;

    if (minDist < effectiveThreshold) {
      _consecutiveMatch++;
      _consecutiveMiss = 0;
      lastMatchedLabel = bestLabel;

      if (_consecutiveMatch >= kMatchFrames) {
        state.authStatus = AuthStatus.authenticated;
        state.authenticatedTrackingId =
            face.trackingId; // Lock on to this physical face
      }
    } else {
      _consecutiveMiss++;
      _consecutiveMatch = 0;
      lastMatchedLabel = null;

      // Instant driver swap: 2 consecutive mismatches trigger unauthorized (<0.3s)
      final requiredMisses = 2;

      if (_consecutiveMiss >= requiredMisses) {
        state.authStatus = AuthStatus.unauthorized;
        state.authenticatedTrackingId = null;
      }
    }
  }

  Future<void> resetAndReenroll() async {
    await _storage.delete(key: _keyEmbedding);
    isEnrolled = false;
    _referenceEmbeddings = [];
    _referenceLabels = [];
    activeTripEmbedding = null;
    lastMatchedLabel = null;
    _consecutiveMatch = 0;
    _consecutiveMiss = 0;
    await _enrollFromReferencePhotos();
  }

  void resetLiveAuthState() {
    activeTripEmbedding = null;
    lastMatchedLabel = null;
    _consecutiveMatch = 0;
    _consecutiveMiss = 0;
  }

  /// Synchronously clears all enrolled face data so [processAuth] cannot
  /// produce a match until [resetAndReenroll] or [_enrollFromReferencePhotos]
  /// completes. Use this before switching back to a scanning phase when you
  /// need to prevent an instant re-match on the next camera frame.

  void clearEnrollment() {
    isEnrolled = false;
    _referenceEmbeddings = [];
    _referenceLabels = [];
    activeTripEmbedding = null;
    lastMatchedLabel = null;
    _consecutiveMatch = 0;
    _consecutiveMiss = 0;
  }

  Future<void> clearCache() async {
    await _storage.delete(key: _keyEmbedding);
    isEnrolled = false;
    _referenceEmbeddings = [];
    _referenceLabels = [];
    activeTripEmbedding = null;
    lastMatchedLabel = null;
    _consecutiveMatch = 0;
    _consecutiveMiss = 0;
  }
  // ── MobileFaceNet Model Loading ────────────────────────────────────────────

  Future<void> _loadFaceNetModel() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _faceNetInterpreter = await Interpreter.fromAsset(
        'assets/models/mobile_face_net.tflite',
        options: options,
      );
      _modelLoaded = true;
      final inputShape = _faceNetInterpreter!.getInputTensor(0).shape;
      final outputShape = _faceNetInterpreter!.getOutputTensor(0).shape;
      print(
        '[Auth] MobileFaceNet loaded. Input: $inputShape, Output: $outputShape',
      );
    } catch (e) {
      print('[Auth] ERROR loading MobileFaceNet: $e');
      _modelLoaded = false;
    }
  }

  // ── Reference Photo Enrollment ─────────────────────────────────────────────

  Future<void> _enrollFromReferencePhotos() async {
    if (!_modelLoaded) {
      print('[Auth] Cannot enroll — MobileFaceNet not loaded.');
      return;
    }

    final tempDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: false,
        enableTracking: false,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    final List<List<double>> embeddings = [];
    final List<String> labels = [];

    // 1) First check for downloaded API photos
    final appDir = await _getVisibleDirectory();
    final downloadedDir = Directory('${appDir.path}/downloaded_faces');

    if (await downloadedDir.exists()) {
      final files = downloadedDir.listSync().whereType<File>().toList();
      print('[Auth] Found ${files.length} downloaded photos from API.');

      for (final file in files) {
        try {
          final imageBytes = await file.readAsBytes();
          final fileName = file.path.split(RegExp(r'[/\\]')).last;

          final inputImage = InputImage.fromFilePath(file.path);
          final faces = await tempDetector.processImage(inputImage);

          List<double>? embedding;
          if (faces.isNotEmpty) {
            embedding = _embedFaceFromJpeg(imageBytes, faces.first.boundingBox);
          } else {
            print('[Auth] ML Kit detected 0 faces in $fileName — using full image fallback.');
            embedding = _embedFaceFromJpeg(imageBytes, null);
          }

          if (embedding != null) {
            // Filename format: id__name__timestamp.jpg (or fallback to id_name_timestamp.jpg)
            String driverId = 'unknown';
            String driverName = 'unknown';
            if (fileName.contains('__')) {
              final parts = fileName.split('__');
              if (parts.isNotEmpty) driverId = parts[0];
              if (parts.length >= 2)
                driverName = parts[1].replaceAll('_', ' ');
            } else {
              final parts = fileName.split('_');
              if (parts.isNotEmpty) {
                driverId = parts[0];
                if (parts.length > 2) {
                  driverName = parts.sublist(1, parts.length - 1).join(' ');
                } else if (parts.length == 2) {
                  driverName = parts[1];
                }
              }
            }
            driverName = driverName
                .replaceAll('.jpg', '')
                .replaceAll('.jpeg', '')
                .replaceAll('.png', '');

            final label = '$driverId|$driverName';

            embeddings.add(embedding);
            labels.add(label);
            print('[Auth] ✓ Enrolled photo: $fileName -> label=$label');
          } else {
            print(
              '[Auth] WARNING: Failed to extract face embedding from $fileName',
            );
          }
        } catch (e) {
          print('[Auth] Error enrolling API photo ${file.path}: $e');
        }
      }
    }
    await tempDetector.close();
    print('[Auth] Temp detector closed.');

    if (embeddings.isEmpty) {
      print('[Auth] WARNING: No embeddings generated — auth disabled.');
      return;
    }

    _referenceEmbeddings = embeddings;
    _referenceLabels = labels;
    isEnrolled = true;

    try {
      await _storage.write(
        key: _keyEmbedding,
        value: jsonEncode({'embeddings': embeddings, 'labels': labels}),
      );
      print(
        '[Auth] ${embeddings.length} embeddings (+labels) saved to secure storage.',
      );
    } catch (e) {
      print('[Auth] Storage write failed: $e');
    }
  }

  /// Label from an API-downloaded filename.
  /// Format: <driverId>__<Driver_Name>__<timestamp>.jpg
  /// -> "driverId|Driver Name"  (monitor_flow splits on '|').
  String _labelFromDownloadedFile(String path) {
    final name = path.split('/').last.split('\\').last;
    final base = name.replaceAll(
      RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false),
      '',
    );
    final parts = base.split('__');
    if (parts.length >= 2) {
      final id = parts[0];
      final driverName = parts[1].replaceAll('_', ' ');
      return '$id|$driverName';
    }
    return base;
  }

  /// Extracts the reference folder name from an asset path.
  /// Example:
  /// assets/reference_faces/Authorized_driver_1/photo.jpg
  /// -> Authorized_driver_1
  String _labelFromAsset(String assetPath) {
    final parts = assetPath.split('/');
    final idx = parts.indexOf('reference_faces');

    if (idx >= 0 && idx + 1 < parts.length) {
      return parts[idx + 1];
    }

    return 'unknown';
  }

  // ── Dynamic Gallery Enrollment ─────────────────────────────────────────────

  Future<int> enrollNewDriverFromGallery(List<String> filePaths) async {
    if (!_modelLoaded) return 0;

    final tempDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: false,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );

    int enrolledCount = 0;

    for (final path in filePaths) {
      try {
        final tempFile = File(path);
        final imageBytes = await tempFile.readAsBytes();

        final inputImage = InputImage.fromFilePath(path);
        final faces = await tempDetector.processImage(inputImage);

        if (faces.isNotEmpty) {
          final face = faces.first;
          final embedding = _embedFaceFromJpeg(imageBytes, face.boundingBox);

          if (embedding != null) {
            _referenceEmbeddings.add(embedding);
            _referenceLabels.add('gallery');
            enrolledCount++;
            print('[Auth] Dynamic enrollment successful from $path');
          }
        }
      } catch (e) {
        print('[Auth] Error dynamically enrolling from $path: $e');
      }
    }

    await tempDetector.close();

    if (enrolledCount > 0) {
      isEnrolled = true;

      try {
        await _storage.write(
          key: _keyEmbedding,
          value: jsonEncode({
            'embeddings': _referenceEmbeddings,
            'labels': _referenceLabels,
          }),
        );
        print(
          '[Auth] Now storing ${_referenceEmbeddings.length} total embeddings '
              'in secure storage.',
        );
      } catch (e) {
        print('[Auth] Storage write failed: $e');
      }
    }

    return enrolledCount;
  }

  // ── Face Embedding from JPEG bytes (enrollment) ────────────────────────────

  List<double>? _embedFaceFromJpeg(Uint8List jpegBytes, Rect? box) {
    try {
      img.Image? decoded = img.decodeImage(jpegBytes);
      if (decoded == null) return null;

      // CRITICAL FIX: Bake EXIF orientation so pixel buffer matches upright image.
      decoded = img.bakeOrientation(decoded);

      int cx = 0;
      int cy = 0;
      int cw = decoded.width;
      int ch = decoded.height;

      if (box != null && box.width > 5 && box.height > 5) {
        cx = box.left.toInt().clamp(0, decoded.width - 1);
        cy = box.top.toInt().clamp(0, decoded.height - 1);
        cw = box.width.toInt().clamp(1, decoded.width - cx);
        ch = box.height.toInt().clamp(1, decoded.height - cy);
      }

      final cropped = img.copyCrop(
        decoded,
        x: cx,
        y: cy,
        width: cw,
        height: ch,
      );

      final resized = img.copyResize(cropped, width: 112, height: 112);

      final pixels = Float32List(112 * 112 * 3);
      int idx = 0;

      for (int py = 0; py < 112; py++) {
        for (int px = 0; px < 112; px++) {
          final pixel = resized.getPixel(px, py);

          // MobileFaceNet expects [-1, 1] normalized RGB
          pixels[idx++] = (pixel.r / 127.5) - 1.0;
          pixels[idx++] = (pixel.g / 127.5) - 1.0;
          pixels[idx++] = (pixel.b / 127.5) - 1.0;
        }
      }

      return _runFaceNet(pixels);
    } catch (e) {
      print('[Auth] JPEG embedding error: $e');
      return null;
    }
  }

  // ── Face Embedding from YUV camera frame (live auth) ──────────────────────

  List<double>? _embedFaceFromCameraImage(
      CameraImage image,
      int rotation,
      Rect box,
      ) {
    if (image.planes.isEmpty) return null;

    try {
      final int srcWidth = image.width;
      final int srcHeight = image.height;

      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];

      final yBytes = yPlane.bytes;
      final uBytes = uPlane.bytes;
      final vBytes = vPlane.bytes;

      final yRowStride = yPlane.bytesPerRow;
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;

      // Ensure crop dimensions are valid
      final cw = box.width.toInt().clamp(1, 1000);
      final ch = box.height.toInt().clamp(1, 1000);

      final croppedImg = img.Image(width: cw, height: ch);

      // Extract the exact face bounding box using YUV->RGB
      for (int ty = 0; ty < ch; ty++) {
        for (int tx = 0; tx < cw; tx++) {
          final rx = box.left + tx;
          final ry = box.top + ty;

          int sx = 0;
          int sy = 0;

          if (rotation == 90) {
            sx = ry.toInt().clamp(0, srcWidth - 1);
            sy = (srcHeight - 1 - rx.toInt()).clamp(0, srcHeight - 1);
          } else if (rotation == 270) {
            sx = (srcWidth - 1 - ry.toInt()).clamp(0, srcWidth - 1);
            sy = rx.toInt().clamp(0, srcHeight - 1);
          } else if (rotation == 180) {
            sx = (srcWidth - 1 - rx.toInt()).clamp(0, srcWidth - 1);
            sy = (srcHeight - 1 - ry.toInt()).clamp(0, srcHeight - 1);
          } else {
            sx = rx.toInt().clamp(0, srcWidth - 1);
            sy = ry.toInt().clamp(0, srcHeight - 1);
          }

          final int yIdx = sy * yRowStride + sx;
          final int uvIdx = (sy >> 1) * uvRowStride + (sx >> 1) * uvPixelStride;

          final int yVal = yIdx < yBytes.length ? yBytes[yIdx] : 0;
          final int uVal = uvIdx < uBytes.length ? uBytes[uvIdx] - 128 : 0;
          final int vVal = uvIdx < vBytes.length ? vBytes[uvIdx] - 128 : 0;

          final int r = (yVal + (1.402 * vVal)).round().clamp(0, 255);
          final int g = (yVal - (0.344136 * uVal) - (0.714136 * vVal))
              .round()
              .clamp(0, 255);
          final int b = (yVal + (1.772 * uVal)).round().clamp(0, 255);

          croppedImg.setPixelRgb(tx, ty, r, g, b);
        }
      }

      // High-quality bilinear resize to exactly match the reference photo processing
      final resized = img.copyResize(croppedImg, width: 112, height: 112);

      final pixels = Float32List(112 * 112 * 3);
      int idx = 0;

      for (int py = 0; py < 112; py++) {
        for (int px = 0; px < 112; px++) {
          final pixel = resized.getPixel(px, py);
          pixels[idx++] = (pixel.r / 127.5) - 1.0;
          pixels[idx++] = (pixel.g / 127.5) - 1.0;
          pixels[idx++] = (pixel.b / 127.5) - 1.0;
        }
      }

      return _runFaceNet(pixels);
    } catch (e) {
      print('[Auth] YUV extraction error: $e');
      return null;
    }
  }

  // ── Run MobileFaceNet Inference ────────────────────────────────────────────

  List<double>? _runFaceNet(Float32List pixels) {
    if (!_modelLoaded || _faceNetInterpreter == null) return null;

    try {
      _faceNetInterpreter!.getInputTensor(0).data = pixels.buffer.asUint8List();

      _faceNetInterpreter!.invoke();

      final outputData = Float32List.sublistView(
        _faceNetInterpreter!.getOutputTensor(0).data,
      );

      // Output is [1, 192] — take first 192 values and L2 normalize
      final rawEmbedding = outputData
          .sublist(0, min(192, outputData.length))
          .toList();

      return _l2Normalize(rawEmbedding);
    } catch (e) {
      print('[Auth] FaceNet inference error: $e');
      return null;
    }
  }

  // ── L2 Normalization ───────────────────────────────────────────────────────

  List<double> _l2Normalize(List<double> vector) {
    double sumSq = 0.0;

    for (final v in vector) {
      sumSq += v * v;
    }

    final norm = sqrt(sumSq);
    if (norm == 0) return vector;

    final result = List<double>.filled(vector.length, 0.0);

    for (int i = 0; i < vector.length; i++) {
      result[i] = vector[i] / norm;
    }

    return result;
  }

  // ── L2 Distance ───────────────────────────────────────────────────────────

  double _euclidean(List<double> a, List<double> b) {
    double sum = 0.0;
    final len = min(a.length, b.length);

    for (int i = 0; i < len; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }

    return sqrt(sum);
  }

  Future<Directory> _getVisibleDirectory() async {
    if (Platform.isAndroid) {
      final downloadDir = Directory(
        '/storage/emulated/0/Download/monitoring_driver',
      );
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

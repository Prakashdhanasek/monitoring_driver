import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'monitor_state.dart';

class IsolateInitMessage {
  final SendPort sendPort;
  final Uint8List modelBytes;
  final String labelsText;
  final String documentsDirectoryPath;
  IsolateInitMessage(this.sendPort, this.modelBytes, this.labelsText, this.documentsDirectoryPath);
}

class IsolateFrameMessage {
  final int width;
  final int height;
  final int rotation;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final bool isNV12;
  final bool facePresent;
  final String driverId;
  final String documentsDirectoryPath;

  IsolateFrameMessage({
    required this.width, required this.height, required this.rotation,
    required this.yPlane, required this.uPlane, required this.vPlane,
    required this.yRowStride, required this.uvRowStride, required this.uvPixelStride,
    required this.isNV12, required this.facePresent, required this.driverId, required this.documentsDirectoryPath,
  });
}

class IsolateResultMessage {
  final List<DetectedObject> detectedObjects;
  final bool abnormalBehavior;
  final String? savedFolderPath;
  final int inferenceTimeMs;

  IsolateResultMessage({
    required this.detectedObjects,
    required this.abnormalBehavior,
    this.savedFolderPath,
    required this.inferenceTimeMs,
  });
}

class ObjectDetectorEngine {
  bool _isInitialized = false;
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final ReceivePort _receivePort = ReceivePort();
  bool _isProcessingFrame = false;
  String? _docsPath;
  MonitorState? _state;

  Future<void> initialize() async {
    try {
      print('\n=========================================');
      print('[YOLO ENGINE] Starting Initialization...');
      
      final directory = await getApplicationDocumentsDirectory();
      _docsPath = directory.path;

      final modelData = await rootBundle.load('assets/models/custom_yolo.tflite');
      final labelsText = await rootBundle.loadString('assets/models/labels.txt');
      
      print('[YOLO ENGINE] Model and labels loaded from assets.');

      _isolate = await Isolate.spawn(
        _yoloIsolateEntryPoint,
        IsolateInitMessage(_receivePort.sendPort, modelData.buffer.asUint8List(), labelsText, _docsPath ?? ''),
      );

      _receivePort.listen((message) {
        if (message is SendPort) {
          _isolateSendPort = message;
          _isInitialized = true;
          print('[YOLO ENGINE] Isolate is ONLINE and READY.');
          print('=========================================\n');
        } else if (message is IsolateResultMessage) {
          _isProcessingFrame = false;
          if (_state != null) {
            _updateState(_state!, message);
          }
        } else if (message is String) {
          print('\n🚨 [ISOLATE FATAL ERROR] $message\n');
          _isProcessingFrame = false;
        }
      });
    } catch (e) {
      print('[YOLO ENGINE] Failed to initialize: $e');
    }
  }

  void processFrame(CameraImage image, MonitorState state, int rotation) {
    if (!_isInitialized || _isolateSendPort == null || _isProcessingFrame) return;
    _isProcessingFrame = true;
    _state = state;

    final bool isNV12 = image.planes.length == 2;
    final msg = IsolateFrameMessage(
      width: image.width, height: image.height, rotation: rotation,
      yPlane: image.planes[0].bytes, uPlane: image.planes[1].bytes, vPlane: isNV12 ? image.planes[1].bytes : image.planes[2].bytes,
      yRowStride: image.planes[0].bytesPerRow, uvRowStride: image.planes[1].bytesPerRow, uvPixelStride: image.planes[1].bytesPerPixel ?? (isNV12 ? 2 : 1),
      isNV12: isNV12,
      facePresent: state.faceCount > 0,
      driverId: 'Driver_Active',
      documentsDirectoryPath: _docsPath ?? '',
    );
    _isolateSendPort!.send(msg);
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort.close();
  }

  void _updateState(MonitorState state, IsolateResultMessage result) {
    state.detectedObjects = result.detectedObjects;
    state.yoloInferenceTimeMs = result.inferenceTimeMs;
    state.yoloIsolateStatus = 'Active';
    state.yoloRawDetections = result.detectedObjects.map((o) => '${o.label}: ${(o.confidence * 100).toStringAsFixed(1)}%').toList();

    // ── Zero-False-Positive Filter for Distraction Classes (Task 3) ──
    final now = DateTime.now();
    for (final label in ['phone', 'cigarette']) {
      final detected = result.detectedObjects.firstWhere(
        (o) => o.label == label && o.confidence > 0.85,
        orElse: () => DetectedObject(label: '', confidence: 0, x: 0, y: 0, width: 0, height: 0),
      );

      if (detected.label.isNotEmpty) {
        state.consecutiveDistractions[label] = (state.consecutiveDistractions[label] ?? 0) + 1;
        
        if (state.consecutiveDistractions[label]! >= 15) {
          final lastCooldown = state.distractionCooldowns[label];
          if (lastCooldown == null || now.difference(lastCooldown).inSeconds >= 30) {
            state.distractionCooldowns[label] = now;
            state.totalDistractionCount++;
            
            state.addAlert(AlertEvent(
              type: 'flag_distraction_$label',
              message: 'FLAG: DISTRACTION - ${label.toUpperCase()} DETECTED (>85% for 15 frames)',
              needsScreenshot: true,
              isMajorFlag: true,
            ));
          }
        }
      } else {
        state.consecutiveDistractions[label] = 0;
      }
    }

    // ── Automatic Seatbelt Buckled detection (Task 3) ──
    final hasSeatbelt = result.detectedObjects.any((o) => o.label == 'seatbelt' && o.confidence > 0.50);
    if (hasSeatbelt) {
      state.seatbeltBuckled = true;
      state.lastSeatbeltDetected = now;
    } else {
      if (state.lastSeatbeltDetected != null && now.difference(state.lastSeatbeltDetected!).inSeconds >= 5) {
        state.seatbeltBuckled = false;
      }
    }

    // ── Abnormal Behavior Handling (Task 4) ──
    if (result.abnormalBehavior) {
      if (state.recentAlerts.where((a) => a.type == 'flag_abnormal').isEmpty) {
        state.addAlert(AlertEvent(
          type: 'flag_abnormal',
          message: 'FLAG: ABNORMAL BEHAVIOR (Sudden Driver Absence / Bounding Box Displacement)',
          needsScreenshot: false,
          isMajorFlag: true,
        )..screenshotPath = result.savedFolderPath);
      }
    }
  }
}

// ── ISOLATE WORKER CODE ─────────────────────────────────────────────────────

void _yoloIsolateEntryPoint(IsolateInitMessage initMessage) async {
  final mainSendPort = initMessage.sendPort;
  final receivePort = ReceivePort();

  try {
    // Try GPU/CoreML delegate first; if the device can't run YOLOv8 on the
    // delegate (very common), fall back to CPU so detection still works.
    late Interpreter interpreter;
    try {
      final gpuOptions = InterpreterOptions()..threads = 2;
      if (Platform.isAndroid) {
        gpuOptions.addDelegate(GpuDelegateV2());
      } else if (Platform.isIOS) {
        gpuOptions.addDelegate(CoreMlDelegate());
      }
      interpreter = Interpreter.fromBuffer(initMessage.modelBytes, options: gpuOptions);
      mainSendPort.send('Diagnostics: delegate (GPU/CoreML) active');
    } catch (e) {
      final cpuOptions = InterpreterOptions()..threads = 2;
      interpreter = Interpreter.fromBuffer(initMessage.modelBytes, options: cpuOptions);
      mainSendPort.send('Diagnostics: GPU delegate failed -> CPU fallback ($e)');
    }
    final labels = initMessage.labelsText.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    
    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);
    
    final int targetH = inputTensor.shape[1];
    final int targetW = inputTensor.shape[2];
    final bool isQuantized = inputTensor.type == TensorType.uint8 || inputTensor.type == TensorType.int8;
    
    mainSendPort.send('Diagnostics: Target ${targetW}x$targetH | Quantized: $isQuantized');

    final dynamic inputBuffer;
    if (isQuantized) {
      inputBuffer = Uint8List(1 * targetH * targetW * 3);
    } else {
      inputBuffer = Float32List(1 * targetH * targetW * 3);
    }

    final rgbBytes = Uint8List(targetH * targetW * 3);
    final List<Uint8List> ringBuffer = [];
    Map<String, Point<double>> prevCenters = {};
    bool prevFacePresent = true;

    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      if (message is IsolateFrameMessage) {
        final stopwatch = Stopwatch()..start();
        _convertImage(message, inputBuffer, rgbBytes, targetW, targetH, isQuantized);
        
        inputTensor.setTo(inputBuffer.buffer.asUint8List());
        interpreter.invoke();

        final outputData = Float32List.sublistView(outputTensor.data);
        final numBoxes = outputTensor.shape[2];
        final numClasses = outputTensor.shape[1] - 4;
        
        final rawDetections = _parse(outputData, labels, numBoxes, numClasses, targetW, targetH);
        stopwatch.stop();
        final inferenceTime = stopwatch.elapsedMilliseconds;

        // Maintain 15-second Ring Buffer in RAM as compressed JPEGs
        final image = img.Image.fromBytes(
          width: targetW,
          height: targetH,
          bytes: rgbBytes.buffer,
          numChannels: 3,
        );
        final jpegBytes = Uint8List.fromList(img.encodeJpg(image, quality: 60));
        ringBuffer.add(jpegBytes);
        if (ringBuffer.length > 90) { // ~15 seconds at 6 fps
          ringBuffer.removeAt(0);
        }

        // Abnormal Behavior Detection
        bool abnormal = false;
        if (prevFacePresent && !message.facePresent && ringBuffer.length > 30) {
          abnormal = true; // sudden absence of driver
        }
        prevFacePresent = message.facePresent;

        // Check for erratic bounding box movement (center coordinate displacement > 25% of frame)
        final Map<String, Point<double>> currentCenters = {};
        for (final obj in rawDetections) {
          final center = Point<double>(obj.x + obj.width / 2.0, obj.y + obj.height / 2.0);
          currentCenters[obj.label] = center;
          if (prevCenters.containsKey(obj.label)) {
            final prevCenter = prevCenters[obj.label]!;
            final dist = sqrt(pow(center.x - prevCenter.x, 2) + pow(center.y - prevCenter.y, 2));
            if (dist > 0.25) {
              abnormal = true;
            }
          }
        }
        prevCenters = currentCenters;

        String? savedPath;
        if (abnormal && ringBuffer.isNotEmpty) {
          savedPath = await _saveRingBufferToDisk(ringBuffer, message.documentsDirectoryPath, message.driverId);
          ringBuffer.clear();
        }

        mainSendPort.send(IsolateResultMessage(
          detectedObjects: rawDetections,
          abnormalBehavior: abnormal,
          savedFolderPath: savedPath,
          inferenceTimeMs: inferenceTime,
        ));
      }
    });
  } catch (e, stacktrace) {
    mainSendPort.send('INITIALIZATION ERROR: $e\n$stacktrace');
  }
}

Future<String?> _saveRingBufferToDisk(List<Uint8List> ringBuffer, String documentsDirectoryPath, String driverId) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final folderPath = '$documentsDirectoryPath/SafeDrive_Evidence_${driverId}_$timestamp';
  final dir = Directory(folderPath);
  await dir.create(recursive: true);
  for (int i = 0; i < ringBuffer.length; i++) {
    final file = File('${dir.path}/frame_$i.jpg');
    await file.writeAsBytes(ringBuffer[i]);
  }
  return folderPath;
}

void _convertImage(IsolateFrameMessage msg, dynamic inputBuffer, Uint8List rgbBytes, int targetW, int targetH, bool isQuantized) {
  int bufferIdx = 0;
  int rgbIdx = 0;
  for (int ty = 0; ty < targetH; ty++) {
    for (int tx = 0; tx < targetW; tx++) {
      // Rotate coordinates if rotation is 90, 180 or 270 degrees
      int sx = 0;
      int sy = 0;

      if (msg.rotation == 90) {
        sx = (ty * msg.width) ~/ targetH;
        sy = ((targetW - 1 - tx) * msg.height) ~/ targetW;
      } else if (msg.rotation == 180) {
        sx = ((targetW - 1 - tx) * msg.width) ~/ targetW;
        sy = ((targetH - 1 - ty) * msg.height) ~/ targetH;
      } else if (msg.rotation == 270) {
        sx = ((targetH - 1 - ty) * msg.width) ~/ targetH;
        sy = (tx * msg.height) ~/ targetW;
      } else {
        sx = (tx * msg.width) ~/ targetW;
        sy = (ty * msg.height) ~/ targetH;
      }

      // Clamp sx, sy to frame dimensions
      sx = sx.clamp(0, msg.width - 1);
      sy = sy.clamp(0, msg.height - 1);

      final int yIdx = sy * msg.yRowStride + sx;
      final int uvIdx = (sy ~/ 2) * msg.uvRowStride + (sx ~/ 2) * msg.uvPixelStride;

      final int y = msg.yPlane[yIdx];
      final int u = msg.uPlane[uvIdx] - 128;
      final int v = msg.isNV12 
          ? (((uvIdx + 1) < msg.vPlane.length) ? msg.vPlane[uvIdx + 1] - 128 : 0)
          : ((uvIdx < msg.vPlane.length) ? msg.vPlane[uvIdx] - 128 : 0);

      final int r = (y + (1.402 * v)).round().clamp(0, 255);
      final int g = (y - (0.344136 * u) - (0.714136 * v)).round().clamp(0, 255);
      final int b = (y + (1.772 * u)).round().clamp(0, 255);

      rgbBytes[rgbIdx++] = r;
      rgbBytes[rgbIdx++] = g;
      rgbBytes[rgbIdx++] = b;

      if (isQuantized) {
        inputBuffer[bufferIdx++] = r;
        inputBuffer[bufferIdx++] = g;
        inputBuffer[bufferIdx++] = b;
      } else {
        inputBuffer[bufferIdx++] = r / 255.0;
        inputBuffer[bufferIdx++] = g / 255.0;
        inputBuffer[bufferIdx++] = b / 255.0;
      }
    }
  }
}

List<DetectedObject> _parse(Float32List output, List<String> labels, int numBoxes, int numClasses, int targetW, int targetH) {
  final List<DetectedObject> found = [];
  for (int col = 0; col < numBoxes; col++) {
    double maxProb = 0.0;
    int bestClass = -1;
    for (int cls = 0; cls < numClasses; cls++) {
      if (cls >= labels.length) continue;
      final prob = output[(4 + cls) * numBoxes + col];
      if (prob > maxProb) { maxProb = prob; bestClass = cls; }
    }
    if (maxProb > 0.35 && bestClass != -1) {
      final cx = output[0 * numBoxes + col];
      final cy = output[1 * numBoxes + col];
      final w = output[2 * numBoxes + col];
      final h = output[3 * numBoxes + col];
      
      // This model already outputs NORMALIZED (0-1) coordinates, so do NOT
      // divide by target size again. (Confirmed: box channel max ~= 1.0.)
      // Stay robust: only rescale if some export hands back pixel-scale values.
      double normCx = cx, normCy = cy, normW = w, normH = h;
      if (normCx > 1.5 || normCy > 1.5 || normW > 1.5 || normH > 1.5) {
        normCx = cx / targetW;
        normCy = cy / targetH;
        normW = w / targetW;
        normH = h / targetH;
      }

      found.add(DetectedObject(
        label: labels[bestClass],
        confidence: maxProb,
        x: (normCx - normW / 2.0).clamp(0.0, 1.0),
        y: (normCy - normH / 2.0).clamp(0.0, 1.0),
        width: normW.clamp(0.0, 1.0),
        height: normH.clamp(0.0, 1.0),
      ));
    }
  }
  return found;
}
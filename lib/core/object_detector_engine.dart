// import 'dart:isolate';
// import 'dart:typed_data';
// import 'dart:math';
// import 'dart:io';
// import 'package:flutter/services.dart';
// import 'package:camera/camera.dart';
// import 'package:tflite_flutter/tflite_flutter.dart';
// import 'package:image/image.dart' as img;
// import 'package:path_provider/path_provider.dart';
// import 'monitor_state.dart';

// class IsolateInitMessage {
//   final SendPort sendPort;
//   final Uint8List modelBytes;
//   final String labelsText;
//   final String documentsDirectoryPath;
//   IsolateInitMessage(this.sendPort, this.modelBytes, this.labelsText, this.documentsDirectoryPath);
// }

// class IsolateFrameMessage {
//   final int width;
//   final int height;
//   final int rotation;
//   final Uint8List yPlane;
//   final Uint8List uPlane;
//   final Uint8List vPlane;
//   final int yRowStride;
//   final int uvRowStride;
//   final int uvPixelStride;
//   final bool isNV12;
//   final bool facePresent;
//   final String driverId;
//   final String documentsDirectoryPath;

//   IsolateFrameMessage({
//     required this.width, required this.height, required this.rotation,
//     required this.yPlane, required this.uPlane, required this.vPlane,
//     required this.yRowStride, required this.uvRowStride, required this.uvPixelStride,
//     required this.isNV12, required this.facePresent, required this.driverId, required this.documentsDirectoryPath,
//   });
// }

// class IsolateResultMessage {
//   final List<DetectedObject> detectedObjects;
//   final bool abnormalBehavior;
//   final String? savedFolderPath;
//   final int inferenceTimeMs;

//   IsolateResultMessage({
//     required this.detectedObjects,
//     required this.abnormalBehavior,
//     this.savedFolderPath,
//     required this.inferenceTimeMs,
//   });
// }

// class ObjectDetectorEngine {
//   bool _isInitialized = false;
//   Isolate? _isolate;
//   SendPort? _isolateSendPort;
//   final ReceivePort _receivePort = ReceivePort();
//   bool _isProcessingFrame = false;
//   String? _docsPath;
//   MonitorState? _state;

//   Future<void> initialize() async {
//     try {
//       print('\n=========================================');
//       print('[YOLO ENGINE] Starting Initialization...');

//       final directory = await getApplicationDocumentsDirectory();
//       _docsPath = directory.path;

//       final modelData = await rootBundle.load('assets/models/custom_yolo_updated.tflite');
//       final labelsText = await rootBundle.loadString('assets/models/labels.txt');

//       print('[YOLO ENGINE] Model and labels loaded from assets.');

//       _isolate = await Isolate.spawn(
//         _yoloIsolateEntryPoint,
//         IsolateInitMessage(_receivePort.sendPort, modelData.buffer.asUint8List(), labelsText, _docsPath ?? ''),
//       );

//       _receivePort.listen((message) {
//         if (message is SendPort) {
//           _isolateSendPort = message;
//           _isInitialized = true;
//           print('[YOLO ENGINE] Isolate is ONLINE and READY.');
//           print('=========================================\n');
//         } else if (message is IsolateResultMessage) {
//           _isProcessingFrame = false;
//           if (_state != null) {
//             _updateState(_state!, message);
//           }
//         } else if (message is String) {
//           print('\n🚨 [ISOLATE FATAL ERROR] $message\n');
//           _isProcessingFrame = false;
//         }
//       });
//     } catch (e) {
//       print('[YOLO ENGINE] Failed to initialize: $e');
//     }
//   }

//   void processFrame(CameraImage image, MonitorState state, int rotation) {
//     if (!_isInitialized || _isolateSendPort == null || _isProcessingFrame) return;
//     _isProcessingFrame = true;
//     _state = state;

//     final bool isNV12 = image.planes.length == 2;
//     final msg = IsolateFrameMessage(
//       width: image.width, height: image.height, rotation: rotation,
//       yPlane: image.planes[0].bytes, uPlane: image.planes[1].bytes, vPlane: isNV12 ? image.planes[1].bytes : image.planes[2].bytes,
//       yRowStride: image.planes[0].bytesPerRow, uvRowStride: image.planes[1].bytesPerRow, uvPixelStride: image.planes[1].bytesPerPixel ?? (isNV12 ? 2 : 1),
//       isNV12: isNV12,
//       facePresent: state.faceCount > 0,
//       driverId: 'Driver_Active',
//       documentsDirectoryPath: _docsPath ?? '',
//     );
//     _isolateSendPort!.send(msg);
//   }

//   void dispose() {
//     _isolate?.kill(priority: Isolate.immediate);
//     _receivePort.close();
//   }

//   void _updateState(MonitorState state, IsolateResultMessage result) {
//     state.detectedObjects = result.detectedObjects;
//     state.yoloInferenceTimeMs = result.inferenceTimeMs;
//     state.yoloIsolateStatus = 'Active';
//     state.yoloRawDetections = result.detectedObjects.map((o) => '${o.label}: ${(o.confidence * 100).toStringAsFixed(1)}%').toList();

//     // ── Zero-False-Positive Filter for Distraction Classes (Task 3) ──
//     final now = DateTime.now();
//     for (final label in ['phone', 'cigarette']) {
//       final detected = result.detectedObjects.firstWhere(
//         (o) => o.label == label && o.confidence > 0.85,
//         orElse: () => DetectedObject(label: '', confidence: 0, x: 0, y: 0, width: 0, height: 0),
//       );

//       if (detected.label.isNotEmpty) {
//         state.consecutiveDistractions[label] = (state.consecutiveDistractions[label] ?? 0) + 1;

//         if (state.consecutiveDistractions[label]! >= 15) {
//           final lastCooldown = state.distractionCooldowns[label];
//           if (lastCooldown == null || now.difference(lastCooldown).inSeconds >= 30) {
//             state.distractionCooldowns[label] = now;
//             state.totalDistractionCount++;

//             state.addAlert(AlertEvent(
//               type: 'flag_distraction_$label',
//               message: 'FLAG: DISTRACTION - ${label.toUpperCase()} DETECTED (>85% for 15 frames)',
//               needsScreenshot: true,
//               isMajorFlag: true,
//             ));
//           }
//         }
//       } else {
//         state.consecutiveDistractions[label] = 0;
//       }
//     }

//     // ── Automatic Seatbelt Buckled detection (Task 3) ──
//     final hasSeatbelt = result.detectedObjects.any((o) => o.label == 'seatbelt' && o.confidence > 0.50);
//     if (hasSeatbelt) {
//       state.seatbeltBuckled = true;
//       state.lastSeatbeltDetected = now;
//     } else {
//       if (state.lastSeatbeltDetected != null && now.difference(state.lastSeatbeltDetected!).inSeconds >= 5) {
//         state.seatbeltBuckled = false;
//       }
//     }

//     // ── Abnormal Behavior Handling (Task 4) ──
//     if (result.abnormalBehavior) {
//       if (state.recentAlerts.where((a) => a.type == 'flag_abnormal').isEmpty) {
//         state.addAlert(AlertEvent(
//           type: 'flag_abnormal',
//           message: 'FLAG: ABNORMAL BEHAVIOR (Sudden Driver Absence / Bounding Box Displacement)',
//           needsScreenshot: false,
//           isMajorFlag: true,
//         )..screenshotPath = result.savedFolderPath);
//       }
//     }
//   }
// }

// // ── ISOLATE WORKER CODE ─────────────────────────────────────────────────────

// void _yoloIsolateEntryPoint(IsolateInitMessage initMessage) async {
//   final mainSendPort = initMessage.sendPort;
//   final receivePort = ReceivePort();

//   try {
//     // Try GPU/CoreML delegate first; if the device can't run YOLOv8 on the
//     // delegate (very common), fall back to CPU so detection still works.
//     late Interpreter interpreter;
//     try {
//       final gpuOptions = InterpreterOptions()..threads = 2;
//       if (Platform.isAndroid) {
//         gpuOptions.addDelegate(GpuDelegateV2());
//       } else if (Platform.isIOS) {
//         gpuOptions.addDelegate(CoreMlDelegate());
//       }
//       interpreter = Interpreter.fromBuffer(initMessage.modelBytes, options: gpuOptions);
//       mainSendPort.send('Diagnostics: delegate (GPU/CoreML) active');
//     } catch (e) {
//       final cpuOptions = InterpreterOptions()..threads = 2;
//       interpreter = Interpreter.fromBuffer(initMessage.modelBytes, options: cpuOptions);
//       mainSendPort.send('Diagnostics: GPU delegate failed -> CPU fallback ($e)');
//     }
//     final labels = initMessage.labelsText.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

//     final inputTensor = interpreter.getInputTensor(0);
//     final outputTensor = interpreter.getOutputTensor(0);

//     final int targetH = inputTensor.shape[1];
//     final int targetW = inputTensor.shape[2];
//     final bool isQuantized = inputTensor.type == TensorType.uint8 || inputTensor.type == TensorType.int8;

//     mainSendPort.send('Diagnostics: Target ${targetW}x$targetH | Quantized: $isQuantized');

//     final dynamic inputBuffer;
//     if (isQuantized) {
//       inputBuffer = Uint8List(1 * targetH * targetW * 3);
//     } else {
//       inputBuffer = Float32List(1 * targetH * targetW * 3);
//     }

//     final rgbBytes = Uint8List(targetH * targetW * 3);
//     final List<Uint8List> ringBuffer = [];
//     Map<String, Point<double>> prevCenters = {};
//     bool prevFacePresent = true;

//     mainSendPort.send(receivePort.sendPort);

//     receivePort.listen((message) async {
//       if (message is IsolateFrameMessage) {
//         final stopwatch = Stopwatch()..start();
//         _convertImage(message, inputBuffer, rgbBytes, targetW, targetH, isQuantized);

//         inputTensor.setTo(inputBuffer.buffer.asUint8List());
//         interpreter.invoke();

//         final outputData = Float32List.sublistView(outputTensor.data);
//         final numBoxes = outputTensor.shape[2];
//         final numClasses = outputTensor.shape[1] - 4;

//         final rawDetections = _parse(outputData, labels, numBoxes, numClasses, targetW, targetH);
//         stopwatch.stop();
//         final inferenceTime = stopwatch.elapsedMilliseconds;

//         // Maintain 15-second Ring Buffer in RAM as compressed JPEGs
//         final image = img.Image.fromBytes(
//           width: targetW,
//           height: targetH,
//           bytes: rgbBytes.buffer,
//           numChannels: 3,
//         );
//         final jpegBytes = Uint8List.fromList(img.encodeJpg(image, quality: 60));
//         ringBuffer.add(jpegBytes);
//         if (ringBuffer.length > 90) { // ~15 seconds at 6 fps
//           ringBuffer.removeAt(0);
//         }

//         // Abnormal Behavior Detection
//         bool abnormal = false;
//         if (prevFacePresent && !message.facePresent && ringBuffer.length > 30) {
//           abnormal = true; // sudden absence of driver
//         }
//         prevFacePresent = message.facePresent;

//         // Check for erratic bounding box movement (center coordinate displacement > 25% of frame)
//         final Map<String, Point<double>> currentCenters = {};
//         for (final obj in rawDetections) {
//           final center = Point<double>(obj.x + obj.width / 2.0, obj.y + obj.height / 2.0);
//           currentCenters[obj.label] = center;
//           if (prevCenters.containsKey(obj.label)) {
//             final prevCenter = prevCenters[obj.label]!;
//             final dist = sqrt(pow(center.x - prevCenter.x, 2) + pow(center.y - prevCenter.y, 2));
//             if (dist > 0.25) {
//               abnormal = true;
//             }
//           }
//         }
//         prevCenters = currentCenters;

//         String? savedPath;
//         if (abnormal && ringBuffer.isNotEmpty) {
//           savedPath = await _saveRingBufferToDisk(ringBuffer, message.documentsDirectoryPath, message.driverId);
//           ringBuffer.clear();
//         }

//         mainSendPort.send(IsolateResultMessage(
//           detectedObjects: rawDetections,
//           abnormalBehavior: abnormal,
//           savedFolderPath: savedPath,
//           inferenceTimeMs: inferenceTime,
//         ));
//       }
//     });
//   } catch (e, stacktrace) {
//     mainSendPort.send('INITIALIZATION ERROR: $e\n$stacktrace');
//   }
// }

// Future<String?> _saveRingBufferToDisk(List<Uint8List> ringBuffer, String documentsDirectoryPath, String driverId) async {
//   final timestamp = DateTime.now().millisecondsSinceEpoch;
//   final folderPath = '$documentsDirectoryPath/SafeDrive_Evidence_${driverId}_$timestamp';
//   final dir = Directory(folderPath);
//   await dir.create(recursive: true);
//   for (int i = 0; i < ringBuffer.length; i++) {
//     final file = File('${dir.path}/frame_$i.jpg');
//     await file.writeAsBytes(ringBuffer[i]);
//   }
//   return folderPath;
// }

// void _convertImage(IsolateFrameMessage msg, dynamic inputBuffer, Uint8List rgbBytes, int targetW, int targetH, bool isQuantized) {
//   int bufferIdx = 0;
//   int rgbIdx = 0;
//   for (int ty = 0; ty < targetH; ty++) {
//     for (int tx = 0; tx < targetW; tx++) {
//       // Rotate coordinates if rotation is 90, 180 or 270 degrees
//       int sx = 0;
//       int sy = 0;

//       if (msg.rotation == 90) {
//         sx = (ty * msg.width) ~/ targetH;
//         sy = ((targetW - 1 - tx) * msg.height) ~/ targetW;
//       } else if (msg.rotation == 180) {
//         sx = ((targetW - 1 - tx) * msg.width) ~/ targetW;
//         sy = ((targetH - 1 - ty) * msg.height) ~/ targetH;
//       } else if (msg.rotation == 270) {
//         sx = ((targetH - 1 - ty) * msg.width) ~/ targetH;
//         sy = (tx * msg.height) ~/ targetW;
//       } else {
//         sx = (tx * msg.width) ~/ targetW;
//         sy = (ty * msg.height) ~/ targetH;
//       }

//       // Clamp sx, sy to frame dimensions
//       sx = sx.clamp(0, msg.width - 1);
//       sy = sy.clamp(0, msg.height - 1);

//       final int yIdx = sy * msg.yRowStride + sx;
//       final int uvIdx = (sy ~/ 2) * msg.uvRowStride + (sx ~/ 2) * msg.uvPixelStride;

//       final int y = msg.yPlane[yIdx];
//       final int u = msg.uPlane[uvIdx] - 128;
//       final int v = msg.isNV12
//           ? (((uvIdx + 1) < msg.vPlane.length) ? msg.vPlane[uvIdx + 1] - 128 : 0)
//           : ((uvIdx < msg.vPlane.length) ? msg.vPlane[uvIdx] - 128 : 0);

//       final int r = (y + (1.402 * v)).round().clamp(0, 255);
//       final int g = (y - (0.344136 * u) - (0.714136 * v)).round().clamp(0, 255);
//       final int b = (y + (1.772 * u)).round().clamp(0, 255);

//       rgbBytes[rgbIdx++] = r;
//       rgbBytes[rgbIdx++] = g;
//       rgbBytes[rgbIdx++] = b;

//       if (isQuantized) {
//         inputBuffer[bufferIdx++] = r;
//         inputBuffer[bufferIdx++] = g;
//         inputBuffer[bufferIdx++] = b;
//       } else {
//         inputBuffer[bufferIdx++] = r / 255.0;
//         inputBuffer[bufferIdx++] = g / 255.0;
//         inputBuffer[bufferIdx++] = b / 255.0;
//       }
//     }
//   }
// }

// List<DetectedObject> _parse(Float32List output, List<String> labels, int numBoxes, int numClasses, int targetW, int targetH) {
//   final List<DetectedObject> found = [];
//   for (int col = 0; col < numBoxes; col++) {
//     double maxProb = 0.0;
//     int bestClass = -1;
//     for (int cls = 0; cls < numClasses; cls++) {
//       if (cls >= labels.length) continue;
//       final prob = output[(4 + cls) * numBoxes + col];
//       if (prob > maxProb) { maxProb = prob; bestClass = cls; }
//     }
//     if (maxProb > 0.35 && bestClass != -1) {
//       final cx = output[0 * numBoxes + col];
//       final cy = output[1 * numBoxes + col];
//       final w = output[2 * numBoxes + col];
//       final h = output[3 * numBoxes + col];

//       // This model already outputs NORMALIZED (0-1) coordinates, so do NOT
//       // divide by target size again. (Confirmed: box channel max ~= 1.0.)
//       // Stay robust: only rescale if some export hands back pixel-scale values.
//       double normCx = cx, normCy = cy, normW = w, normH = h;
//       if (normCx > 1.5 || normCy > 1.5 || normW > 1.5 || normH > 1.5) {
//         normCx = cx / targetW;
//         normCy = cy / targetH;
//         normW = w / targetW;
//         normH = h / targetH;
//       }

//       found.add(DetectedObject(
//         label: labels[bestClass],
//         confidence: maxProb,
//         x: (normCx - normW / 2.0).clamp(0.0, 1.0),
//         y: (normCy - normH / 2.0).clamp(0.0, 1.0),
//         width: normW.clamp(0.0, 1.0),
//         height: normH.clamp(0.0, 1.0),
//       ));
//     }
//   }
//   return found;
// }

// import 'dart:isolate';
// import 'dart:typed_data';
// import 'dart:math';
// import 'dart:io';
// import 'package:flutter/services.dart';
// import 'package:camera/camera.dart';
// import 'package:tflite_flutter/tflite_flutter.dart';
// import 'package:image/image.dart' as img;
// import 'package:path_provider/path_provider.dart';
// import 'monitor_state.dart';

// class IsolateInitMessage {
//   final SendPort sendPort;
//   final Uint8List modelBytes;
//   final String documentsDirectoryPath;
//   IsolateInitMessage(this.sendPort, this.modelBytes, this.documentsDirectoryPath);
// }

// class IsolateFrameMessage {
//   final int width, height, rotation;
//   final Uint8List yPlane, uPlane, vPlane;
//   final int yRowStride, uvRowStride, uvPixelStride;
//   final bool facePresent;
//   final String driverId;
//   final String documentsDirectoryPath;

//   IsolateFrameMessage({
//     required this.width, required this.height, required this.rotation,
//     required this.yPlane, required this.uPlane, required this.vPlane,
//     required this.yRowStride, required this.uvRowStride, required this.uvPixelStride,
//     required this.facePresent, required this.driverId, required this.documentsDirectoryPath,
//   });
// }

// class IsolateCommandDump {
//   final String docsPath;
//   final String driverId;
//   IsolateCommandDump(this.docsPath, this.driverId);
// }

// class IsolateResultMessage {
//   final List<DetectedObject> detectedObjects;
//   final bool abnormalBehavior;
//   final String? savedFolderPath;
//   final int inferenceTimeMs;
//   final bool isEvidenceDump;
//   final String debugInfo;

//   IsolateResultMessage({
//     required this.detectedObjects,
//     required this.abnormalBehavior,
//     this.savedFolderPath,
//     required this.inferenceTimeMs,
//     this.isEvidenceDump = false,
//     this.debugInfo = '',
//   });
// }

// class ObjectDetectorEngine {
//   bool _isInitialized = false;
//   Isolate? _isolate;
//   SendPort? _isolateSendPort;
//   final ReceivePort _receivePort = ReceivePort();
//   bool _isProcessingFrame = false;
//   String? _docsPath;
//   MonitorState? _state;

//   Future<void> initialize() async {
//     try {
//       final directory = await getApplicationDocumentsDirectory();
//       _docsPath = directory.path;

//       // Load the unified 5-class model
//       final modelData = await rootBundle.load('assets/models/custom_yolo_updated.tflite');

//       _isolate = await Isolate.spawn(
//         _yoloIsolateEntryPoint,
//         IsolateInitMessage(
//           _receivePort.sendPort,
//           modelData.buffer.asUint8List(),
//           _docsPath ?? '',
//         ),
//       );

//       _receivePort.listen((message) {
//         if (message is SendPort) {
//           _isolateSendPort = message;
//           _isInitialized = true;
//           print('[YOLO ENGINE] Unified 5-Class Isolate is ONLINE and READY.');
//         } else if (message is IsolateResultMessage) {
//           if (!message.isEvidenceDump) {
//             _isProcessingFrame = false;
//           }
//           if (_state != null) {
//             _updateState(_state!, message);
//           }
//         } else if (message is String) {
//           // Debug/info messages from isolate
//           print('[YOLO ISOLATE] $message');
//           if (_state != null && message.startsWith('TENSOR_INFO:')) {
//             _state!.yoloInputShape = message;
//           }
//         }
//       });
//     } catch (e) {
//       print('[YOLO ENGINE] Failed to initialize: $e');
//     }
//   }

//   void processFrame(CameraImage image, MonitorState state, int rotation) {
//     if (!_isInitialized || _isolateSendPort == null || _isProcessingFrame) return;
//     _isProcessingFrame = true;
//     _state = state;
//     state.documentsDirectoryPath = _docsPath;

//     final msg = IsolateFrameMessage(
//       width: image.width,
//       height: image.height,
//       rotation: rotation,
//       yPlane: image.planes[0].bytes,
//       uPlane: image.planes[1].bytes,
//       vPlane: image.planes[2].bytes,
//       yRowStride: image.planes[0].bytesPerRow,
//       uvRowStride: image.planes[1].bytesPerRow,
//       uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
//       facePresent: state.faceCount > 0,
//       driverId: 'Driver_Active',
//       documentsDirectoryPath: _docsPath ?? '',
//     );
//     _isolateSendPort!.send(msg);
//   }

//   void dispose() {
//     _isolate?.kill(priority: Isolate.immediate);
//     _receivePort.close();
//   }

//   void _updateState(MonitorState state, IsolateResultMessage result) {
//     if (result.isEvidenceDump && result.savedFolderPath != null) {
//       try {
//         final alert = state.recentAlerts.firstWhere(
//           (a) => a.needsScreenshot && a.screenshotPath == null,
//         );
//         alert.screenshotPath = result.savedFolderPath;
//       } catch (e) {}
//       return;
//     }

//     state.detectedObjects = result.detectedObjects;
//     state.yoloInferenceTimeMs = result.inferenceTimeMs;
//     state.yoloIsolateStatus = 'Active';

//     // Debug info from isolate
//     if (result.debugInfo.isNotEmpty) {
//       state.yoloRawDetections = [result.debugInfo];
//     }

//     // Map detections to state booleans
//     // Labels order: 0=cigarette, 1=phone, 2=seatbelt, 3=eating, 4=drinking
//     state.hasEating = result.detectedObjects.any((o) => o.label == 'eating') || state.isChewing;
//     state.hasDrinking = result.detectedObjects.any((o) => o.label == 'drinking');
//     state.hasPhone = result.detectedObjects.any((o) => o.label == 'phone');
//     state.hasCigarette = result.detectedObjects.any((o) => o.label == 'cigarette');

//     final now = DateTime.now();
//     bool requestEvidenceDump = false;

//     // Leaky Bucket temporal smoothing for each banned object category
//     final evaluationList = [
//       {'label': 'phone', 'detected': state.hasPhone},
//       {'label': 'cigarette', 'detected': state.hasCigarette},
//       {'label': 'eating', 'detected': state.hasEating},
//       {'label': 'drinking', 'detected': state.hasDrinking},
//     ];

//     for (final eval in evaluationList) {
//       final label = eval['label'] as String;
//       final detected = eval['detected'] as bool;

//       int currentScore = state.consecutiveDistractions[label] ?? 0;

//       if (detected) {
//         currentScore += 2; // Fast fill when object is seen
//       } else {
//         currentScore -= 1; // Slow drain — tolerates flickering
//       }

//       currentScore = currentScore.clamp(0, 20);
//       state.consecutiveDistractions[label] = currentScore;

//       // Trigger at score >= 8 (reduced from 15 for faster response)
// if (currentScore >= 12) {        final lastCooldown = state.distractionCooldowns[label];
//         if (lastCooldown == null ||
//             now.difference(lastCooldown).inSeconds >= 30) {
//           state.distractionCooldowns[label] = now;
//           state.totalDistractionCount++;

//           state.addAlert(AlertEvent(
//             type: 'flag_distraction_$label',
//             message: 'FLAG: BANNED OBJECT - ${label.toUpperCase()} DETECTED',
//             needsScreenshot: true,
//             isMajorFlag: true,
//           ));
//           requestEvidenceDump = true;

//           // Reset to avoid repeat spam within cooldown
//           state.consecutiveDistractions[label] = 0;
//         }
//       }
//     }

//     if (requestEvidenceDump) {
//       _isolateSendPort?.send(
//         IsolateCommandDump(_docsPath ?? '', 'Driver_Active'),
//       );
//     }

//     // Seatbelt persistence (5-second grace period after last detection)
//     final hasSeatbelt = result.detectedObjects.any((o) => o.label == 'seatbelt');
//     if (hasSeatbelt) {
//       state.seatbeltBuckled = true;
//       state.lastSeatbeltDetected = now;
//     } else if (state.lastSeatbeltDetected != null &&
//         now.difference(state.lastSeatbeltDetected!).inSeconds >= 5) {
//       state.seatbeltBuckled = false;
//     }

//     if (result.abnormalBehavior) {
//       if (state.recentAlerts.where((a) => a.type == 'flag_abnormal').isEmpty) {
//         state.addAlert(AlertEvent(
//           type: 'flag_abnormal',
//           message: 'FLAG: SUDDEN ABSENCE / DISPLACEMENT',
//           needsScreenshot: true,
//           isMajorFlag: true,
//         ));
//         _isolateSendPort?.send(
//           IsolateCommandDump(_docsPath ?? '', 'Driver_Active'),
//         );
//       }
//     }
//   }
// }

// // ── ISOLATE WORKER ──────────────────────────────────────────────────────────

// void _yoloIsolateEntryPoint(IsolateInitMessage initMessage) async {
//   final mainSendPort = initMessage.sendPort;
//   final receivePort = ReceivePort();

//   try {
//     // Use 1 thread — GPU delegate disabled; causes isolate crashes on many devices
//     final options = InterpreterOptions()..threads = 1;

//     final interpreter = Interpreter.fromBuffer(
//       initMessage.modelBytes,
//       options: options,
//     );

//     // Label order MUST match the training configuration exactly
//     // 0=cigarette, 1=phone, 2=seatbelt, 3=eating, 4=drinking
//     const labels = ['cigarette', 'phone', 'seatbelt', 'eating', 'drinking'];
//     const numClasses = 5;

//     final inputTensors = interpreter.getInputTensors();
//     final outputTensors = interpreter.getOutputTensors();

//     if (inputTensors.isEmpty || outputTensors.isEmpty) {
//       mainSendPort.send('ERROR: No input/output tensors found in model');
//       mainSendPort.send(receivePort.sendPort);
//       return;
//     }

//     final inputShape = inputTensors[0].shape;   // [1, H, W, 3]
//     final outputShape = outputTensors[0].shape; // [1, 9, 8400]

//     mainSendPort.send(
//       'TENSOR_INFO: in=${inputShape.toString()} out=${outputShape.toString()}',
//     );

//     final targetH = inputShape[1];
//     final targetW = inputShape[2];
//     final isQuantized = inputTensors[0].type == TensorType.uint8 ||
//         inputTensors[0].type == TensorType.int8;

//     // numBoxes = last dim of output = 8400 anchor candidates
//     final numBoxes = outputShape[2];
//     // numRows = middle dim = 9 (4 box + 5 classes)
//     final numRows = outputShape[1];

//     mainSendPort.send(
//       'INIT: H=$targetH W=$targetW quantized=$isQuantized boxes=$numBoxes rows=$numRows',
//     );

//     // Pre-allocated flat buffers — reused every frame to avoid GC pressure
//     final Float32List inputFloat = Float32List(targetH * targetW * 3);
//     final Uint8List inputUint8 = Uint8List(targetH * targetW * 3);
//     final Uint8List rgbBytes = Uint8List(targetH * targetW * 3);

//     // Output flat buffer — tflite_flutter fills this after invoke()
//     // Size: numRows * numBoxes = 9 * 8400 = 75600 floats
//     final Float32List outputFlat = Float32List(numRows * numBoxes);

//     // Get tensor references once for the frame loop
//     final inputTensorRef = interpreter.getInputTensors()[0];
//     final outputTensorRef = interpreter.getOutputTensors()[0];

//     // Ring buffer for evidence capture
//     final List<Uint8List> ringBufferRgb = [];
//     bool prevFacePresent = true;
//     int frameCount = 0;

//     // Signal ready
//     mainSendPort.send(receivePort.sendPort);

//     receivePort.listen((message) async {
//       if (message is IsolateCommandDump) {
//         if (ringBufferRgb.isNotEmpty) {
//           final path = await _saveEvidence(
//             ringBufferRgb,
//             message.docsPath,
//             message.driverId,
//             targetW,
//             targetH,
//           );
//           mainSendPort.send(IsolateResultMessage(
//             detectedObjects: [],
//             abnormalBehavior: false,
//             savedFolderPath: path,
//             inferenceTimeMs: 0,
//             isEvidenceDump: true,
//           ));
//         }
//         return;
//       }

//       if (message is IsolateFrameMessage) {
//         frameCount++;
//         final stopwatch = Stopwatch()..start();

//         // YUV -> RGB conversion (fast integer math)
//         _fastConvertImage(
//           message,
//           isQuantized ? inputUint8 : inputFloat,
//           rgbBytes,
//           targetW,
//           targetH,
//           isQuantized,
//         );

//         // ── Run inference ──────────────────────────────────────────────────
//         // CORRECT tflite_flutter pattern:
//         //   1. setTo(TypedData) — loads input into native tensor
//         //   2. invoke()         — runs the model
//         //   3. .data            — reads output ByteBuffer back
//         //
//         // DO NOT pass nested Dart Lists to run() — tflite_flutter cannot
//         // reliably write back into generic List<List<...>> objects.
//         try {
//           if (isQuantized) {
//             inputTensorRef.setTo(inputUint8);
//           } else {
//             inputTensorRef.setTo(inputFloat);
//           }

//           interpreter.invoke();

//           // Read output as flat Float32List (row-major: [rows][boxes])
//           final rawOut = outputTensorRef.data.buffer.asFloat32List();
//           // Copy into our pre-allocated buffer (avoids holding a ByteBuffer reference)
//           final copyLen = rawOut.length < outputFlat.length ? rawOut.length : outputFlat.length;
//           outputFlat.setRange(0, copyLen, rawOut);
//         } catch (e) {
//           mainSendPort.send('RUN_ERROR: $e');
//           stopwatch.stop();
//           mainSendPort.send(IsolateResultMessage(
//             detectedObjects: [],
//             abnormalBehavior: false,
//             inferenceTimeMs: stopwatch.elapsedMilliseconds,
//           ));
//           return;
//         }

//         stopwatch.stop();

//         // Parse detections
//         final rawDetections = _parseOutput(
//           outputFlat,
//           labels,
//           numBoxes,
//           numClasses,
//         );

//         // Debug logging every 30 frames
//         String debugInfo = '';
//         if (frameCount % 30 == 0) {
//           final debugStr = _buildDebugStr(outputFlat, labels, numBoxes, numClasses);
//           mainSendPort.send('DEBUG[f$frameCount]: dets=${rawDetections.length} | $debugStr');
//           debugInfo = 'dets=${rawDetections.length} | $debugStr';
//         }

//         // Maintain evidence ring buffer
//         ringBufferRgb.add(Uint8List.fromList(rgbBytes));
//         if (ringBufferRgb.length > 5) ringBufferRgb.removeAt(0);

//         // Abnormal behaviour: face was present then disappeared
//         bool abnormal = false;
//         if (prevFacePresent && !message.facePresent && ringBufferRgb.length >= 5) {
//           abnormal = true;
//         }
//         prevFacePresent = message.facePresent;

//         mainSendPort.send(IsolateResultMessage(
//           detectedObjects: rawDetections,
//           abnormalBehavior: abnormal,
//           inferenceTimeMs: stopwatch.elapsedMilliseconds,
//           debugInfo: debugInfo,
//         ));
//       }
//     });
//   } catch (e, stack) {
//     mainSendPort.send('INIT_EXCEPTION: $e\n$stack');
//     // Still send port so isolate doesn't hang
//     mainSendPort.send(receivePort.sendPort);
//   }
// }

// // ── YUV -> RGB ───────────────────────────────────────────────────────────────

// void _fastConvertImage(
//   IsolateFrameMessage msg,
//   dynamic inputBuffer,
//   Uint8List rgbBytes,
//   int targetW,
//   int targetH,
//   bool isQuantized,
// ) {
//   int bufferIdx = 0;
//   int rgbIdx = 0;

//   for (int ty = 0; ty < targetH; ty++) {
//     for (int tx = 0; tx < targetW; tx++) {
//       int sx, sy;

//       switch (msg.rotation) {
//         case 90:
//           sx = (ty * msg.width) ~/ targetH;
//           sy = ((targetW - 1 - tx) * msg.height) ~/ targetW;
//           break;
//         case 180:
//           sx = ((targetW - 1 - tx) * msg.width) ~/ targetW;
//           sy = ((targetH - 1 - ty) * msg.height) ~/ targetH;
//           break;
//         case 270:
//           sx = ((targetH - 1 - ty) * msg.width) ~/ targetH;
//           sy = (tx * msg.height) ~/ targetW;
//           break;
//         default: // 0
//           sx = (tx * msg.width) ~/ targetW;
//           sy = (ty * msg.height) ~/ targetH;
//       }

//       sx = sx.clamp(0, msg.width - 1);
//       sy = sy.clamp(0, msg.height - 1);

//       final int yIdx = sy * msg.yRowStride + sx;
//       final int uvIdx =
//           (sy ~/ 2) * msg.uvRowStride + (sx ~/ 2) * msg.uvPixelStride;

//       final int yVal = msg.yPlane[yIdx];
//       final int u = msg.uPlane[uvIdx] - 128;
//       final int v = msg.vPlane[uvIdx] - 128;

//       final int r = (yVal + ((359 * v) >> 8)).clamp(0, 255);
//       final int g = (yVal - ((88 * u + 183 * v) >> 8)).clamp(0, 255);
//       final int b = (yVal + ((454 * u) >> 8)).clamp(0, 255);

//       rgbBytes[rgbIdx++] = r;
//       rgbBytes[rgbIdx++] = g;
//       rgbBytes[rgbIdx++] = b;

//       if (isQuantized) {
//         (inputBuffer as Uint8List)[bufferIdx++] = r;
//         (inputBuffer as Uint8List)[bufferIdx++] = g;
//         (inputBuffer as Uint8List)[bufferIdx++] = b;
//       } else {
//         (inputBuffer as Float32List)[bufferIdx++] = r / 255.0;
//         (inputBuffer as Float32List)[bufferIdx++] = g / 255.0;
//         (inputBuffer as Float32List)[bufferIdx++] = b / 255.0;
//       }
//     }
//   }
// }

// // ── Evidence save ────────────────────────────────────────────────────────────

// Future<String?> _saveEvidence(
//   List<Uint8List> ringBufferRgb,
//   String docsPath,
//   String driverId,
//   int w,
//   int h,
// ) async {
//   final timestamp = DateTime.now().millisecondsSinceEpoch;
//   final folderPath = '$docsPath/SafeDrive_Evidence_${driverId}_$timestamp';
//   final dir = Directory(folderPath);
//   await dir.create(recursive: true);

//   for (int i = 0; i < ringBufferRgb.length; i++) {
//     final image = img.Image.fromBytes(
//       width: w,
//       height: h,
//       bytes: ringBufferRgb[i].buffer,
//       numChannels: 3,
//     );
//     final jpeg = img.encodeJpg(image, quality: 70);
//     final file = File('${dir.path}/frame_$i.jpg');
//     await file.writeAsBytes(jpeg);
//   }
//   return folderPath;
// }

// // ── Detection parsers ────────────────────────────────────────────────────────

// /// Debug string: show top scores from first 200 boxes
// String _buildDebugStr(
//   Float32List output,
//   List<String> labels,
//   int numBoxes,
//   int numClasses,
// ) {
//   double globalMax = 0.0;
//   String bestLabel = 'none';
//   int scanLimit = min(numBoxes, 200);

//   for (int col = 0; col < scanLimit; col++) {
//     for (int cls = 0; cls < numClasses; cls++) {
//       final prob = output[(4 + cls) * numBoxes + col];
//       if (prob > globalMax) {
//         globalMax = prob;
//         bestLabel = labels[cls];
//       }
//     }
//   }
//   return 'peak=$bestLabel@${globalMax.toStringAsFixed(3)}';
// }

// /// Production parser with NMS
// List<DetectedObject> _parseOutput(
//   Float32List output,
//   List<String> labels,
//   int numBoxes,
//   int numClasses,
// ) {
//   // YOLO output layout: [1, 9, 8400]
//   // Flattened: index = row * numBoxes + col
//   // Rows 0-3: cx, cy, w, h (normalized 0..1)
//   // Rows 4-8: class confidence scores (cigarette, phone, seatbelt, eating, drinking)
//   const double threshold = 0.55;
//   final List<DetectedObject> found = [];

//   for (int col = 0; col < numBoxes; col++) {
//     double maxProb = 0.0;
//     int bestClass = -1;

//     for (int cls = 0; cls < numClasses; cls++) {
//       final prob = output[(4 + cls) * numBoxes + col];
//       if (prob > maxProb) {
//         maxProb = prob;
//         bestClass = cls;
//       }
//     }

//     if (maxProb > threshold && bestClass != -1) {
//       final normCx = output[0 * numBoxes + col];
//       final normCy = output[1 * numBoxes + col];
//       final normW = output[2 * numBoxes + col];
//       final normH = output[3 * numBoxes + col];

//       found.add(DetectedObject(
//         label: labels[bestClass],
//         confidence: maxProb,
//         x: (normCx - normW / 2.0).clamp(0.0, 1.0),
//         y: (normCy - normH / 2.0).clamp(0.0, 1.0),
//         width: normW.clamp(0.0, 1.0),
//         height: normH.clamp(0.0, 1.0),
//       ));
//     }
//   }

//   // NMS — remove overlapping duplicates, keep highest confidence
//   final List<DetectedObject> filtered = [];
//   for (final obj in found) {
//     bool isDuplicate = false;
//     for (int i = 0; i < filtered.length; i++) {
//       final ex = filtered[i];
//       final overlapX = max(0.0, min(obj.x + obj.width, ex.x + ex.width) - max(obj.x, ex.x));
//       final overlapY = max(0.0, min(obj.y + obj.height, ex.y + ex.height) - max(obj.y, ex.y));
//       final overlapArea = overlapX * overlapY;
//       final objArea = obj.width * obj.height;

//       if (objArea > 0 && overlapArea > (objArea * 0.45)) {
//         isDuplicate = true;
//         if (obj.confidence > ex.confidence) {
//           filtered[i] = obj;
//         }
//         break;
//       }
//     }
//     if (!isDuplicate) filtered.add(obj);
//   }
//   return filtered;
// }

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
  final Uint8List
  primaryModelBytes; // custom_yolo.tflite  — 3-class (phone/cigarette/seatbelt)
  final Uint8List
  secondaryModelBytes; // custom_yolo_updated.tflite — 5-class (eating/drinking)
  final String documentsDirectoryPath;
  IsolateInitMessage(
    this.sendPort,
    this.primaryModelBytes,
    this.secondaryModelBytes,
    this.documentsDirectoryPath,
  );
}

class IsolateFrameMessage {
  final int width, height, rotation;
  final Uint8List yPlane, uPlane, vPlane;
  final int yRowStride, uvRowStride, uvPixelStride;
  final bool facePresent;
  final String driverId;
  final String documentsDirectoryPath;

  IsolateFrameMessage({
    required this.width,
    required this.height,
    required this.rotation,
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.facePresent,
    required this.driverId,
    required this.documentsDirectoryPath,
  });
}

class IsolateCommandDump {
  final String docsPath;
  final String driverId;
  IsolateCommandDump(this.docsPath, this.driverId);
}

class IsolateResultMessage {
  final List<DetectedObject> detectedObjects;
  final bool abnormalBehavior;
  final String? savedFolderPath;
  final int inferenceTimeMs;
  final bool isEvidenceDump;
  final String debugInfo;

  IsolateResultMessage({
    required this.detectedObjects,
    required this.abnormalBehavior,
    this.savedFolderPath,
    required this.inferenceTimeMs,
    this.isEvidenceDump = false,
    this.debugInfo = '',
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
      final directory = await getApplicationDocumentsDirectory();
      _docsPath = directory.path;

      // PRIMARY: 3-class model — phone/cigarette/seatbelt
      // Use the actual packaged asset location.
      final primaryData = await rootBundle.load(
        'assets/models/custom_yolo.tflite',
      );

      // SECONDARY: 5-class model — we use this ONLY for eating/drinking classes
      final secondaryData = await rootBundle.load(
        'assets/models/custom_yolo_updated.tflite',
      );

      _isolate = await Isolate.spawn(
        _yoloIsolateEntryPoint,
        IsolateInitMessage(
          _receivePort.sendPort,
          primaryData.buffer.asUint8List(),
          secondaryData.buffer.asUint8List(),
          _docsPath ?? '',
        ),
      );

      _receivePort.listen((message) {
        if (message is SendPort) {
          _isolateSendPort = message;
          _isInitialized = true;
          print(
            '[YOLO ENGINE] Dual-Model Isolate ONLINE. Primary=3-class Secondary=5-class',
          );
        } else if (message is IsolateResultMessage) {
          if (!message.isEvidenceDump) {
            _isProcessingFrame = false;
          }
          if (_state != null) {
            _updateState(_state!, message);
          }
        } else if (message is String) {
          print('[YOLO ISOLATE] $message');
          if (_state != null) {
            if (message.startsWith('TENSOR_INFO:') ||
                message.startsWith('INIT:') ||
                message.startsWith('DEBUG') ||
                message.startsWith('RUN_ERROR')) {
              _state!.yoloIsolateStatus = message.substring(
                0,
                message.length.clamp(0, 60),
              );
            }
          }
        }
      });
    } catch (e) {
      print('[YOLO ENGINE] Failed to initialize: $e');
    }
  }

  void processFrame(CameraImage image, MonitorState state, int rotation) {
    if (!_isInitialized || _isolateSendPort == null || _isProcessingFrame)
      return;
    _isProcessingFrame = true;
    _state = state;
    state.documentsDirectoryPath = _docsPath;

    final msg = IsolateFrameMessage(
      width: image.width,
      height: image.height,
      rotation: rotation,
      yPlane: image.planes[0].bytes,
      uPlane: image.planes[1].bytes,
      vPlane: image.planes[2].bytes,
      yRowStride: image.planes[0].bytesPerRow,
      uvRowStride: image.planes[1].bytesPerRow,
      uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
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
    if (result.isEvidenceDump && result.savedFolderPath != null) {
      try {
        final alert = state.recentAlerts.firstWhere(
          (a) => a.needsScreenshot && a.screenshotPath == null,
        );
        alert.screenshotPath = result.savedFolderPath;
      } catch (e) {}
      return;
    }

    state.detectedObjects = result.detectedObjects;
    state.yoloInferenceTimeMs = result.inferenceTimeMs;
    state.yoloIsolateStatus = 'Active';

    // Debug info from isolate
    if (result.debugInfo.isNotEmpty) {
      state.yoloRawDetections = [result.debugInfo];
    }

    // Map detections to state booleans
    // Labels order: 0=cigarette, 1=phone, 2=seatbelt, 3=eating, 4=drinking
    state.hasEating =
        result.detectedObjects.any((o) => o.label == 'eating') ||
        state.isChewing;
    state.hasDrinking = result.detectedObjects.any(
      (o) => o.label == 'drinking',
    );
    state.hasPhone = result.detectedObjects.any((o) => o.label == 'phone');
    state.hasCigarette = result.detectedObjects.any(
      (o) => o.label == 'cigarette',
    );

    final now = DateTime.now();
    bool requestEvidenceDump = false;

    // Leaky Bucket temporal smoothing for each banned object category
    final evaluationList = [
      {'label': 'phone', 'detected': state.hasPhone},
      {'label': 'cigarette', 'detected': state.hasCigarette},
      {'label': 'eating', 'detected': state.hasEating},
      {'label': 'drinking', 'detected': state.hasDrinking},
    ];

    for (final eval in evaluationList) {
      final label = eval['label'] as String;
      final detected = eval['detected'] as bool;

      int currentScore = state.consecutiveDistractions[label] ?? 0;

      if (detected) {
        currentScore += 4; // Fast fill when object is seen
      } else {
        currentScore -= 1; // Slow drain — tolerates flickering
      }

      currentScore = currentScore.clamp(0, 20);
      state.consecutiveDistractions[label] = currentScore;

      // Trigger at score >= 8
      if (currentScore >= 8) {
        final lastCooldown = state.distractionCooldowns[label];
        if (lastCooldown == null ||
            now.difference(lastCooldown).inSeconds >= 30) {
          state.distractionCooldowns[label] = now;
          state.totalDistractionCount++;

          state.addAlert(
            AlertEvent(
              type: 'flag_distraction_$label',
              message: 'FLAG: BANNED OBJECT - ${label.toUpperCase()} DETECTED',
              needsScreenshot: true,
              isMajorFlag: true,
            ),
          );
          requestEvidenceDump = true;

          // Reset to avoid repeat spam within cooldown
          state.consecutiveDistractions[label] = 0;
        }
      }
    }

    if (requestEvidenceDump) {
      _isolateSendPort?.send(
        IsolateCommandDump(_docsPath ?? '', 'Driver_Active'),
      );
    }

    // Seatbelt persistence (5-second grace period after last detection)
    final hasSeatbelt = result.detectedObjects.any(
      (o) => o.label == 'seatbelt',
    );
    if (hasSeatbelt) {
      state.seatbeltBuckled = true;
      state.lastSeatbeltDetected = now;
    } else if (state.lastSeatbeltDetected != null &&
        now.difference(state.lastSeatbeltDetected!).inSeconds >= 5) {
      state.seatbeltBuckled = false;
    }

    if (result.abnormalBehavior) {
      if (state.recentAlerts.where((a) => a.type == 'flag_abnormal').isEmpty) {
        state.addAlert(
          AlertEvent(
            type: 'flag_abnormal',
            message: 'FLAG: SUDDEN ABSENCE / DISPLACEMENT',
            needsScreenshot: true,
            isMajorFlag: true,
          ),
        );
        _isolateSendPort?.send(
          IsolateCommandDump(_docsPath ?? '', 'Driver_Active'),
        );
      }
    }
  }
}

// ── ISOLATE WORKER ──────────────────────────────────────────────────────────
// Dual-model approach:
//   Primary model   (custom_yolo.tflite)         → [1, 7, 8400] → 3 classes: phone/cigarette/seatbelt
//   Secondary model (custom_yolo_updated.tflite) → [1, 9, 8400] → 5 classes, but we ONLY use eating/drinking

void _yoloIsolateEntryPoint(IsolateInitMessage initMessage) async {
  final mainSendPort = initMessage.sendPort;
  final receivePort = ReceivePort();

  try {
    final options = InterpreterOptions()..threads = 2;

    // ── Load PRIMARY model (3-class: cigarette, phone, seatbelt) ──────────
    final interpA = Interpreter.fromBuffer(
      initMessage.primaryModelBytes,
      options: options,
    );

    final inA = interpA.getInputTensors()[0];
    final outA = interpA.getOutputTensors()[0];
    final shapeInA = inA.shape; // [1, H, W, 3]
    final shapeOutA = outA.shape; // [1, 7, 8400]
    final hA = shapeInA[1];
    final wA = shapeInA[2];
    final numBoxesA = shapeOutA[2]; // 8400
    final numRowsA = shapeOutA[1]; // 7  (4 box + 3 class)
    const labelsA = ['cigarette', 'phone', 'seatbelt'];
    const numClassesA = 3;

    mainSendPort.send('TENSOR_INFO: A=[${shapeInA}]->[${shapeOutA}] 3-class');

    // ── Load SECONDARY model (5-class, eating/drinking only) ──────────────
    final interpB = Interpreter.fromBuffer(
      initMessage.secondaryModelBytes,
      options: options,
    );

    final inB = interpB.getInputTensors()[0];
    final outB = interpB.getOutputTensors()[0];
    final shapeInB = inB.shape; // [1, H, W, 3]
    final shapeOutB = outB.shape; // [1, 9, 8400]
    final hB = shapeInB[1];
    final wB = shapeInB[2];
    final numBoxesB = shapeOutB[2];
    final numRowsB = shapeOutB[1];
    // We use ALL 5 labels from model B but only report eating/drinking
    const labelsB = ['cigarette', 'phone', 'seatbelt', 'eating', 'drinking'];
    const numClassesB = 5;
    const eatDrinkOnly = {
      'eating',
      'drinking',
    }; // Only these classes from model B

    mainSendPort.send(
      'TENSOR_INFO: B=[${shapeInB}]->[${shapeOutB}] 5-class (eating/drinking only)',
    );

    // ── Pre-allocated buffers ──────────────────────────────────────────────
    final isQuantizedA =
        inA.type == TensorType.uint8 || inA.type == TensorType.int8;
    final isQuantizedB =
        inB.type == TensorType.uint8 || inB.type == TensorType.int8;

    final Float32List inputFloatA = Float32List(hA * wA * 3);
    final Uint8List inputUint8A = Uint8List(hA * wA * 3);
    final Float32List inputFloatB = Float32List(hB * wB * 3);
    final Uint8List inputUint8B = Uint8List(hB * wB * 3);
    final Uint8List rgbBytesA = Uint8List(hA * wA * 3);
    final Uint8List rgbBytesB = Uint8List(hB * wB * 3);

    final Float32List outputFlatA = Float32List(
      numRowsA * numBoxesA,
    ); // 7*8400=58800
    final Float32List outputFlatB = Float32List(
      numRowsB * numBoxesB,
    ); // 9*8400=75600

    final List<Uint8List> ringBufferRgb = [];
    bool prevFacePresent = true;
    int frameCount = 0;

    mainSendPort.send(receivePort.sendPort); // Signal ready

    receivePort.listen((message) async {
      if (message is IsolateCommandDump) {
        if (ringBufferRgb.isNotEmpty) {
          final path = await _saveEvidence(
            ringBufferRgb,
            message.docsPath,
            message.driverId,
            wA,
            hA,
          );
          mainSendPort.send(
            IsolateResultMessage(
              detectedObjects: [],
              abnormalBehavior: false,
              savedFolderPath: path,
              inferenceTimeMs: 0,
              isEvidenceDump: true,
            ),
          );
        }
        return;
      }

      if (message is IsolateFrameMessage) {
        frameCount++;
        final stopwatch = Stopwatch()..start();

        // ── Always run Model A (phone/cigarette/seatbelt) ──────────────────
        _fastConvertImage(
          message,
          isQuantizedA ? inputUint8A : inputFloatA,
          rgbBytesA,
          wA,
          hA,
          isQuantizedA,
        );

        List<DetectedObject> detectionsA = [];
        try {
          inA.setTo(isQuantizedA ? inputUint8A : inputFloatA);
          interpA.invoke();
          final rawA = outA.data.buffer.asFloat32List();
          outputFlatA.setRange(
            0,
            rawA.length.clamp(0, outputFlatA.length),
            rawA,
          );
          detectionsA = _parseOutput(
            outputFlatA,
            labelsA,
            numBoxesA,
            numClassesA,
            confidenceThreshold: 0.35,
          );
        } catch (e) {
          mainSendPort.send('RUN_ERROR_A: $e');
        }

        // ── Run Model B (eating/drinking) every 3rd frame ──────────────────
        List<DetectedObject> detectionsB = [];
        if (frameCount % 3 == 0) {
          _fastConvertImage(
            message,
            isQuantizedB ? inputUint8B : inputFloatB,
            rgbBytesB,
            wB,
            hB,
            isQuantizedB,
          );
          try {
            inB.setTo(isQuantizedB ? inputUint8B : inputFloatB);
            interpB.invoke();
            final rawB = outB.data.buffer.asFloat32List();
            outputFlatB.setRange(
              0,
              rawB.length.clamp(0, outputFlatB.length),
              rawB,
            );
            // Only report eating/drinking from model B
            final allB = _parseOutput(
              outputFlatB,
              labelsB,
              numBoxesB,
              numClassesB,
              confidenceThreshold: 0.40,
            );
            detectionsB = allB
                .where((d) => eatDrinkOnly.contains(d.label))
                .toList();
          } catch (e) {
            mainSendPort.send('RUN_ERROR_B: $e');
          }
        }

        stopwatch.stop();

        // Merge: Model A provides phone/cigarette/seatbelt, Model B provides eating/drinking
        final allDetections = [...detectionsA, ...detectionsB];

        // Debug every 30 frames
        String debugInfo = '';
        if (frameCount % 30 == 0) {
          final peaksA = _buildDebugStr(
            outputFlatA,
            labelsA,
            numBoxesA,
            numClassesA,
          );
          final peaksB = _buildDebugStr(
            outputFlatB,
            labelsB,
            numBoxesB,
            numClassesB,
          );
          final msg = 'A[$peaksA] B[$peaksB] dets=${allDetections.length}';
          mainSendPort.send('DEBUG[f$frameCount]: $msg');
          debugInfo = msg;
        }

        // Evidence ring buffer
        ringBufferRgb.add(Uint8List.fromList(rgbBytesA));
        if (ringBufferRgb.length > 5) ringBufferRgb.removeAt(0);

        bool abnormal = false;
        if (prevFacePresent &&
            !message.facePresent &&
            ringBufferRgb.length >= 5) {
          abnormal = true;
        }
        prevFacePresent = message.facePresent;

        mainSendPort.send(
          IsolateResultMessage(
            detectedObjects: allDetections,
            abnormalBehavior: abnormal,
            inferenceTimeMs: stopwatch.elapsedMilliseconds,
            debugInfo: debugInfo,
          ),
        );
      }
    });
  } catch (e) {
    mainSendPort.send('ISOLATE_FATAL: $e');
    mainSendPort.send(receivePort.sendPort);
  }
}

// ── YUV -> RGB ───────────────────────────────────────────────────────────────

void _fastConvertImage(
  IsolateFrameMessage msg,
  dynamic inputBuffer,
  Uint8List rgbBytes,
  int targetW,
  int targetH,
  bool isQuantized,
) {
  int bufferIdx = 0;
  int rgbIdx = 0;

  for (int ty = 0; ty < targetH; ty++) {
    for (int tx = 0; tx < targetW; tx++) {
      int sx, sy;

      switch (msg.rotation) {
        case 90:
          sx = (ty * msg.width) ~/ targetH;
          sy = ((targetW - 1 - tx) * msg.height) ~/ targetW;
          break;
        case 180:
          sx = ((targetW - 1 - tx) * msg.width) ~/ targetW;
          sy = ((targetH - 1 - ty) * msg.height) ~/ targetH;
          break;
        case 270:
          sx = ((targetH - 1 - ty) * msg.width) ~/ targetH;
          sy = (tx * msg.height) ~/ targetW;
          break;
        default: // 0
          sx = (tx * msg.width) ~/ targetW;
          sy = (ty * msg.height) ~/ targetH;
      }

      sx = sx.clamp(0, msg.width - 1);
      sy = sy.clamp(0, msg.height - 1);

      final int yIdx = sy * msg.yRowStride + sx;
      final int uvIdx =
          (sy ~/ 2) * msg.uvRowStride + (sx ~/ 2) * msg.uvPixelStride;

      final int yVal = msg.yPlane[yIdx];
      final int u = msg.uPlane[uvIdx] - 128;
      final int v = msg.vPlane[uvIdx] - 128;

      final int r = (yVal + ((359 * v) >> 8)).clamp(0, 255);
      final int g = (yVal - ((88 * u + 183 * v) >> 8)).clamp(0, 255);
      final int b = (yVal + ((454 * u) >> 8)).clamp(0, 255);

      rgbBytes[rgbIdx++] = r;
      rgbBytes[rgbIdx++] = g;
      rgbBytes[rgbIdx++] = b;

      if (isQuantized) {
        (inputBuffer as Uint8List)[bufferIdx++] = r;
        (inputBuffer as Uint8List)[bufferIdx++] = g;
        (inputBuffer as Uint8List)[bufferIdx++] = b;
      } else {
        (inputBuffer as Float32List)[bufferIdx++] = r / 255.0;
        (inputBuffer as Float32List)[bufferIdx++] = g / 255.0;
        (inputBuffer as Float32List)[bufferIdx++] = b / 255.0;
      }
    }
  }
}

// ── Evidence save ────────────────────────────────────────────────────────────

Future<String?> _saveEvidence(
  List<Uint8List> ringBufferRgb,
  String docsPath,
  String driverId,
  int w,
  int h,
) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final folderPath = '$docsPath/SafeDrive_Evidence_${driverId}_$timestamp';
  final dir = Directory(folderPath);
  await dir.create(recursive: true);

  for (int i = 0; i < ringBufferRgb.length; i++) {
    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: ringBufferRgb[i].buffer,
      numChannels: 3,
    );
    final jpeg = img.encodeJpg(image, quality: 70);
    final file = File('${dir.path}/frame_$i.jpg');
    await file.writeAsBytes(jpeg);
  }
  return folderPath;
}

// ── Detection parsers ────────────────────────────────────────────────────────

/// Debug string: show top scores from first 200 boxes
String _buildDebugStr(
  Float32List output,
  List<String> labels,
  int numBoxes,
  int numClasses,
) {
  double globalMax = 0.0;
  String bestLabel = 'none';
  int scanLimit = min(numBoxes, 200);

  for (int col = 0; col < scanLimit; col++) {
    for (int cls = 0; cls < numClasses; cls++) {
      final prob = output[(4 + cls) * numBoxes + col];
      if (prob > globalMax) {
        globalMax = prob;
        bestLabel = labels[cls];
      }
    }
  }
  return 'peak=$bestLabel@${globalMax.toStringAsFixed(3)}';
}

/// Production parser with NMS
List<DetectedObject> _parseOutput(
  Float32List output,
  List<String> labels,
  int numBoxes,
  int numClasses, {
  double confidenceThreshold = 0.40,
}) {
  // YOLO output layout: [1, rows, boxes]
  // Flattened: index = row * numBoxes + col
  // Rows 0-3: cx, cy, w, h (normalized 0..1)
  // Rows 4+: class confidence scores
  final List<DetectedObject> found = [];

  for (int col = 0; col < numBoxes; col++) {
    double maxProb = 0.0;
    int bestClass = -1;

    for (int cls = 0; cls < numClasses; cls++) {
      final prob = output[(4 + cls) * numBoxes + col];
      if (prob > maxProb) {
        maxProb = prob;
        bestClass = cls;
      }
    }

    if (maxProb > confidenceThreshold && bestClass != -1) {
      final normCx = output[0 * numBoxes + col];
      final normCy = output[1 * numBoxes + col];
      final normW = output[2 * numBoxes + col];
      final normH = output[3 * numBoxes + col];

      found.add(
        DetectedObject(
          label: labels[bestClass],
          confidence: maxProb,
          x: (normCx - normW / 2.0).clamp(0.0, 1.0),
          y: (normCy - normH / 2.0).clamp(0.0, 1.0),
          width: normW.clamp(0.0, 1.0),
          height: normH.clamp(0.0, 1.0),
        ),
      );
    }
  }

  // NMS — remove overlapping duplicates, keep highest confidence
  final List<DetectedObject> filtered = [];
  for (final obj in found) {
    bool isDuplicate = false;
    for (int i = 0; i < filtered.length; i++) {
      final ex = filtered[i];
      final overlapX = max(
        0.0,
        min(obj.x + obj.width, ex.x + ex.width) - max(obj.x, ex.x),
      );
      final overlapY = max(
        0.0,
        min(obj.y + obj.height, ex.y + ex.height) - max(obj.y, ex.y),
      );
      final overlapArea = overlapX * overlapY;
      final objArea = obj.width * obj.height;

      if (objArea > 0 && overlapArea > (objArea * 0.45)) {
        isDuplicate = true;
        if (obj.confidence > ex.confidence) {
          filtered[i] = obj;
        }
        break;
      }
    }
    if (!isDuplicate) filtered.add(obj);
  }
  return filtered;
}

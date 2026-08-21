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

    // Map detections to state booleans using stronger per-label confidence thresholds
    const double kPhoneConfidence = 0.60;
    const double kCigaretteConfidence = 0.60;
    const double kEatingConfidence = 0.50;
    const double kDrinkingConfidence = 0.50;
    const double kSeatbeltConfidence = 0.50;

    final eatingDetections = result.detectedObjects.where(
      (o) => o.label == 'eating' && o.confidence > kEatingConfidence,
    );
    state.hasEating = eatingDetections.isNotEmpty || state.isChewing;
    state.eatingConfidence = eatingDetections.isNotEmpty
        ? eatingDetections
              .map((o) => o.confidence)
              .reduce((a, b) => a > b ? a : b)
        : 0.0;

    final drinkingDetections = result.detectedObjects.where(
      (o) => o.label == 'drinking' && o.confidence > kDrinkingConfidence,
    );
    state.hasDrinking = drinkingDetections.isNotEmpty;
    state.drinkingConfidence = drinkingDetections.isNotEmpty
        ? drinkingDetections
              .map((o) => o.confidence)
              .reduce((a, b) => a > b ? a : b)
        : 0.0;

    final phoneDetections = result.detectedObjects.where(
      (o) => o.label == 'phone' && o.confidence > kPhoneConfidence,
    );
    state.hasPhone = phoneDetections.isNotEmpty;
    state.phoneConfidence = phoneDetections.isNotEmpty
        ? phoneDetections
              .map((o) => o.confidence)
              .reduce((a, b) => a > b ? a : b)
        : 0.0;

    final cigaretteDetections = result.detectedObjects.where(
      (o) => o.label == 'cigarette' && o.confidence > kCigaretteConfidence,
    );
    state.hasCigarette = cigaretteDetections.isNotEmpty;
    state.cigaretteConfidence = cigaretteDetections.isNotEmpty
        ? cigaretteDetections
              .map((o) => o.confidence)
              .reduce((a, b) => a > b ? a : b)
        : 0.0;

    final now = DateTime.now();
    bool requestEvidenceDump = false;

    // Phone Tracking: Continuous 1.5s duration with 1.5s visual grace buffer
    if (state.hasPhone) {
      state.continuousPhoneLostSince = null;
      state.continuousPhoneSince ??= now;

      if (now.difference(state.continuousPhoneSince!).inMilliseconds >= 1500) {
        final lastCooldown = state.distractionCooldowns['phone'];
        if (lastCooldown == null ||
            now.difference(lastCooldown).inSeconds >= 30) {
          state.distractionCooldowns['phone'] = now;
          state.totalDistractionCount++;

          state.addAlert(
            AlertEvent(
              type: 'flag_distraction_phone',
              message: 'FLAG: BANNED OBJECT - PHONE DETECTED',
              needsScreenshot: true,
              isMajorFlag: true,
            ),
          );
          requestEvidenceDump = true;
          state.reportPhoneViolation = true;
          state.continuousPhoneSince = null; // reset to avoid spamming
        }
      }
    } else {
      if (state.continuousPhoneSince != null) {
        state.continuousPhoneLostSince ??= now;
        if (now.difference(state.continuousPhoneLostSince!).inMilliseconds >=
            1500) {
          state.continuousPhoneSince = null;
          state.continuousPhoneLostSince = null;
        }
      }
    }

    // ── STRICT CONTINUOUS CIGARETTE TRACKING ──
    const int kSustainedCigaretteMs = 2500; // 2.5s continuous smoking gesture
    const int kCigaretteGraceMs = 1500; // 1.5s grace loop to combat ML jitter

    if (state.hasCigarette) {
      if (state.continuousCigaretteSince == null) {
        state.continuousCigaretteSince = now;
      } else {
        if (now.difference(state.continuousCigaretteSince!).inMilliseconds >=
            kSustainedCigaretteMs) {
          state.reportCigaretteViolation = true;
          state.continuousCigaretteSince = null;
        }
      }
      state.continuousNoCigaretteSince = null;
    } else {
      if (state.continuousCigaretteSince != null) {
        state.continuousNoCigaretteSince ??= now;
        if (now.difference(state.continuousNoCigaretteSince!).inMilliseconds >=
            kCigaretteGraceMs) {
          state.continuousCigaretteSince = null;
          state.continuousNoCigaretteSince = null;
        }
      }
    }

    // Leaky Bucket temporal smoothing for other banned object categories
    final detectionConfig = {
      'eating': {'detected': state.hasEating, 'step': 2, 'threshold': 9},
      'drinking': {'detected': state.hasDrinking, 'step': 2, 'threshold': 9},
    };

    for (final entry in detectionConfig.entries) {
      final label = entry.key;
      final detected = entry.value['detected'] as bool;
      final step = entry.value['step'] as int;
      final threshold = entry.value['threshold'] as int;

      int currentScore = state.consecutiveDistractions[label] ?? 0;
      currentScore += detected ? step : -1;
      currentScore = currentScore.clamp(0, 20);
      state.consecutiveDistractions[label] = currentScore;

      if (currentScore >= threshold) {
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

    final hasSeatbelt = result.detectedObjects.any(
      (o) => o.label == 'seatbelt' && o.confidence > kSeatbeltConfidence,
    );

    if (requestEvidenceDump) {
      _isolateSendPort?.send(
        IsolateCommandDump(_docsPath ?? '', 'Driver_Active'),
      );
    }

    // // Seatbelt persistence (5-second grace period after last detection)
    // final hasSeatbelt = result.detectedObjects.any(
    //   (o) => o.label == 'seatbelt',
    // );

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

const int _kYoloInputSize = 640;

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
    final modelHeightA = shapeInA[1];
    final modelWidthA = shapeInA[2];
    if (modelHeightA != _kYoloInputSize || modelWidthA != _kYoloInputSize) {
      mainSendPort.send(
        'WARN: Primary model input shape ${modelWidthA}x${modelHeightA} != $_kYoloInputSize',
      );
    }
    final hA = modelHeightA == _kYoloInputSize ? _kYoloInputSize : modelHeightA;
    final wA = modelWidthA == _kYoloInputSize ? _kYoloInputSize : modelWidthA;
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
    final modelHeightB = shapeInB[1];
    final modelWidthB = shapeInB[2];
    if (modelHeightB != _kYoloInputSize || modelWidthB != _kYoloInputSize) {
      mainSendPort.send(
        'WARN: Secondary model input shape ${modelWidthB}x${modelHeightB} != $_kYoloInputSize',
      );
    }
    final hB = modelHeightB == _kYoloInputSize ? _kYoloInputSize : modelHeightB;
    final wB = modelWidthB == _kYoloInputSize ? _kYoloInputSize : modelWidthB;
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
          final rawA = Float32List.sublistView(outA.data);
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
            confidenceThreshold: 0.25,
          );
        } catch (e) {
          mainSendPort.send('RUN_ERROR_A: $e');
        }

        // ── Run Model B (eating/drinking) disabled ──
        // DISABLED (false) to prevent false positives and save CPU cycles.
        List<DetectedObject> detectionsB = [];
        if (false) {
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
            final rawB = Float32List.sublistView(outB.data);
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
              confidenceThreshold: 0.25,
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

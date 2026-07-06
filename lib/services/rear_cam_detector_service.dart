import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

// ── Message types ─────────────────────────────────────────────────────────────

class _InitMsg {
  final SendPort replyTo;
  final Uint8List modelBytes;
  _InitMsg(this.replyTo, this.modelBytes);
}

class _FrameMsg {
  final Uint8List jpegBytes;
  _FrameMsg(this.jpegBytes);
}

// ── Public result types ───────────────────────────────────────────────────────

class RearDetection {
  final String label;
  final double confidence;

  /// Bounding box as normalized coords (0–1) relative to the original JPEG frame.
  final double x, y, width, height;

  const RearDetection({
    required this.label,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

class RearDetectionResult {
  final List<RearDetection> detections;

  /// Original JPEG frame dimensions (used by the painter to place boxes correctly).
  final int frameWidth;
  final int frameHeight;

  const RearDetectionResult(this.detections, this.frameWidth, this.frameHeight);
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Runs YOLO11n-full-int8 on JPEG frames from the rear ESP32-CAM in an Isolate.
/// Detects pedestrians, vehicles and animals relevant to reversing.
class RearCamDetectorService {
  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  bool _isReady = false;
  bool _busy = false;

  bool get isReady => _isReady;
  bool get isBusy => _busy;

  /// Fired on the main thread after each inference completes.
  void Function(RearDetectionResult result)? onResult;

  Future<void> initialize() async {
    try {
      print('[RearDetector] Initializing service, loading yolo11n_full_int8.tflite asset...');
      final bytes = await rootBundle.load(
        'assets/models/yolo11n_full_int8.tflite',
      );
      print('[RearDetector] Asset loaded. Size: ${bytes.lengthInBytes} bytes. Spawning isolate...');
      _isolate = await Isolate.spawn(
        _isolateWorker,
        _InitMsg(_receivePort.sendPort, bytes.buffer.asUint8List()),
      );
      _receivePort.listen((msg) {
        if (msg is SendPort) {
          _sendPort = msg;
          _isReady = true;
          print('[RearDetector] Isolate ready and SendPort received.');
        } else if (msg is RearDetectionResult) {
          _busy = false;
          print('[RearDetector] Received results from isolate. Detections count: ${msg.detections.length}');
          onResult?.call(msg);
        } else if (msg is String) {
          print('[RearDetector] Isolate Message: $msg');
        }
      });
    } catch (e) {
      print('[RearDetector] Init error: $e');
    }
  }

  /// Feed a raw JPEG frame for detection.
  /// Silently ignored if the previous frame is still being processed.
  void processFrame(Uint8List jpegBytes) {
    if (!_isReady) {
      print('[RearDetector] processFrame ignored: Service not ready.');
      return;
    }
    if (_busy) {
      // Ignored silently to avoid log spam, as previous frame is still running
      return;
    }
    if (_sendPort == null) {
      print('[RearDetector] processFrame ignored: SendPort is null.');
      return;
    }
    _busy = true;
    print('[RearDetector] Sending JPEG frame to isolate for inference (${jpegBytes.length} bytes)...');
    _sendPort!.send(_FrameMsg(jpegBytes));
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort.close();
  }
}

// ── COCO-80 labels ────────────────────────────────────────────────────────────

const List<String> _kCoco80 = [
  'person',
  'bicycle',
  'car',
  'motorcycle',
  'airplane',
  'bus',
  'train',
  'truck',
  'boat',
  'traffic light',
  'fire hydrant',
  'stop sign',
  'parking meter',
  'bench',
  'bird',
  'cat',
  'dog',
  'horse',
  'sheep',
  'cow',
  'elephant',
  'bear',
  'zebra',
  'giraffe',
  'backpack',
  'umbrella',
  'handbag',
  'tie',
  'suitcase',
  'frisbee',
  'skis',
  'snowboard',
  'sports ball',
  'kite',
  'baseball bat',
  'baseball glove',
  'skateboard',
  'surfboard',
  'tennis racket',
  'bottle',
  'wine glass',
  'cup',
  'fork',
  'knife',
  'spoon',
  'bowl',
  'banana',
  'apple',
  'sandwich',
  'orange',
  'broccoli',
  'carrot',
  'hot dog',
  'pizza',
  'donut',
  'cake',
  'chair',
  'couch',
  'potted plant',
  'bed',
  'dining table',
  'toilet',
  'tv',
  'laptop',
  'mouse',
  'remote',
  'keyboard',
  'cell phone',
  'microwave',
  'oven',
  'toaster',
  'sink',
  'refrigerator',
  'book',
  'clock',
  'vase',
  'scissors',
  'teddy bear',
  'hair drier',
  'toothbrush',
];

/// Obstacle classes detected by ALL cameras (rear, front, left, right).
/// This single set is shared — both the rear overlay and the front/side
/// CamDetectionPanel use the same RearCamDetectorService isolate.
const Set<String> _kRelevant = {
  'person',
  'bicycle',
  'car',
  'motorcycle',
  'bus',
  'truck',
  'dog',
  'cat',
  'traffic light',
  'stop sign',
};

const double _kConf = 0.25;
const double _kIou = 0.45;

// ── Isolate worker ────────────────────────────────────────────────────────────

void _isolateWorker(_InitMsg init) {
  final port = ReceivePort();
  init.replyTo.send(port.sendPort);

  late Interpreter interp;
  try {
    interp = Interpreter.fromBuffer(
      init.modelBytes,
      options: InterpreterOptions()..threads = 4,
    );
  } catch (e) {
    init.replyTo.send('INIT_ERROR: $e');
    return;
  }

  final inTensor = interp.getInputTensors()[0];
  final outTensor = interp.getOutputTensors()[0];
  final inShape = inTensor.shape; // [1, H, W, 3]
  final outShape = outTensor.shape; // [1, 84, 8400] OR [1, 8400, 84]

  final H = inShape[1];
  final W = inShape[2];

  // ── Auto-detect output layout ──────────────────────────────────────────────
  // Standard Ultralytics export: [1, 84, 8400] → outShape[1]=84, outShape[2]=8400
  // Some exports are transposed:  [1, 8400, 84] → outShape[1]=8400, outShape[2]=84
  final bool isTransposed = outShape[1] > outShape[2];
  final int numRows = isTransposed ? outShape[2] : outShape[1]; // 84
  final int numBoxes = isTransposed ? outShape[1] : outShape[2]; // 8400

  // ── Input tensor info ──────────────────────────────────────────────────────
  final inType = inTensor.type;
  final inIsInt8 = inType == TensorType.int8;
  final inIsUint8 = inType == TensorType.uint8;

  // ── Output tensor info ─────────────────────────────────────────────────────
  final outType = outTensor.type;
  final outIsFloat32 = outType == TensorType.float32;
  final outIsInt8 = outType == TensorType.int8;
  final outIsUint8 = outType == TensorType.uint8;

  // Dequantization params (only meaningful when output is quantized)
  double outScale = 1.0;
  int outZeroPoint = 0;
  if (!outIsFloat32) {
    try {
      outScale = outTensor.params.scale;
      outZeroPoint = outTensor.params.zeroPoint;
    } catch (_) {
      // Fallback: assume standard YOLO full-int8 mapping
      outScale = 1.0 / 255.0;
      outZeroPoint = -128;
    }
  }

  // Input dequantization params (for building quantized input)
  double inScale = 1.0 / 255.0;
  int inZeroPoint = -128;
  if (inIsInt8 || inIsUint8) {
    try {
      inScale = inTensor.params.scale;
      inZeroPoint = inTensor.params.zeroPoint;
      if (inScale == 0.0) {
        inScale = 1.0 / 255.0;
      }
    } catch (_) {}
  }

  // Pre-allocated buffers
  final outputBuf = Float32List(numRows * numBoxes);

  init.replyTo.send(
    'READY: in=${inShape} type=${inType.name} inScale=$inScale inZP=$inZeroPoint | '
    'out=$outShape type=${outType.name} transposed=$isTransposed | '
    'outScale=$outScale outZP=$outZeroPoint',
  );

  port.listen((msg) {
    if (msg is! _FrameMsg) return;
    final stopwatch = Stopwatch()..start();
    try {
      final decoded = img.decodeJpg(msg.jpegBytes);
      if (decoded == null) {
        init.replyTo.send('FRAME_ERROR: JPEG decoding failed.');
        init.replyTo.send(RearDetectionResult([], 0, 0));
        return;
      }

      final origW = decoded.width;
      final origH = decoded.height;

      final resized = img.copyResize(
        decoded,
        width: W,
        height: H,
        interpolation: img.Interpolation.nearest,
      );

      // ── Build input buffer ─────────────────────────────────────────────────
      if (inIsInt8) {
        // Full int8 signed input: pixel_uint8 → int8 via quantization params
        // Formula: q = clamp(round(f / scale) + zeroPoint, -128, 127)
        // If scale is small (< 0.1), f is pixel / 255.0. Otherwise f is pixel.
        final double scaleFactor = (inScale < 0.1) ? 255.0 : 1.0;
        final buf = Int8List(H * W * 3);
        int idx = 0;
        for (int y = 0; y < H; y++) {
          for (int x = 0; x < W; x++) {
            final p = resized.getPixel(x, y);
            buf[idx++] = ((p.r / scaleFactor) / inScale + inZeroPoint).round().clamp(
              -128,
              127,
            );
            buf[idx++] = ((p.g / scaleFactor) / inScale + inZeroPoint).round().clamp(
              -128,
              127,
            );
            buf[idx++] = ((p.b / scaleFactor) / inScale + inZeroPoint).round().clamp(
              -128,
              127,
            );
          }
        }
        inTensor.setTo(buf);
      } else if (inIsUint8) {
        // Uint8 input: pass raw pixel values [0, 255] directly
        // Formula: q = clamp(round(f / scale) + zeroPoint, 0, 255)
        // If scale is small (< 0.1), f is pixel / 255.0. Otherwise f is pixel.
        final double scaleFactor = (inScale < 0.1) ? 255.0 : 1.0;
        final buf = Uint8List(H * W * 3);
        int idx = 0;
        for (int y = 0; y < H; y++) {
          for (int x = 0; x < W; x++) {
            final p = resized.getPixel(x, y);
            buf[idx++] = ((p.r / scaleFactor) / inScale + inZeroPoint).round().clamp(
              0,
              255,
            );
            buf[idx++] = ((p.g / scaleFactor) / inScale + inZeroPoint).round().clamp(
              0,
              255,
            );
            buf[idx++] = ((p.b / scaleFactor) / inScale + inZeroPoint).round().clamp(
              0,
              255,
            );
          }
        }
        inTensor.setTo(buf);
      } else {
        // Float32 input: normalise [0, 1]
        final buf = Float32List(H * W * 3);
        int idx = 0;
        for (int y = 0; y < H; y++) {
          for (int x = 0; x < W; x++) {
            final p = resized.getPixel(x, y);
            buf[idx++] = p.r / 255.0;
            buf[idx++] = p.g / 255.0;
            buf[idx++] = p.b / 255.0;
          }
        }
        inTensor.setTo(buf);
      }

      // ── Run inference ──────────────────────────────────────────────────────
      interp.invoke();

      // ── Read + dequantize output ───────────────────────────────────────────
      if (outIsFloat32) {
        final raw = Float32List.sublistView(outTensor.data);
        outputBuf.setRange(0, raw.length.clamp(0, outputBuf.length), raw);
      } else if (outIsInt8) {
        // int8 bytes: 1 byte per value → dequantize to float
        final raw = Int8List.sublistView(outTensor.data);
        final total = min(numRows * numBoxes, raw.length);
        for (int i = 0; i < total; i++) {
          outputBuf[i] = (raw[i] - outZeroPoint) * outScale;
        }
      } else if (outIsUint8) {
        final raw = Uint8List.sublistView(outTensor.data);
        final total = min(numRows * numBoxes, raw.length);
        for (int i = 0; i < total; i++) {
          outputBuf[i] = (raw[i] - outZeroPoint) * outScale;
        }
      }

      // ── Parse detections ───────────────────────────────────────────────────
      // Standard layout [1, 84, 8400]: outputBuf[row * numBoxes + box]
      // Transposed layout [1, 8400, 84]: outputBuf[box * numRows + row]
      double _get(int row, int box) => isTransposed
          ? outputBuf[box * numRows + row]
          : outputBuf[row * numBoxes + box];

      double minVal = 9999.0;
      double maxVal = -9999.0;
      for (int i = 0; i < outputBuf.length; i++) {
        final v = outputBuf[i];
        if (v < minVal) minVal = v;
        if (v > maxVal) maxVal = v;
      }
      init.replyTo.send('DEBUG: outputBuf min=${minVal.toStringAsFixed(4)} max=${maxVal.toStringAsFixed(4)} length=${outputBuf.length}');
      final temp = [for (int r = 0; r < min(15, numRows); r++) _get(r, 0).toStringAsFixed(4)];
      init.replyTo.send('DEBUG: Box 0 rows 0..15: $temp');

      final dets = <RearDetection>[];
      int rawAboveConf = 0;
      for (int b = 0; b < numBoxes; b++) {
        double maxScore = 0.0;
        int maxClass = -1;
        for (int c = 4; c < numRows; c++) {
          final s = _get(c, b);
          if (s > maxScore) {
            maxScore = s;
            maxClass = c - 4;
          }
        }
        if (maxScore < _kConf) continue;
        rawAboveConf++;
        if (maxClass < 0 || maxClass >= _kCoco80.length) continue;

        final label = _kCoco80[maxClass];
        if (!_kRelevant.contains(label)) continue;

        // Coordinates: in model pixel space (0–W, 0–H) → normalise to [0, 1]
        final cx = _get(0, b) / W;
        final cy = _get(1, b) / H;
        final bw = _get(2, b) / W;
        final bh = _get(3, b) / H;

        final x = (cx - bw / 2).clamp(0.0, 1.0);
        final y = (cy - bh / 2).clamp(0.0, 1.0);
        final w = bw.clamp(0.0, 1.0 - x);
        final h = bh.clamp(0.0, 1.0 - y);

        dets.add(
          RearDetection(
            label: label,
            confidence: maxScore,
            x: x,
            y: y,
            width: w,
            height: h,
          ),
        );
      }

      final nmsResult = _nms(dets);
      final elapsed = stopwatch.elapsedMilliseconds;
      init.replyTo.send(
        'Inference done in ${elapsed}ms. '
        'Raw detections above conf($_kConf): $rawAboveConf. '
        'Relevant detections after NMS: ${nmsResult.map((d) => "${d.label}(${(d.confidence*100).toStringAsFixed(0)}%)").toList()}'
      );

      init.replyTo.send(RearDetectionResult(nmsResult, origW, origH));
    } catch (e) {
      init.replyTo.send('FRAME_ERROR: $e');
      init.replyTo.send(RearDetectionResult([], 0, 0));
    }
  });
}

// ── NMS helpers ───────────────────────────────────────────────────────────────

List<RearDetection> _nms(List<RearDetection> dets) {
  if (dets.isEmpty) return dets;
  dets.sort((a, b) => b.confidence.compareTo(a.confidence));
  final suppressed = List.filled(dets.length, false);
  final out = <RearDetection>[];
  for (int i = 0; i < dets.length; i++) {
    if (suppressed[i]) continue;
    out.add(dets[i]);
    for (int j = i + 1; j < dets.length; j++) {
      if (!suppressed[j] && _iou(dets[i], dets[j]) > _kIou) {
        suppressed[j] = true;
      }
    }
  }
  return out;
}

double _iou(RearDetection a, RearDetection b) {
  final ix1 = max(a.x, b.x);
  final iy1 = max(a.y, b.y);
  final ix2 = min(a.x + a.width, b.x + b.width);
  final iy2 = min(a.y + a.height, b.y + b.height);
  if (ix2 <= ix1 || iy2 <= iy1) return 0.0;
  final inter = (ix2 - ix1) * (iy2 - iy1);
  final union = a.width * a.height + b.width * b.height - inter;
  return union <= 0 ? 0.0 : inter / union;
}

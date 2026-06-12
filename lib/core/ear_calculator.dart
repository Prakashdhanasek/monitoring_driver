// lib/core/ear_calculator.dart
// Eye Aspect Ratio & Mouth Aspect Ratio — direct port of Python formulas
// EAR = (|P2-P6| + |P3-P5|) / (2 * |P1-P4|)  — Soukupová & Čech 2016

import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class EarCalculator {
  /// Euclidean distance between two points
  static double _dist(Point<double> a, Point<double> b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return sqrt(dx * dx + dy * dy);
  }

  /// Calculate EAR for one eye given 6 landmark points
  /// p1=outer corner, p2=upper-outer, p3=upper-inner,
  /// p4=inner corner, p5=lower-inner, p6=lower-outer
  static double calculateEar(List<Point<double>> pts) {
    if (pts.length < 6) return 0.0;
    final vertical1 = _dist(pts[1], pts[5]);
    final vertical2 = _dist(pts[2], pts[4]);
    final horizontal = _dist(pts[0], pts[3]);
    if (horizontal < 1e-6) return 0.0;
    return (vertical1 + vertical2) / (2.0 * horizontal);
  }

  /// Calculate MAR for mouth
  /// MAR = (|Lip2-Lip10| + |Lip3-Lip9| + |Lip4-Lip8|) / (3 * |Corner-Corner|)
  static double calculateMar(List<Point<double>> pts) {
    if (pts.length < 8) return 0.0;
    final v1 = _dist(pts[1], pts[7]);
    final v2 = _dist(pts[2], pts[6]);
    final v3 = _dist(pts[3], pts[5]);
    final h = _dist(pts[0], pts[4]);
    if (h < 1e-6) return 0.0;
    return (v1 + v2 + v3) / (3.0 * h);
  }

  /// Extract eye landmark points from MLKit FaceLandmark
  /// MLKit landmark types mapped to our EAR 6-point model
  static List<Point<double>> extractLeftEyePoints(Face face) {
    final contour = face.contours[FaceContourType.leftEye];
    if (contour == null || contour.points.isEmpty) return [];
    final pts = contour.points;
    if (pts.length < 16) return []; // MLKit eye contours always have 16 points

    // Map MLKit 16-point contour to 6-point EAR model
    // 0 = left corner, 8 = right corner
    // 2, 6 = top eyelid | 14, 10 = bottom eyelid
    return [
      Point<double>(pts[0].x.toDouble(), pts[0].y.toDouble()),   // p0: Left corner
      Point<double>(pts[2].x.toDouble(), pts[2].y.toDouble()),   // p1: Top-left
      Point<double>(pts[6].x.toDouble(), pts[6].y.toDouble()),   // p2: Top-right
      Point<double>(pts[8].x.toDouble(), pts[8].y.toDouble()),   // p3: Right corner
      Point<double>(pts[10].x.toDouble(), pts[10].y.toDouble()), // p4: Bottom-right
      Point<double>(pts[14].x.toDouble(), pts[14].y.toDouble()), // p5: Bottom-left
    ];
  }

  static List<Point<double>> extractRightEyePoints(Face face) {
    final contour = face.contours[FaceContourType.rightEye];
    if (contour == null || contour.points.isEmpty) return [];
    final pts = contour.points;
    if (pts.length < 16) return [];
    
    return [
      Point<double>(pts[0].x.toDouble(), pts[0].y.toDouble()),
      Point<double>(pts[2].x.toDouble(), pts[2].y.toDouble()),
      Point<double>(pts[6].x.toDouble(), pts[6].y.toDouble()),
      Point<double>(pts[8].x.toDouble(), pts[8].y.toDouble()),
      Point<double>(pts[10].x.toDouble(), pts[10].y.toDouble()),
      Point<double>(pts[14].x.toDouble(), pts[14].y.toDouble()),
    ];
  }

  static List<Point<double>> extractMouthPoints(Face face) {
    final upper = face.contours[FaceContourType.upperLipTop];
    final lower = face.contours[FaceContourType.lowerLipBottom];
    final leftCorner = face.landmarks[FaceLandmarkType.leftMouth];
    final rightCorner = face.landmarks[FaceLandmarkType.rightMouth];
    if (upper == null || lower == null || leftCorner == null || rightCorner == null) {
      return [];
    }
    // Build 8-point mouth model
    final midUpper = upper.points[upper.points.length ~/ 2];
    final midLower = lower.points[lower.points.length ~/ 2];
    return [
      Point<double>(leftCorner.position.x.toDouble(), leftCorner.position.y.toDouble()),
      Point<double>(midUpper.x.toDouble() - 10, midUpper.y.toDouble()),
      Point<double>(midUpper.x.toDouble(), midUpper.y.toDouble()),
      Point<double>(midUpper.x.toDouble() + 10, midUpper.y.toDouble()),
      Point<double>(rightCorner.position.x.toDouble(), rightCorner.position.y.toDouble()),
      Point<double>(midLower.x.toDouble() + 10, midLower.y.toDouble()),
      Point<double>(midLower.x.toDouble(), midLower.y.toDouble()),
      Point<double>(midLower.x.toDouble() - 10, midLower.y.toDouble()),
    ];
  }
}

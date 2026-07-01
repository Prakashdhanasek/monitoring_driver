
enum AuthStatus { scanning, authenticated, unauthorized, multipleFaces }
enum DrowsinessLevel { alert, drowsy, asleep }
enum DistractionStatus { forward, distracted }
enum MonitorMode { normal, sunglasses, oneEye }

class AlertEvent {
  final String type;
  final String message;
  final DateTime timestamp;
  final bool needsScreenshot;
  final bool isMajorFlag;
  String? screenshotPath;

  AlertEvent({
    required this.type,
    required this.message,
    this.needsScreenshot = false,
    this.isMajorFlag = false,
  }) : timestamp = DateTime.now();
}

class MonitorState {
  // Auth
  AuthStatus authStatus = AuthStatus.scanning;
  double authDistance = -1.0;
  int? authenticatedTrackingId;
  int faceCount = 0;
  bool seatbeltBuckled = false;
  DateTime? lastSeatbeltDetected;

  double gpsLat = 0.0;
double gpsLng = 0.0;
double vehicleSpeed = 0.0;

  // Calibration
  bool calibrated = false;
  int calibrationFrame = 0;

  // Mode
  MonitorMode monitorMode = MonitorMode.normal;
  String oneEyeSide = '';

  // EAR
  double leftEar = 0.0;
  double rightEar = 0.0;
  double earBaseline = 0.28;
  double earThreshold = 0.21;
  List<double> calibrationEarValues = [];

  // Drowsiness timer & PERCLOS
  DateTime? eyesClosedSince;
  DateTime? eyesOpenSince;
  DateTime? perclosExceededSince;
  DateTime? yoloYawnDetectedSince;
  DateTime? sunglassesHeadDropSince;
  
  // Drowsiness 'Strike' System
  int drowsyAlertCount = 0;
  DateTime? continuousDrowsySince;
  DateTime? continuousRecoverySince;

  DrowsinessLevel drowsinessLevel = DrowsinessLevel.alert;
  int totalDrowsyCount = 0;
  List<bool> eyeClosureHistory = [];
  static const int perclosWindowSize = 900; 

  // MAR (sunglasses mode)
  double mar = 0.0;
  DateTime? yawningSince;

  // Head pose
  double yaw = 0.0;
  double pitch = 0.0;
  double roll = 0.0;
  DistractionStatus distractionStatus = DistractionStatus.forward;
  DateTime? distractedSince;
  DateTime? headDropSince;

  // Chewing Detection
  List<DateTime> chewTimestamps = [];
  bool lastMouthStateOpen = false;
  DateTime? chewingFlaggedSince;
  bool isChewing = false;

  // Blink tracking
  List<DateTime> blinkTimestamps = [];
  List<double> recentEarHistory = [];
  double blinkBaseline = 0.0;
  bool blinkBaselineSet = false;
  DateTime? blinkBaselineStart;
  int blinkBaselineCount = 0;
  bool impairmentFlag = false;
  DateTime? impairmentFlaggedSince;
  DateTime? impairmentSuppressedUntil;
  bool lastEyeStateOpen = true;

  // Driver historical baseline
  double headSwayBaseline = 0.0;
  List<double> headPitchHistory = [];
  List<double> headYawHistory = [];

  // Distraction tracking
  int totalDistractionCount = 0;
  DateTime? lastDistractionFlagTime;
  Map<String, int> consecutiveDistractions = {};
  Map<String, DateTime> distractionCooldowns = {};

  // Distraction Strike System (looking away)
  // 1-4 strikes = audio alert, 5 strikes = major flag
  int distractionStrikeCount = 0;
  DateTime? continuousDistractedSince;
  DateTime? continuousForwardSince;
  DateTime? lastDistractionStrikeCooldown;

  // Object detection
  List<DetectedObject> detectedObjects = [];
  
  // YOLO Diagnostics
  String yoloInputShape = 'unknown';
  String yoloOutputShape = 'unknown';
  int yoloInferenceTimeMs = 0;
  String yoloIsolateStatus = 'Initializing...';
  List<String> yoloRawDetections = [];
  int cameraStreamWidth = 0;
  int cameraStreamHeight = 0;
  int cameraRotation = 0;
  String? documentsDirectoryPath;

  // Alert log
  List<AlertEvent> recentAlerts = [];
  Map<String, DateTime> lastScreenshotTime = {};

  // Frame counters & Debouncing
  int frameCount = 0;
  int consecutiveMobileFrames = 0;
  int consecutiveDrinkFrames = 0;
  int consecutiveSmokeFrames = 0;
  int consecutiveFoodFrames = 0;
  Map<String, DateTime> alertCooldowns = {};

  void addAlert(AlertEvent e) {
    recentAlerts.insert(0, e);
    if (recentAlerts.length > 20) recentAlerts.removeLast();
  }

  void resetCalibration() {
    calibrated = false;
    calibrationFrame = 0;
    calibrationEarValues.clear();
    earBaseline = 0.28;
    earThreshold = 0.21;
    monitorMode = MonitorMode.normal;
    oneEyeSide = '';
    blinkBaselineSet = false;
    blinkBaselineStart = null;
    blinkTimestamps.clear();
    impairmentFlag = false;
    impairmentFlaggedSince = null;
    drowsinessLevel = DrowsinessLevel.alert;
    totalDrowsyCount = 0;
    distractionStatus = DistractionStatus.forward;
    eyesClosedSince = null;
    eyesOpenSince = null;
    perclosExceededSince = null;
    yoloYawnDetectedSince = null;
    sunglassesHeadDropSince = null;
    drowsyAlertCount = 0;
    continuousDrowsySince = null;
    continuousRecoverySince = null;
    distractedSince = null;
    headDropSince = null;
    seatbeltBuckled = false;
    totalDistractionCount = 0;
    lastDistractionFlagTime = null;
    consecutiveDistractions.clear();
    distractionCooldowns.clear();
    distractionStrikeCount = 0;
    continuousDistractedSince = null;
    continuousForwardSince = null;
    lastDistractionStrikeCooldown = null;
    headSwayBaseline = 0.0;
    headPitchHistory.clear();
    headYawHistory.clear();
    recentEarHistory.clear();
    chewTimestamps.clear();
    lastMouthStateOpen = false;
    chewingFlaggedSince = null;
    isChewing = false;
    eyeClosureHistory.clear();
    roll = 0.0;
    yoloInputShape = 'unknown';
    yoloOutputShape = 'unknown';
    yoloInferenceTimeMs = 0;
    yoloIsolateStatus = 'Ready';
    yoloRawDetections.clear();
    cameraStreamWidth = 0;
    cameraStreamHeight = 0;
    cameraRotation = 0;
    severeImpairmentWarning = false;
    closedIntervals.clear();
    consecutiveMobileFrames = 0;
    consecutiveDrinkFrames = 0;
    consecutiveSmokeFrames = 0;
    consecutiveFoodFrames = 0;
    hasPhone = false;
    hasCigarette = false;
    hasEating = false;
    hasDrinking = false;
    phoneConfidence = 0.0;
    cigaretteConfidence = 0.0;
    eatingConfidence = 0.0;
    drinkingConfidence = 0.0;
    recentAlerts.clear();
    alertCooldowns.clear();
  }

  bool severeImpairmentWarning = false;
  List<ClosedInterval> closedIntervals = [];

  bool hasPhone = false;
  bool hasCigarette = false;
  bool hasEating = false;
  bool hasDrinking = false;

  double phoneConfidence = 0.0;
  double cigaretteConfidence = 0.0;
  double eatingConfidence = 0.0;
  double drinkingConfidence = 0.0;
}

class DetectedObject {
  final String label;
  final double confidence;
  final double x, y, width, height;
  DetectedObject({
    required this.label,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

class ClosedInterval {
  DateTime start;
  DateTime? end;
  ClosedInterval(this.start, [this.end]);
}

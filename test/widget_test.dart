import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monitoring_driver/services/reversing_detector_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Mock the MethodChannel for sensors_plus to avoid MissingPluginException
    const MethodChannel methodChannel = MethodChannel('dev.fluttercommunity.plus/sensors/method');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      (MethodCall methodCall) async {
        return null;
      },
    );

    // Mock the EventChannel for user accelerometer
    const MethodChannel eventChannel = MethodChannel('dev.fluttercommunity.plus/sensors/user_accelerometer');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      eventChannel,
      (MethodCall methodCall) async {
        return null;
      },
    );
  });

  test('ReversingDetectorService starts with isReversing = false', () {
    final detector = ReversingDetectorService();
    expect(detector.isReversing, isFalse);
    detector.dispose();
  });

  test('ReversingDetectorService triggers isReversing on negative GPS latitude', () {
    final detector = ReversingDetectorService();
    expect(detector.isReversing, isFalse);

    // Update GPS with a negative latitude
    detector.updateGps(-10.0, 20.0, 15.0, 0.0);
    expect(detector.isReversing, isTrue);

    detector.dispose();
  });

  test('ReversingDetectorService triggers isReversing on negative GPS speed', () {
    final detector = ReversingDetectorService();
    expect(detector.isReversing, isFalse);

    // Update GPS with a negative speed
    detector.updateGps(10.0, 20.0, -5.0, 0.0);
    expect(detector.isReversing, isTrue);

    detector.dispose();
  });
}

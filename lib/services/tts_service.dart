import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  DateTime? _lastSpokeAt;

  Future<void> init() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);   
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      _ready = true;
      debugPrint('[TTS] Ready.');
    } catch (e) {
      debugPrint('[TTS] init error: $e');
    }
  }

  /// Voice alert speak cheyyuka. 3s cooldown — spam ozhivakkan.
  Future<void> speak(String message) async {
    if (!_ready) return;
    final now = DateTime.now();
    if (_lastSpokeAt != null &&
        now.difference(_lastSpokeAt!).inMilliseconds < 3000) {
      return;
    }
    _lastSpokeAt = now;
    try {
      await _tts.stop();
      await _tts.speak(message);
      debugPrint('[TTS] Speaking: $message');
    } catch (e) {
      debugPrint('[TTS] speak error: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum AlertLang { english, hindi, malayalam, tamil }

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  DateTime? _lastSpokeAt;
  AlertLang _lang = AlertLang.english;

  static const Map<AlertLang, String> _langCodes = {
    AlertLang.english: 'en-US',
    AlertLang.hindi: 'hi-IN',
    AlertLang.malayalam: 'ml-IN',
    AlertLang.tamil: 'ta-IN',
  };

  Future<void> init() async {
    try {
      await _tts.setLanguage(_langCodes[_lang]!);
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

  Future<void> setLanguage(AlertLang lang) async {
    _lang = lang;
    final code = _langCodes[lang]!;
    try {
      final available = await _tts.isLanguageAvailable(code);
      if (available == true) {
        await _tts.setLanguage(code);
        debugPrint('[TTS] Language set to $code');
      } else {
        debugPrint('[TTS] $code not available on device — falling back to en-US');
        await _tts.setLanguage('en-US');
        _lang = AlertLang.english;
      }
    } catch (e) {
      debugPrint('[TTS] setLanguage error: $e');
    }
  }

  AlertLang get currentLang => _lang;

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
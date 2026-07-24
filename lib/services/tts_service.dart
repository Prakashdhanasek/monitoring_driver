import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum AlertLang { english, hindi, malayalam, tamil, kannada }

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
    AlertLang.kannada: 'kn-IN',
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

      // Pre-download all language voice packs at startup
      _preloadAllLanguages();
    } catch (e) {
      debugPrint('[TTS] init error: $e');
    }
  }

  /// Triggers Google TTS engine to check and download voice data for all
  /// supported languages. Uses Android's TextToSpeech.Engine.ACTION_CHECK_TTS_DATA
  /// via a platform channel, and also synthesizes a short phrase in each language
  /// to force the engine to fetch network voices if local ones are missing.
  Future<void> _preloadAllLanguages() async {
    // Step 1: Fire the Android TTS check/install intent via platform channel
    try {
      const platform = MethodChannel('kiosk');
      await platform.invokeMethod('installTtsData');
      debugPrint('[TTS] Triggered TTS data install intent');
    } catch (e) {
      debugPrint('[TTS] installTtsData channel not available: $e');
    }

    // Step 2: Synthesize a short phrase in each language to force network voice download
    final savedVolume = 0.0; // mute during preload
    await _tts.setVolume(savedVolume);
    for (final entry in _langCodes.entries) {
      final code = entry.value;
      try {
        final available = await _tts.isLanguageAvailable(code);
        if (available == true) {
          await _tts.setLanguage(code);
          // Speak a real word (not just space) to trigger actual voice synthesis
          await _tts.speak('.');
          await Future.delayed(const Duration(milliseconds: 500));
          await _tts.stop();
          debugPrint('[TTS] Preloaded voice for: $code');
        } else {
          debugPrint('[TTS] $code not available on this device');
        }
      } catch (e) {
        debugPrint('[TTS] Preload error for $code: $e');
      }
    }
    // Restore volume and language
    await _tts.setVolume(1.0);
    await _tts.setLanguage(_langCodes[_lang]!);
    debugPrint(
      '[TTS] All languages preloaded. Restored to: ${_langCodes[_lang]}',
    );
  }

  Future<void> setLanguage(AlertLang lang) async {
    if (lang == AlertLang.english) {
      _lang = AlertLang.english;
      await _tts.setLanguage('en-US');
      debugPrint('[TTS] Language set to en-US');
      return;
    }

    final code = _langCodes[lang]!;
    try {
      // Step 1: check if locale is recognised at all
      final available = await _tts.isLanguageAvailable(code);
      if (available != true) {
        debugPrint('[TTS] $code not supported — falling back to en-US');
        _lang = AlertLang.english;
        await _tts.setLanguage('en-US');
        return;
      }

      // Step 2: check that an actual voice exists for this locale.
      // isLanguageAvailable can return true even when no voice pack is
      // installed, causing a silent "No local or network voice found" failure.
      final voices = await _tts.getVoices as List?;
      final langPrefix = code.split('-').first.toLowerCase(); // e.g. "ml"
      final hasVoice =
          voices?.any((v) {
            final locale = (v['locale'] ?? '').toString().toLowerCase();
            return locale.startsWith(langPrefix);
          }) ??
          false;

      if (hasVoice) {
        await _tts.setLanguage(code);
        _lang = lang;
        debugPrint('[TTS] Language set to $code');
      } else {
        debugPrint(
          '[TTS] $code has no installed voice pack — falling back to en-US. '
          'Install voices: Settings → General Management → Text-to-speech → Google → Language → Download $code',
        );
        _lang = AlertLang.english;
        await _tts.setLanguage('en-US');
      }
    } catch (e) {
      debugPrint('[TTS] setLanguage error: $e');
      _lang = AlertLang.english;
      await _tts.setLanguage('en-US');
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

  /// Speaks [message] immediately, bypassing the 3-second throttle, and
  /// awaits full speech completion. Use for critical one-shot alerts
  /// (e.g. licence expiry dialogs) where guaranteed playback is required.
  Future<void> speakImmediately(String message) async {
    if (!_ready) return;
    _lastSpokeAt = DateTime.now();
    try {
      await _tts.stop();
      await _tts.speak(message);
      debugPrint('[TTS] speakImmediately: $message');
    } catch (e) {
      debugPrint('[TTS] speakImmediately error: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

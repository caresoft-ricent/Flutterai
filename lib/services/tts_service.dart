import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final ttsServiceProvider = Provider<TtsService>((ref) {
  return TtsService();
});

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.52);
    await _tts.setPitch(1.0);
    _initialized = true;
  }

  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _init();
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    if (!_initialized) return;
    await _tts.stop();
  }

  void dispose() {
    _tts.stop();
  }
}

import 'dart:async';

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
    // 在部分 Android 机型上 awaitSpeakCompletion=true 可能导致 Future 不返回，
    // 从而卡住 UI 流程（例如“识别完成，正在解析意图...”一直转圈）。
    try {
      await _tts.awaitSpeakCompletion(false);
    } catch (_) {
      // ignore
    }
    _initialized = true;
  }

  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _init();
    try {
      await _tts.stop();
    } catch (_) {
      // ignore
    }
    // 非阻塞播报，避免底层插件/系统 TTS 状态异常时阻塞业务流程。
    try {
      unawaited(_tts.speak(text));
    } catch (_) {
      // ignore
    }
  }

  Future<void> stop() async {
    if (!_initialized) return;
    await _tts.stop();
  }

  void dispose() {
    _tts.stop();
  }
}

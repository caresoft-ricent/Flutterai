import 'package:flutter_riverpod/flutter_riverpod.dart';

final speechServiceProvider = Provider<SpeechService>((ref) {
  return SpeechService.instance;
});

class SpeechService {
  SpeechService._();

  static final SpeechService instance = SpeechService._();

  bool _isListening = false;
  String? _lastInitError;
  String? _lastInitStage;

  bool get isListening => _isListening;
  bool get isReady => false;
  String? get lastInitError => _lastInitError;
  String? get lastInitStage => _lastInitStage;

  Future<bool> init({
    void Function(double progress)? onDownloadProgress,
    bool requireMicPermission = false,
  }) async {
    _lastInitStage = 'web';
    _lastInitError = 'Web 端不支持离线语音识别（sherpa_onnx/ffi）';
    return false;
  }

  Future<bool> startListening({
    required void Function(String partial) onPartialResult,
    required void Function(String text) onFinalResult,
    void Function(double progress)? onDownloadProgress,
    bool finalizeOnEndpoint = true,
    bool preferOnline = false,
  }) async {
    _lastInitStage = 'web';
    _lastInitError = 'Web 端暂不支持语音识别（请用 iOS/Android 真机）';
    _isListening = false;
    return false;
  }

  Future<void> stopListening({
    void Function(String text)? onFinalResult,
  }) async {
    _isListening = false;
    onFinalResult?.call('');
  }

  Future<void> cancel() async {
    _isListening = false;
  }
}

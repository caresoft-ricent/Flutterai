import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_downloader.dart';
import 'xunfei_speech_service.dart';
import '../app_local_secrets.dart' as local_secrets;

final speechServiceProvider = Provider<SpeechService>((ref) {
  return SpeechService.instance;
});

class SpeechService {
  SpeechService._();

  static final SpeechService instance = SpeechService._();

  static const _sherpaExampleSnippet = '''
final config = OnlineRecognizerConfig(
  sampleRate: 16000,
  transducer: OnlineTransducerModelConfig(
    encoderFilename: modelDir + '/encoder.onnx',
    decoderFilename: modelDir + '/decoder.onnx',
    joinerFilename: modelDir + '/joiner.onnx',
  ),
  tokensFilename: modelDir + '/tokens.txt',
  hotwordsFile: modelDir + '/hotwords.txt',
  enableEndpoint: true,  // VAD
);

final recognizer = await OnlineRecognizer.fromConfig(config);
final stream = recognizer.createStream();
''';

  bool _initialized = false;
  bool _initializing = false;
  bool _isListening = false;

  final XunfeiSpeechService _xunfei = XunfeiSpeechService();
  _SpeechBackend _backend = _SpeechBackend.offlineSherpa;

  String? _lastInitError;
  String? _lastInitStage;

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  sherpa.VoiceActivityDetector? _vad;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _recordSub;

  final Queue<Uint8List> _audioQueue = Queue<Uint8List>();
  bool _audioLoopRunning = false;
  Future<void>? _audioLoopFuture;
  DateTime _lastPartialEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFinalEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

  String _lastPartial = '';
  String _lastFinal = '';

  bool _finalizeOnEndpoint = true;

  void Function(String text)? _onFinalResult;

  String? _xunfeiAppIdOrNull() {
    const v = String.fromEnvironment('XUNFEI_APP_ID', defaultValue: '');
    final s = v.trim();
    if (s.isNotEmpty) return s;
    final local = local_secrets.kXunfeiAppId.trim();
    return local.isEmpty ? null : local;
  }

  String? _xunfeiApiKeyOrNull() {
    const v = String.fromEnvironment('XUNFEI_API_KEY', defaultValue: '');
    final s = v.trim();
    if (s.isNotEmpty) return s;
    final local = local_secrets.kXunfeiApiKey.trim();
    return local.isEmpty ? null : local;
  }

  String? _xunfeiApiSecretOrNull() {
    const v = String.fromEnvironment('XUNFEI_API_SECRET', defaultValue: '');
    final s = v.trim();
    if (s.isNotEmpty) return s;
    final local = local_secrets.kXunfeiApiSecret.trim();
    return local.isEmpty ? null : local;
  }

  void _log(String message) {
    // ignore: avoid_print
    print('[SpeechService] $message');
  }

  bool get isListening => _isListening;
  bool get isReady => _initialized;
  String? get lastInitError => _lastInitError;
  String? get lastInitStage => _lastInitStage;

  void _setInitStage(String stage) {
    _lastInitStage = stage;
    _log('init: stage=$stage');
  }

  Future<String> _fileStat(String path) async {
    try {
      final f = File(path);
      final ok = await f.exists();
      if (!ok) return '${p.basename(path)}(missing)';
      final len = await f.length();
      return '${p.basename(path)}(${len}B)';
    } catch (e) {
      return '${p.basename(path)}(stat-failed:$e)';
    }
  }

  Future<String> _defaultModelDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'models', 'sherpa-zh-en');
  }

  Future<String?> _findBpeVocab(String modelDir) async {
    try {
      final root = Directory(modelDir);
      if (!await root.exists()) return null;
      File? best;
      int bestLen = -1;
      await for (final ent in root.list(recursive: true, followLinks: false)) {
        if (ent is! File) continue;
        final name = p.basename(ent.path).toLowerCase();
        if (!name.contains('bpe')) continue;
        if (!(name.endsWith('.vocab') || name.endsWith('.txt'))) continue;
        final len = await ent.length();
        if (len > bestLen) {
          best = ent;
          bestLen = len;
        }
      }
      return best?.path;
    } catch (_) {
      return null;
    }
  }

  sherpa.OnlineRecognizer _createRecognizerWithFallbacks({
    required sherpa.FeatureConfig feat,
    required String encoder,
    required String decoder,
    required String joiner,
    required String tokens,
    required String hotwords,
    required String? bpeVocab,
  }) {
    final attemptSummaries = <String>[];

    sherpa.OnlineRecognizer tryCreate({
      required String label,
      required bool enableEndpoint,
      required String hotwordsFile,
      required String modelType,
      required String modelingUnit,
      required String bpeVocabPath,
    }) {
      final decodingMethod =
          hotwordsFile.isNotEmpty ? 'modified_beam_search' : 'greedy_search';
      final config = sherpa.OnlineRecognizerConfig(
        feat: feat,
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
          ),
          tokens: tokens,
          numThreads: 2,
          provider: 'cpu',
          // Enable native debug printing; crucial on iOS for ORT load failures.
          debug: true,
          modelType: modelType,
          modelingUnit: modelingUnit,
          bpeVocab: bpeVocabPath,
        ),
        decodingMethod: decodingMethod,
        maxActivePaths: decodingMethod == 'modified_beam_search' ? 4 : 4,
        enableEndpoint: enableEndpoint,
        rule1MinTrailingSilence: 0.5,
        rule2MinTrailingSilence: 0.5,
        rule3MinUtteranceLength: 10,
        hotwordsFile: hotwordsFile,
        hotwordsScore: 2.5,
      );

      _log('init: createRecognizer attempt=$label '
          '(endpoint=$enableEndpoint, hotwords=${hotwordsFile.isNotEmpty}, '
          'modelType=${modelType.isEmpty ? "(empty)" : modelType}, '
          'modelingUnit=${modelingUnit.isEmpty ? "(empty)" : modelingUnit}, '
          'bpeVocab=${bpeVocabPath.isEmpty ? "(empty)" : p.basename(bpeVocabPath)}, '
          'decodingMethod=$decodingMethod)');
      return sherpa.OnlineRecognizer(config);
    }

    final bpe = bpeVocab ?? '';

    // 1) Most likely config
    final variants = <Map<String, dynamic>>[
      {
        'label': 'A-default',
        'endpoint': true,
        'hotwords': hotwords,
        'modelType': '',
        'unit': '',
        'bpe': '',
      },
      // 2) Hotwords parsing can fail on some builds; retry without it.
      {
        'label': 'B-no-hotwords',
        'endpoint': true,
        'hotwords': '',
        'modelType': '',
        'unit': '',
        'bpe': '',
      },
      // 3) Endpointing off (in case endpoint rules interact oddly).
      {
        'label': 'C-no-endpoint',
        'endpoint': false,
        'hotwords': '',
        'modelType': '',
        'unit': '',
        'bpe': '',
      },
    ];

    // 4) If bpe vocab exists, try enabling modelingUnit=bpe.
    if (bpe.isNotEmpty) {
      variants.addAll([
        {
          'label': 'D-bpe',
          'endpoint': true,
          'hotwords': hotwords,
          'modelType': '',
          'unit': 'bpe',
          'bpe': bpe,
        },
        {
          'label': 'E-bpe-no-hotwords',
          'endpoint': true,
          'hotwords': '',
          'modelType': '',
          'unit': 'bpe',
          'bpe': bpe,
        },
      ]);
    }

    // 5) Some native builds gate behavior by modelType.
    // Try a minimal set of common values.
    const modelTypes = ['zipformer', 'zipformer2'];
    for (final t in modelTypes) {
      variants.add({
        'label': 'T-$t',
        'endpoint': true,
        'hotwords': '',
        'modelType': t,
        'unit': bpe.isNotEmpty ? 'bpe' : '',
        'bpe': bpe.isNotEmpty ? bpe : '',
      });
    }

    Exception? last;
    for (final v in variants) {
      try {
        return tryCreate(
          label: v['label'] as String,
          enableEndpoint: v['endpoint'] as bool,
          hotwordsFile: v['hotwords'] as String,
          modelType: v['modelType'] as String,
          modelingUnit: v['unit'] as String,
          bpeVocabPath: v['bpe'] as String,
        );
      } catch (e) {
        final msg = e.toString();
        attemptSummaries.add('${v['label']}:$msg');
        last = e is Exception ? e : Exception(msg);
      }
    }

    throw Exception(
      'Failed to create online recognizer. Attempts: ${attemptSummaries.join(' | ')}'
      '${last == null ? '' : '\nLast: $last'}',
    );
  }

  Future<bool> init({
    void Function(double progress)? onDownloadProgress,
    bool requireMicPermission = false,
  }) async {
    if (_initialized) return true;
    if (_initializing) {
      while (_initializing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _initialized;
    }

    _initializing = true;
    try {
      _lastInitError = null;
      _lastInitStage = null;
      final sw = Stopwatch()..start();

      if (requireMicPermission) {
        _setInitStage('permission');
        _log('init: requesting microphone permission...');
        final micStatus = await Permission.microphone.request();
        if (!micStatus.isGranted) {
          _log('init: microphone permission denied');
          _lastInitError = 'init阶段[permission]失败：麦克风权限未授权';
          return false;
        }
      }

      final modelDir = await _defaultModelDir();
      _log(
          'init: os=${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      _log('init: modelDir=$modelDir');

      _setInitStage('ensureModel');
      _log('init: ensureModel in $modelDir');
      await ModelDownloader.ensureModel(
        modelDir,
        onProgress: onDownloadProgress,
      );

      final encoder = p.join(modelDir, 'encoder.onnx');
      final decoder = p.join(modelDir, 'decoder.onnx');
      final joiner = p.join(modelDir, 'joiner.onnx');
      final tokens = p.join(modelDir, 'tokens.txt');
      final hotwords = p.join(modelDir, 'hotwords.txt');
      final vadModel = p.join(modelDir, 'silero_vad.onnx');

      final bpeVocab = await _findBpeVocab(modelDir);
      if (bpeVocab != null) {
        _log('init: found bpe vocab candidate: ${p.basename(bpeVocab)}');
      }

      _setInitStage('verifyFiles');
      _log('init: verify required files...');
      _log('init: fileStats: '
          '${await _fileStat(encoder)}, '
          '${await _fileStat(decoder)}, '
          '${await _fileStat(joiner)}, '
          '${await _fileStat(tokens)}, '
          '${await _fileStat(hotwords)}, '
          '${await _fileStat(vadModel)}');

      final missing = <String>[];
      for (final f in [encoder, decoder, joiner, tokens]) {
        if (!await File(f).exists()) missing.add(p.basename(f));
      }
      if (missing.isNotEmpty) {
        _lastInitError = 'init阶段[verifyFiles]失败：模型文件缺失：${missing.join(', ')}';
        _log('init: missing files: ${missing.join(', ')}');
        return false;
      }

      // Guard against partial/zero-sized files that can happen if extraction was interrupted.
      final tooSmall = <String>[];
      for (final f in [encoder, decoder, joiner, tokens]) {
        final len = await File(f).length();
        if (len < 1024) tooSmall.add('${p.basename(f)}(${len}B)');
      }
      if (tooSmall.isNotEmpty) {
        _lastInitError =
            'init阶段[verifyFiles]失败：模型文件疑似不完整：${tooSmall.join(', ')}';
        _log('init: suspicious small files: ${tooSmall.join(', ')}');
        return false;
      }

      _setInitStage('initBindings');
      _log('init: initBindings()');
      _log(
          'init: sherpa example snippet loaded (${_sherpaExampleSnippet.length} chars)');
      sherpa.initBindings();

      _setInitStage('createRecognizer');
      _log('init: create OnlineRecognizer');
      _recognizer?.free();
      _recognizer = _createRecognizerWithFallbacks(
        feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
        encoder: encoder,
        decoder: decoder,
        joiner: joiner,
        tokens: tokens,
        hotwords: hotwords,
        bpeVocab: bpeVocab,
      );

      _setInitStage('createVad');
      _log('init: create Silero VAD');
      _vad?.free();
      _vad = null;
      try {
        final hasVad = await File(vadModel).exists();
        if (!hasVad) {
          _log('init: silero_vad.onnx missing -> fallback to endpoint rules');
        } else {
          _vad = sherpa.VoiceActivityDetector(
            config: sherpa.VadModelConfig(
              sampleRate: 16000,
              numThreads: 1,
              provider: 'cpu',
              debug: false,
              sileroVad: sherpa.SileroVadModelConfig(
                model: vadModel,
                threshold: 0.5,
                minSilenceDuration: 0.5,
                minSpeechDuration: 0.2,
                windowSize: 512,
                maxSpeechDuration: 10.0,
              ),
            ),
            bufferSizeInSeconds: 30,
          );
        }
      } catch (e) {
        _log('init: VAD init failed: $e -> fallback to endpoint rules');
        _vad = null;
      }

      _initialized = true;
      sw.stop();
      _log('init: done in ${sw.elapsedMilliseconds}ms');
      return true;
    } catch (e, st) {
      final stage = _lastInitStage ?? 'unknown';
      _lastInitError = 'init阶段[$stage]失败：$e';
      _log('init: failed at stage=$stage: $e');
      _log('init: stack: $st');
      return false;
    } finally {
      _initializing = false;
    }
  }

  Future<bool> startListening({
    required void Function(String partial) onPartialResult,
    required void Function(String text) onFinalResult,
    void Function(double progress)? onDownloadProgress,
    bool finalizeOnEndpoint = true,
    bool preferOnline = false,
  }) async {
    if (_isListening) return true;

    // Prefer Xunfei online STT when requested and credentials are present.
    // Any failure (no network / auth / ws) falls back to offline sherpa.
    if (preferOnline) {
      _log('startListening: preferOnline=true, trying xunfei');
      final appId = _xunfeiAppIdOrNull();
      final apiKey = _xunfeiApiKeyOrNull();
      final apiSecret = _xunfeiApiSecretOrNull();
      if (appId != null && apiKey != null && apiSecret != null) {
        try {
          _xunfei.configure(appId: appId, apiKey: apiKey, apiSecret: apiSecret);
          final okOnline = await _xunfei.startListening(
            onPartialResult: onPartialResult,
            onFinalResult: onFinalResult,
          );
          if (okOnline) {
            _log('startListening: using xunfei backend');
            _backend = _SpeechBackend.xunfei;
            _isListening = true;
            _onFinalResult = onFinalResult;
            return true;
          }
        } catch (e) {
          _log('xunfei start failed, fallback offline: $e');
        }
      } else {
        _log('startListening: preferOnline requested but xunfei creds missing');
      }
    }

    final ok = await init(
      onDownloadProgress: onDownloadProgress,
      requireMicPermission: true,
    );
    if (!ok) return false;
    if (_recognizer == null) return false;

    _lastPartial = '';
    _lastFinal = '';

    _onFinalResult = onFinalResult;
    _finalizeOnEndpoint = finalizeOnEndpoint;

    _isListening = true;
    _backend = _SpeechBackend.offlineSherpa;
    _stream?.free();
    _stream = _recognizer!.createStream();
    _recognizer!.reset(_stream!);
    _vad?.reset();
    _vad?.clear();

    _audioQueue.clear();
    _lastPartialEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastFinalEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    _startAudioLoop(
      onPartialResult: onPartialResult,
      onFinalResult: onFinalResult,
    );

    _recorder ??= AudioRecorder();
    final recorder = _recorder!;

    if (!await recorder.hasPermission()) {
      _log('startListening: recorder permission denied');
      _isListening = false;
      return false;
    }

    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
    );

    _recordSub?.cancel();
    _recordSub = stream.listen(
      (chunk) {
        if (!_isListening) return;
        // Keep callback lightweight; enqueue for async processing.
        _enqueueAudioChunk(chunk);
      },
      onError: (e) {
        _log('record stream error: $e');
        // If the recorder stream fails while user is still holding, stop cleanly
        // so UI can recover and we can still finalize any partial ASR.
        if (_isListening) {
          unawaited(stopListening());
        }
      },
      onDone: () {
        _log('record stream done');
        if (_isListening) {
          unawaited(stopListening());
        }
      },
      cancelOnError: true,
    );

    return true;
  }

  Future<void> stopListening({
    void Function(String text)? onFinalResult,
  }) async {
    if (!_isListening) return;

    if (_backend == _SpeechBackend.xunfei) {
      try {
        await _xunfei.stopListening(
            onFinalResult: onFinalResult ?? _onFinalResult);
      } finally {
        _isListening = false;
        _onFinalResult = null;
        _backend = _SpeechBackend.offlineSherpa;
      }
      return;
    }
    _isListening = false;

    // Stop processing loop quickly.
    _audioQueue.clear();
    _audioLoopRunning = false;

    try {
      await _recordSub?.cancel();
      _recordSub = null;
    } catch (_) {
      // ignore
    }

    try {
      await _recorder?.stop();
    } catch (_) {
      // ignore
    }

    // Ensure the audio loop has fully stopped before freeing native resources.
    final loop = _audioLoopFuture;
    if (loop != null) {
      try {
        await loop.timeout(const Duration(milliseconds: 800));
      } catch (e) {
        _log('stopListening: audio loop wait timeout/error: $e');
      }
    }

    final recognizer = _recognizer;
    final s = _stream;
    if (recognizer != null && s != null) {
      try {
        s.inputFinished();
        while (recognizer.isReady(s)) {
          recognizer.decode(s);
        }
        final r = recognizer.getResult(s);
        final text = r.text.trim();
        if (text.isNotEmpty && text != _lastFinal) {
          _lastFinal = text;
          final cb = onFinalResult ?? _onFinalResult;
          cb?.call(text);
        }
      } catch (e) {
        _log('stopListening finalize error: $e');
      } finally {
        try {
          s.free();
        } catch (_) {
          // ignore
        }
        _stream = null;
      }
    }

    _onFinalResult = null;
  }

  Future<void> cancel() async {
    if (!_isListening) return;
    if (_backend == _SpeechBackend.xunfei) {
      try {
        await _xunfei.cancel();
      } finally {
        _isListening = false;
        _onFinalResult = null;
        _backend = _SpeechBackend.offlineSherpa;
      }
      return;
    }

    _isListening = false;
    _audioQueue.clear();
    _audioLoopRunning = false;
    try {
      await _recordSub?.cancel();
      _recordSub = null;
    } catch (_) {
      // ignore
    }
    try {
      await _recorder?.cancel();
    } catch (_) {
      // ignore
    }

    final loop = _audioLoopFuture;
    if (loop != null) {
      try {
        await loop.timeout(const Duration(milliseconds: 800));
      } catch (_) {
        // ignore
      }
    }
    try {
      _stream?.free();
    } catch (_) {
      // ignore
    }
    _stream = null;

    _onFinalResult = null;
  }

  void _enqueueAudioChunk(Uint8List chunk) {
    // Bound queue to avoid memory growth if processing lags.
    const maxQueued = 50;
    if (_audioQueue.length >= maxQueued) {
      _audioQueue.removeFirst();
    }
    _audioQueue.add(chunk);
  }

  void _startAudioLoop({
    required void Function(String partial) onPartialResult,
    required void Function(String text) onFinalResult,
  }) {
    if (_audioLoopRunning) return;
    _audioLoopRunning = true;
    _audioLoopFuture = _audioProcessingLoop(
      onPartialResult: onPartialResult,
      onFinalResult: onFinalResult,
    );
  }

  Future<void> _audioProcessingLoop({
    required void Function(String partial) onPartialResult,
    required void Function(String text) onFinalResult,
  }) async {
    // Run on main isolate but yield frequently so UI stays responsive.
    while (_audioLoopRunning) {
      if (!_isListening) break;

      if (_audioQueue.isEmpty) {
        // No pending audio; yield.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        continue;
      }

      final chunk = _audioQueue.removeFirst();
      try {
        _handleAudioChunkQueued(
          chunk,
          onPartialResult: onPartialResult,
          onFinalResult: onFinalResult,
        );
      } catch (e) {
        _log('audio loop chunk error: $e');
      }

      // Yield every chunk.
      await Future<void>.delayed(Duration.zero);
    }

    _audioLoopRunning = false;
    _audioLoopFuture = null;
  }

  void _handleAudioChunkQueued(
    Uint8List chunk, {
    required void Function(String partial) onPartialResult,
    required void Function(String text) onFinalResult,
  }) {
    final recognizer = _recognizer;
    final vad = _vad;
    final stream = _stream;
    if (recognizer == null || stream == null) return;

    final floatSamples = _pcm16BytesToFloat32(chunk);
    if (floatSamples.isEmpty) return;

    // Throttle partial updates to reduce UI churn.
    final now = DateTime.now();
    final canEmitPartial =
        now.difference(_lastPartialEmitAt).inMilliseconds >= 120;
    final canEmitFinal = now.difference(_lastFinalEmitAt).inMilliseconds >= 250;

    void maybeEmitPartial() {
      if (!canEmitPartial) return;
      final r = recognizer.getResult(stream);
      final partial = r.text.trim();
      if (partial.isNotEmpty && partial != _lastPartial) {
        _lastPartial = partial;
        _lastPartialEmitAt = DateTime.now();
        onPartialResult(partial);
      }
    }

    void maybeEmitFinalAndReset() {
      if (!canEmitFinal) return;
      final r = recognizer.getResult(stream);
      final finalText = r.text.trim();
      if (finalText.isNotEmpty && finalText != _lastFinal) {
        _lastFinal = finalText;
        _lastFinalEmitAt = DateTime.now();
        onFinalResult(finalText);
      }
      recognizer.reset(stream);
    }

    // Always feed streaming audio to the recognizer so partial results work.
    stream.acceptWaveform(samples: floatSamples, sampleRate: 16000);

    // Don't spin too long in one tick.
    for (var i = 0; i < 2 && recognizer.isReady(stream); i++) {
      recognizer.decode(stream);
    }
    maybeEmitPartial();

    if (_finalizeOnEndpoint) {
      // Endpointing: if Silero VAD is available, use it as an additional
      // end-of-utterance trigger (without feeding its segmented audio, to avoid
      // double-feeding).
      if (vad != null) {
        vad.acceptWaveform(floatSamples);
        if (vad.isDetected()) {
          maybeEmitFinalAndReset();
          vad.reset();
          vad.clear();
          return;
        }
      }

      if (recognizer.isEndpoint(stream)) {
        maybeEmitFinalAndReset();
        vad?.reset();
        vad?.clear();
      }
    }
  }

  Float32List _pcm16BytesToFloat32(Uint8List bytes) {
    if (bytes.isEmpty) return Float32List(0);
    final bd = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little);
      out[i] = v / 32768.0;
    }
    return out;
  }
}

enum _SpeechBackend {
  offlineSherpa,
  xunfei,
}

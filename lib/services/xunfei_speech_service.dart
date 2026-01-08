import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';

class XunfeiSpeechService {
  static const _host = 'iat-api.xfyun.cn';
  static const _path = '/v2/iat';

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordSub;
  IOWebSocketChannel? _channel;

  bool _isListening = false;
  bool get isListening => _isListening;

  String? _appId;
  String? _apiKey;
  String? _apiSecret;

  void configure({
    required String appId,
    required String apiKey,
    required String apiSecret,
  }) {
    _appId = appId.trim();
    _apiKey = apiKey.trim();
    _apiSecret = apiSecret.trim();
  }

  bool get _hasCreds {
    final a = _appId;
    final k = _apiKey;
    final s = _apiSecret;
    return a != null &&
        a.isNotEmpty &&
        k != null &&
        k.isNotEmpty &&
        s != null &&
        s.isNotEmpty;
  }

  Uri _buildAuthUrl() {
    final apiKey = _apiKey!;
    final apiSecret = _apiSecret!;

    final date = HttpDate.format(DateTime.now().toUtc());
    final signatureOrigin = 'host: $_host\n'
        'date: $date\n'
        'GET $_path HTTP/1.1';

    final hmacSha256 = Hmac(sha256, utf8.encode(apiSecret));
    final signatureSha = hmacSha256.convert(utf8.encode(signatureOrigin));
    final signature = base64.encode(signatureSha.bytes);

    final authorizationOrigin =
        'api_key="$apiKey", algorithm="hmac-sha256", headers="host date request-line", signature="$signature"';
    final authorization = base64.encode(utf8.encode(authorizationOrigin));

    return Uri.parse('wss://$_host$_path').replace(queryParameters: {
      'authorization': authorization,
      'date': date,
      'host': _host,
    });
  }

  Future<bool> startListening({
    required void Function(String partial) onPartialResult,
    required void Function(String text) onFinalResult,
  }) async {
    if (_isListening) return true;
    if (!_hasCreds) return false;

    if (!await _recorder.hasPermission()) {
      return false;
    }

    _isListening = true;

    // Connect websocket first.
    final uri = _buildAuthUrl();
    try {
      _channel = IOWebSocketChannel.connect(uri,
          pingInterval: const Duration(seconds: 10));
    } catch (_) {
      _isListening = false;
      return false;
    }

    final channel = _channel!;
    final appId = _appId!;

    final completer = Completer<bool>();
    final Map<int, String> segmentsBySn = <int, String>{};
    String lastEmittedPartial = '';
    bool gotFinal = false;

    String buildText() {
      if (segmentsBySn.isEmpty) return '';
      final keys = segmentsBySn.keys.toList()..sort();
      final sb = StringBuffer();
      for (final k in keys) {
        final s = segmentsBySn[k];
        if (s == null || s.isEmpty) continue;
        sb.write(s);
      }
      return sb.toString();
    }

    late final StreamSubscription sub;
    sub = channel.stream.listen(
      (event) {
        try {
          final obj = jsonDecode(event.toString()) as Map<String, dynamic>;
          final code = obj['code'] as int? ?? -1;
          if (code != 0) {
            final msg =
                (obj['message'] ?? obj['desc'] ?? 'xunfei error').toString();
            if (!completer.isCompleted) completer.complete(false);
            throw StateError('讯飞识别失败：$code $msg');
          }

          final data = obj['data'] as Map<String, dynamic>?;
          final result = data?['result'] as Map<String, dynamic>?;
          final status = data?['status'] as int?;
          if (result != null) {
            final sn = (result['sn'] is int) ? result['sn'] as int : null;
            final pgs = result['pgs']?.toString();
            final rg = result['rg'];

            final ws = result['ws'];
            if (ws is List) {
              final sb = StringBuffer();
              for (final w in ws) {
                if (w is! Map) continue;
                final cw = w['cw'];
                if (cw is List && cw.isNotEmpty) {
                  final first = cw.first;
                  if (first is Map && first['w'] != null) {
                    sb.write(first['w'].toString());
                  }
                }
              }
              final text = sb.toString().trim();
              if (text.isNotEmpty) {
                if (sn != null) {
                  // With `dwa=wpgs`, Xunfei may send corrections (pgs=rpl) with a replace range (rg).
                  if (pgs == 'rpl' && rg is List && rg.length == 2) {
                    final a = (rg[0] is int) ? rg[0] as int : null;
                    final b = (rg[1] is int) ? rg[1] as int : null;
                    if (a != null && b != null) {
                      for (int i = a; i <= b; i++) {
                        if (i == sn) continue;
                        segmentsBySn.remove(i);
                      }
                    }
                  }
                  segmentsBySn[sn] = text;
                } else {
                  // Fallback when sn is missing: append as best-effort.
                  final k = segmentsBySn.isEmpty
                      ? 0
                      : (segmentsBySn.keys.reduce((x, y) => x > y ? x : y) + 1);
                  segmentsBySn[k] = text;
                }

                final assembled = buildText();
                if (assembled.isNotEmpty && assembled != lastEmittedPartial) {
                  lastEmittedPartial = assembled;
                  onPartialResult(assembled);
                }
              }
            }
          }

          if (status == 2 && !gotFinal) {
            gotFinal = true;
            final finalText = buildText().trim();
            if (finalText.isNotEmpty) {
              onFinalResult(finalText);
            }
            if (!completer.isCompleted) completer.complete(true);
          }
        } catch (_) {
          // ignore parse errors here; failures will surface through stop.
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(false);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(gotFinal);
      },
      cancelOnError: true,
    );

    // Start recording stream.
    final audioStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
    );

    int frameStatus = 0;
    _recordSub?.cancel();
    _recordSub = audioStream.listen(
      (chunk) {
        if (!_isListening) return;
        final payload = {
          'common': {'app_id': appId},
          'business': {
            'language': 'zh_cn',
            'domain': 'iat',
            'accent': 'mandarin',
            'vad_eos': 2000,
            'dwa': 'wpgs',
          },
          'data': {
            'status': frameStatus,
            'format': 'audio/L16;rate=16000',
            'encoding': 'raw',
            'audio': base64.encode(chunk),
          },
        };
        channel.sink.add(jsonEncode(payload));
        if (frameStatus == 0) frameStatus = 1;
      },
      onError: (_) async {
        await stopListening(onFinalResult: onFinalResult);
      },
      onDone: () async {
        await stopListening(onFinalResult: onFinalResult);
      },
      cancelOnError: true,
    );

    // If we never get any response soon, still consider it started.
    // The facade will fallback if needed.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 800)).then((_) {
      if (!completer.isCompleted) completer.complete(true);
    }));

    final ok = await completer.future;
    if (!ok) {
      await sub.cancel();
    }
    return ok;
  }

  Future<void> stopListening({
    void Function(String text)? onFinalResult,
  }) async {
    if (!_isListening) return;
    _isListening = false;

    try {
      await _recordSub?.cancel();
      _recordSub = null;
    } catch (_) {}

    try {
      await _recorder.stop();
    } catch (_) {}

    final channel = _channel;
    if (channel != null) {
      try {
        // Send last frame.
        final payload = {
          'data': {
            'status': 2,
            'format': 'audio/L16;rate=16000',
            'encoding': 'raw',
            'audio': '',
          }
        };
        channel.sink.add(jsonEncode(payload));
      } catch (_) {}
      try {
        // Give the server a short time to return the final status=2 result.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await channel.sink.close();
      } catch (_) {}
    }
    _channel = null;
  }

  Future<void> cancel() async {
    if (!_isListening) return;
    _isListening = false;
    try {
      await _recordSub?.cancel();
      _recordSub = null;
    } catch (_) {}
    try {
      await _recorder.cancel();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }
}

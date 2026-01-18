import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final insta360OscServiceProvider = Provider<Insta360OscService>((ref) {
  return Insta360OscService();
});

class Insta360OscInfo {
  final int? httpPort;
  final String? manufacturer;
  final String? model;
  final String? firmwareVersion;

  const Insta360OscInfo({
    required this.httpPort,
    required this.manufacturer,
    required this.model,
    required this.firmwareVersion,
  });

  static Insta360OscInfo fromJson(Map<String, dynamic> json) {
    final endpoints = json['endpoints'];
    int? httpPort;
    if (endpoints is Map) {
      final v = endpoints['httpPort'];
      if (v is num) httpPort = v.toInt();
    }

    return Insta360OscInfo(
      httpPort: httpPort,
      manufacturer: json['manufacturer']?.toString(),
      model: json['model']?.toString(),
      firmwareVersion: json['firmwareVersion']?.toString(),
    );
  }
}

class Insta360OscService {
  final Dio _dio;

  Insta360OscService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 10),
              ),
            );

  Map<String, String> get _xsrfHeaders => const {
        'Content-Type': 'application/json; charset=utf-8',
        'X-XSRF-Protected': '1',
        'Accept': 'application/json',
        'Connection': 'close',
      };

  bool _isOk(int? code) => code != null && code >= 200 && code < 300;

  Never _throwBadHttp(String where, Response resp) {
    final code = resp.statusCode;
    final data = resp.data;
    throw StateError('OSC $where 失败：HTTP $code\n$data');
  }

  bool _looksLikeConnectionDrop(Object e) {
    if (e is DioException) {
      final m = '${e.error ?? ''} ${e.message ?? ''}'.toLowerCase();
      return m.contains('connection closed') ||
          m.contains('socket') ||
          m.contains('broken pipe') ||
          m.contains('connection reset') ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown;
    }
    final m = e.toString().toLowerCase();
    return m.contains('connection closed') ||
        m.contains('connection reset') ||
        m.contains('socket');
  }

  Future<T> _withRetry<T>(Future<T> Function() run) async {
    const maxAttempts = 2;
    Object? last;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await run();
      } catch (e) {
        last = e;
        if (attempt == maxAttempts || !_looksLikeConnectionDrop(e)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    // Should be unreachable.
    throw StateError('unexpected retry state: $last');
  }

  Uri _parseBaseUri(String baseUrl) {
    final raw = baseUrl.trim();
    if (raw.isEmpty) {
      throw ArgumentError('baseUrl 不能为空');
    }
    final normalized = raw.startsWith('http://') || raw.startsWith('https://')
        ? raw
        : 'http://$raw';
    final uri = Uri.parse(normalized);
    if (uri.host.isEmpty) {
      throw ArgumentError('baseUrl 无效：$baseUrl');
    }
    return uri;
  }

  Uri _withPort(Uri base, int? httpPort) {
    if (httpPort == null || httpPort <= 0) return base;
    if (base.port == httpPort) return base;
    return base.replace(port: httpPort);
  }

  Future<Insta360OscInfo> getInfo({
    required String baseUrl,
    CancelToken? cancelToken,
  }) async {
    final base = _parseBaseUri(baseUrl);
    final url = base.replace(path: '/osc/info');
    final resp = await _withRetry(
      () => _dio.get(
        url.toString(),
        cancelToken: cancelToken,
        options: Options(
          headers: _xsrfHeaders,
          validateStatus: (_) => true,
        ),
      ),
    );

    if (!_isOk(resp.statusCode)) {
      _throwBadHttp('/osc/info', resp);
    }

    final data = _asJsonMap(resp.data);
    return Insta360OscInfo.fromJson(data);
  }

  /// Executes OSC command.
  Future<Map<String, dynamic>> _execute(
    Uri base,
    String name, {
    Map<String, dynamic>? parameters,
    CancelToken? cancelToken,
  }) async {
    final url = base.replace(path: '/osc/commands/execute');
    final body = <String, dynamic>{'name': name};
    if (parameters != null) body['parameters'] = parameters;
    final resp = await _withRetry(
      () => _dio.post(
        url.toString(),
        data: body,
        cancelToken: cancelToken,
        options: Options(
          headers: _xsrfHeaders,
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      ),
    );

    final map = _tryAsJsonMap(resp.data);
    if (_isOk(resp.statusCode)) {
      return map ?? _asJsonMap(resp.data);
    }
    // Many OSC implementations return HTTP 400 with a JSON body including
    // {state:error, error:{code,message}}. Preserve it for caller handling.
    if (map != null && map['state'] != null) return map;
    _throwBadHttp('/osc/commands/execute', resp);
  }

  Future<Map<String, dynamic>> _commandStatus(
    Uri base,
    String id, {
    CancelToken? cancelToken,
  }) async {
    final url = base.replace(path: '/osc/commands/status');
    final resp = await _withRetry(
      () => _dio.post(
        url.toString(),
        data: {'id': id},
        cancelToken: cancelToken,
        options: Options(
          headers: _xsrfHeaders,
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      ),
    );
    if (!_isOk(resp.statusCode)) {
      _throwBadHttp('/osc/commands/status', resp);
    }
    return _asJsonMap(resp.data);
  }

  /// Minimal end-to-end: take picture then download bytes.
  ///
  /// This follows the OSC (HTTP) pattern used by 360 cameras.
  Future<Uint8List> takePictureAndDownload({
    required String baseUrl,
    CancelToken? cancelToken,
  }) async {
    final base = _parseBaseUri(baseUrl);
    final info = await getInfo(baseUrl: baseUrl, cancelToken: cancelToken);
    final httpBase = _withPort(base, info.httpPort);

    final fileUri = await _takePictureAndGetFileUri(
      httpBase,
      cancelToken: cancelToken,
    );
    return await downloadFile(
      baseUrl: httpBase.toString(),
      fileUri: fileUri,
      cancelToken: cancelToken,
    );
  }

  Future<String> _takePictureAndGetFileUri(
    Uri base, {
    Duration timeout = const Duration(seconds: 40),
    CancelToken? cancelToken,
  }) async {
    final first = await _execute(
      base,
      'camera.takePicture',
      cancelToken: cancelToken,
    );

    if (_isDisabledBecauseNotImageMode(first)) {
      // Try to switch to image mode and retry once.
      await _ensureImageMode(base, cancelToken: cancelToken);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final second = await _execute(
        base,
        'camera.takePicture',
        cancelToken: cancelToken,
      );
      return await _finishTakePicture(base, second,
          timeout: timeout, cancelToken: cancelToken);
    }

    return await _finishTakePicture(base, first,
        timeout: timeout, cancelToken: cancelToken);
  }

  Future<String> _finishTakePicture(
    Uri base,
    Map<String, dynamic> first, {
    required Duration timeout,
    CancelToken? cancelToken,
  }) async {
    final state = first['state']?.toString();
    if (state == 'done') {
      final uri = _extractFileUri(first);
      if (uri != null) return uri;
      throw StateError('拍照成功但未返回 fileUri');
    }

    if (state == 'error') {
      throw StateError('相机执行失败：${first['error'] ?? first}');
    }

    final id = first['id']?.toString();
    if (id == null || id.isEmpty) {
      throw StateError('相机返回 inProgress 但缺少命令 id');
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      final st = await _commandStatus(base, id, cancelToken: cancelToken);
      final s = st['state']?.toString();
      if (s == 'done') {
        final uri = _extractFileUri(st);
        if (uri != null) return uri;
        throw StateError('拍照完成但未返回 fileUri');
      }
      if (s == 'error') {
        throw StateError('相机执行失败：${st['error'] ?? st}');
      }
    }

    throw TimeoutException('拍照超时（${timeout.inSeconds}s）');
  }

  bool _isDisabledBecauseNotImageMode(Map<String, dynamic> json) {
    final state = json['state']?.toString();
    if (state != 'error') return false;
    final err = json['error'];
    if (err is! Map) return false;
    final code = err['code']?.toString() ?? '';
    final msg = err['message']?.toString().toLowerCase() ?? '';
    if (code != 'disabledCommand') return false;
    return msg.contains('not working in image mode') ||
        msg.contains('image mode');
  }

  Future<void> _ensureImageMode(Uri base, {CancelToken? cancelToken}) async {
    // OSC standard option key is captureMode.
    // Many cameras accept {options:{captureMode:"image"}}.
    final r = await _execute(
      base,
      'camera.setOptions',
      parameters: {
        'options': {
          'captureMode': 'image',
        },
      },
      cancelToken: cancelToken,
    );

    final s = r['state']?.toString();
    if (s == 'error') {
      // Don't hard-fail; some firmwares don't expose captureMode. Caller will
      // still get the original error on retry.
      return;
    }
  }

  Future<Uint8List> downloadFile({
    required String baseUrl,
    required String fileUri,
    CancelToken? cancelToken,
  }) async {
    final base = _parseBaseUri(baseUrl);
    final target = _resolveFileUri(base, fileUri);

    final resp = await _withRetry(
      () => _dio.get<List<int>>(
        target.toString(),
        cancelToken: cancelToken,
        options: Options(
          headers: const {
            'X-XSRF-Protected': '1',
            'Connection': 'close',
          },
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      ),
    );

    if (!_isOk(resp.statusCode)) {
      _throwBadHttp('download', resp);
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('下载失败：返回为空');
    }
    return Uint8List.fromList(bytes);
  }

  Uri _resolveFileUri(Uri base, String fileUri) {
    final u = fileUri.trim();
    if (u.isEmpty) throw ArgumentError('fileUri 为空');
    if (u.startsWith('http://') || u.startsWith('https://')) {
      return Uri.parse(u);
    }
    // OSC results may return relative paths.
    return base.resolve(u);
  }

  String? _extractFileUri(Map<String, dynamic> json) {
    final results = json['results'];
    if (results is Map) {
      final m = results.cast<String, dynamic>();
      for (final key in const ['fileUri', 'fileUrl', 'fileURL', 'uri', 'url']) {
        final v = m[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    }
    return null;
  }

  Map<String, dynamic> _asJsonMap(dynamic data) {
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    }
    if (data is List<int>) {
      final s = utf8.decode(data, allowMalformed: true);
      final decoded = jsonDecode(s);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    }
    throw StateError('OSC 响应不是 JSON 对象');
  }

  Map<String, dynamic>? _tryAsJsonMap(dynamic data) {
    try {
      return _asJsonMap(data);
    } catch (_) {
      return null;
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/acceptance_record.dart';
import '../models/backend_records.dart';
import '../models/library.dart';
import '../models/target.dart';
import '../services/online_vision_service.dart';

final backendApiServiceProvider = Provider<BackendApiService>((ref) {
  return BackendApiService();
});

class BackendApiService {
  late final Dio _dio;

  static const _prefsKeyBaseUrl = 'backend_base_url';

  BackendApiService() {
    _dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl(),
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 8),
        headers: {
          'Content-Type': 'application/json',
        },
      ),
    );
  }

  static String _normalizeBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return 'http://127.0.0.1:8000';

    // Remove trailing slash.
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }

    // Users sometimes paste a baseUrl like "http://x:8000/v1".
    // Our endpoints already include "/v1/...", so normalize it away.
    if (s.toLowerCase().endsWith('/v1')) {
      s = s.substring(0, s.length - 3);
      while (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
    }

    return s.isEmpty ? 'http://127.0.0.1:8000' : s;
  }

  static Future<String?> getBaseUrlOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefsKeyBaseUrl);
      final s = v?.trim();
      return (s == null || s.isEmpty) ? null : s;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setBaseUrlOverride(String? value) async {
    final v = value?.trim();
    final prefs = await SharedPreferences.getInstance();
    if (v == null || v.isEmpty) {
      await prefs.remove(_prefsKeyBaseUrl);
    } else {
      await prefs.setString(_prefsKeyBaseUrl, _normalizeBaseUrl(v));
    }
  }

  static Future<String> getEffectiveBaseUrl() async {
    final override = await getBaseUrlOverride();
    if (override != null) return _normalizeBaseUrl(override);
    const v = String.fromEnvironment(
      'BACKEND_BASE_URL',
      defaultValue: 'http://127.0.0.1:8000',
    );
    return _normalizeBaseUrl(v);
  }

  Future<void> _refreshRuntimeBaseUrl() async {
    final effective = await getEffectiveBaseUrl();
    if (_dio.options.baseUrl != effective) {
      _dio.options.baseUrl = effective;
    }
  }

  Future<String?> _uploadPhotoIfNeeded(String? path) async {
    final p = (path ?? '').trim();
    if (p.isEmpty) return null;

    String? uploadsPathFromRef(String s) {
      final v = s.trim();
      if (v.isEmpty) return null;
      if (v.startsWith('/uploads/')) return v;
      if (v.startsWith('uploads/')) return '/$v';
      if (v.startsWith('http://') || v.startsWith('https://')) {
        try {
          final uri = Uri.parse(v);
          if (uri.path.startsWith('/uploads/')) return uri.path;
        } catch (_) {
          return null;
        }
      }
      return null;
    }

    // If this is already an uploaded photo URL, normalize to a stable relative path.
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return uploadsPathFromRef(p) ?? p;
    }

    final file = File(p);
    if (!file.existsSync()) {
      // Keep original so current-device preview can still work.
      return p;
    }

    try {
      await _refreshRuntimeBaseUrl();
      final filename =
          p.split('/').isNotEmpty ? p.split('/').last : 'photo.jpg';
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(p, filename: filename),
      });
      final resp = await _dio.post('/v1/uploads/photo', data: form);
      final data = resp.data;
      if (data is Map) {
        final rawPath = data['path']?.toString().trim();
        if (rawPath != null && rawPath.isNotEmpty) {
          return uploadsPathFromRef(rawPath) ?? rawPath;
        }
        final rawUrl = data['url']?.toString().trim();
        if (rawUrl != null && rawUrl.isNotEmpty) {
          return uploadsPathFromRef(rawUrl) ?? rawUrl;
        }
      }
      return p;
    } catch (_) {
      return p;
    }
  }

  Future<List<String>> _uploadPhotosIfNeeded(List<String> paths) async {
    final out = <String>[];
    for (final p in paths) {
      final u = await _uploadPhotoIfNeeded(p);
      if (u != null && u.trim().isNotEmpty) out.add(u.trim());
    }
    return out;
  }

  String _baseUrl() {
    const v = String.fromEnvironment(
      'BACKEND_BASE_URL',
      defaultValue: 'http://127.0.0.1:8000',
    );
    return _normalizeBaseUrl(v);
  }

  String _projectName() {
    const v = String.fromEnvironment('PROJECT_NAME', defaultValue: '演示项目');
    final s = v.trim();
    return s.isEmpty ? '演示项目' : s;
  }

  Future<void> ensureProject() async {
    await _refreshRuntimeBaseUrl();
    try {
      await _dio.post(
        '/v1/projects/ensure',
        data: {
          'name': _projectName(),
        },
      );
    } catch (_) {
      // Non-blocking for MVP.
    }
  }

  Future<bool> health() async {
    await _refreshRuntimeBaseUrl();
    try {
      final resp = await _dio.get('/v1/health');
      final data = resp.data;
      if (data is Map && data['status'] == 'ok') return true;
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  Future<int?> upsertAcceptanceRecord({
    required AcceptanceRecord record,
    required LibraryItem? library,
    required TargetItem target,
    required String? division,
    required String? subdivision,
    OnlineVisionStructuredResult? ai,
    required int? localId,
  }) async {
    await ensureProject();

    final uploadedPhoto = await _uploadPhotoIfNeeded(record.photoPath);

    final aiJson = ai?.rawJson;
    final aiPayload = ai == null
        ? null
        : jsonEncode(
            aiJson ??
                {
                  'type': ai.type,
                  'summary': ai.summary,
                  'defect_type': ai.defectType,
                  'severity': ai.severity,
                  'rectify_suggestion': ai.rectifySuggestion,
                  'match_id': ai.matchId,
                  'questions': ai.questions,
                  'raw_text': ai.rawText,
                },
          );

    try {
      final resp = await _dio.post(
        '/v1/acceptance-records',
        data: {
          'project_name': _projectName(),
          'region_code': record.regionCode,
          'region_text': record.regionText,
          'division': division,
          'subdivision': subdivision,
          'item': library?.name ?? record.libraryName,
          'item_code': library?.idCode ?? record.libraryCode,
          'indicator': target.name,
          'indicator_code': target.idCode,
          'result': record.result.name,
          'photo_path': uploadedPhoto,
          'remark': record.remark,
          'ai_json': aiPayload,
          'client_created_at': record.createdAt.toIso8601String(),
          'source': 'flutter',
          'client_record_id': localId == null ? null : 'acceptance-$localId',
        },
      );
      final data = resp.data;
      if (data is Map && data['id'] is int) return data['id'] as int;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<BackendAcceptanceRecord>> listAcceptanceRecords({
    int limit = 200,
  }) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get(
      '/v1/acceptance-records',
      queryParameters: {
        'project_name': _projectName(),
        'limit': limit,
      },
    );
    final data = resp.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => BackendAcceptanceRecord.fromJson(
            e.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }

  Future<int?> upsertIssueReport({
    required String regionText,
    required String division,
    required String subDivision,
    required String item,
    required String indicator,
    required String description,
    required String severity,
    required int? deadlineDays,
    required String responsibleUnit,
    required String responsiblePerson,
    required String? libraryId,
    required String? photoPath,
    required String clientRecordId,
  }) async {
    await ensureProject();

    final uploadedPhoto = await _uploadPhotoIfNeeded(photoPath);

    try {
      final resp = await _dio.post(
        '/v1/issue-reports',
        data: {
          'project_name': _projectName(),
          'region_text': regionText,
          'division': division,
          'subdivision': subDivision,
          'item': item,
          'indicator': indicator,
          'library_id': libraryId,
          'description': description,
          'severity': severity,
          'deadline_days': deadlineDays,
          'responsible_unit': responsibleUnit,
          'responsible_person': responsiblePerson,
          'status': 'open',
          'photo_path': uploadedPhoto,
          'client_created_at': DateTime.now().toIso8601String(),
          'source': 'flutter',
          'client_record_id': clientRecordId,
        },
      );
      final data = resp.data;
      if (data is Map && data['id'] is int) return data['id'] as int;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<BackendIssueReport>> listIssueReports({
    int limit = 200,
  }) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get(
      '/v1/issue-reports',
      queryParameters: {
        'project_name': _projectName(),
        'limit': limit,
      },
    );
    final data = resp.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => BackendIssueReport.fromJson(
            e.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }

  Future<BackendIssueReport?> getIssueReport(int id) async {
    await _refreshRuntimeBaseUrl();
    try {
      final resp = await _dio.get('/v1/issue-reports/$id');
      final data = resp.data;
      if (data is! Map) return null;
      return BackendIssueReport.fromJson(
        data.map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<BackendRectificationAction>> listIssueActions(int issueId) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get('/v1/issue-reports/$issueId/actions');
    final data = resp.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => BackendRectificationAction.fromJson(
              e.map((k, v) => MapEntry(k.toString(), v)),
            ))
        .toList();
  }

  Future<int?> addIssueAction({
    required int issueId,
    required String actionType,
    required String content,
    List<String> photoPaths = const [],
    String? actorRole,
    String? actorName,
  }) async {
    await _refreshRuntimeBaseUrl();
    final uploaded = await _uploadPhotosIfNeeded(photoPaths);
    try {
      final resp = await _dio.post(
        '/v1/issue-reports/$issueId/actions',
        data: {
          'action_type': actionType,
          'content': content,
          'photo_urls': uploaded,
          'actor_role': actorRole,
          'actor_name': actorName,
        },
      );
      final data = resp.data;
      if (data is Map && data['id'] is int) return data['id'] as int;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> closeIssue({
    required int issueId,
    required String content,
    List<String> photoPaths = const [],
    String? actorRole,
    String? actorName,
  }) async {
    await _refreshRuntimeBaseUrl();
    final uploaded = await _uploadPhotosIfNeeded(photoPaths);
    try {
      final resp = await _dio.post(
        '/v1/issue-reports/$issueId/close',
        data: {
          'action_type': 'close',
          'content': content,
          'photo_urls': uploaded,
          'actor_role': actorRole,
          'actor_name': actorName,
        },
      );
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  Future<List<BackendRectificationAction>> listAcceptanceActions(
    int recordId,
  ) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get('/v1/acceptance-records/$recordId/actions');
    final data = resp.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => BackendRectificationAction.fromJson(
              e.map((k, v) => MapEntry(k.toString(), v)),
            ))
        .toList();
  }

  Future<int?> addAcceptanceAction({
    required int recordId,
    required String actionType,
    required String content,
    List<String> photoPaths = const [],
    String? actorRole,
    String? actorName,
  }) async {
    await _refreshRuntimeBaseUrl();
    final uploaded = await _uploadPhotosIfNeeded(photoPaths);
    try {
      final resp = await _dio.post(
        '/v1/acceptance-records/$recordId/actions',
        data: {
          'action_type': actionType,
          'content': content,
          'photo_urls': uploaded,
          'actor_role': actorRole,
          'actor_name': actorName,
        },
      );
      final data = resp.data;
      if (data is Map && data['id'] is int) return data['id'] as int;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> verifyAcceptance({
    required int recordId,
    required String result,
    required String remark,
    List<String> photoPaths = const [],
    String? actorRole,
    String? actorName,
  }) async {
    await _refreshRuntimeBaseUrl();
    final uploaded = await _uploadPhotosIfNeeded(photoPaths);
    try {
      final resp = await _dio.post(
        '/v1/acceptance-records/$recordId/verify',
        data: {
          'result': result,
          'remark': remark,
          'photo_urls': uploaded,
          'actor_role': actorRole,
          'actor_name': actorName,
        },
      );
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> getDashboardSummary({
    int limit = 10,
  }) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get(
      '/v1/dashboard/summary',
      queryParameters: {
        'project_name': _projectName(),
        'limit': limit,
      },
    );
    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v));
    }
    throw StateError('Invalid dashboard payload');
  }

  Future<Map<String, dynamic>> getDashboardFocus({
    int timeRangeDays = 14,
    String? building,
  }) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get(
      '/v1/dashboard/focus',
      queryParameters: {
        'project_name': _projectName(),
        'time_range_days': timeRangeDays,
        if (building != null && building.trim().isNotEmpty)
          'building': building.trim(),
      },
    );
    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v));
    }
    throw StateError('Invalid focus payload');
  }

  Future<Map<String, dynamic>> getAiStatus() async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.get('/v1/ai/status');
    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v));
    }
    throw StateError('Invalid ai status payload');
  }

  Future<Map<String, dynamic>> aiChat({
    required String query,
    List<Map<String, String>>? messages,
  }) async {
    await _refreshRuntimeBaseUrl();
    final resp = await _dio.post(
      '/v1/ai/chat',
      data: {
        'query': query,
        'project_name': _projectName(),
        if (messages != null) 'messages': messages,
      },
    );
    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v));
    }
    throw StateError('Invalid chat payload');
  }
}

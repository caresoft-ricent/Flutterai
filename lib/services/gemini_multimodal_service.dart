import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_local_secrets.dart' as local_secrets;

final geminiMultimodalServiceProvider =
    Provider<GeminiMultimodalService>((ref) {
  return GeminiMultimodalService();
});

class GeminiImageAnalysisResult {
  final String text;
  final List<String> questions;
  final Map<String, dynamic>? rawJson;
  final List<GeminiDefectMatch> matches;

  const GeminiImageAnalysisResult({
    required this.text,
    required this.questions,
    required this.rawJson,
    required this.matches,
  });
}

class GeminiDefectMatch {
  final String id;
  final String evidence;
  final String confidence;

  const GeminiDefectMatch({
    required this.id,
    required this.evidence,
    required this.confidence,
  });
}

class GeminiMultimodalService {
  String? _apiKeyOrNull() {
    const v = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
    final s = v.trim();
    if (s.isNotEmpty) return s;
    final local = local_secrets.kGeminiApiKey.trim();
    return local.isEmpty ? null : local;
  }

  String _normalizeModelName(String name) {
    var s = name.trim();
    if (s.startsWith('models/')) {
      s = s.substring('models/'.length);
    }
    return s;
  }

  String _modelName() {
    const v = String.fromEnvironment('GEMINI_MODEL', defaultValue: '');
    final s = _normalizeModelName(v);
    if (s.isNotEmpty) return s;
    final local = _normalizeModelName(local_secrets.kGeminiModel);
    // 2026 年初常见可用命名是 gemini-flash(-lite)-latest。
    return local.isEmpty ? 'gemini-flash-lite-latest' : local;
  }

  bool _looksLikeModelNotFound(Object e) {
    final msg = e.toString();
    return msg.contains('is not found') ||
        msg.contains('not found') ||
        msg.contains('Call ListModels');
  }

  Future<List<String>> _listModelsThatSupportGenerateContent(
    String apiKey,
  ) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
    );

    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.headers.set('accept', 'application/json');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[Gemini] listModels failed: ${resp.statusCode}');
        return const [];
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];

      final models = decoded['models'];
      if (models is! List) return const [];

      final out = <String>[];
      for (final m in models) {
        if (m is! Map) continue;
        final name = m['name']?.toString().trim() ?? '';
        if (name.isEmpty) continue;

        final methods = m['supportedGenerationMethods'];
        final supportsGenerate = methods is List &&
            methods.any((x) => x?.toString() == 'generateContent');
        if (!supportsGenerate) continue;

        out.add(_normalizeModelName(name));
      }

      // De-dupe while preserving order.
      final seen = <String>{};
      return [
        for (final m in out)
          if (seen.add(m)) m,
      ];
    } catch (e) {
      debugPrint('[Gemini] listModels error: $e');
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  List<String> _rankSuggestedModels(List<String> models) {
    // Heuristic preference: flash > pro > others; latest preferred.
    final copy = [...models];
    int score(String m) {
      final s = m.toLowerCase();
      var v = 0;
      if (s.contains('flash')) v += 100;
      if (s.contains('pro')) v += 50;
      if (s.contains('latest')) v += 10;
      return -v; // sort ascending
    }

    copy.sort((a, b) => score(a).compareTo(score(b)));
    return copy;
  }

  List<String> _fallbackModelNames(String primary) {
    final p = _normalizeModelName(primary);
    final out = <String>[];

    // If user provided gemini-1.5-flash, try gemini-1.5-flash-latest.
    if (!p.endsWith('-latest')) {
      out.add('$p-latest');
    }

    // A couple of pragmatic fallbacks that are commonly enabled.
    // (We keep this short to avoid surprising behavior.)
    if (p != 'gemini-flash-lite-latest') out.add('gemini-flash-lite-latest');
    if (p != 'gemini-flash-latest') out.add('gemini-flash-latest');
    if (p != 'gemini-2.0-flash') out.add('gemini-2.0-flash');
    if (p != 'gemini-1.5-flash-latest') out.add('gemini-1.5-flash-latest');
    if (p != 'gemini-1.5-pro-latest') out.add('gemini-1.5-pro-latest');

    // De-dupe while preserving order.
    final seen = <String>{};
    return [
      for (final m in out)
        if (seen.add(m)) m,
    ];
  }

  Future<String> _generateWithModelRest(
    String modelName,
    String apiKey, {
    required String prompt,
    required List<int> imageBytes,
  }) async {
    final m = _normalizeModelName(modelName);
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$apiKey',
    );

    final body = <String, dynamic>{
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inlineData': {
                'mimeType': 'image/jpeg',
                'data': base64Encode(imageBytes),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.2,
        // Slightly higher to reduce chance of truncated JSON.
        'maxOutputTokens': 768,
        // Ask Gemini to return machine-readable JSON (when supported by model).
        'responseMimeType': 'application/json',
      },
    };

    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('accept', 'application/json');
      req.write(jsonEncode(body));

      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final snippet =
            respBody.length > 400 ? respBody.substring(0, 400) : respBody;
        throw StateError('Gemini HTTP ${resp.statusCode}: $snippet');
      }

      final decoded = jsonDecode(respBody);
      if (decoded is! Map) {
        throw StateError('Gemini 返回格式异常（非 JSON 对象）');
      }

      final candidates = decoded['candidates'];
      if (candidates is! List || candidates.isEmpty) {
        throw StateError('Gemini 未返回候选结果');
      }

      final first = candidates.first;
      if (first is! Map) {
        throw StateError('Gemini 候选格式异常');
      }

      final content = first['content'];
      if (content is! Map) {
        throw StateError('Gemini content 格式异常');
      }

      final parts = content['parts'];
      if (parts is! List || parts.isEmpty) {
        throw StateError('Gemini 未返回文本 parts');
      }

      final sb = StringBuffer();
      for (final p in parts) {
        if (p is Map && p['text'] != null) {
          final t = p['text'].toString();
          if (t.isNotEmpty) sb.write(t);
        }
      }

      final text = sb.toString().trim();
      if (text.isEmpty) {
        throw StateError('Gemini 未返回文本结果');
      }

      return text;
    } finally {
      client.close(force: true);
    }
  }

  Future<GeminiImageAnalysisResult> analyzeImageAutoStructured(
    String imagePath, {
    required String sceneHint,
    required String hint,
    List<String>? defectLibraryCandidateLines,
  }) async {
    final apiKey = _apiKeyOrNull();
    if (apiKey == null) {
      throw StateError(
          '未配置 Gemini API Key（GEMINI_API_KEY 或 app_local_secrets.dart:kGeminiApiKey）');
    }

    final bytes = await File(imagePath).readAsBytes();

    final primaryModel = _modelName();
    debugPrint(
      '[Gemini] analyzeImageAutoStructured: model=$primaryModel, bytes=${bytes.length}',
    );

    final prompt = _buildPrompt(
      sceneHint: sceneHint,
      hint: hint,
      defectLibraryCandidateLines: defectLibraryCandidateLines,
    );

    var text = '';
    var usedModel = primaryModel;
    try {
      text = await _generateWithModelRest(
        primaryModel,
        apiKey,
        prompt: prompt,
        imageBytes: bytes,
      );
    } catch (e) {
      if (!_looksLikeModelNotFound(e)) rethrow;

      final fallbacks = _fallbackModelNames(primaryModel);
      final fromApi = _rankSuggestedModels(
        await _listModelsThatSupportGenerateContent(apiKey),
      );
      final candidates = <String>[
        ...fallbacks,
        ...fromApi,
      ];

      // De-dupe and avoid retrying the same model.
      final seen = <String>{primaryModel};
      final uniq = <String>[
        for (final m in candidates)
          if (seen.add(m)) m,
      ];

      debugPrint(
        '[Gemini] model not available: $primaryModel, trying fallbacks=${uniq.take(6).toList()}${uniq.length > 6 ? '...' : ''}',
      );

      Object? lastError = e;
      for (final m in uniq) {
        try {
          text = await _generateWithModelRest(
            m,
            apiKey,
            prompt: prompt,
            imageBytes: bytes,
          );
          debugPrint('[Gemini] fallback model succeeded: $m');
          usedModel = m;
          lastError = null;
          break;
        } catch (e2) {
          lastError = e2;
        }
      }

      if (lastError != null) throw lastError;
    }

    if (text.trim().isEmpty) {
      throw StateError('Gemini 未返回文本结果');
    }

    // Try parse JSON from response; tolerate code fences.
    var jsonObj = _tryExtractJson(text);
    debugPrint(
      '[Gemini] response: chars=${text.length}, json=${jsonObj != null}',
    );

    // If the model returned partial JSON (e.g. only type), retry once with a repair prompt.
    final hasCandidates = (defectLibraryCandidateLines ?? const [])
        .any((e) => e.trim().isNotEmpty);

    final rawTrim = text.trim();
    final looksLikeTruncatedJson =
        rawTrim.startsWith('{') && !rawTrim.endsWith('}');
    final looksJsonishButUnparseable = jsonObj == null &&
        (looksLikeTruncatedJson || rawTrim.contains('"type"'));

    if ((jsonObj != null &&
            !_looksCompleteStructuredJson(jsonObj,
                hasCandidates: hasCandidates)) ||
        looksJsonishButUnparseable) {
      debugPrint(
          '[Gemini] structured json incomplete/unparseable; retrying once');
      try {
        final repairPrompt = _buildRepairPrompt(
          previousOutput: text,
          defectLibraryCandidateLines: defectLibraryCandidateLines,
        );
        final repairedText = await _generateWithModelRest(
          usedModel,
          apiKey,
          prompt: repairPrompt,
          imageBytes: bytes,
        );
        final repairedJson = _tryExtractJson(repairedText);
        if (repairedJson != null) {
          text = repairedText;
          jsonObj = repairedJson;
        }
      } catch (e) {
        debugPrint('[Gemini] repair retry failed: $e');
      }
    }

    if (jsonObj == null) {
      return GeminiImageAnalysisResult(
        text: text,
        questions: const [],
        rawJson: null,
        matches: const [],
      );
    }

    final matches = <GeminiDefectMatch>[];
    final m = jsonObj['matches'];
    if (m is List) {
      for (final item in m) {
        if (item is! Map) continue;
        final id = (item['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        final evidence = (item['evidence'] ?? '').toString().trim();
        final confidence = (item['confidence'] ?? '').toString().trim();
        matches.add(
          GeminiDefectMatch(
            id: id,
            evidence: evidence,
            confidence: confidence,
          ),
        );
      }
    }

    final questions = <String>[];
    final q = jsonObj['questions'];
    if (q is List) {
      for (final item in q) {
        final s = item?.toString().trim();
        if (s != null && s.isNotEmpty) questions.add(s);
      }
    }

    final summary =
        (jsonObj['summary'] ?? jsonObj['text'] ?? '').toString().trim();
    final type = (jsonObj['type'] ?? '').toString().trim();

    final sb = StringBuffer();
    if (type.isNotEmpty) {
      sb.writeln('类型：$type');
    }
    if (summary.isNotEmpty) {
      sb.writeln(summary);
    } else {
      sb.writeln(text);
    }

    return GeminiImageAnalysisResult(
      text: sb.toString().trim(),
      questions: questions,
      rawJson: jsonObj,
      matches: matches,
    );
  }

  String _buildPrompt({
    required String sceneHint,
    required String hint,
    List<String>? defectLibraryCandidateLines,
  }) {
    final candidates = (defectLibraryCandidateLines ?? const [])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final candidateSection = candidates.isEmpty
        ? ''
        : '''\n\n可选问题库条目（只能从下面选择 id）：\n${candidates.take(30).map((e) => '- $e').join('\n')}\n\n规则：\n- 如果 type="defect"：matches 必须返回 1 条，id 必须从上面列表选择（即使不确定，也要选最接近的一条，confidence=low）。\n- 只有当 type="ocr" 或 type="other" 时，matches 才允许返回空数组。\n''';

    const template =
        '''\n\n你必须输出下面 JSON 模板的同构对象（字段不能缺失，数组/对象可为空）：\n{\n  "type": "defect",\n  "summary": "",\n  "extracted": {},\n  "defects": [\n    {"name": "", "severity": "", "evidence": ""}\n  ],\n  "matches": [\n    {"id": "", "evidence": "", "confidence": "low"}\n  ],\n  "questions": []\n}\n\n注意：\n- confidence 只能是 "low" | "medium" | "high"\n- type="defect" 时：defects 必须是数组（可为空数组），matches 必须是数组且长度=1\n- 任何情况下都不要输出代码块/Markdown/额外解释\n''';

    return '''你是工地质量巡检助手。请根据图片进行判断，并以严格 JSON 输出，便于落库。

关键要求：
- 只输出 JSON（不要任何解释性文字、不要提及“Gemini/识别效果/接下来”等）。
- 输出必须以 { 开头，以 } 结尾。
- 所有字符串必须使用双引号，JSON 必须可被严格解析。

场景：$sceneHint
额外要求：$hint
$candidateSection

输出要求：
1) 必须返回 JSON（不要 Markdown，不要代码块）。
2) 字段必须齐全（不要省略任何字段），且 JSON 必须可被严格解析。
3) 不要编造看不清的字段；不确定请在 questions 里提问。
$template
''';
  }

  bool _looksCompleteStructuredJson(
    Map<String, dynamic> obj, {
    required bool hasCandidates,
  }) {
    bool hasKey(String k) => obj.containsKey(k);
    final hasAllKeys = hasKey('type') &&
        hasKey('summary') &&
        hasKey('extracted') &&
        hasKey('defects') &&
        hasKey('matches') &&
        hasKey('questions');
    if (!hasAllKeys) return false;

    final type = (obj['type'] ?? '').toString().trim();
    if (type != 'ocr' && type != 'defect' && type != 'other') return false;

    final matches = obj['matches'];
    if (matches is! List) return false;

    if (type == 'defect') {
      // For defects, we require a matches entry when candidates exist.
      if (hasCandidates) {
        if (matches.length != 1) return false;
        final m0 = matches.first;
        if (m0 is! Map) return false;
        final id = (m0['id'] ?? '').toString().trim();
        if (id.isEmpty) return false;
      }
      final defects = obj['defects'];
      if (defects is! List) return false;
    }

    return true;
  }

  String _buildRepairPrompt({
    required String previousOutput,
    List<String>? defectLibraryCandidateLines,
  }) {
    final prev = previousOutput.trim();
    final clipped = prev.length > 1200 ? prev.substring(0, 1200) : prev;

    final candidates = (defectLibraryCandidateLines ?? const [])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(30)
        .toList();

    final candidateSection = candidates.isEmpty
        ? ''
        : '''\n\n可选问题库条目（只能从下面选择 id）：\n${candidates.map((e) => '- $e').join('\n')}\n\n规则：\n- 如果 type="defect"：matches 必须返回 1 条，id 必须从上面列表选择（即使不确定，也要选最接近的一条，confidence=low）。\n- 只有当 type="ocr" 或 type="other" 时，matches 才允许返回空数组。\n''';

    return '''你上一轮输出不符合要求（字段缺失/结构不完整或 JSON 被截断）。

请重新输出：只能输出 1 个 JSON 对象，且必须包含字段：
type, summary, extracted, defects, matches, questions（一个都不能少）。

严格遵循这个模板（字段不能缺失，数组/对象可为空）：
{
  "type": "defect",
  "summary": "",
  "extracted": {},
  "defects": [{"name": "", "severity": "", "evidence": ""}],
  "matches": [{"id": "", "evidence": "", "confidence": "low"}],
  "questions": []
}

$candidateSection

约束：
- 只输出 JSON，不要任何解释文字。
- confidence 只能是 "low" | "medium" | "high"。

你上一轮输出如下（仅供纠错，不要原样复述）：
$clipped
''';
  }

  Map<String, dynamic>? _tryExtractJson(String text) {
    var s = text;
    // Strip BOM that may appear in some runtimes.
    s = s.replaceAll('\uFEFF', '');
    s = s.trim();
    // Strip common fences if present
    if (s.startsWith('```')) {
      s = s.replaceAll(RegExp(r'^```[a-zA-Z]*\n?'), '');
      s = s.replaceAll(RegExp(r'```\s*$'), '');
      s = s.trim();
    }

    // Try locate first {...} block
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    var candidate = s.substring(start, end + 1).trim();
    candidate = candidate.replaceAll('\uFEFF', '');

    try {
      final obj = jsonDecode(candidate);
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return obj.cast<String, dynamic>();
      return null;
    } catch (_) {
      // Gemini sometimes returns JSON with trailing commas. Try a light repair.
      final repaired = candidate.replaceAll(
        RegExp(r',\s*([}\]])'),
        r'$1',
      );
      try {
        final obj = jsonDecode(repaired);
        if (obj is Map<String, dynamic>) return obj;
        if (obj is Map) return obj.cast<String, dynamic>();
        return null;
      } catch (_) {
        return null;
      }
    }
  }
}

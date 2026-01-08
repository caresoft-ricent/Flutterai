import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../app_local_secrets.dart' as local_secrets;

final geminiServiceProvider = Provider<GeminiService>((ref) {
  return GeminiService();
});

/// 极简稳版 Prompt（7 个核心字段）。
///
/// 目标：最大化 JSON 完整输出概率，避免超长模板/冗余字段导致被截断。
const String kGeminiMinimalPrompt = r'''
你是工地巡检/验收拍照助手。根据图片判断，并只输出 1 个可严格解析的 JSON 对象。

必须满足：
- 只输出 JSON（不要 Markdown/不要代码块/不要解释文字）。
- JSON 必须以 { 开头，以 } 结尾。
- 字段必须齐全（一个都不能少）：type, summary, defect_type, severity, rectify_suggestion, match_id, questions。

字段含义：
- type: "defect" | "irrelevant" | "other"
- summary: 1-2 句结论（必须具体、可核验：构件/部位 + 现象 + 位置特征；避免空泛词如“存在隐患/需整改”）
- defect_type: 缺陷类型（type=defect 时填写；用短语，尽量具体，如“混凝土露筋/蜂窝麻面/裂缝/锈蚀/临边防护缺失”等；否则空字符串）
- severity: "low" | "medium" | "high"（type=defect 时填写；否则 "low"）
- rectify_suggestion: 2-4 个具体整改动作（用中文短句，用；分隔；要包含可执行动作/材料/工序，避免“加强管理/注意安全”等泛化表述）
- match_id: 命中问题库条目 id（无命中则空字符串）
- questions: 需要用户补充的信息列表（不需要则空数组）

额外硬性约束（为避免输出太泛）：
- summary 必须至少包含 2 个“可见证据点”（例如：破损/掉角/露筋/锈蚀/渗水/裂缝/缺失/松动/倾斜/变形/堵塞 等中的具体描述）。
- 若照片无法判断或不是施工部位：type=irrelevant，summary 用中文提示“请重拍××（施工部位）”。
- 不要编造尺寸/数量/规范条款；除非图片中能明确读到/看到。

输出模板（必须同构）：
{
  "type": "defect",
  "summary": "",
  "defect_type": "",
  "severity": "low",
  "rectify_suggestion": "",
  "match_id": "",
  "questions": []
}
''';

class GeminiStructuredResult {
  final String type;
  final String summary;
  final String defectType;
  final String severity;
  final String rectifySuggestion;
  final String matchId;
  final List<String> questions;
  final Map<String, dynamic>? rawJson;
  final String rawText;

  const GeminiStructuredResult({
    required this.type,
    required this.summary,
    required this.defectType,
    required this.severity,
    required this.rectifySuggestion,
    required this.matchId,
    required this.questions,
    required this.rawJson,
    required this.rawText,
  });

  bool get matchedHistory => matchId.trim().isNotEmpty;
}

class GeminiService {
  String? _apiKeyOrNull() {
    const v = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
    final s = v.trim();
    if (s.isNotEmpty) return s;
    final local = local_secrets.kGeminiApiKey.trim();
    return local.isEmpty ? null : local;
  }

  String _modelName() {
    // 按需求强制为 2026 年最佳实践：gemini-2.5-flash
    return 'gemini-2.5-flash';
  }

  String _buildPrompt({
    required String sceneHint,
    required String hint,
    List<String>? defectLibraryCandidateLines,
  }) {
    final candidates = (defectLibraryCandidateLines ?? const [])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(30)
        .toList();

    final candidateSection = candidates.isEmpty
        ? ''
        : '''\n可选问题库条目（仅在 type=defect 时可填写 match_id；若命中必须从下列选择 id）：\n${candidates.map((e) => '- $e').join('\n')}\n\n规则：\n- 若 type=defect 且明显属于上述条目：match_id 必须填入对应 id\n- 若无法确定命中：match_id 置空字符串\n''';

    return '''$kGeminiMinimalPrompt

场景：$sceneHint
补充要求：$hint
$candidateSection
''';
  }

  GenerationConfig _generationConfig() {
    return GenerationConfig(
      temperature: 0.15,
      // 给足输出上限，避免结构化 JSON 被截断。
      maxOutputTokens: 2048,
      responseMimeType: 'application/json',
    );
  }

  String _cleanupJsonText(String input) {
    var s = input.trim();
    // 清理 ```json ... ``` 或 ``` ... ```
    s = s.replaceAll(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\s*```\s*$'), '');
    s = s.trim();
    return s;
  }

  bool _looksComplete(Map<String, dynamic> obj) {
    bool has(String k) => obj.containsKey(k);
    final ok = has('type') &&
        has('summary') &&
        has('defect_type') &&
        has('severity') &&
        has('rectify_suggestion') &&
        has('match_id') &&
        has('questions');
    if (!ok) return false;

    final type = (obj['type'] ?? '').toString().trim();
    if (type != 'defect' && type != 'irrelevant' && type != 'other') {
      return false;
    }

    final q = obj['questions'];
    if (q is! List) return false;

    return true;
  }

  GeminiStructuredResult _fromJson(
    Map<String, dynamic> obj, {
    required String rawText,
  }) {
    String str(String k) => (obj[k] ?? '').toString().trim();

    final type = str('type');
    final summary = str('summary');
    final defectType = str('defect_type');
    final severity = str('severity');
    final rectifySuggestion = str('rectify_suggestion');
    final matchId = str('match_id');

    final questions = <String>[];
    final q = obj['questions'];
    if (q is List) {
      for (final item in q) {
        final s = item?.toString().trim();
        if (s != null && s.isNotEmpty) questions.add(s);
      }
    }

    return GeminiStructuredResult(
      type: type,
      summary: summary,
      defectType: defectType,
      severity: severity,
      rectifySuggestion: rectifySuggestion,
      matchId: matchId,
      questions: questions,
      rawJson: obj,
      rawText: rawText,
    );
  }

  GeminiStructuredResult _offlineFallback(
    String rawText, {
    List<String>? defectLibraryCandidateLines,
  }) {
    final t = rawText.trim();

    final irrelevant =
        RegExp(r'无法判断|看不清|请重拍|不相关|irrelevant', caseSensitive: false)
            .hasMatch(t);

    String matchId = '';
    final candidates = (defectLibraryCandidateLines ?? const [])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // 简单规则：如果返回文本里直接包含某个候选 id，则认为命中。
    for (final c in candidates) {
      final id = c.split(RegExp(r'\s+')).first.trim();
      if (id.isEmpty) continue;
      if (t.contains(id)) {
        matchId = id;
        break;
      }
    }

    final summary =
        t.isEmpty ? '识别结果解析失败，请重试。' : (t.length > 80 ? t.substring(0, 80) : t);

    return GeminiStructuredResult(
      type: irrelevant ? 'irrelevant' : 'other',
      summary: irrelevant ? '请拍摄施工部位' : summary,
      defectType: '',
      severity: 'low',
      rectifySuggestion: '',
      matchId: matchId,
      questions: const [],
      rawJson: null,
      rawText: rawText,
    );
  }

  GeminiStructuredResult _fallbackFromError(Object e) {
    final msg = e.toString();
    final overloaded = msg.contains('503') ||
        msg.toLowerCase().contains('overloaded') ||
        msg.toLowerCase().contains('unavailable');

    return GeminiStructuredResult(
      type: 'other',
      summary: overloaded ? '在线模型繁忙，请稍后重试。' : '在线识别失败，请重试。',
      defectType: '',
      severity: 'low',
      rectifySuggestion: '',
      matchId: '',
      questions: const [],
      rawJson: null,
      rawText: msg,
    );
  }

  Future<GeminiStructuredResult> analyzeImageAutoStructured(
    String imagePath, {
    required String sceneHint,
    required String hint,
    List<String>? defectLibraryCandidateLines,
  }) async {
    final apiKey = _apiKeyOrNull();
    if (apiKey == null) {
      throw StateError(
        '未配置 Gemini API Key（GEMINI_API_KEY 或 app_local_secrets.dart:kGeminiApiKey）',
      );
    }

    final imageBytes = await File(imagePath).readAsBytes();
    debugPrint('[GeminiSDK] image bytes=${imageBytes.length}');
    final prompt = _buildPrompt(
      sceneHint: sceneHint,
      hint: hint,
      defectLibraryCandidateLines: defectLibraryCandidateLines,
    );

    final model = GenerativeModel(
      model: _modelName(),
      apiKey: apiKey,
      generationConfig: _generationConfig(),
    );

    Future<String> callOnce(String p) async {
      final response = await model.generateContent([
        Content.multi([
          TextPart(p),
          DataPart('image/jpeg', imageBytes),
        ]),
      ]);
      return response.text ?? '';
    }

    // 第一次调用：极简 prompt。
    String raw;
    try {
      raw = await callOnce(prompt);
    } catch (e) {
      debugPrint('[GeminiSDK] request failed: $e');
      return _fallbackFromError(e);
    }
    var cleaned = _cleanupJsonText(raw);

    Map<String, dynamic>? obj;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map) {
        obj = decoded.cast<String, dynamic>();
      }
    } catch (_) {
      obj = null;
    }

    // 若解析失败或字段不齐全：再补救重试一次（极短修复提示）。
    if (obj == null || !_looksComplete(obj)) {
      debugPrint('[GeminiSDK] invalid/incomplete json; retry once');
      final clipped =
          cleaned.length > 800 ? cleaned.substring(0, 800) : cleaned;

      final repairPrompt = '''$kGeminiMinimalPrompt

你上一轮输出无法解析或字段缺失。请仅输出 1 个完整 JSON 对象（与模板同构），不要输出任何解释文字。

上一轮输出片段（仅供纠错，不要原样复述）：
$clipped
''';

      try {
        raw = await callOnce(repairPrompt);
      } catch (e) {
        debugPrint('[GeminiSDK] repair request failed: $e');
        return _fallbackFromError(e);
      }
      cleaned = _cleanupJsonText(raw);

      try {
        final decoded = jsonDecode(cleaned);
        if (decoded is Map) {
          obj = decoded.cast<String, dynamic>();
        } else {
          obj = null;
        }
      } catch (_) {
        obj = null;
      }
    }

    if (obj == null || !_looksComplete(obj)) {
      return _offlineFallback(
        cleaned.isEmpty ? raw : cleaned,
        defectLibraryCandidateLines: defectLibraryCandidateLines,
      );
    }

    return _fromJson(obj, rawText: cleaned);
  }
}

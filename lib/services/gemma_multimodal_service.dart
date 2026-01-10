import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_local_secrets.dart' as local_secrets;
import '../models/parsed_intent.dart';

final gemmaMultimodalServiceProvider = Provider<GemmaMultimodalService>((ref) {
  final service = GemmaMultimodalService();
  ref.onDispose(service.dispose);
  return service;
});

class GemmaImageAnalysisResult {
  final String text;
  final List<String> questions;

  const GemmaImageAnalysisResult({
    required this.text,
    required this.questions,
  });
}

class GemmaMultimodalService {
  // Gated model (Gemma license) – requires HuggingFace token + accepted license.
  // See: https://huggingface.co/google/gemma-3n-E2B-it-litert-preview
  static const String _defaultModelUrl =
      'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task?download=true';
  static const String _defaultModelFilename = 'gemma-3n-E2B-it-int4.task';
  static const String _defaultModelIdBase = 'gemma-3n-E2B-it-int4';

  String get modelUrl => const String.fromEnvironment(
        'GEMMA_MM_MODEL_URL',
        defaultValue: _defaultModelUrl,
      ).trim();

  String get modelFilename => const String.fromEnvironment(
        'GEMMA_MM_MODEL_FILENAME',
        defaultValue: _defaultModelFilename,
      ).trim();

  String get _modelIdBase => const String.fromEnvironment(
        'GEMMA_MM_MODEL_ID_BASE',
        defaultValue: _defaultModelIdBase,
      ).trim();

  static const ModelType _modelType = ModelType.gemmaIt;

  InferenceModel? _model;
  Future<void>? _modelFuture;

  String? _hfTokenOrNull() {
    const token = String.fromEnvironment('HUGGINGFACE_TOKEN', defaultValue: '');
    final trimmed = token.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final local = local_secrets.kHuggingfaceToken.trim();
    return local.isEmpty ? null : local;
  }

  Future<String?> _pickInstalledInferenceModelId() async {
    final installed = await FlutterGemma.listInstalledModels();
    if (installed.isEmpty) return null;

    // flutter_gemma 可能会把安装后的 id 记为不带扩展名的 spec.name。
    // 优先挑选我们期望的 Gemma 3n int4。
    if (installed.contains(_modelIdBase)) return _modelIdBase;
    if (installed.contains(modelFilename)) return modelFilename;

    final containsBase = installed.where((e) => e.contains(_modelIdBase));
    if (containsBase.isNotEmpty) return containsBase.first;

    // 兜底：挑一个 .task 推理模型。
    final task = installed.where((e) => e.toLowerCase().endsWith('.task'));
    if (task.isNotEmpty) return task.first;
    return installed.first;
  }

  Future<void> _ensureActiveInferenceModelOrThrow() async {
    if (FlutterGemma.hasActiveModel()) return;

    final id = await _pickInstalledInferenceModelId();
    if (id == null) {
      throw StateError('未安装 Gemma 模型，请先安装模型');
    }

    // 仅设置 active spec：若已安装则不会重新下载。
    final spec = InferenceModelSpec.fromLegacyUrl(
      name: id,
      modelUrl: modelUrl,
    );
    await FlutterGemmaPlugin.instance.modelManager
        .ensureModelReadyFromSpec(spec);

    if (!FlutterGemma.hasActiveModel()) {
      throw StateError('未设置 Gemma 活动模型，请先安装模型');
    }
  }

  Future<void> ensureInstalled(
      {void Function(int progress)? onProgress}) async {
    // If already installed, ensure it's also set as active for this run.
    // Note: flutter_gemma does not persist active model across app restarts.
    final installedId = await _pickInstalledInferenceModelId();
    if (installedId != null) {
      await _ensureActiveInferenceModelOrThrow();
      return;
    }

    final token = _hfTokenOrNull();

    // This specific Gemma 3n LiteRT preview model is gated on HuggingFace.
    // Without a token, the download will always fail with 401.
    if (token == null) {
      throw StateError(
        '缺少 HuggingFace Token：该模型在 HuggingFace 为受限仓库（gated repo），需要先同意 Gemma 许可并提供 token。\n\n'
        '配置方式：\n'
        '1) 推荐：运行/打包命令加 --dart-define=HUGGINGFACE_TOKEN=...\n'
        '2) （仅内测/本机）写入 lib/app_local_secrets.dart 的 kHuggingfaceToken\n',
      );
    }

    // Install from network (cached by plugin). This may throw if token/access missing.
    try {
      await FlutterGemma.installModel(modelType: _modelType)
          .fromNetwork(modelUrl, token: token)
          .withProgress((p) {
        // Some downloader implementations may emit negative progress on failure.
        final clamped = p.clamp(0, 100);
        onProgress?.call(clamped);
      }).install();
    } catch (e) {
      final msg = e.toString();
      final is401 = msg.contains(' 401') ||
          msg.contains('response code 401') ||
          msg.contains('TaskHttpException') && msg.contains('401');
      final isRestricted = msg.toLowerCase().contains('restricted') ||
          msg.toLowerCase().contains('be authenticated') ||
          msg.toLowerCase().contains('log in');

      if (is401 || isRestricted) {
        throw StateError(
          'Gemma 多模态模型下载失败（401 未授权）。\n'
          '请确认：\n'
          '1) 已在 HuggingFace 打开模型页并同意/申请访问（gated repo）\n'
          '2) 使用的 Token 具备 read 权限且未过期\n'
          '3) 运行/打包命令包含 --dart-define=HUGGINGFACE_TOKEN=...\n'
          '原始错误：$msg',
        );
      }

      rethrow;
    }

    // After install, make sure active model is set.
    await _ensureActiveInferenceModelOrThrow();
  }

  Future<InferenceModel> _ensureModelLoaded() async {
    // In case the app restarted and active spec is lost, recover it.
    await _ensureActiveInferenceModelOrThrow();

    final existing = _model;
    if (existing != null) return existing;

    final inFlight = _modelFuture;
    if (inFlight != null) {
      await inFlight;
      final loaded = _model;
      if (loaded == null) {
        throw StateError('Gemma 多模态模型加载失败（未知原因）');
      }
      return loaded;
    }

    final completer = Completer<void>();
    _modelFuture = completer.future;
    try {
      late final InferenceModel model;
      try {
        model = await FlutterGemma.getActiveModel(
          // Keep this modest to reduce iOS memory pressure (KV cache etc.).
          maxTokens: 1024,
          supportImage: true,
          maxNumImages: 1,
        );
      } catch (e) {
        final msg = e.toString();
        final looksLikeMmapOom = msg.contains('Failed to map') ||
            msg.contains('Cannot allocate memory') ||
            msg.contains('failedToInitializeEngine') ||
            msg.contains('LiteRTResourceCalculator');
        if (looksLikeMmapOom) {
          throw StateError(
            'Gemma 引擎初始化失败：iOS 无法映射模型文件（内存不足/文件过大）。\n'
            '建议改用更小的多模态 .task 模型，然后通过 dart-define 指定：\n'
            '--dart-define=GEMMA_MM_MODEL_URL=...\n'
            '--dart-define=GEMMA_MM_MODEL_FILENAME=...\n'
            '--dart-define=GEMMA_MM_MODEL_ID_BASE=...\n'
            '原始错误：$msg',
          );
        }
        rethrow;
      }
      _model = model;
      return model;
    } finally {
      completer.complete();
      _modelFuture = null;
    }
  }

  Future<String> _generateOnce(Message message,
      {required bool enableVision}) async {
    final model = await _ensureModelLoaded();
    final session = await model.createSession(
      temperature: 0.2,
      topK: 40,
      topP: 0.9,
      enableVisionModality: enableVision,
    );

    try {
      await session.addQueryChunk(message);
      return await session.getResponse();
    } finally {
      try {
        await session.close();
      } catch (_) {}
    }
  }

  String _intentPrompt(String userInput) {
    return '''你是河狸云工序验收语音助手，只处理验收和问题上报意图。
用户输入：$userInput

请严格输出 JSON，格式：
{
  "intent": "procedure_acceptance" | "report_issue" | "unknown",
  "region_text": "1栋6层" 或 null,
  "region_code": null,
  "library_name": "钢筋" 或 null,
  "library_code": null
}

如果无法判断意图，intent 设为 "unknown"。
只输出 JSON，不要任何解释。''';
  }

  ParsedIntentResult _extractAndParseJson(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw FormatException('LLM 输出不包含 JSON：$text');
    }
    final jsonText = text.substring(start, end + 1);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('LLM JSON 不是对象：$jsonText');
    }

    String? readString(String key) {
      final v = decoded[key];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty || s.toLowerCase() == 'null' ? null : s;
    }

    return ParsedIntentResult(
      intent: (readString('intent') ?? 'unknown').trim(),
      regionText: readString('region_text'),
      regionCode: readString('region_code'),
      libraryName: readString('library_name'),
      libraryCode: readString('library_code'),
    );
  }

  Map<String, dynamic> _extractJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw FormatException('LLM 输出不包含 JSON：$text');
    }
    final jsonText = text.substring(start, end + 1);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('LLM JSON 不是对象：$jsonText');
    }
    return decoded;
  }

  double _readDouble01(Map<String, dynamic> obj, String key,
      {double fallback = 0.0}) {
    final v = obj[key];
    if (v == null) return fallback;
    if (v is num) return v.toDouble().clamp(0.0, 1.0);
    final parsed = double.tryParse(v.toString());
    if (parsed == null) return fallback;
    return parsed.clamp(0.0, 1.0);
  }

  String _readStringOrEmpty(Map<String, dynamic> obj, String key) {
    final v = obj[key];
    if (v == null) return '';
    final s = v.toString().trim();
    return s.toLowerCase() == 'null' ? '' : s;
  }

  String _classifyPrompt({
    String? targetName,
    String? targetStandard,
    String? sceneHint,
  }) {
    final sb = StringBuffer();
    sb.writeln('你是河狸云工序验收/巡检助手。请对图片做“场景分类”。');
    if (sceneHint != null && sceneHint.trim().isNotEmpty) {
      sb.writeln('拍摄场景提示：${sceneHint.trim()}');
    }
    if (targetName != null && targetName.trim().isNotEmpty) {
      sb.writeln('当前检查点：${targetName.trim()}');
    }
    if (targetStandard != null && targetStandard.trim().isNotEmpty) {
      sb.writeln('验收标准：${targetStandard.trim()}');
    }
    sb.writeln();
    sb.writeln('请判断图片更像哪一类：');
    sb.writeln('- ocr：送货单/合格证/铭牌/标签/表格/印刷文字为主，目标是提取文字与字段');
    sb.writeln('- defect：现场实体/构件/工艺/缺陷为主，目标是判断质量问题与建议');
    sb.writeln('- other：都不是或无法判断');
    sb.writeln();
    sb.writeln('请严格输出 JSON（只输出 JSON，不要解释）：');
    sb.writeln('{');
    sb.writeln('  "mode": "ocr" | "defect" | "other",');
    sb.writeln('  "confidence": 0.0-1.0,');
    sb.writeln('  "reason": "一句话原因",');
    sb.writeln('  "retake_hint": "如需补拍，给出一句话建议；否则为空"');
    sb.writeln('}');
    return sb.toString();
  }

  String _ocrPrompt({
    String? sceneHint,
  }) {
    final sb = StringBuffer();
    sb.writeln('你是河狸云离线识别助手。请对图片进行 OCR 类信息抽取。');
    if (sceneHint != null && sceneHint.trim().isNotEmpty) {
      sb.writeln('场景提示：${sceneHint.trim()}');
    }
    sb.writeln();
    sb.writeln('要求：');
    sb.writeln('1) 尽量逐字读取清晰可见的文字；看不清就留空，不要编造');
    sb.writeln('2) 识别送货单/合格证/铭牌/标签时，尽量抽取关键字段');
    sb.writeln('3) 严格输出 JSON（只输出 JSON，不要解释）');
    sb.writeln();
    sb.writeln('{');
    sb.writeln('  "doc_type": "送货单"|"合格证"|"铭牌"|"标签"|"表格"|"其他",');
    sb.writeln('  "confidence": 0.0-1.0,');
    sb.writeln('  "fields": {');
    sb.writeln('    "supplier": "" ,');
    sb.writeln('    "material": "" ,');
    sb.writeln('    "spec": "" ,');
    sb.writeln('    "batch_no": "" ,');
    sb.writeln('    "model": "" ,');
    sb.writeln('    "serial_no": "" ,');
    sb.writeln('    "date": "" ,');
    sb.writeln('    "project": ""');
    sb.writeln('  },');
    sb.writeln('  "questions": [""],');
    sb.writeln('  "raw_text": "" ,');
    sb.writeln('  "retake_hint": ""');
    sb.writeln('}');
    return sb.toString();
  }

  String _defectPrompt({
    required String hint,
    String? targetName,
    String? targetStandard,
    String? sceneHint,
  }) {
    final sb = StringBuffer();
    sb.writeln('你是河狸云工序验收/巡检助手。请基于图片做质量问题判断。');
    if (sceneHint != null && sceneHint.trim().isNotEmpty) {
      sb.writeln('场景提示：${sceneHint.trim()}');
    }
    if (targetName != null && targetName.trim().isNotEmpty) {
      sb.writeln('当前检查点：${targetName.trim()}');
    }
    if (targetStandard != null && targetStandard.trim().isNotEmpty) {
      sb.writeln('验收标准：${targetStandard.trim()}');
    }
    sb.writeln('任务：$hint');
    sb.writeln();
    sb.writeln('请严格输出 JSON（只输出 JSON，不要解释）：');
    sb.writeln('{');
    sb.writeln('  "summary": "1-2 句话结论",');
    sb.writeln('  "defects": [');
    sb.writeln('    {"type": "", "severity": "轻微|一般|严重|不确定", "evidence": ""}');
    sb.writeln('  ],');
    sb.writeln('  "suggestions": [""],');
    sb.writeln('  "questions": [""],');
    sb.writeln('  "confidence": 0.0-1.0,');
    sb.writeln('  "retake_hint": ""');
    sb.writeln('}');
    return sb.toString();
  }

  Future<ParsedIntentResult> parseIntent(String userInput) async {
    await ensureInstalled();
    final prompt = _intentPrompt(userInput);
    final res = await _generateOnce(
      Message.text(text: prompt, isUser: true),
      enableVision: false,
    );
    return _extractAndParseJson(res);
  }

  String _imagePrompt({
    required String hint,
    String? targetName,
    String? targetStandard,
  }) {
    final sb = StringBuffer();
    sb.writeln('你是河狸云工序验收/巡检助手。请基于图片做离线识别，并用中文回答。');
    if (targetName != null && targetName.trim().isNotEmpty) {
      sb.writeln('当前检查点：$targetName');
    }
    if (targetStandard != null && targetStandard.trim().isNotEmpty) {
      sb.writeln('验收标准：$targetStandard');
    }
    sb.writeln('任务：$hint');
    sb.writeln();
    sb.writeln('请输出 3-6 行，包含：');
    sb.writeln('1) 图片内容概述');
    sb.writeln('2) 可能问题/风险（如有）');
    sb.writeln('3) 建议的处理/补充拍摄角度');
    return sb.toString();
  }

  Future<dynamic> _processImageOrThrow(String imagePath) async {
    final file = File(imagePath);
    final bytes = await file.readAsBytes();

    final mm = await MultimodalImageHandler.processImageForAI(
      imageBytes: Uint8List.fromList(bytes),
      modelType: _modelType,
      enableValidation: true,
      enableProcessing: true,
    );

    if (!mm.success || mm.processedImage == null) {
      final msg = mm.error?.message ?? '图片处理失败';
      throw StateError(msg);
    }
    return mm.processedImage!;
  }

  /// 自动判断图片是“文档/OCR”还是“现场缺陷/问题判断”，并返回用于记录的简短文本。
  ///
  /// 说明：为了保持离线与最小改动，本方法用 Gemma 多模态完成分类与抽取。
  /// 如果你们后续对 OCR 精度有硬要求，建议改成“专用 OCR + Gemma 做结构化”。
  Future<GemmaImageAnalysisResult> analyzeImageAutoStructured(
    String imagePath, {
    String? sceneHint,
    String hint = '请识别图片中的质量问题（如果有），并给出简短描述，便于记录。',
    String? targetName,
    String? targetStandard,
  }) async {
    await ensureInstalled();

    final processedImage = await _processImageOrThrow(imagePath);

    Map<String, dynamic>? classify;
    try {
      final prompt = _classifyPrompt(
        targetName: targetName,
        targetStandard: targetStandard,
        sceneHint: sceneHint,
      );
      final message = MultimodalImageHandler.createMultimodalMessage(
        text: prompt,
        processedImage: processedImage,
        modelType: _modelType,
        isUser: true,
      );
      final res = await _generateOnce(message, enableVision: true);
      classify = _extractJsonObject(res);
    } catch (_) {
      classify = null;
    }

    final modeRaw =
        classify == null ? '' : _readStringOrEmpty(classify, 'mode');
    final mode = (modeRaw == 'ocr' || modeRaw == 'defect' || modeRaw == 'other')
        ? modeRaw
        : 'defect';

    if (mode == 'ocr') {
      final prompt = _ocrPrompt(sceneHint: sceneHint);
      final message = MultimodalImageHandler.createMultimodalMessage(
        text: prompt,
        processedImage: processedImage,
        modelType: _modelType,
        isUser: true,
      );
      final res = await _generateOnce(message, enableVision: true);
      try {
        final obj = _extractJsonObject(res);
        final docType = _readStringOrEmpty(obj, 'doc_type');
        final conf = _readDouble01(obj, 'confidence');
        final rawText = _readStringOrEmpty(obj, 'raw_text');
        final retake = _readStringOrEmpty(obj, 'retake_hint');
        final fields =
            (obj['fields'] is Map) ? (obj['fields'] as Map) : const {};

        final questions = (obj['questions'] is List)
            ? (obj['questions'] as List)
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .take(6)
                .toList()
            : const <String>[];

        String readField(String key) {
          final v = fields[key];
          if (v == null) return '';
          return v.toString().trim();
        }

        final parts = <String>[
          '【文档识别】${docType.isEmpty ? 'OCR' : docType}（置信度 ${conf.toStringAsFixed(2)}）',
          if (readField('supplier').isNotEmpty) '供货单位：${readField('supplier')}',
          if (readField('material').isNotEmpty) '材料：${readField('material')}',
          if (readField('spec').isNotEmpty) '规格：${readField('spec')}',
          if (readField('batch_no').isNotEmpty) '批次：${readField('batch_no')}',
          if (readField('model').isNotEmpty) '型号：${readField('model')}',
          if (readField('serial_no').isNotEmpty) '编号：${readField('serial_no')}',
          if (readField('date').isNotEmpty) '日期：${readField('date')}',
          if (readField('project').isNotEmpty) '项目：${readField('project')}',
          if (rawText.trim().isNotEmpty) '原文：${rawText.trim()}',
          if (retake.trim().isNotEmpty) '补拍建议：${retake.trim()}',
        ];
        return GemmaImageAnalysisResult(
            text: parts.join('\n'), questions: questions);
      } catch (_) {
        return GemmaImageAnalysisResult(
            text: '【文档识别】\n${res.trim()}', questions: const []);
      }
    }

    // defect / other: default to defect-style guidance.
    final prompt = _defectPrompt(
      hint: hint,
      targetName: targetName,
      targetStandard: targetStandard,
      sceneHint: sceneHint,
    );
    final message = MultimodalImageHandler.createMultimodalMessage(
      text: prompt,
      processedImage: processedImage,
      modelType: _modelType,
      isUser: true,
    );
    final res = await _generateOnce(message, enableVision: true);

    try {
      final obj = _extractJsonObject(res);
      final summary = _readStringOrEmpty(obj, 'summary');
      final conf = _readDouble01(obj, 'confidence');
      final retake = _readStringOrEmpty(obj, 'retake_hint');

      final questions = (obj['questions'] is List)
          ? (obj['questions'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .take(6)
              .toList()
          : const <String>[];

      final defects =
          (obj['defects'] is List) ? (obj['defects'] as List) : const [];
      String formatDefects() {
        if (defects.isEmpty) return '';
        final lines = <String>[];
        for (final d in defects.take(3)) {
          if (d is! Map) continue;
          final type = (d['type'] ?? '').toString().trim();
          final sev = (d['severity'] ?? '').toString().trim();
          final ev = (d['evidence'] ?? '').toString().trim();
          if (type.isEmpty && ev.isEmpty) continue;
          final head = type.isEmpty ? '问题' : type;
          final sevText = sev.isEmpty ? '' : '（$sev）';
          lines.add('- $head$sevText${ev.isEmpty ? '' : '：$ev'}');
        }
        return lines.join('\n');
      }

      final suggestions = (obj['suggestions'] is List)
          ? (obj['suggestions'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[];

      final parts = <String>[
        '【缺陷判断】置信度 ${conf.toStringAsFixed(2)}',
        if (summary.isNotEmpty) '结论：$summary',
        if (formatDefects().isNotEmpty) '问题：\n${formatDefects()}',
        if (suggestions.isNotEmpty) '建议：${suggestions.take(3).join('；')}',
        if (retake.trim().isNotEmpty) '补拍建议：${retake.trim()}',
      ];
      return GemmaImageAnalysisResult(
          text: parts.join('\n'), questions: questions);
    } catch (_) {
      return GemmaImageAnalysisResult(
          text: '【缺陷判断】\n${res.trim()}', questions: const []);
    }
  }

  Future<String> analyzeImageAuto(
    String imagePath, {
    String? sceneHint,
    String hint = '请识别图片中的质量问题（如果有），并给出简短描述，便于记录。',
    String? targetName,
    String? targetStandard,
  }) async {
    final r = await analyzeImageAutoStructured(
      imagePath,
      sceneHint: sceneHint,
      hint: hint,
      targetName: targetName,
      targetStandard: targetStandard,
    );
    return r.text;
  }

  Future<String> analyzeImageFile(
    String imagePath, {
    required String hint,
    String? targetName,
    String? targetStandard,
  }) async {
    await ensureInstalled();

    final processedImage = await _processImageOrThrow(imagePath);

    final prompt = _imagePrompt(
      hint: hint,
      targetName: targetName,
      targetStandard: targetStandard,
    );

    final message = MultimodalImageHandler.createMultimodalMessage(
      text: prompt,
      processedImage: processedImage,
      modelType: _modelType,
      isUser: true,
    );

    final res = await _generateOnce(message, enableVision: true);

    // Best-effort corruption detection.
    try {
      final validation = MultimodalImageHandler.validateModelResponse(
        res,
        originalPrompt: prompt,
        processedImage: processedImage,
      );
      if (!validation.isValid && validation.isCorrupted) {
        return '（识别结果疑似异常，建议重拍）\n$res';
      }
    } catch (_) {}

    return res.trim();
  }

  Future<void> dispose() async {
    final model = _model;
    _model = null;
    if (model != null) {
      try {
        await model.close();
      } catch (_) {}
    }
  }
}

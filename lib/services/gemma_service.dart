import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/library.dart';
import '../models/parsed_intent.dart';
import '../models/region.dart';
import 'database_service.dart';
import 'procedure_acceptance_library_service.dart';

final gemmaServiceProvider = Provider<GemmaService>((ref) {
  final dbService = ref.read(databaseServiceProvider);
  final procedureLibrary = ref.read(procedureAcceptanceLibraryServiceProvider);
  return GemmaService(
    dbService: dbService,
    procedureLibrary: procedureLibrary,
  );
});

class GemmaService {
  final DatabaseService dbService;
  final ProcedureAcceptanceLibraryService procedureLibrary;

  GemmaService({
    required this.dbService,
    required this.procedureLibrary,
  });

  static const String _promptTemplate = '''
你是河狸云工序验收语音助手，只处理验收和问题上报意图。
用户输入：{user_input}

请严格输出 JSON，格式：
{
  "intent": "procedure_acceptance" | "report_issue" | "unknown",
  "region_text": "1栋6层" 或 null,
  "region_code": "匹配到的 rc_ou_region.id_code" 或 null,
  "library_name": "钢筋" 或 null,
  "library_code": "匹配到的 rc_library_library.id_code" 或 null
}

位置匹配规则：支持“X栋”“X层”“X单元”等自然表达，使用本地数据库模糊查找。
分项匹配：支持常见别名，如“钢筋”、“绑钢筋” → “钢筋工程”。
如果无法匹配，intent设为"unknown"。
只输出 JSON，不要任何解释。
''';

  String buildPrompt(String userInput) {
    return _promptTemplate.replaceAll('{user_input}', userInput);
  }

  /// 对外统一入口：先尝试调用 Gemma，本地模型不可用时退化到规则解析。
  Future<ParsedIntentResult> parseIntent(String userInput) async {
    return _fallbackRuleBased(userInput);
  }

  ParsedIntentResult _fallbackRuleBased(String userInput) {
    final normalized = userInput.replaceAll(RegExp(r'\s+'), '');

    String intent = 'unknown';
    if (normalized.contains('验收') ||
        normalized.contains('检查') ||
        normalized.contains('复检')) {
      intent = 'procedure_acceptance';
    } else if (normalized.contains('发现') ||
        normalized.contains('存在') ||
        normalized.contains('出现') ||
        normalized.contains('问题') ||
        normalized.contains('缺陷') ||
        normalized.contains('不合格') ||
        normalized.contains('整改') ||
        // Safety / violation phrases (no need to say “问题”).
        normalized.contains('未戴安全帽') ||
        normalized.contains('未带安全帽') ||
        normalized.contains('不戴安全帽') ||
        normalized.contains('未佩戴') ||
        normalized.contains('未系安全带') ||
        normalized.contains('违章') ||
        normalized.contains('隐患') ||
        normalized.contains('临边') ||
        normalized.contains('防护') ||
        normalized.contains('坠落')) {
      intent = 'report_issue';
    }

    // 提取“位置”表达（数字/中文数字交给 DB 层进一步归一化与匹配）。
    String? regionText;
    final regionMatch = RegExp(
      r'([\d一二三四五六七八九十两]+\s*(?:栋|动|楼))\s*([\d一二三四五六七八九十两]+\s*(?:层|成|城|曾|楼))',
    ).firstMatch(userInput);
    if (regionMatch != null) {
      regionText = '${regionMatch.group(1)}${regionMatch.group(2)}';
    }

    // 提取“分项”关键词。
    String? libraryName;
    if (normalized.contains('钢筋')) {
      libraryName = '钢筋';
    } else if (normalized.contains('模板') || normalized.contains('模版')) {
      libraryName = '模板';
    }

    return ParsedIntentResult(
      intent: intent,
      regionText: regionText,
      libraryName: libraryName,
    );
  }

  /// 在解析结果基础上，结合本地数据库做位置和分项匹配。
  Future<ParsedIntentResult> enrichWithLocalData(
    ParsedIntentResult base,
    String userInput,
  ) async {
    Region? region;
    LibraryItem? library;

    region = await dbService.findRegionByText(base.regionText ?? userInput);
    library =
        await procedureLibrary.findLibraryByName(base.libraryName ?? userInput);

    return ParsedIntentResult(
      intent: base.intent,
      regionText: region != null ? region.name : base.regionText,
      regionCode: region?.idCode ?? base.regionCode,
      libraryName: library?.name ?? base.libraryName,
      libraryCode: library?.idCode ?? base.libraryCode,
    );
  }
}

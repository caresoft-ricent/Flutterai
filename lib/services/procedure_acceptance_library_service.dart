import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/library.dart';
import '../models/target.dart';
import '../utils/localized_assets.dart';
import 'database_service.dart';

final procedureAcceptanceLibraryServiceProvider =
    Provider<ProcedureAcceptanceLibraryService>((ref) {
  return ProcedureAcceptanceLibraryService(
    dbService: ref.read(databaseServiceProvider),
  );
});

class ProcedureAcceptanceLibraryService {
  static const String _assetPath =
      'assets/acceptance_library/procedure_simplified.json';

  final DatabaseService dbService;

  ProcedureAcceptanceLibraryService({required this.dbService});

  Future<void>? _loadFuture;
  Locale? _loadedLocale;
  final List<_ProcedureLibraryItem> _items = [];
  final Map<String, _ProcedureLibraryItem> _byCode = {};
  final Map<String, List<TargetItem>> _targetsByCode = {};

  Future<void> _ensureLoaded({Locale? locale}) {
    final effectiveLocale = locale ?? _loadedLocale;
    if (_loadFuture != null && _loadedLocale == effectiveLocale) {
      return _loadFuture!;
    }
    _loadedLocale = effectiveLocale;
    return _loadFuture = _loadFromAssets(locale: effectiveLocale);
  }

  Future<void> _loadFromAssets({Locale? locale}) async {
    final raw = (locale == null)
        ? await rootBundle.loadString(_assetPath)
        : await loadStringLocalized(_assetPath, locale: locale);
    final decoded = json.decode(raw);
    if (decoded is! List) {
      throw StateError('$_assetPath: expected a JSON list');
    }

    _items.clear();
    _byCode.clear();
    _targetsByCode.clear();

    // New structure: each row is a single target under a library.
    // Fields: CateName / ChildCateName / LibraryName / TargetName / Remark.
    // We group rows by (CateName, ChildCateName, LibraryName).
    final Map<String, _ProcedureLibraryItem> grouped = {};
    final Map<String, List<TargetItem>> groupedTargets = {};
    final Map<String, String> groupKeyToCode = {};
    var groupCount = 0;

    for (var i = 0; i < decoded.length; i++) {
      final row = decoded[i];
      if (row is! Map) continue;

      final cateName = (row['CateName'] ?? '').toString().trim();
      final childCateName = (row['ChildCateName'] ?? '').toString().trim();
      final libraryName = (row['LibraryName'] ?? '').toString().trim();
      final targetName = (row['TargetName'] ?? '').toString().trim();
      final remark = (row['Remark'] ?? '').toString();

      // Backward-compat: old structure had no TargetName and put all indicators in Remark.
      final hasTargetName = targetName.isNotEmpty;

      if (libraryName.isEmpty) continue;

      final groupKey = '$cateName||$childCateName||$libraryName';
      var code = groupKeyToCode[groupKey];
      if (code == null) {
        code = _procedureCode(groupCount);
        groupKeyToCode[groupKey] = code;
        groupCount++;

        final displayName = childCateName.isEmpty && cateName.isEmpty
            ? libraryName
            : '$libraryName（${cateName.isEmpty ? '未分类' : cateName}/${childCateName.isEmpty ? '未分项' : childCateName}）';

        final library = LibraryItem(id: '', idCode: code, name: displayName);
        final item = _ProcedureLibraryItem(
          cateName: cateName,
          childCateName: childCateName,
          libraryName: libraryName,
          library: library,
          normalizedKeys:
              _buildNormalizedKeys(cateName, childCateName, libraryName),
        );
        grouped[code] = item;
        groupedTargets[code] = <TargetItem>[];
      }

      final targets = groupedTargets[code]!;

      if (hasTargetName) {
        targets.add(
          TargetItem(
            id: '',
            idCode: _targetCode(code, targets.length),
            libraryCode: code,
            name: targetName,
            description: _cleanDescription(remark),
          ),
        );
      } else {
        // Old format: split remark into multiple indicators.
        final indicators = _splitRemarkToIndicators(remark);
        for (final indicator in indicators) {
          if (indicator.trim().isEmpty) continue;
          targets.add(
            TargetItem(
              id: '',
              idCode: _targetCode(code, targets.length),
              libraryCode: code,
              name: '指标${targets.length + 1}',
              description: indicator,
            ),
          );
        }
      }
    }

    for (final entry in grouped.entries) {
      final code = entry.key;
      final item = entry.value;
      final targets = groupedTargets[code] ?? const <TargetItem>[];
      _items.add(item);
      _byCode[code] = item;
      _targetsByCode[code] = targets;
    }
  }

  Future<LibraryItem?> getLibraryByCode(String code) async {
    await _ensureLoaded();
    final hit = _byCode[code];
    if (hit != null) return hit.library;
    return dbService.getLibraryByCode(code);
  }

  Future<List<TargetItem>> getTargetsByLibraryCode(String libraryCode) async {
    await _ensureLoaded();
    final hit = _targetsByCode[libraryCode];
    if (hit != null) return hit;
    return dbService.getTargetsByLibraryCode(libraryCode);
  }

  /// 通过验收库 code 反查分部/子分部（仅对 assets/procedure_simplified.json 内生成的 Pxxxx 有效）。
  /// 若 code 不存在于 assets（例如数据库里的 A001/A002），返回 null。
  Future<({String category, String subcategory})?> getCategoryPathByLibraryCode(
      String libraryCode) async {
    await _ensureLoaded();
    final hit = _byCode[libraryCode];
    if (hit == null) return null;
    return (category: hit.cateName, subcategory: hit.childCateName);
  }

  Future<void> ensureLoaded({Locale? locale}) async {
    await _ensureLoaded(locale: locale);
  }

  Future<List<LibraryItem>> getAllLibraries() async {
    await _ensureLoaded();
    return _items.map((item) => item.library).toList();
  }

  Future<List<String>> getCategories() async {
    await _ensureLoaded();
    final categories = _items.map((item) => item.cateName).toSet().toList();
    categories.sort();
    return categories;
  }

  Future<List<String>> getSubcategories(String category) async {
    await _ensureLoaded();
    final subcategories = _items
        .where((item) => item.cateName == category)
        .map((item) => item.childCateName)
        .toSet()
        .toList();
    subcategories.sort();
    return subcategories;
  }

  Future<List<LibraryItem>> getLibraries(
      String category, String subcategory) async {
    await _ensureLoaded();
    final libraries = _items
        .where((item) =>
            item.cateName == category && item.childCateName == subcategory)
        .map((item) => item.library)
        .toList();
    libraries.sort((a, b) => a.name.compareTo(b.name));
    return libraries;
  }

  /// 尝试从“工序验收库(assets)”里匹配更细分的工序（如“地下室底板钢筋验收”）。
  /// 若无法匹配，再回落到数据库里“钢筋工程/模板工程”等粗粒度分项。
  Future<LibraryItem?> findLibraryByName(String text) async {
    await _ensureLoaded();

    final normalized = _normalizeText(text);
    if (normalized.isEmpty) return dbService.findLibraryByName(text);

    _ProcedureLibraryItem? best;
    var bestScore = 0;
    var bestTargetCount = -1;

    for (final item in _items) {
      final score = _scoreMatch(normalized, item);
      if (score <= 0) continue;

      // Prefer more specific match; if tie, prefer larger target set.
      final targetCount = _targetsByCode[item.library.idCode]?.length ?? 0;
      if (score > bestScore ||
          (score == bestScore && targetCount > bestTargetCount)) {
        bestScore = score;
        bestTargetCount = targetCount;
        best = item;
      }
    }

    // 经验阈值：命中 libraryName / childCateName / cateName 任一关键字。
    if (best != null && bestScore >= 40) {
      return best.library;
    }

    // 对“钢筋/模板”这类极短泛词，为了让语音验收能自动带出分部/子分部，
    // 允许采用 assets 中的一个“默认最匹配”分项（按 targets 数量优先）。
    final generic = normalized;
    final isGeneric = generic == '钢筋' || generic == '模板' || generic == '模版';
    if (best != null && isGeneric && bestScore >= 35) {
      return best.library;
    }

    return dbService.findLibraryByName(text);
  }

  int _scoreMatch(String normalizedInput, _ProcedureLibraryItem item) {
    var score = 0;

    bool hasCjk(String s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s);

    double diceCoefficient(String a, String b) {
      if (a.isEmpty || b.isEmpty) return 0;
      if (a == b) return 1;

      Set<String> grams2(String s) {
        final out = <String>{};
        for (var i = 0; i < s.length - 1; i++) {
          out.add(s.substring(i, i + 2));
        }
        return out;
      }

      // For very short tokens, fall back to char overlap.
      if (a.length < 2 || b.length < 2) return 0;
      if (a.length == 2 || b.length == 2) {
        final sa = a.split('').toSet();
        final sb = b.split('').toSet();
        return sa.intersection(sb).length /
            (sa.length > sb.length ? sa.length : sb.length);
      }

      final ga = grams2(a);
      final gb = grams2(b);
      if (ga.isEmpty || gb.isEmpty) return 0;
      final inter = ga.intersection(gb).length;
      return (2 * inter) / (ga.length + gb.length);
    }

    for (final key in item.normalizedKeys) {
      if (key.isEmpty) continue;
      if (normalizedInput.contains(key)) {
        // Longer keys indicate more specific match.
        score = score < 100 + key.length ? 100 + key.length : score;
      } else {
        // Fuzzy match: tolerate minor ASR errors / missing characters.
        // Only apply to meaningful CJK phrases to avoid noisy matches.
        if (key.length >= 3 && hasCjk(key) && hasCjk(normalizedInput)) {
          final d = diceCoefficient(normalizedInput, key);
          if (d >= 0.62) {
            final s = (80 * d).round() + key.length;
            score = score < s ? s : score;
          }
        }
      }
    }

    // Weak match: if only mentions 钢筋/模板 and the libraryName also contains it.
    if (score == 0) {
      final hasSteel = normalizedInput.contains('钢筋');
      final hasForm =
          normalizedInput.contains('模板') || normalizedInput.contains('模版');
      final libNorm = _normalizeText(item.libraryName);
      if (hasSteel && libNorm.contains('钢筋')) score = 35;
      if (hasForm && (libNorm.contains('模板') || libNorm.contains('模版'))) {
        score = score < 35 ? 35 : score;
      }

      // Extra fuzzy fallback for very common phrases like “绑扎钢筋/钢筋绑扎”.
      if (score == 0 && hasCjk(normalizedInput) && hasCjk(libNorm)) {
        final d = diceCoefficient(normalizedInput, libNorm);
        if (d >= 0.70) {
          score = (55 * d).round();
        }
      }
    }

    // Boost if input also mentions the subcategory.
    final childKey = _normalizeText(item.childCateName);
    if (childKey.isNotEmpty && normalizedInput.contains(childKey)) {
      score += 20;
    }

    final cateKey = _normalizeText(item.cateName);
    if (cateKey.isNotEmpty && normalizedInput.contains(cateKey)) {
      score += 10;
    }

    return score;
  }

  static String _procedureCode(int index) {
    final n = index + 1;
    return 'P${n.toString().padLeft(4, '0')}';
  }

  static String _targetCode(String libraryCode, int targetIndex) {
    return '$libraryCode${(targetIndex + 1).toString().padLeft(3, '0')}';
  }

  static List<String> _buildNormalizedKeys(
    String cateName,
    String childCateName,
    String libraryName,
  ) {
    final keys = <String>{};

    void addKey(String s) {
      final v = _normalizeText(s);
      if (v.isNotEmpty) keys.add(v);
    }

    // Most specific first.
    addKey(libraryName);
    addKey(libraryName.replaceAll('验收', ''));
    addKey(childCateName);
    addKey(cateName);

    // Combined keys help when user speaks “结构工程地下室底板钢筋验收”.
    addKey('$childCateName$libraryName');
    addKey('$cateName$childCateName$libraryName');

    return keys.toList(growable: false);
  }

  static String _normalizeText(String input) {
    var text = input.trim();
    text = text.replaceAll(RegExp(r'\s+'), '');

    // Conservative homophone fixes.
    text = text.replaceAll('刚进', '钢筋');
    text = text.replaceAll('刚劲', '钢筋');
    text = text.replaceAll('干净', '钢筋');
    text = text.replaceAll('模版', '模板');

    // Strip some common filler words.
    text = text.replaceAll('我要', '');
    text = text.replaceAll('进行', '');
    text = text.replaceAll('开始', '');
    text = text.replaceAll('一下', '');
    text = text.replaceAll('的', '');

    return text;
  }

  static List<String> _splitRemarkToIndicators(String remarkRaw) {
    var text = remarkRaw;
    text = text.replaceAll('\r', '\n');
    text = text.replaceAll(RegExp(r'[\t\u3000]+'), ' ');
    text = text.replaceAll(RegExp(r'\n+'), '\n');
    text = text.trim();
    if (text.isEmpty) return const [];

    // Primary: 1、2、3、 or 1.2.
    final markers = RegExp(r'(?:^|[\s\n。；;])\d{1,3}[、\.．]\s*')
        .allMatches(text)
        .toList(growable: false);

    if (markers.length >= 2) {
      final parts = <String>[];
      for (var i = 0; i < markers.length; i++) {
        final start = markers[i].end;
        final end =
            (i + 1 < markers.length) ? markers[i + 1].start : text.length;
        final seg = text.substring(start, end);
        final cleaned = _cleanIndicator(seg);
        if (cleaned.isNotEmpty) parts.add(cleaned);
      }
      if (parts.isNotEmpty) return parts;
    }

    // Fallback: try splitting by newlines or sentence-ending punctuation.
    final rough = text
        .split(RegExp(r'[\n。；;]+'))
        .map(_cleanIndicator)
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return rough;
  }

  static String _cleanIndicator(String seg) {
    var s = seg.trim();
    s = s.replaceAll(RegExp(r'^[\s\n。；;、]+'), '');
    s = s.replaceAll(RegExp(r'[\s\n]+'), ' ');
    s = s.trim();
    return s;
  }

  static String _cleanDescription(String raw) {
    var s = raw;
    s = s.replaceAll('\r', '\n');
    s = s.replaceAll(RegExp(r'[\t\u3000]+'), ' ');
    s = s.replaceAll(RegExp(r'\n+'), '\n');
    s = s.trim();
    return s;
  }
}

class _ProcedureLibraryItem {
  final String cateName;
  final String childCateName;
  final String libraryName;
  final LibraryItem library;
  final List<String> normalizedKeys;

  _ProcedureLibraryItem({
    required this.cateName,
    required this.childCateName,
    required this.libraryName,
    required this.library,
    required this.normalizedKeys,
  });
}

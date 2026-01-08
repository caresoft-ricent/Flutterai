import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final defectLibraryServiceProvider = Provider<DefectLibraryService>((ref) {
  return DefectLibraryService();
});

enum DefectSource {
  quality,
  safety,
}

class DefectLibraryEntry {
  final String id;
  final DefectSource source;

  final String division; // 分部名称
  final String subDivision; // 子分部名称
  final String item; // 分项名称
  final String indicator; // 指标名称

  final String levelRaw; // 问题级别 (原始)
  final int? deadlineDays; // 整改天数
  final String suggestion; // 整改建议

  const DefectLibraryEntry({
    required this.id,
    required this.source,
    required this.division,
    required this.subDivision,
    required this.item,
    required this.indicator,
    required this.levelRaw,
    required this.deadlineDays,
    required this.suggestion,
  });

  String get levelNormalized {
    final s = levelRaw.trim();
    if (s.contains('严重')) return '严重';
    if (s.contains('一般')) return '一般';

    // Many safety libraries use numeric levels (e.g., 1/2/3). We map conservatively.
    final n = int.tryParse(s);
    if (n != null) {
      // 1 is typically the most severe.
      return n <= 1 ? '严重' : '一般';
    }

    return '一般';
  }

  String get deadlineLabel {
    final d = deadlineDays;
    if (d == null || d <= 0) return '';
    return '$d天';
  }

  String toPromptLine() {
    // Keep this compact to reduce tokens.
    final src = source == DefectSource.safety ? '安全' : '质量';
    final lvl = levelNormalized;
    final days = deadlineDays == null ? '' : ' / $deadlineDays天';
    return '$id | $src | $lvl$days | $division / $subDivision / $item | $indicator';
  }

  String searchableText() {
    return '$division $subDivision $item $indicator'.toLowerCase();
  }
}

class DefectLibraryService {
  static const _qualityAsset = 'assets/defect_library/6.质量巡检体系.json';
  static const _safetyAsset = 'assets/defect_library/8.安全巡检体系.json';

  List<DefectLibraryEntry>? _entries;
  Map<String, DefectLibraryEntry>? _byId;
  Future<void>? _loading;

  Future<void> ensureLoaded() {
    if (_entries != null) return Future.value();
    return _loading ??= _load();
  }

  List<DefectLibraryEntry> get entries {
    final e = _entries;
    return e ?? const [];
  }

  DefectLibraryEntry? byId(String id) {
    final m = _byId;
    if (m == null) return null;
    return m[id];
  }

  List<DefectLibraryEntry> suggest({
    required String query,
    int limit = 30,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return entries.take(limit).toList();
    }

    int score(DefectLibraryEntry e) {
      final t = e.searchableText();
      var s = 0;
      // Phrase match (works when query already contains indicator keywords).
      if (t.contains(q)) s += 30;

      // Token match: supports Chinese without whitespace by generating n-grams.
      for (final token in _tokens(q)) {
        if (token.length < 2) continue;
        if (!t.contains(token)) continue;

        // Weight by token length: n-grams are shorter so score them lower.
        if (token.length >= 6) {
          s += 12;
        } else if (token.length >= 4) {
          s += 10;
        } else if (token.length == 3) {
          s += 6;
        } else {
          // 2-char token
          s += 3;
        }
      }
      return -s; // sort ascending
    }

    final copy = [...entries];
    copy.sort((a, b) => score(a).compareTo(score(b)));
    return copy.take(limit).toList();
  }

  Iterable<String> _tokens(String q) sync* {
    // Split by common separators.
    final parts = q
        .split(RegExp(r'[\s,，。；;、/\\\-|_]+'))
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty);

    for (final part in parts) {
      yield part;

      // For CJK text without spaces, also generate short n-grams so we can
      // match keywords like "混凝土" against indicator strings.
      if (_hasCjk(part) && part.length >= 4) {
        yield* _cjkNgrams(part, n: 3, maxCount: 60);
        yield* _cjkNgrams(part, n: 2, maxCount: 80);
      }
    }
  }

  bool _hasCjk(String s) {
    return RegExp(r'[\u4E00-\u9FFF]').hasMatch(s);
  }

  Iterable<String> _cjkNgrams(
    String s, {
    required int n,
    required int maxCount,
  }) sync* {
    if (n <= 1) return;
    if (s.length < n) return;

    var count = 0;
    for (var i = 0; i <= s.length - n; i++) {
      final gram = s.substring(i, i + n);
      // Skip grams with spaces or punctuation-like characters.
      if (RegExp(r'[\s,，。；;、/\\\-|_]').hasMatch(gram)) continue;
      yield gram;
      count++;
      if (count >= maxCount) return;
    }
  }

  Future<void> _load() async {
    final quality = await _loadOne(_qualityAsset, DefectSource.quality);
    final safety = await _loadOne(_safetyAsset, DefectSource.safety);

    final all = <DefectLibraryEntry>[...quality, ...safety];
    _entries = all;

    final map = <String, DefectLibraryEntry>{
      for (final e in all) e.id: e,
    };
    _byId = map;
  }

  Future<List<DefectLibraryEntry>> _loadOne(
    String assetPath,
    DefectSource source,
  ) async {
    final raw = await rootBundle.loadString(assetPath);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const [];

    final sheets = decoded['sheets'];
    if (sheets is! Map) return const [];

    // Our generated file uses a single sheet called Sheet0.
    final sheet0 = sheets.values.isEmpty ? null : sheets.values.first;
    if (sheet0 is! List) return const [];

    final out = <DefectLibraryEntry>[];
    for (final row in sheet0) {
      if (row is! Map) continue;

      final serial = (row['序号'] ?? '').toString().trim();
      final division = (row['分部名称'] ?? '').toString().trim();
      final sub = (row['子分部名称'] ?? '').toString().trim();
      final item = (row['分项名称'] ?? '').toString().trim();
      final indicator = (row['指标名称'] ?? '').toString().trim();
      final level = (row['问题级别'] ?? '').toString().trim();
      final suggestion = (row['整改建议'] ?? '').toString().trim();
      final daysStr = (row['整改天数'] ?? '').toString().trim();
      final days = int.tryParse(daysStr);

      if (indicator.isEmpty && item.isEmpty) continue;

      // Stable id: source prefix + serial (falls back to hash if missing).
      final prefix = source == DefectSource.safety ? 'S' : 'Q';
      final id = serial.isNotEmpty
          ? '$prefix-$serial'
          : '$prefix-${(division + sub + item + indicator).hashCode.abs()}';

      out.add(
        DefectLibraryEntry(
          id: id,
          source: source,
          division: division,
          subDivision: sub,
          item: item,
          indicator: indicator,
          levelRaw: level,
          deadlineDays: days,
          suggestion: suggestion,
        ),
      );
    }

    return out;
  }
}

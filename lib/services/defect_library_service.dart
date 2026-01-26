import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/localized_assets.dart';

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
  static const bool _debugMatch =
      bool.fromEnvironment('DEFECT_MATCH_DEBUG', defaultValue: false);

  static const double _bm25K1 = 1.2;
  static const double _bm25B = 0.75;
  static const double _wIndicator = 2.2;
  static const double _wHierarchy = 1.0;

  static const _qualityAsset = 'assets/defect_library/6.质量巡检体系.json';
  static const _safetyAsset = 'assets/defect_library/8.安全巡检体系.json';

  List<DefectLibraryEntry>? _entries;
  Map<String, DefectLibraryEntry>? _byId;
  Future<void>? _loading;

  Locale? _loadedLocale;

  _Bm25Index? _bm25;

  Future<void> ensureLoaded({Locale? locale}) {
    final effectiveLocale = locale ?? _loadedLocale;
    final loading = _loading;
    if (_entries != null && _loadedLocale == effectiveLocale) {
      return Future.value();
    }
    if (loading != null && _loadedLocale == effectiveLocale) {
      return loading;
    }
    _loadedLocale = effectiveLocale;
    final future = _load(locale: effectiveLocale);
    _loading = future;
    return future;
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
    final raw = query.trim().toLowerCase();
    if (raw.isEmpty) {
      return entries.take(limit).toList();
    }

    final q = _normalizeForSearch(raw);
    final stop = _stopTokens;

    int weightByLen(int len) {
      if (len >= 6) return 10;
      if (len >= 4) return 8;
      if (len == 3) return 5;
      return 3; // 2-char token
    }

    bool isStrongToken(String t) {
      if (t.length < 2 || t.length > 6) return false;
      if (stop.contains(t)) return false;
      // Skip pure numbers / obvious region parts.
      if (RegExp(r'^\d+$').hasMatch(t)) return false;
      if (RegExp(r'^\d+(?:栋|楼|层|#)$').hasMatch(t)) return false;
      return _hasCjk(t);
    }

    final expandedTokens = <String>{
      ..._tokens(raw).map(_normalizeForSearch),
      ..._tokens(q).map(_normalizeForSearch),
      ..._expandQueryTokens(raw).map(_normalizeForSearch),
    }..removeWhere((t) => t.isEmpty);

    // Query terms for BM25: include n-grams from normalized query + expanded tokens.
    final qTerms = <String, int>{};
    void addQTerm(String t, {int w = 1}) {
      final term = t.trim();
      if (term.isEmpty) return;
      if (term.length < 2) return;
      if (stop.contains(term)) return;
      qTerms[term] = (qTerms[term] ?? 0) + w;
    }

    for (final t in expandedTokens) {
      addQTerm(t);
      if (isStrongToken(t)) addQTerm(t);
    }
    for (final t in _indexTermsFromNormalized(q, max2: 120, max3: 120)) {
      addQTerm(t);
    }
    if (q.length >= 2 && q.length <= 8) addQTerm(q, w: 2);

    int score(DefectLibraryEntry e) {
      final indicator = _normalizeForSearch(e.indicator);
      final itemNorm = _normalizeForSearch(e.item);
      final subNorm = _normalizeForSearch(e.subDivision);
      final hierarchy =
          _normalizeForSearch('${e.division} ${e.subDivision} ${e.item}');
      final all = _normalizeForSearch(
          '${e.division} ${e.subDivision} ${e.item} ${e.indicator}');

      var s = 0;

      // Strong phrase match.
      if (q.length >= 2 && indicator.contains(q)) s += 120;
      if (q.length >= 2 && all.contains(q)) s += 50;

      // Token match (indicator weighted higher).
      final strong = <String>{};
      var strongHit = 0;
      for (final token0 in expandedTokens) {
        final token = token0.trim();
        if (token.length < 2) continue;
        if (stop.contains(token)) continue;

        final inInd = indicator.contains(token);
        final inAll = all.contains(token);
        if (inInd) {
          s += weightByLen(token.length) * 3;
        } else if (inAll) {
          // Give some credit for matching division/sub/item even when indicator differs.
          s += weightByLen(token.length);
        }

        if (isStrongToken(token)) {
          if (strong.add(token) && inInd) strongHit++;
        }
      }

      // Heuristic: for short defect phrases (e.g., "露筋"), prefer entries whose
      // subdivision/item also contains the keyword (more specific category), and
      // avoid entries where the keyword only appears inside a long list-style
      // indicator (common source of false positives such as "防水基层处理" rows).
      if (strong.length == 1) {
        final only = strong.first;
        if (only.length <= 3) {
          final inItem = itemNorm.contains(only);
          final inSub = subNorm.contains(only);
          if (inItem) s += 40;
          if (!inItem && inSub) s += 18;

          // Penalize list-style indicators when the keyword isn't part of item/subdivision.
          // We detect list separators on the raw indicator text (not normalized).
          final rawInd = e.indicator;
          final looksLikeList = rawInd.contains('、') ||
              rawInd.contains('，') ||
              rawInd.contains(',') ||
              rawInd.contains('；') ||
              rawInd.contains(';');
          if (!inItem && !inSub && looksLikeList && indicator.contains(only)) {
            s -= 28;
          }
        }
      }

      // Bonus when multiple strong keywords all appear in indicator.
      if (strong.length >= 2) {
        final allHit = strong.where(indicator.contains).length;
        if (allHit == strong.length) {
          s += 30;
        } else {
          s += allHit * 6;
        }
      }

      // Honeycomb/pitted concrete: users say "蜂窝麻面" but the library tends to
      // label it under "孔洞蜂窝" / "蜂窝、疏松".
      final queryHoneycomb =
          q.contains('蜂窝') && (q.contains('麻面') || q.contains('蜂窝麻面'));
      if (queryHoneycomb) {
        if (itemNorm.contains('孔洞蜂窝')) s += 80;
        if (indicator.contains('蜂窝') && indicator.contains('疏松')) s += 40;

        // If query is not about leakage, down-weight leakage-related categories
        // that merely mention honeycomb in a list.
        final queryLeak = q.contains('渗漏') || q.contains('漏水');
        final entryLeak = subNorm.contains('渗漏') || itemNorm.contains('渗漏');
        if (!queryLeak && entryLeak && indicator.contains('蜂窝')) {
          s -= 25;
        }
      }

      // Small preference: indicators that are closer in length to the query.
      final diff = (indicator.length - q.length).abs();
      s -= diff.clamp(0, 20);

      // If indicator doesn't contain any strong keyword at all, slightly penalize.
      if (strong.isNotEmpty && strongHit == 0) {
        s -= 8;
      }

      // Prefer indicator matches over only-hierarchy matches.
      if (s > 0 && hierarchy.contains(q) && !indicator.contains(q)) {
        s -= 5;
      }

      return s;
    }

    final bm25 = _bm25;
    double bm25ScoreFor(DefectLibraryEntry e) {
      if (bm25 == null) return 0;
      return bm25.score(
        entryId: e.id,
        queryTerms: qTerms,
      );
    }

    final scored = <({DefectLibraryEntry e, int hs, double bs, double fs})>[];
    for (final e in entries) {
      final hs = score(e);
      final bs = bm25ScoreFor(e);
      // Combine: BM25 is primary signal; heuristics are domain constraints.
      final fs = bs * 100.0 + hs;
      scored.add((e: e, hs: hs, bs: bs, fs: fs));
    }

    scored.sort((a, b) {
      if (a.fs != b.fs) return b.fs.compareTo(a.fs);

      final ia = _normalizeForSearch(a.e.indicator).contains(q);
      final ib = _normalizeForSearch(b.e.indicator).contains(q);
      if (ia != ib) return ia ? -1 : 1;

      return a.e.id.compareTo(b.e.id);
    });

    if (_debugMatch) {
      debugPrint('[DefectMatch] query="$query" norm="$q"');
      final strongTokens = expandedTokens.where(isStrongToken).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      debugPrint(
          '[DefectMatch] strongTokens=${strongTokens.take(12).toList()}');
      debugPrint('[DefectMatch] bm25Terms=${qTerms.keys.take(20).toList()}');
      for (final it in scored.take(5)) {
        final e = it.e;
        debugPrint(
          '[DefectMatch] final=${it.fs.toStringAsFixed(2)} bm25=${it.bs.toStringAsFixed(3)} heur=${it.hs} id=${e.id} :: ${e.division} / ${e.subDivision} / ${e.item} | ${e.indicator}',
        );
      }
    }

    return scored.take(limit).map((x) => x.e).toList();
  }

  Iterable<String> _indexTermsFromNormalized(
    String s, {
    required int max2,
    required int max3,
  }) sync* {
    final t = s.trim();
    if (t.isEmpty) return;

    if (_hasCjk(t)) {
      // Exact short phrase helps with very short queries.
      if (t.length >= 2 && t.length <= 6) {
        yield t;
      }
      yield* _cjkNgrams(t, n: 2, maxCount: max2);
      yield* _cjkNgrams(t, n: 3, maxCount: max3);
      return;
    }

    // Basic ASCII fallback (rare in this domain).
    for (final m in RegExp(r'[a-z0-9]{2,}').allMatches(t)) {
      yield m.group(0)!;
    }
  }

  static const _stopTokens = <String>{
    '日常巡检',
    '巡检',
    '验收',
    '发现',
    '存在',
    '出现',
    '问题',
    '隐患',
    '说明',
    '类型',
    '严重程度',
    '整改',
    '建议',
    '请',
    '重拍',
    '施工',
    '现场',
    '照片',
    '拍照',
    '部位',
    '位置',
  };

  String _normalizeForSearch(String input) {
    // Remove spaces and common punctuation so "蜂窝、麻面" and "蜂窝麻面" match.
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[，,。.;；、/\\\-|_]+'), '');
  }

  Iterable<String> _expandQueryTokens(String raw) sync* {
    final s = _normalizeForSearch(raw);
    if (s.isEmpty) return;

    // STT variants for "麻面".
    final hasMaMian = s.contains('麻面') || s.contains('满面') || s.contains('马面');
    final hasFengWo = s.contains('蜂窝');

    // Common defect phrases -> helpful extra keywords.
    if (s.contains('蜂窝麻面') || (hasFengWo && hasMaMian)) {
      yield '蜂窝麻面';
      yield '蜂窝';
      yield '麻面';
      yield '混凝土';

      // The library often records this as "孔洞蜂窝" / "蜂窝、疏松" rather than "麻面".
      yield '孔洞蜂窝';
      yield '孔洞';
      yield '疏松';
    }
    if (s.contains('蜂窝')) {
      yield '蜂窝';
      yield '混凝土';
      yield '孔洞蜂窝';
      yield '疏松';
    }
    if (s.contains('麻面')) {
      yield '麻面';
      yield '混凝土';
      // In this library, "麻面" is closer to "疏松/蜂窝" category.
      yield '疏松';
      yield '孔洞蜂窝';
    }
    if (s.contains('露筋') || s.contains('钢筋外露')) {
      yield '露筋';
      yield '钢筋外露';
      yield '钢筋';
    }

    // STT homophones: "漏筋" is often recognized but the library uses "露筋".
    if (s.contains('漏筋')) {
      yield '漏筋';
      yield '露筋';
      yield '钢筋外露';
      yield '钢筋';
    }
    if (s.contains('保护层不足') || s.contains('保护层厚度不足')) {
      yield '保护层不足';
      yield '保护层厚度';
      yield '钢筋保护层';
    }
    if (s.contains('空鼓')) {
      yield '空鼓';
    }
    if (s.contains('开裂') || s.contains('裂缝')) {
      yield '开裂';
      yield '裂缝';
    }
    if (s.contains('渗漏') || s.contains('漏水')) {
      yield '渗漏';
      yield '漏水';
    }
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

  Future<void> _load({Locale? locale}) async {
    final quality = await _loadOne(
      _qualityAsset,
      DefectSource.quality,
      locale: locale,
    );
    final safety = await _loadOne(
      _safetyAsset,
      DefectSource.safety,
      locale: locale,
    );

    final all = <DefectLibraryEntry>[...quality, ...safety];
    _entries = all;

    final map = <String, DefectLibraryEntry>{
      for (final e in all) e.id: e,
    };
    _byId = map;

    _bm25 = _Bm25Index.build(
      entries: all,
      normalize: _normalizeForSearch,
      termFn: _indexTermsFromNormalized,
    );
  }

  Future<List<DefectLibraryEntry>> _loadOne(
      String assetPath, DefectSource source,
      {Locale? locale}) async {
    final raw = (locale == null)
        ? await rootBundle.loadString(assetPath)
        : await loadStringLocalized(assetPath, locale: locale);
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

class _Bm25EntryStats {
  final Map<String, int> tfIndicator;
  final Map<String, int> tfHierarchy;
  final int docLen;

  const _Bm25EntryStats({
    required this.tfIndicator,
    required this.tfHierarchy,
    required this.docLen,
  });
}

class _Bm25Index {
  final int n;
  final double avgDocLen;
  final Map<String, int> df;
  final Map<String, _Bm25EntryStats> statsById;

  const _Bm25Index({
    required this.n,
    required this.avgDocLen,
    required this.df,
    required this.statsById,
  });

  static _Bm25Index build({
    required List<DefectLibraryEntry> entries,
    required String Function(String) normalize,
    required Iterable<String> Function(
      String, {
      required int max2,
      required int max3,
    }) termFn,
  }) {
    final df = <String, int>{};
    final statsById = <String, _Bm25EntryStats>{};
    var totalLen = 0;

    for (final e in entries) {
      final indicatorNorm = normalize(e.indicator);
      final hierarchyNorm =
          normalize('${e.division} ${e.subDivision} ${e.item}');

      final indTerms = termFn(indicatorNorm, max2: 220, max3: 180).toList();
      final hierTerms = termFn(hierarchyNorm, max2: 140, max3: 120).toList();

      final tfInd = <String, int>{};
      for (final t in indTerms) {
        tfInd[t] = (tfInd[t] ?? 0) + 1;
      }
      final tfHier = <String, int>{};
      for (final t in hierTerms) {
        tfHier[t] = (tfHier[t] ?? 0) + 1;
      }

      final docLen = indTerms.length + hierTerms.length;
      totalLen += docLen;

      final seen = <String>{
        ...tfInd.keys,
        ...tfHier.keys,
      };
      for (final t in seen) {
        df[t] = (df[t] ?? 0) + 1;
      }

      statsById[e.id] = _Bm25EntryStats(
        tfIndicator: tfInd,
        tfHierarchy: tfHier,
        docLen: docLen,
      );
    }

    final n = entries.length;
    final avg = n == 0 ? 0.0 : totalLen / n;
    return _Bm25Index(n: n, avgDocLen: avg, df: df, statsById: statsById);
  }

  double score({
    required String entryId,
    required Map<String, int> queryTerms,
  }) {
    final stats = statsById[entryId];
    if (stats == null || n == 0 || avgDocLen <= 0) return 0;

    final docLen = stats.docLen.toDouble();
    var score = 0.0;

    for (final kv in queryTerms.entries) {
      final term = kv.key;
      final qtf = kv.value;
      final dfv = df[term];
      if (dfv == null || dfv <= 0) continue;

      final idf = math.log(1.0 + (n - dfv + 0.5) / (dfv + 0.5));
      final tf =
          (stats.tfIndicator[term] ?? 0) * DefectLibraryService._wIndicator +
              (stats.tfHierarchy[term] ?? 0) * DefectLibraryService._wHierarchy;
      if (tf <= 0) continue;

      final denom = tf +
          DefectLibraryService._bm25K1 *
              (1.0 -
                  DefectLibraryService._bm25B +
                  DefectLibraryService._bm25B * (docLen / avgDocLen));
      final frac = (tf * (DefectLibraryService._bm25K1 + 1.0)) / denom;

      // Mild query term frequency effect.
      final qBoost = 1.0 + (qtf - 1).clamp(0, 3) * 0.15;
      score += idf * frac * qBoost;
    }

    return score;
  }
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/supervision_library.dart';
import '../services/speech_service.dart';
import '../services/supervision_library_service.dart';
import '../services/supervision_pdf_service.dart';
import 'supervision_checklist_screen.dart';
import 'supervision_pdf_preview_screen.dart';

class SupervisionCheckScreen extends ConsumerStatefulWidget {
  static const routeName = 'supervision-check';

  const SupervisionCheckScreen({super.key});

  @override
  ConsumerState<SupervisionCheckScreen> createState() =>
      _SupervisionCheckScreenState();
}

class _SupervisionCheckScreenState
    extends ConsumerState<SupervisionCheckScreen> {
  final _onSiteController = TextEditingController();

  String _projectName = '中国医学科学院阜外医院深圳医院三期建设项目施工总承包工程';
  final List<String> _projectOptions = [
    '中国医学科学院阜外医院深圳医院三期建设项目施工总承包工程',
  ];

  String _phase = '主体';
  final List<String> _phaseOptions = ['主体', '装修', '机电'];

  int _progressPercent = 80;

  SupervisionLibraryDefinition? _library;
  Map<String, Map<String, SupervisionItemSelection>> _selections = {};

  bool _voiceProcessing = false;
  String _voicePartial = '';
  String _voiceLast = '';
  String _pendingFinalText = '';

  int get _checkedItemCount {
    var c = 0;
    for (final cat in _selections.values) {
      for (final sel in cat.values) {
        if (sel.hasHazard != null) c++;
      }
    }
    return c;
  }

  int get _totalItemCount {
    final lib = _library;
    if (lib == null) return 0;
    var c = 0;
    for (final cat in lib.categories) {
      c += cat.items.length;
    }
    return c;
  }

  @override
  void initState() {
    super.initState();
    // Preload the library so the progress ratio shows a real denominator
    // (e.g. 0/104) before entering the checklist.
    scheduleMicrotask(_ensureLibraryLoaded);
  }

  @override
  void dispose() {
    _onSiteController.dispose();
    super.dispose();
  }

  Future<void> _ensureLibraryLoaded() async {
    if (_library != null) return;
    final service = ref.read(supervisionLibraryServiceProvider);
    final lib = await service.load();
    if (!mounted) return;
    setState(() {
      _library = lib;
    });
  }

  Future<void> _openChecklist() async {
    await _ensureLibraryLoaded();
    if (!mounted) return;
    final lib = _library;
    if (lib == null) return;

    final result = await Navigator.of(context)
        .push<Map<String, Map<String, SupervisionItemSelection>>>(
      MaterialPageRoute(
        builder: (_) => SupervisionChecklistScreen(
          library: lib,
          selections: _selections,
        ),
      ),
    );

    if (!mounted) return;
    if (result != null) {
      setState(() {
        _selections = result;
      });
    }
  }

  Future<void> _generatePdf() async {
    await _ensureLibraryLoaded();

    final lib = _library;
    if (lib == null) return;

    final checked = <({
      String category,
      String itemTitle,
      SupervisionItemSelection selection,
    })>[];

    for (final cat in lib.categories) {
      final map = _selections[cat.title];
      if (map == null) continue;
      for (final item in cat.items) {
        final sel = map[item.title];
        if (sel == null) continue;
        if (sel.hasHazard == null) continue;
        checked
            .add((category: cat.title, itemTitle: item.title, selection: sel));
      }
    }

    final pdf = SupervisionPdfService();
    Uint8List bytes;
    try {
      bytes = await pdf.buildNoticePdf(
        baseInfo: SupervisionBaseInfo(
          projectName: _projectName,
          phase: _phase,
          progressPercent: _progressPercent,
          createdAt: DateTime.now(),
        ),
        checkedItems: checked,
      );
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('无法生成 PDF'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('知道了'),
              ),
            ],
          );
        },
      );
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SupervisionPdfPreviewScreen(
          pdfBytes: bytes,
          title: '文书预览',
        ),
      ),
    );
  }

  Future<void> _startVoice() async {
    final speech = ref.read(speechServiceProvider);

    setState(() {
      _voiceProcessing = true;
      _voicePartial = '';
      _pendingFinalText = '';
    });

    final ok = await speech.startListening(
      preferOnline: true,
      onDownloadProgress: (_) {},
      onPartialResult: (partial) {
        if (!mounted) return;
        setState(() {
          _voicePartial = partial;
        });
      },
      onFinalResult: (finalText) {
        if (!mounted) return;
        setState(() {
          _pendingFinalText = finalText;
        });
      },
    );

    if (!ok && mounted) {
      setState(() {
        _voiceProcessing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('语音识别启动失败')),
      );
    }
  }

  Future<void> _stopVoice() async {
    final speech = ref.read(speechServiceProvider);
    var finalFromStop = '';
    await speech.stopListening(
      onFinalResult: (t) {
        finalFromStop = t;
      },
    );

    if (!mounted) return;
    final merged = (finalFromStop.trim().isNotEmpty
            ? finalFromStop.trim()
            : _pendingFinalText.trim())
        .trim();

    setState(() {
      _voiceProcessing = false;
      _voicePartial = '';
      _pendingFinalText = '';
      if (merged.isNotEmpty) _voiceLast = merged;
    });

    if (merged.isEmpty) return;
    await _handleVoiceText(merged);
  }

  List<String> _splitSentences(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return const [];
    return s
        .split(RegExp(r'[\n\r。！？；;]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  String _norm(String s) {
    return s
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[，,。.!！?？；;、:"“”‘’\(\)（）\[\]【】]+'), '')
        .toLowerCase();
  }

  int _sharedCharScore(String a, String b, {int cap = 6}) {
    if (a.isEmpty || b.isEmpty) return 0;
    final sa = a.split('').toSet();
    final sb = b.split('').toSet();
    final n = sa.intersection(sb).length;
    return (n > cap ? cap : n);
  }

  double _diceCoefficient(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.length == 1 || b.length == 1) {
      final sa = a.split('').toSet();
      final sb = b.split('').toSet();
      return sa.intersection(sb).length /
          (sa.length > sb.length ? sa.length : sb.length);
    }

    Set<String> grams(String s) {
      final out = <String>{};
      for (var i = 0; i < s.length - 1; i++) {
        out.add(s.substring(i, i + 2));
      }
      return out;
    }

    final ga = grams(a);
    final gb = grams(b);
    if (ga.isEmpty || gb.isEmpty) return 0;
    final inter = ga.intersection(gb).length;
    return (2 * inter) / (ga.length + gb.length);
  }

  ({String category, String itemTitle, String indicator, int score})?
      _bestMatch(String sentence, SupervisionLibraryDefinition lib) {
    final q = _norm(sentence);
    if (q.isEmpty) return null;

    ({String category, String itemTitle, String indicator, int score})? best;

    for (final cat in lib.categories) {
      final catN = _norm(cat.title);
      for (final item in cat.items) {
        final itemN = _norm(item.title);
        for (final ind in item.indicators) {
          final indN = _norm(ind);
          if (indN.isEmpty || indN == '其他') continue;

          var score = 0;

          // Exact/substring match gets high weight.
          if (catN.isNotEmpty && q.contains(catN)) score += 5;
          if (itemN.isNotEmpty && q.contains(itemN)) score += 8;
          if (indN.isNotEmpty && q.contains(indN)) score += 14;

          // Fuzzy match: Dice coefficient on bigrams works well for Chinese.
          score += (6 * _diceCoefficient(q, catN)).round();
          score += (10 * _diceCoefficient(q, itemN)).round();
          score += (16 * _diceCoefficient(q, indN)).round();

          // Lightweight robustness for short/partial phrases.
          score += _sharedCharScore(q, indN);
          score += (_sharedCharScore(q, itemN) / 2).floor();

          if (best == null || score > best.score) {
            best = (
              category: cat.title,
              itemTitle: item.title,
              indicator: ind,
              score: score,
            );
          }
        }
      }
    }

    if (best == null) return null;
    // We keep the confirm dialog, so allow a looser threshold to improve usability.
    return best.score >= 6 ? best : null;
  }

  void _appendOnSiteLine(String line) {
    final old = _onSiteController.text.trimRight();
    final next = old.isEmpty ? line : '$old\n$line';
    _onSiteController.text = next;
    _onSiteController.selection =
        TextSelection.collapsed(offset: _onSiteController.text.length);
  }

  void _applySelectionFromMatch({
    required String category,
    required String itemTitle,
    required String indicator,
  }) {
    final currentCat =
        _selections[category] ?? <String, SupervisionItemSelection>{};
    final old = currentCat[itemTitle] ?? const SupervisionItemSelection.empty();
    currentCat[itemTitle] = old.copyWith(
      hasHazard: true,
      selectedIndicator: indicator,
      lastCheckAt: DateTime.now(),
    );
    _selections[category] = currentCat;
  }

  Future<void> _handleVoiceText(String raw) async {
    await _ensureLibraryLoaded();
    if (!mounted) return;
    final lib = _library;
    if (lib == null) return;

    for (final sentence in _splitSentences(raw)) {
      final match = _bestMatch(sentence, lib);

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('确认登记'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('识别内容：$sentence'),
                const SizedBox(height: 10),
                if (match == null)
                  const Text('未匹配到问题库，将仅按原文登记。')
                else
                  Text(
                    '匹配结果：\n${match.category} / ${match.itemTitle}\n指标：${match.indicator}',
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消重说'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('确认写入'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      if (confirmed != true) continue;

      setState(() {
        if (match == null) {
          _appendOnSiteLine(sentence);
        } else {
          _appendOnSiteLine(
              '${match.category}/${match.itemTitle}：${match.indicator}');
          _applySelectionFromMatch(
            category: match.category,
            itemTitle: match.itemTitle,
            indicator: match.indicator,
          );
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已写入现场检查情况')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('日常监督'),
        leading: TextButton(
          onPressed: () => context.go('/'),
          child: const Text('取消'),
        ),
        actions: [
          TextButton(
            onPressed: _generatePdf,
            child: const Text('确定'),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            children: [
              _sectionTitle('基础信息'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(width: 64, child: Text('工程')),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            value: _projectName,
                            decoration: const InputDecoration(isDense: true),
                            selectedItemBuilder: (ctx) {
                              return _projectOptions
                                  .map(
                                    (e) => Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        e,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(growable: false);
                            },
                            items: _projectOptions
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(
                                      e,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _projectName = v);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _formRow(
                label: '施工阶段',
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _phase,
                        decoration: const InputDecoration(isDense: true),
                        items: _phaseOptions
                            .map((e) =>
                                DropdownMenuItem(value: e, child: Text(e)))
                            .toList(growable: false),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _phase = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 120,
                      child: DropdownButtonFormField<int>(
                        value: _progressPercent,
                        decoration: const InputDecoration(isDense: true),
                        items: const [0, 20, 40, 60, 80, 90, 100]
                            .map((e) =>
                                DropdownMenuItem(value: e, child: Text('$e%')))
                            .toList(growable: false),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _progressPercent = v);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _sectionTitle('监督用表'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('抽查事项清单（二级）'),
                subtitle: const Text('按子分部进入，逐条选择“无隐患/有隐患”'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$_checkedItemCount/$_totalItemCount'),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: _openChecklist,
              ),
              const Divider(height: 1),
              _sectionTitle('现场检查情况'),
              TextField(
                controller: _onSiteController,
                maxLines: 6,
                minLines: 4,
                decoration: InputDecoration(
                  hintText: '长按麦克风说一句，系统将匹配问题库并确认写入（每条自动换行）。\n也可手动补充编辑。',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      setState(() {
                        _onSiteController.clear();
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('文书发放'),
                subtitle: const Text('将依据“有隐患”的条目生成 PDF 文书并加盖红章'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _generatePdf,
              ),
              const Divider(height: 1),
              const SizedBox(height: 12),
              if (_voicePartial.isNotEmpty || _voiceLast.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('语音登记'),
                      if (_voicePartial.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('实时识别：$_voicePartial'),
                      ],
                      if (_voiceLast.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('上次识别：$_voiceLast',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Center(
              child: _voiceFab(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _voiceFab() {
    final cs = Theme.of(context).colorScheme;
    final bg = _voiceProcessing ? cs.primary : cs.primaryContainer;
    final fg = _voiceProcessing ? cs.onPrimary : cs.onPrimaryContainer;

    return GestureDetector(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请长按麦克风开始说话，松开结束')),
        );
      },
      onLongPressStart: (_) async {
        if (_voiceProcessing) return;
        await _startVoice();
      },
      onLongPressEnd: (_) async {
        if (!_voiceProcessing) return;
        await _stopVoice();
      },
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              blurRadius: 12,
              color: Colors.black26,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Icon(Icons.mic, color: fg, size: 34),
      ),
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        t,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  Widget _formRow({required String label, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

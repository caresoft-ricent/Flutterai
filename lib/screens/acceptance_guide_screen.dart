import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/acceptance_record.dart';
import '../models/library.dart';
import '../models/region.dart';
import '../models/target.dart';
import '../services/database_service.dart';
import '../services/defect_library_service.dart';
import '../services/gemini_service.dart';
import '../services/gemma_multimodal_service.dart';
import '../services/offline_cache_service.dart';
import '../services/tts_service.dart';
import '../services/use_gemma_multimodal_service.dart';
import '../utils/constants.dart';
import 'camera_capture_screen.dart';
import 'home_screen.dart';

class AcceptanceGuideScreen extends ConsumerStatefulWidget {
  static const routeName = 'acceptance-guide';

  final Region? region;
  final LibraryItem? library;

  const AcceptanceGuideScreen({
    super.key,
    required this.region,
    required this.library,
  });

  @override
  ConsumerState<AcceptanceGuideScreen> createState() =>
      _AcceptanceGuideScreenState();
}

class _AcceptanceGuideScreenState extends ConsumerState<AcceptanceGuideScreen> {
  List<TargetItem> _targets = [];
  bool _loading = true;
  bool _submitting = false;

  final ScrollController _listController = ScrollController();
  bool _headerCollapsed = false;
  double _lastScrollOffset = 0;
  int? _currentIndex;
  Map<String, GlobalKey> _itemKeys = {};

  final Map<String, AcceptanceRecord> _records = {};
  final Map<String, AcceptanceResult> _results = {};
  final Map<String, GeminiStructuredResult> _aiResults = {};

  GeminiStructuredResult _withMatchId(GeminiStructuredResult r, String id) {
    return GeminiStructuredResult(
      type: r.type,
      summary: r.summary,
      defectType: r.defectType,
      severity: r.severity,
      rectifySuggestion: r.rectifySuggestion,
      matchId: id,
      questions: r.questions,
      rawJson: r.rawJson,
      rawText: r.rawText,
    );
  }

  int? _nextUnansweredIndex() {
    for (var i = 0; i < _targets.length; i++) {
      if (!_results.containsKey(_targets[i].idCode)) return i;
    }
    return null;
  }

  void _scrollToIndex(int index) {
    if (index < 0 || index >= _targets.length) return;
    final key = _itemKeys[_targets[index].idCode];
    if (key == null) return;
    final ctx = key.currentContext;
    if (ctx == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = key.currentContext;
      if (c == null) return;
      Scrollable.ensureVisible(
        c,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignment: 0.2,
      );
    });
  }

  Future<void> _speakTargetPrompt(int index) async {
    if (index < 0 || index >= _targets.length) return;
    final tts = ref.read(ttsServiceProvider);
    final target = _targets[index];
    final content = (target.description).trim().isEmpty
        ? target.name
        : target.description.trim();
    await tts.speak('第${index + 1}项：$content。');
  }

  Future<void> _speakNextPromptOrCompletion() async {
    final tts = ref.read(ttsServiceProvider);
    final next = _nextUnansweredIndex();
    if (next == null) {
      await tts.speak('所有主控项已判定。您可以点击提交。');
      return;
    }
    await _speakTargetPrompt(next);
  }

  String _resultText(AcceptanceResult r) {
    switch (r) {
      case AcceptanceResult.qualified:
        return '合格';
      case AcceptanceResult.unqualified:
        return '不合格';
      case AcceptanceResult.pending:
        return '甩项';
    }
  }

  @override
  void initState() {
    super.initState();
    _listController.addListener(_handleListScroll);
    _loadData();
  }

  void _handleListScroll() {
    if (!_listController.hasClients) return;
    final offset = _listController.position.pixels;
    final isScrollingDown = offset > _lastScrollOffset;
    final isScrollingUp = offset < _lastScrollOffset;
    _lastScrollOffset = offset;

    if (!mounted) return;

    // Auto expand when user returns to top.
    if (offset <= 0 && _headerCollapsed && isScrollingUp) {
      setState(() {
        _headerCollapsed = false;
      });
      return;
    }

    // Auto collapse only when user scrolls down away from top.
    if (_headerCollapsed) return;
    if (!isScrollingDown) return;
    if (offset <= 0) return;
    setState(() {
      _headerCollapsed = true;
    });
  }

  @override
  void dispose() {
    _listController.removeListener(_handleListScroll);
    _listController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseServiceProvider);
    final tts = ref.read(ttsServiceProvider);

    final library = widget.library;
    if (library == null) {
      setState(() {
        _loading = false;
      });
      return;
    }

    final targets = await db.getTargetsByLibraryCode(library.idCode);

    if (!mounted) return;
    setState(() {
      _targets = targets;
      _itemKeys = {for (final t in targets) t.idCode: GlobalKey()};
      _loading = false;
      _currentIndex = targets.isEmpty ? null : 0;
    });

    if (targets.isNotEmpty) {
      await tts.speak('开始验收${library.name}，共有${targets.length}个检查指标。');
      await _speakTargetPrompt(0);
      _scrollToIndex(0);
    }
  }

  int get _unqualifiedCount =>
      _results.values.where((r) => r == AcceptanceResult.unqualified).length;

  bool get _allAnswered =>
      _targets.isNotEmpty && _results.length == _targets.length;

  String get _overallResultText {
    if (_targets.isEmpty) return '';
    if (_unqualifiedCount > 0) return '不合格';
    if (_allAnswered) return '合格';
    return '待确认';
  }

  Future<void> _onResultSelected(
      TargetItem target, AcceptanceResult result) async {
    final cache = ref.read(offlineCacheServiceProvider);
    final tts = ref.read(ttsServiceProvider);

    final record = AcceptanceRecord(
      regionCode: widget.region?.idCode ?? '',
      regionText: widget.region?.name ?? '',
      libraryCode: widget.library?.idCode ?? '',
      libraryName: widget.library?.name ?? '',
      targetCode: target.idCode,
      targetName: target.name,
      result: result,
      createdAt: DateTime.now(),
    );

    final id = await cache.saveRecord(record);
    _records[target.idCode] = record.copyWith(id: id);
    _results[target.idCode] = result;

    if (!mounted) return;
    setState(() {});

    final chosenText = _resultText(result);
    if (result == AcceptanceResult.unqualified) {
      await tts.speak('已选择$chosenText，请拍照记录。');
    } else {
      await tts.speak('已选择$chosenText。');
    }

    if (result == AcceptanceResult.unqualified) {
      await _takePhoto(target);
    }

    final next = _nextUnansweredIndex();
    if (mounted) {
      setState(() {
        _currentIndex = next;
      });
      if (next != null) {
        _scrollToIndex(next);
      }
    }
    await _speakNextPromptOrCompletion();
  }

  Future<void> _submitAndReturnHome() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
    });
    try {
      if (!_allAnswered) {
        final tts = ref.read(ttsServiceProvider);
        await tts.speak('请先完成所有主控项的判定，再提交。');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先完成所有主控项的判定')),
        );
        return;
      }

      final tts = ref.read(ttsServiceProvider);
      await tts.speak('本次验收已完成，数据已本地保存，返回主界面继续。');
      if (!mounted) return;
      context.goNamed(HomeScreen.routeName);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Future<void> _takePhoto(TargetItem target) async {
    try {
      final tts = ref.read(ttsServiceProvider);
      final path = await CameraCaptureScreen.capture(context);
      if (!mounted || path == null || path.isEmpty) return;

      final cache = ref.read(offlineCacheServiceProvider);
      final existing = _records[target.idCode];
      if (existing != null) {
        var updated = existing.copyWith(photoPath: path);

        // Optional: offline image recognition remark.
        final enabled = ref.read(useGemmaMultimodalProvider);
        if (enabled) {
          try {
            final mm = ref.read(gemmaMultimodalServiceProvider);
            final analysis = await mm.analyzeImageAuto(
              path,
              sceneHint: '工序验收拍照（可能是构件/工艺照片，也可能是铭牌/合格证）',
              hint: '请结合验收标准，判断是否存在明显问题，并给出简短备注。',
              targetName: target.name,
              targetStandard: target.description,
            );
            updated = updated.copyWith(remark: analysis);
          } catch (_) {
            // Ignore analysis failure.
          }
        }

        // Online Gemini structured analysis (for acceptance display).
        try {
          // 本地问题库候选（assets/defect_library），不涉及后端。
          final defectLibrary = ref.read(defectLibraryServiceProvider);
          await defectLibrary.ensureLoaded();
          final candidateQuery = <String>[
            '工序验收',
            widget.library?.name ?? '',
            widget.region?.name ?? '',
            target.name,
            target.description,
          ].where((s) => s.trim().isNotEmpty).join(' ');
          final candidates = defectLibrary.suggest(
            query: candidateQuery,
            limit: 30,
          );
          final candidateLines =
              candidates.map((e) => e.toPromptLine()).toList();

          final gemini = ref.read(geminiServiceProvider);
          var ai = await gemini.analyzeImageAutoStructured(
            path,
            sceneHint: '工序验收拍照（可能是构件/工艺照片，也可能是铭牌/合格证）',
            hint: '如果照片不是施工部位或无法判断，请返回 type=irrelevant 并提示重拍。',
            defectLibraryCandidateLines: candidateLines,
          );

          // 若 Gemini 未给出 match_id，使用本地缺陷库按 summary 等再推断一次。
          if (ai.type.trim() == 'defect' && ai.matchId.trim().isEmpty) {
            final inferQuery = <String>[
              candidateQuery,
              ai.summary,
              ai.defectType,
              ai.rectifySuggestion,
            ].where((s) => s.trim().isNotEmpty).join(' ');

            final inferred = defectLibrary.suggest(query: inferQuery, limit: 1);
            if (inferred.isNotEmpty) {
              ai = _withMatchId(ai, inferred.first.id);
            }
          }

          _aiResults[target.idCode] = ai;
        } catch (_) {
          // Ignore online analysis failure.
        }

        await cache.updateRecord(updated);
        _records[target.idCode] = updated;
      }

      await tts.speak('照片已保存。');

      if (!mounted) return;
      setState(() {});
    } catch (_) {
      // 摄像头初始化或拍照失败时，忽略即可，仅不保存照片路径。
    }
  }

  @override
  Widget build(BuildContext context) {
    final regionName = widget.region?.name ?? '未知位置';
    final libraryName = widget.library?.name ?? '未知分项';
    final batchTitle = '第1批($regionName)';
    final headerSummary = '演示项目｜新城公司  $libraryName  $regionName';

    return Scaffold(
      appBar: AppBar(
        title: const Text('工序验收'),
        actions: [
          IconButton(
            onPressed: _submitting
                ? null
                : () {
                    context.goNamed(HomeScreen.routeName);
                  },
            icon: const Icon(Icons.close),
            tooltip: '关闭',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _targets.isEmpty
              ? const Center(child: Text('未找到该分项的验收指标'))
              : SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          child: _headerCollapsed
                              ? Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        headerSummary,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () {
                                        setState(() {
                                          _headerCollapsed = false;
                                        });
                                      },
                                      icon: const Icon(Icons.expand_more),
                                      tooltip: '展开信息',
                                    ),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '演示项目｜新城公司',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () {
                                            setState(() {
                                              _headerCollapsed = true;
                                            });
                                          },
                                          icon: const Icon(Icons.expand_less),
                                          tooltip: '收起信息',
                                        ),
                                        TextButton(
                                          onPressed: _submitting
                                              ? null
                                              : () {
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(
                                                    const SnackBar(
                                                      content: Text('一键确认（模拟）'),
                                                    ),
                                                  );
                                                  ref
                                                      .read(ttsServiceProvider)
                                                      .speak('已执行一键确认。');
                                                },
                                          child: const Text('一键确认'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: InputDecorator(
                                            decoration: const InputDecoration(
                                              labelText: '工序',
                                              border: OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                            child: Text(libraryName),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: InputDecorator(
                                            decoration: const InputDecoration(
                                              labelText: '部位',
                                              border: OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                            child: Text(regionName),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            batchTitle,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text('查看图纸（占位）'),
                                              ),
                                            );
                                          },
                                          child: const Text('查看图纸'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    const Divider(height: 1),
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('批次描述'),
                                      trailing: const Text(''),
                                      onTap: null,
                                    ),
                                    const Divider(height: 1),
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('责任单位'),
                                      trailing: const Text(''),
                                      onTap: null,
                                    ),
                                    const Divider(height: 1),
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('抄送人'),
                                      trailing: const Text(''),
                                      onTap: null,
                                    ),
                                    const Divider(height: 1),
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('检查批容量'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: null,
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          controller: _listController,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          children: [
                            const SizedBox(height: 12),
                            Text(
                              '主控项',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            for (var i = 0; i < _targets.length; i++)
                              Container(
                                key: _itemKeys[_targets[i].idCode],
                                child: _AcceptanceTargetCard(
                                  target: _targets[i],
                                  selected: _results[_targets[i].idCode],
                                  isCurrent: _currentIndex == i,
                                  onSelected: (r) =>
                                      _onResultSelected(_targets[i], r),
                                  analysis: _aiResults[_targets[i].idCode],
                                ),
                              ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '有 $_unqualifiedCount 条主控项不合格',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ),
                                Text(
                                  '总体结果 $_overallResultText',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _submitting
                                      ? null
                                      : () {
                                          context.goNamed(HomeScreen.routeName);
                                        },
                                  child: const Text('返回'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _submitting
                                      ? null
                                      : () {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                              content: Text('已暂存（本地）'),
                                            ),
                                          );
                                          ref
                                              .read(ttsServiceProvider)
                                              .speak('已暂存到本地。');
                                        },
                                  child: const Text('暂存'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton(
                                  onPressed:
                                      _submitting ? null : _submitAndReturnHome,
                                  child: Text(_submitting ? '提交中…' : '提交'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _AcceptanceTargetCard extends StatelessWidget {
  final TargetItem target;
  final AcceptanceResult? selected;
  final bool isCurrent;
  final ValueChanged<AcceptanceResult> onSelected;
  final GeminiStructuredResult? analysis;

  const _AcceptanceTargetCard({
    required this.target,
    required this.selected,
    required this.isCurrent,
    required this.onSelected,
    required this.analysis,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlightColor = theme.colorScheme.primaryContainer;
    final a = analysis;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: isCurrent ? highlightColor : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              target.description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (a != null) ...[
              const SizedBox(height: 10),
              _AcceptanceAiPanel(result: a),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _resultButton(
                    label: '合格',
                    result: AcceptanceResult.qualified,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _resultButton(
                    label: '不合格',
                    result: AcceptanceResult.unqualified,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _resultButton(
                    label: '甩项',
                    result: AcceptanceResult.pending,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultButton(
      {required String label, required AcceptanceResult result}) {
    final isSelected = selected == result;
    if (isSelected) {
      return FilledButton(
        onPressed: () => onSelected(result),
        child: Text(label),
      );
    }
    return OutlinedButton(
      onPressed: () => onSelected(result),
      child: Text(label),
    );
  }
}

class _AcceptanceAiPanel extends StatelessWidget {
  final GeminiStructuredResult result;

  const _AcceptanceAiPanel({required this.result});

  String _severityText(String v) {
    switch (v.trim().toLowerCase()) {
      case 'high':
        return '高';
      case 'medium':
        return '中';
      case 'low':
      default:
        return '低';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = result.type.trim();

    if (type == 'irrelevant') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '请拍摄施工部位',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    if (type == 'defect') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.error),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.summary.trim().isEmpty ? '发现问题' : result.summary.trim(),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '缺陷类型：${result.defectType.trim().isEmpty ? '未给出' : result.defectType.trim()}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '严重程度：${_severityText(result.severity)}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '整改建议：${result.rectifySuggestion.trim().isEmpty ? '未给出' : result.rectifySuggestion.trim()}',
              style: theme.textTheme.bodySmall,
            ),
            if (result.matchedHistory) ...[
              const SizedBox(height: 8),
              Text(
                '已匹配历史问题',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // other
    final summary = result.summary.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        summary.isEmpty ? '未能判定，请重试。' : summary,
        style: theme.textTheme.bodyMedium,
      ),
    );
  }
}

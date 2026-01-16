import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/acceptance_record.dart';
import '../models/library.dart';
import '../models/region.dart';
import '../models/target.dart';
import '../services/defect_library_service.dart';
import '../services/online_vision_service.dart';
import '../services/gemma_multimodal_service.dart';
import '../services/offline_cache_service.dart';
import '../services/database_service.dart';
import '../services/procedure_acceptance_library_service.dart';
import '../services/gemma_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../services/use_gemma_multimodal_service.dart';
import '../services/use_offline_speech_service.dart';
import '../utils/constants.dart';
import 'camera_capture_screen.dart';
import 'home_screen.dart';
import 'issue_report_screen.dart';

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
  bool _suppressHeaderAutoToggle = false;
  double _lastScrollOffset = 0;
  int? _currentIndex;
  Map<String, GlobalKey> _itemKeys = {};

  // Selection state (same idea as “日常巡检问题库”的级联下拉)
  String? _selectedCategory;
  String? _selectedSubcategory;
  LibraryItem? _selectedLibrary;
  List<String> _categories = [];
  List<String> _subcategories = [];
  List<LibraryItem> _libraries = [];

  LibraryItem? get _currentLibrary => _selectedLibrary ?? widget.library;

  late final TextEditingController _regionController;

  // Voice session state (for "未选择分项" on this page)
  bool _voiceProcessing = false;
  String _voicePartial = '';
  String _voiceLast = '';
  String _voicePendingFinalText = '';

  String get _regionText {
    final t = _regionController.text.trim();
    if (t.isNotEmpty) return t;
    final name = widget.region?.name;
    return (name == null || name.trim().isEmpty) ? '未知位置' : name.trim();
  }

  LibraryItem? _findLibraryOptionByCode(String? code) {
    if (code == null || code.trim().isEmpty) return null;
    for (final l in _libraries) {
      if (l.idCode == code) return l;
    }
    return null;
  }

  final Map<String, AcceptanceRecord> _records = {};
  final Map<String, AcceptanceResult> _results = {};
  final Map<String, OnlineVisionStructuredResult> _aiResults = {};

  OnlineVisionStructuredResult _withMatchId(
    OnlineVisionStructuredResult r,
    String id,
  ) {
    return OnlineVisionStructuredResult(
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

      // Programmatic scroll can trigger header auto toggle; suppress briefly.
      _suppressHeaderAutoToggle = true;
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) _suppressHeaderAutoToggle = false;
      });
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
    // 需求：播报只读“指标名称”，避免说明过长。
    final name = target.name.trim();
    final desc = target.description.trim();
    final content = name.isNotEmpty
        ? name
        : (desc.isEmpty
            ? '未命名指标'
            : (desc.length > 18 ? desc.substring(0, 18) : desc));
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
    _regionController = TextEditingController(text: widget.region?.name ?? '');
    _listController.addListener(_handleListScroll);
    _bootstrap();
  }

  Future<void> _startVoiceSessionListening() async {
    if (_voiceProcessing) return;
    final speech = ref.read(speechServiceProvider);
    final useOfflineSpeech = ref.read(useOfflineSpeechProvider);

    setState(() {
      _voiceProcessing = false;
      _voicePartial = '';
      _voiceLast = '';
      _voicePendingFinalText = '';
    });

    final ok = await speech.startListening(
      preferOnline: !useOfflineSpeech,
      onDownloadProgress: (_) {},
      onPartialResult: (partial) {
        final p = partial.trim();
        if (p.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _voicePartial = p;
          _voicePendingFinalText = p;
        });
      },
      onFinalResult: (text) {
        final t = text.trim();
        if (t.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _voiceLast = t;
          _voicePendingFinalText = t;
        });
      },
    );

    if (!mounted) return;
    if (!ok) {
      final msg = speech.lastInitError ?? '语音识别启动失败';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _stopVoiceSessionListening() async {
    final speech = ref.read(speechServiceProvider);
    if (_voiceProcessing && !speech.isListening) return;

    String finalText = '';
    await speech.stopListening(
      onFinalResult: (t) {
        finalText = t;
      },
    );

    if (!mounted) return;
    finalText = finalText.trim().isEmpty
        ? _voicePendingFinalText.trim()
        : finalText.trim();

    setState(() {
      _voicePendingFinalText = '';
      _voicePartial = '';
      _voiceLast = finalText;
      _voiceProcessing = finalText.isNotEmpty;
    });

    if (finalText.isEmpty) {
      if (mounted) {
        setState(() {
          _voiceProcessing = false;
        });
      }
      return;
    }

    try {
      await _handleRecognizedTextForSelection(finalText);
    } finally {
      if (mounted) {
        setState(() {
          _voiceProcessing = false;
        });
      }
    }
  }

  Future<void> _handleRecognizedTextForSelection(String text) async {
    final gemma = ref.read(gemmaServiceProvider);
    final db = ref.read(databaseServiceProvider);
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    final tts = ref.read(ttsServiceProvider);

    final base = await gemma.parseIntent(text);
    final enriched = await gemma.enrichWithLocalData(base, text);
    if (!mounted) return;

    if (enriched.intent == 'procedure_acceptance') {
      final LibraryItem? library = enriched.libraryCode != null
          ? await procedureLibrary.getLibraryByCode(enriched.libraryCode!)
          : await procedureLibrary
              .findLibraryByName(enriched.libraryName ?? text);

      Region? region;
      if (enriched.regionCode != null) {
        region = await db.getRegionByCode(enriched.regionCode!);
      }
      region ??= (enriched.regionText != null)
          ? Region(
              id: '',
              idCode: enriched.regionCode ?? '',
              name: enriched.regionText!,
              parentIdCode: '',
            )
          : null;

      if (library != null) {
        if (region != null) {
          _regionController.text = region.name;
        }
        await tts.speak('已为您匹配到$_regionText 的 ${library.name}，开始验收。');
        final effective = await _prefillSelectionFromLibrary(library);
        await _loadTargetsForLibrary(effective);
        return;
      }
    }

    if (enriched.intent == 'report_issue') {
      await tts.speak('检测到问题上报意图，进入问题上报页面。');
      if (!mounted) return;
      context.goNamed(IssueReportScreen.routeName, extra: {
        'originText': text,
        'regionText': text,
      });
      return;
    }

    await tts.speak('未能识别分项，请尝试说：我要验收1栋6层的模板工程。');
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
    });

    await _loadCategories();

    final initial = widget.library;
    if (initial != null) {
      final effective = await _prefillSelectionFromLibrary(initial);
      await _loadTargetsForLibrary(effective, speakIntro: false);
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
    });
  }

  void _handleListScroll() {
    if (!_listController.hasClients) return;
    if (_suppressHeaderAutoToggle) return;
    final offset = _listController.position.pixels;
    final isScrollingDown = offset > _lastScrollOffset;
    final isScrollingUp = offset < _lastScrollOffset;
    _lastScrollOffset = offset;

    if (!mounted) return;

    // Auto expand when user returns to top.
    if (offset <= 24 && _headerCollapsed && isScrollingUp) {
      setState(() {
        _headerCollapsed = false;
      });
      return;
    }

    // Auto collapse only when user scrolls down away from top.
    if (_headerCollapsed) return;
    if (!isScrollingDown) return;
    if (offset < 80) return;
    setState(() {
      _headerCollapsed = true;
    });
  }

  @override
  void dispose() {
    _listController.removeListener(_handleListScroll);
    _listController.dispose();
    _regionController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    final categories = await procedureLibrary.getCategories();
    if (!mounted) return;
    setState(() {
      _categories = categories;
    });
  }

  Future<LibraryItem> _prefillSelectionFromLibrary(LibraryItem library) async {
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    var effective = library;
    var path =
        await procedureLibrary.getCategoryPathByLibraryCode(effective.idCode);

    // 语音/数据库粗粒度 code (Axxx) 时，尝试用名称在 assets 中找一个更细的 Pxxxx 来回填。
    if (path == null) {
      final alt = await procedureLibrary.findLibraryByName(library.name);
      if (alt != null && alt.idCode != library.idCode) {
        final altPath =
            await procedureLibrary.getCategoryPathByLibraryCode(alt.idCode);
        if (altPath != null) {
          effective = alt;
          path = altPath;
        }
      }
    }

    if (path == null) {
      setState(() {
        _selectedLibrary = effective;
      });
      return effective;
    }

    final category = path.category;
    final subcategory = path.subcategory;
    final subcategories = await procedureLibrary.getSubcategories(category);
    final libraries =
        await procedureLibrary.getLibraries(category, subcategory);

    if (!mounted) return effective;
    setState(() {
      _selectedCategory = category;
      _subcategories = subcategories;
      _selectedSubcategory = subcategory;
      _libraries = libraries;
      _selectedLibrary =
          _findLibraryOptionByCode(effective.idCode) ?? effective;
    });
    return effective;
  }

  void _resetAcceptanceState() {
    _targets = [];
    _itemKeys = {};
    _currentIndex = null;
    _headerCollapsed = false;
    _records.clear();
    _results.clear();
    _aiResults.clear();
  }

  Future<void> _loadTargetsForLibrary(
    LibraryItem library, {
    bool speakIntro = true,
  }) async {
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    final tts = ref.read(ttsServiceProvider);

    setState(() {
      _loading = true;
      _resetAcceptanceState();
    });

    // 关键修复：工序验收分项(Pxxxx)的指标来自 assets 工序验收库，不能只查数据库。
    final targets =
        await procedureLibrary.getTargetsByLibraryCode(library.idCode);

    if (!mounted) return;
    setState(() {
      _targets = targets;
      _itemKeys = {for (final t in targets) t.idCode: GlobalKey()};
      _currentIndex = targets.isEmpty ? null : 0;
      _loading = false;
    });

    if (!speakIntro) return;
    if (targets.isNotEmpty) {
      await tts.speak('开始验收${library.name}，共有${targets.length}个检查指标。');
      await _speakTargetPrompt(0);
      _scrollToIndex(0);
    } else {
      await tts.speak('未找到该分项的验收指标，请更换分项。');
    }
  }

  Widget _buildCascadingDropdown({
    required String label,
    required String? value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
  }) {
    if (options.isEmpty) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: const Text('-'),
      );
    }

    final safeValue = (value != null && options.contains(value)) ? value : null;

    return DropdownButtonFormField<String>(
      isExpanded: true,
      value: safeValue,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      hint: const Text('请选择'),
      items: [
        for (final o in options)
          DropdownMenuItem<String>(
            value: o,
            child: Text(
              o.isEmpty ? '-' : o,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _buildLibraryDropdown({
    required String label,
    required LibraryItem? value,
    required List<LibraryItem> options,
    required ValueChanged<LibraryItem?> onChanged,
  }) {
    if (options.isEmpty) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: Text(value?.name ?? '-'),
      );
    }

    final safeValue = _findLibraryOptionByCode(value?.idCode);

    return DropdownButtonFormField<LibraryItem>(
      isExpanded: true,
      value: safeValue,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      hint: const Text('请选择'),
      items: [
        for (final o in options)
          DropdownMenuItem<LibraryItem>(
            value: o,
            child: Text(
              o.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Future<void> _onCategoryChanged(String? category) async {
    if (category == null) return;
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    final subcategories = await procedureLibrary.getSubcategories(category);
    if (!mounted) return;
    setState(() {
      _selectedCategory = category;
      _selectedSubcategory = null;
      _selectedLibrary = null;
      _subcategories = subcategories;
      _libraries = [];
      _resetAcceptanceState();
    });
  }

  Future<void> _onSubcategoryChanged(String? subcategory) async {
    if (subcategory == null || _selectedCategory == null) return;
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    final libraries =
        await procedureLibrary.getLibraries(_selectedCategory!, subcategory);
    if (!mounted) return;
    setState(() {
      _selectedSubcategory = subcategory;
      _selectedLibrary = null;
      _libraries = libraries;
      _resetAcceptanceState();
    });
  }

  Future<void> _onLibraryChanged(LibraryItem? library) async {
    if (library == null) return;
    setState(() {
      _selectedLibrary = library;
    });
    await _loadTargetsForLibrary(library);
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

    final library = _currentLibrary;

    final record = AcceptanceRecord(
      regionCode: widget.region?.idCode ?? '',
      regionText: _regionText,
      libraryCode: library?.idCode ?? '',
      libraryName: library?.name ?? '',
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

        // Online structured analysis (for acceptance display).
        try {
          // 本地问题库候选（assets/defect_library），不涉及后端。
          final defectLibrary = ref.read(defectLibraryServiceProvider);
          await defectLibrary.ensureLoaded();
          final candidateQuery = <String>[
            '工序验收',
            _currentLibrary?.name ?? '',
            _regionText,
            target.name,
            target.description,
          ].where((s) => s.trim().isNotEmpty).join(' ');
          final candidates = defectLibrary.suggest(
            query: candidateQuery,
            limit: 30,
          );
          final candidateLines =
              candidates.map((e) => e.toPromptLine()).toList();

          final onlineVision = ref.read(onlineVisionServiceProvider);
          var ai = await onlineVision.analyzeImageAutoStructured(
            path,
            sceneHint: '工序验收拍照（可能是构件/工艺照片，也可能是铭牌/合格证）',
            hint: '如果照片不是施工部位或无法判断，请返回 type=irrelevant 并提示重拍。',
            defectLibraryCandidateLines: candidateLines,
          );

          // 若未给出 match_id，使用本地缺陷库按 summary 等再推断一次。
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
    final regionName = _regionText;
    final libraryName = _currentLibrary?.name ?? '未选择分项';
    final batchTitle = '第1批($regionName)';
    final headerSummary = '演示项目｜新城公司  $libraryName  $regionName';

    Future<void> confirmAllQualified() async {
      if (_targets.isEmpty || _currentLibrary == null) return;
      final cache = ref.read(offlineCacheServiceProvider);
      final tts = ref.read(ttsServiceProvider);
      final library = _currentLibrary;
      final now = DateTime.now();

      setState(() {
        _loading = true;
      });
      try {
        for (final target in _targets) {
          final existing = _records[target.idCode];
          if (existing == null) {
            final record = AcceptanceRecord(
              regionCode: widget.region?.idCode ?? '',
              regionText: _regionText,
              libraryCode: library?.idCode ?? '',
              libraryName: library?.name ?? '',
              targetCode: target.idCode,
              targetName: target.name,
              result: AcceptanceResult.qualified,
              createdAt: now,
            );
            final id = await cache.saveRecord(record);
            _records[target.idCode] = record.copyWith(id: id);
          } else {
            final updated = AcceptanceRecord(
              id: existing.id,
              regionCode: existing.regionCode,
              regionText: _regionText,
              libraryCode: library?.idCode ?? existing.libraryCode,
              libraryName: library?.name ?? existing.libraryName,
              targetCode: existing.targetCode,
              targetName: existing.targetName,
              result: AcceptanceResult.qualified,
              photoPath: existing.photoPath,
              remark: existing.remark,
              createdAt: existing.createdAt,
              uploaded: existing.uploaded,
            );
            await cache.updateRecord(updated);
            _records[target.idCode] = updated;
          }
          _results[target.idCode] = AcceptanceResult.qualified;
        }
      } finally {
        if (mounted) {
          setState(() {
            _currentIndex = null;
            _loading = false;
          });
        }
      }

      await tts.speak('已一键确认，全部主控项为合格。');
    }

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
      body: SafeArea(
        child: Stack(
          children: [
            Column(
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
                                  style: Theme.of(context).textTheme.titleSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    _suppressHeaderAutoToggle = true;
                                    _headerCollapsed = false;
                                  });
                                  Future.delayed(
                                    const Duration(milliseconds: 250),
                                    () {
                                      if (mounted) {
                                        _suppressHeaderAutoToggle = false;
                                      }
                                    },
                                  );
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
                                        _suppressHeaderAutoToggle = true;
                                        _headerCollapsed = true;
                                      });
                                      Future.delayed(
                                        const Duration(milliseconds: 250),
                                        () {
                                          if (mounted) {
                                            _suppressHeaderAutoToggle = false;
                                          }
                                        },
                                      );
                                    },
                                    icon: const Icon(Icons.expand_less),
                                    tooltip: '收起信息',
                                  ),
                                  TextButton(
                                    onPressed: (_submitting || _targets.isEmpty)
                                        ? null
                                        : confirmAllQualified,
                                    child: const Text('一键确认'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildCascadingDropdown(
                                      label: '分部',
                                      value: _selectedCategory,
                                      options: _categories,
                                      onChanged: (v) {
                                        if (v == null) return;
                                        _onCategoryChanged(v);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildCascadingDropdown(
                                      label: '子分部',
                                      value: _selectedSubcategory,
                                      options: _subcategories,
                                      onChanged: (v) {
                                        if (v == null) return;
                                        _onSubcategoryChanged(v);
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildLibraryDropdown(
                                      label: '分项',
                                      value: _currentLibrary,
                                      options: _libraries,
                                      onChanged: (v) {
                                        if (v == null) return;
                                        _onLibraryChanged(v);
                                      },
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
                                      child: TextFormField(
                                        controller: _regionController,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          hintText: '请输入',
                                        ),
                                        onChanged: (_) {
                                          if (!mounted) return;
                                          setState(() {});
                                        },
                                      ),
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
                            ],
                          ),
                  ),
                ),
                Expanded(
                  child: (_currentLibrary == null)
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('请先在上方选择分部/子分部/分项\n或长按下方麦克风用语音选择'),
                              if (_voicePartial.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '实时识别：$_voicePartial',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                              if (_voiceLast.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '上次识别：$_voiceLast',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        )
                      : _targets.isEmpty
                          ? const Center(child: Text('未找到该分项的验收指标'))
                          : ListView(
                              controller: _listController,
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                              children: [
                                const SizedBox(height: 12),
                                Text(
                                  '主控项',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
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
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium,
                                      ),
                                    ),
                                    Text(
                                      '总体结果 $_overallResultText',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                              ],
                            ),
                ),
                SafeArea(
                  top: false,
                  child: (_currentLibrary == null)
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                          child: Center(
                            child: GestureDetector(
                              onTap: () {
                                if (_voiceProcessing) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('请长按麦克风开始说话，松开结束'),
                                  ),
                                );
                              },
                              onLongPressStart: (_) async {
                                await _startVoiceSessionListening();
                              },
                              onLongPressCancel: () {
                                unawaited(_stopVoiceSessionListening());
                              },
                              onLongPressEnd: (_) {
                                unawaited(_stopVoiceSessionListening());
                              },
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                    child: const Icon(
                                      Icons.mic,
                                      color: Colors.white,
                                      size: 38,
                                    ),
                                  ),
                                  if (_voiceProcessing)
                                    const Positioned.fill(
                                      child: Padding(
                                        padding: EdgeInsets.all(18),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : Padding(
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
            if (_loading)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.black12,
                    alignment: Alignment.topCenter,
                    padding: const EdgeInsets.only(top: 12),
                    child: const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
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
  final OnlineVisionStructuredResult? analysis;

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

    final name = target.name.trim();
    final desc = target.description.trim();

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
              name.isEmpty ? '未命名指标' : name,
              style: theme.textTheme.titleSmall,
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                height: 1,
                width: double.infinity,
                color: theme.dividerColor.withAlpha(128),
              ),
              const SizedBox(height: 8),
              _CollapsibleText(
                text: desc,
                collapsedLines: 2,
                style: theme.textTheme.bodyMedium,
              ),
            ],
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
  final OnlineVisionStructuredResult result;

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

class _CollapsibleText extends StatefulWidget {
  final String text;
  final int collapsedLines;
  final TextStyle? style;

  const _CollapsibleText({
    required this.text,
    required this.collapsedLines,
    required this.style,
  });

  @override
  State<_CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<_CollapsibleText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.text.trim();
    if (t.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (ctx, c) {
        final span = TextSpan(text: t, style: widget.style);
        final painter = TextPainter(
          text: span,
          textDirection: Directionality.of(ctx),
          maxLines: widget.collapsedLines,
          ellipsis: '…',
        )..layout(maxWidth: c.maxWidth);

        final exceed = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t,
              style: widget.style,
              maxLines: _expanded ? null : widget.collapsedLines,
              overflow:
                  _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (exceed)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      _expanded = !_expanded;
                    });
                  },
                  child: Text(_expanded ? '收起' : '展开'),
                ),
              ),
          ],
        );
      },
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/defect_library_service.dart';
import '../services/gemma_multimodal_service.dart';
import '../services/online_vision_service.dart';
import '../services/last_inspection_location_service.dart';
import '../services/network_service.dart';
import '../services/backend_api_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../services/gemma_service.dart';
import '../services/database_service.dart';
import '../services/procedure_acceptance_library_service.dart';
import '../services/use_gemma_multimodal_service.dart';
import '../services/use_offline_speech_service.dart';
import '../models/library.dart';
import '../models/region.dart';
import '../widgets/photo_preview.dart';
import 'camera_capture_screen.dart';
import 'acceptance_guide_screen.dart';
import 'home_screen.dart';
import 'records_screen.dart';

class IssueReportScreen extends ConsumerStatefulWidget {
  static const routeName = 'issue-report';

  const IssueReportScreen({super.key});

  @override
  ConsumerState<IssueReportScreen> createState() => _IssueReportScreenState();
}

enum _AiConfirmAction {
  accept,
  cancel,
  voiceDescribe,
}

enum _VoiceConfirmAction {
  accept,
  retry,
  cancel,
}

class _IssueReportScreenState extends ConsumerState<IssueReportScreen> {
  final _descController = TextEditingController();

  bool _listening = false;
  bool _aiAnalyzing = false;
  bool _submitting = false;
  bool _autoCaptureTriggered = false;

  bool? _backendReachable;

  String? _photoPath;

  String _spokenIssueText = '';

  // Voice session state (for "未选择分部分项" on this page)
  bool _sessionProcessing = false;
  String _sessionPartial = '';
  String _sessionLast = '';
  String _sessionPendingFinalText = '';

  String _location = '2# / 3层 / 304';
  final List<String> _locationOptions = [
    '2# / 3层 / 304',
    '1栋 / 6层',
  ];

  bool _locationPrefilledFromExtra = false;

  void _applyLocation(String location, {required bool updateMemory}) {
    final v = location.trim();
    if (v.isEmpty) return;

    setState(() {
      if (!_locationOptions.contains(v)) {
        _locationOptions.insert(0, v);
      }
      _location = v;
    });

    if (updateMemory) {
      unawaited(
        ref.read(lastInspectionLocationProvider.notifier).setLocation(v),
      );
    }
  }

  void _onLocationChangedByUser(String v) {
    _applyLocation(v, updateMemory: true);
  }

  String? _extractIssuePhrase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // Remove location prefix like "3栋4层" (with optional spaces).
    s = s.replaceAll(
      RegExp(
        r'^[\s\S]*?([\d一二三四五六七八九十两]+\s*(?:栋|动|楼))\s*([\d一二三四五六七八九十两]+\s*(?:层|成|城|曾|楼))',
      ),
      '',
    );
    s = s.trim();
    // Prefer text after "发现" / "存在" if present.
    final m = RegExp(r'(发现|存在|出现|有)(.+)$').firstMatch(s);
    if (m != null) {
      final t = (m.group(2) ?? '').trim();
      return t.isEmpty ? null : t;
    }
    if (RegExp(
      r'(不足|过大|过小|破损|开裂|渗漏|缺失|松动|锈蚀|蜂窝|麻面|空鼓|露筋|不合格|'
      r'安全帽|安全带|未佩戴|未戴安全帽|未带安全帽|不戴安全帽|未系安全带|违章|违规|隐患|临边|防护)',
    ).hasMatch(s)) {
      return s;
    }
    return null;
  }

  Future<void> _startSessionListening() async {
    if (_sessionProcessing) return;
    final speech = ref.read(speechServiceProvider);
    final useOfflineSpeech = ref.read(useOfflineSpeechProvider);

    setState(() {
      _sessionPartial = '';
      _sessionLast = '';
      _sessionPendingFinalText = '';
    });

    final ok = await speech.startListening(
      preferOnline: !useOfflineSpeech,
      onDownloadProgress: (_) {},
      onPartialResult: (partial) {
        final p = partial.trim();
        if (p.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _sessionPartial = p;
          _sessionPendingFinalText = p;
        });
      },
      onFinalResult: (text) {
        final t = text.trim();
        if (t.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _sessionLast = t;
          _sessionPendingFinalText = t;
        });
      },
    );

    if (!mounted) return;
    if (!ok) {
      final msg = speech.lastInitError ?? '语音识别启动失败';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _stopSessionListening() async {
    final speech = ref.read(speechServiceProvider);
    if (_sessionProcessing && !speech.isListening) return;

    String finalText = '';
    await speech.stopListening(
      onFinalResult: (t) {
        finalText = t;
      },
    );

    if (!mounted) return;
    finalText = finalText.trim().isEmpty
        ? _sessionPendingFinalText.trim()
        : finalText.trim();

    setState(() {
      _sessionPendingFinalText = '';
      _sessionPartial = '';
      _sessionLast = finalText;
      _sessionProcessing = finalText.isNotEmpty;
    });

    if (finalText.isEmpty) {
      if (mounted) {
        setState(() {
          _sessionProcessing = false;
        });
      }
      return;
    }

    try {
      await _handleRecognizedTextForSession(finalText);
    } finally {
      if (mounted) {
        setState(() {
          _sessionProcessing = false;
        });
      }
    }
  }

  Future<void> _handleRecognizedTextForSession(String text) async {
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
        await tts.speak(
          '已为您匹配到${region?.name ?? enriched.regionText ?? '当前位置'} 的 ${library.name}，进入工序验收。',
        );
        if (!mounted) return;
        context.goNamed(
          AcceptanceGuideScreen.routeName,
          extra: {
            'region': region,
            'library': library,
          },
        );
        return;
      }
    }

    if (enriched.intent == 'report_issue') {
      final spoken = _extractIssuePhrase(text);
      if (enriched.regionText != null &&
          enriched.regionText!.trim().isNotEmpty) {
        _applyLocation(enriched.regionText!.trim(), updateMemory: true);
      }
      if (spoken != null && spoken.trim().isNotEmpty) {
        setState(() {
          _descController.text = spoken.trim();
          _descController.selection = TextSelection.fromPosition(
            TextPosition(offset: _descController.text.length),
          );
          _spokenIssueText = spoken.trim();
        });
        await tts.speak('已为您填写问题描述，请继续选择分部分项或拍照。');
      } else {
        await tts.speak('已进入巡检，请继续描述问题或选择分部分项。');
      }
      return;
    }

    await tts.speak('暂时无法理解您的指令，请尝试说：1栋6层发现模板开裂。');
  }

  String _division = '';
  String _subDivision = '';
  String _item = '';
  String _indicator = '';

  String _level = '一般';
  String _deadline = '3';

  String _unit = '项目部';
  String _owner = '木易';

  String? _selectedLibraryId;
  String? _clientIssueId;

  // Used to avoid self-reinforcing matches: when the description field only
  // contains the last auto-filled indicator, do not feed it back into
  // candidate selection/matching for the next photo.
  String _lastAutoFilledDesc = '';

  List<DefectLibraryEntry> _defectOptions = const [];

  static const _unitOptions = <String>['项目部', '安徽施工'];
  static const _ownerOptions = <String>['木易', '冯施工'];
  static const _levelOptions = <String>['一般', '严重'];
  static const _deadlineOptions = <String>['1', '3', '7', '15'];

  DefectLibraryEntry? _lookupEntryByIdFlexible(
    DefectLibraryService library,
    String id,
  ) {
    final raw = id.trim();
    if (raw.isEmpty) return null;

    String norm(String s) => s.replaceAll(RegExp(r'\s+'), '').trim();

    final n0 = norm(raw);
    var hit = library.byId(n0);
    if (hit != null) return hit;

    final upper = n0.toUpperCase();
    hit = library.byId(upper);
    if (hit != null) return hit;

    // Q123 -> Q-123
    if ((upper.startsWith('Q') || upper.startsWith('S')) &&
        !upper.contains('-')) {
      final withDash = '${upper.substring(0, 1)}-${upper.substring(1)}';
      hit = library.byId(withDash);
      if (hit != null) return hit;
    }

    // 123 -> Q-123 / S-123
    if (RegExp(r'^\d+$').hasMatch(n0)) {
      final parsed = int.tryParse(n0);
      final digits = parsed == null ? n0 : parsed.toString();
      hit = library.byId('Q-$digits') ?? library.byId('S-$digits');
      if (hit != null) return hit;
    }

    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_ensureDefectLibraryLoaded());
    unawaited(_probeBackend());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (kIsWeb) return;
      if (_autoCaptureTriggered) return;
      _autoCaptureTriggered = true;
      unawaited(_takePhoto());
    });
  }

  Future<void> _probeBackend() async {
    final backend = ref.read(backendApiServiceProvider);
    final ok = await backend.health();
    if (!mounted) return;
    setState(() {
      _backendReachable = ok;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final extra = GoRouterState.of(context).extra;
    if (extra is Map && extra['spokenIssueText'] is String) {
      final t = (extra['spokenIssueText'] as String).trim();
      if (t.isNotEmpty) {
        _spokenIssueText = t;
      }
    }

    if (extra is Map && extra['originText'] is String) {
      final originText = (extra['originText'] as String).trim();
      // If user already described the issue in voice and we plan to fill after
      // taking photo, don't prefill the description with raw origin text.
      if (_spokenIssueText.isEmpty &&
          originText.isNotEmpty &&
          _descController.text.trim().isEmpty) {
        _descController.text = originText;
      }
    }

    if (_locationPrefilledFromExtra) return;

    // 1) If this navigation provides a new location (voice: “三栋四层…”),
    //    prefer it and update memory.
    if (extra is Map && extra['regionText'] is String) {
      final raw = (extra['regionText'] as String).trim();
      final formatted = _formatLocationFromRegionText(
        raw,
        existingOptions: _locationOptions,
      );
      if (formatted != null && formatted.isNotEmpty) {
        _locationPrefilledFromExtra = true;
        _applyLocation(formatted, updateMemory: true);
        return;
      }
    }

    // 2) Otherwise, prefill from last remembered location.
    final remembered = ref.read(lastInspectionLocationProvider);
    if (remembered != null && remembered.trim().isNotEmpty) {
      _locationPrefilledFromExtra = true;
      _applyLocation(remembered.trim(), updateMemory: false);
    }
  }

  String? _formatLocationFromRegionText(
    String input, {
    List<String>? existingOptions,
  }) {
    var s = input.replaceAll(RegExp(r'\s+'), '').trim();
    if (s.isEmpty) return null;

    // Normalize common STT homophones for region units.
    // "1动" -> "1栋", "6成/6城/6曾" -> "6层".
    s = s.replaceAllMapped(RegExp(r'(\d+)动'), (m) => '${m.group(1)}栋');
    s = s.replaceAllMapped(
      RegExp(r'(\d+)(成|城|曾)'),
      (m) => '${m.group(1)}层',
    );

    // If caller already provides a dropdown-ready format, keep it.
    if (s.contains('/')) {
      final parts =
          s.split('/').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (parts.isEmpty) return null;
      return parts.join(' / ');
    }

    final bMatch = RegExp(r'(\d+)(?:栋|楼|#)').firstMatch(s);
    final fMatch = RegExp(r'(\d+)(?:层|楼)').firstMatch(s);
    final b = bMatch?.group(1);
    final f = fMatch?.group(1);
    if (b == null && f == null) return null;

    // Optional room number: the first 2-4 digit chunk after the floor token.
    String? room;
    if (fMatch != null) {
      final tail = s.substring(fMatch.end);
      final m = RegExp(r'(\d{2,4})(?:室|房|号)?').firstMatch(tail);
      room = m?.group(1);
    }

    final candidates = <String>[];
    void addCandidate(String buildingSuffix) {
      final r = room;
      final parts = <String>[];
      if (b != null) parts.add('$b$buildingSuffix');
      if (f != null) parts.add('$f层');
      if (r != null && r.isNotEmpty) parts.add(r);
      if (parts.isNotEmpty) candidates.add(parts.join(' / '));

      // Also allow without room for matching existing options.
      if (r != null && r.isNotEmpty) {
        final parts2 = <String>[];
        if (b != null) parts2.add('$b$buildingSuffix');
        if (f != null) parts2.add('$f层');
        if (parts2.isNotEmpty) candidates.add(parts2.join(' / '));
      }
    }

    // Prefer styles seen in the dropdown.
    final opts = existingOptions;
    final preferDong = opts != null && opts.any((e) => e.contains('栋'));
    final preferHash = opts != null && opts.any((e) => e.contains('#'));
    if (preferDong && !preferHash) {
      addCandidate('栋');
      addCandidate('#');
    } else {
      addCandidate('#');
      addCandidate('栋');
    }
    if (opts != null && opts.isNotEmpty) {
      for (final c in candidates) {
        if (opts.contains(c)) return c;
      }
    }

    // Fallback: keep the most informative (with room if present).
    return candidates.isNotEmpty ? candidates.first : null;
  }

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  Future<void> _ensureDefectLibraryLoaded() async {
    try {
      final library = ref.read(defectLibraryServiceProvider);
      await library.ensureLoaded();
      if (!mounted) return;
      setState(() {
        _defectOptions = library.entries;
      });
    } catch (_) {
      // ignore
    }
  }

  String? _deadlineOptionFromDays(int? days) {
    if (days == null) return null;
    const candidates = <int>[1, 3, 7, 15];

    int best = candidates.first;
    int bestDiff = (days - best).abs();
    for (final c in candidates.skip(1)) {
      final diff = (days - c).abs();
      if (diff < bestDiff) {
        best = c;
        bestDiff = diff;
      }
    }
    return '$best';
  }

  List<String> _uniqueNonEmpty(Iterable<String> values) {
    final out = <String>[];
    final seen = <String>{};
    for (final v in values) {
      final s = v.trim();
      if (s.isEmpty) continue;
      if (seen.add(s)) out.add(s);
    }
    return out;
  }

  void _applyEntryDefaults(DefectLibraryEntry e) {
    _selectedLibraryId = e.id;
    _division = e.division;
    _subDivision = e.subDivision;
    _item = e.item;
    _indicator = e.indicator;

    _level = _levelOptions.contains(e.levelNormalized)
        ? e.levelNormalized
        : _levelOptions.first;

    _deadline = _deadlineOptionFromDays(e.deadlineDays) ?? _deadlineOptions[1];
  }

  Future<_AiConfirmAction> _showAiConfirmSheet({
    required Widget body,
    String confirmLabel = '同意并填充',
    String cancelLabel = '不同意',
    bool allowVoiceDescribe = true,
    String voiceDescribeLabel = '我来描述(语音)',
  }) async {
    final action = await showModalBottomSheet<_AiConfirmAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '识别结果（请确认）',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                body,
                const SizedBox(height: 16),
                Row(
                  children: [
                    Flexible(
                      flex: 2,
                      child: OutlinedButton(
                        onPressed: () =>
                            Navigator.of(ctx).pop(_AiConfirmAction.cancel),
                        child: Text(cancelLabel),
                      ),
                    ),
                    if (allowVoiceDescribe) ...[
                      const SizedBox(width: 12),
                      Flexible(
                        flex: 3,
                        child: FilledButton.tonal(
                          onPressed: () => Navigator.of(ctx)
                              .pop(_AiConfirmAction.voiceDescribe),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              voiceDescribeLabel,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    Flexible(
                      flex: 3,
                      child: FilledButton(
                        onPressed: () =>
                            Navigator.of(ctx).pop(_AiConfirmAction.accept),
                        child: Text(confirmLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    return action ?? _AiConfirmAction.cancel;
  }

  Future<void> _voiceDescribeAndFill({required String beforeText}) async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Web 端暂不支持语音识别，请用真机。')),
      );
      return;
    }

    final tts = ref.read(ttsServiceProvider);
    final speech = ref.read(speechServiceProvider);
    final useOfflineSpeech = ref.read(useOfflineSpeechProvider);

    // UX: user chooses to correct AI output, so clear the old output first and
    // show live ASR text as it comes in.
    final previousDesc = _descController.text;
    setState(() {
      _descController.text = '';
      _lastAutoFilledDesc = '';
    });

    Future<String?> captureOnce() async {
      unawaited(tts.speak('请描述你发现的问题。'));

      final completer = Completer<String?>();
      var gotFinal = false;

      final ok = await speech.startListening(
        onPartialResult: (partial) {
          final p = partial.trim();
          if (p.isEmpty) return;
          if (!mounted) return;
          setState(() {
            _descController.text = p;
            _descController.selection = TextSelection.fromPosition(
              TextPosition(offset: _descController.text.length),
            );
          });
        },
        onFinalResult: (text) {
          if (gotFinal) return;
          gotFinal = true;
          final t = text.trim();
          if (!completer.isCompleted) completer.complete(t.isEmpty ? null : t);
        },
        preferOnline: !useOfflineSpeech,
      );

      if (!mounted) return null;
      if (!ok) {
        final msg = speech.lastInitError ?? '语音识别启动失败';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
        return null;
      }

      setState(() {
        _listening = true;
      });

      String? userText;
      try {
        userText = await completer.future.timeout(
          const Duration(seconds: 12),
          onTimeout: () => null,
        );
      } finally {
        try {
          await speech.stopListening();
        } catch (_) {
          // ignore
        }
        if (mounted) {
          setState(() {
            _listening = false;
          });
        }
      }

      return userText?.trim();
    }

    Future<_VoiceConfirmAction> confirmRecognizedText(String text) async {
      final action = await showModalBottomSheet<_VoiceConfirmAction>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '你刚才说的是：',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(text),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(_VoiceConfirmAction.cancel),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: () =>
                              Navigator.of(ctx).pop(_VoiceConfirmAction.retry),
                          child: const Text('重说'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(_VoiceConfirmAction.accept),
                          child: const Text('使用并回填'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );

      return action ?? _VoiceConfirmAction.cancel;
    }

    String? t;
    for (var attempt = 0; attempt < 3; attempt++) {
      final got = await captureOnce();
      if (!mounted) return;
      final s = (got ?? '').trim();
      if (s.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未识别到有效语音内容，请重试。')),
        );
        continue;
      }

      final c = await confirmRecognizedText(s);
      if (!mounted) return;
      if (c == _VoiceConfirmAction.cancel) {
        setState(() {
          _descController.text = previousDesc;
        });
        return;
      }
      if (c == _VoiceConfirmAction.accept) {
        t = s;
        break;
      }
      // retry -> loop
    }

    if (!mounted) return;
    final finalText = (t ?? '').trim();
    if (finalText.isEmpty) return;

    // Fill description from user's own words.
    setState(() {
      _descController.text = finalText;
      _descController.selection = TextSelection.fromPosition(
        TextPosition(offset: _descController.text.length),
      );
    });

    // Infer best match from local defect library and fill cascading fields.
    try {
      final library = ref.read(defectLibraryServiceProvider);
      await library.ensureLoaded();
      final inferred = library.suggest(query: finalText, limit: 1);
      if (!mounted) return;
      if (inferred.isNotEmpty) {
        setState(() {
          _applyEntryDefaults(inferred.first);
        });
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            inferred.isNotEmpty ? '已根据你的描述回填分类，可继续修改。' : '已填入描述，可手动选择分类。',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已填入描述，但本地分类匹配失败，请手动选择。')),
      );
    }
  }

  Widget _aiSummaryLine(String label, String value) {
    final v = value.trim();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 70, child: Text(label)),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  Future<void> _takePhoto() async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Web 端仅用于预览 UI，暂不支持拍照/识别。')),
      );
      return;
    }

    final path = await CameraCaptureScreen.capture(context);
    if (!mounted) return;

    if (path == null || path.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已取消拍照')));
      return;
    }

    setState(() {
      _photoPath = path;
    });

    if (_spokenIssueText.trim().isNotEmpty) {
      unawaited(ref.read(ttsServiceProvider).speak('拍照完成，正在根据你说的问题匹配问题库。'));
      unawaited(_fillFromSpokenIssueAfterPhoto(path));
      return;
    }

    unawaited(ref.read(ttsServiceProvider).speak('拍照完成，开始识别。'));
    unawaited(_analyzePhoto(path));
  }

  Future<void> _fillFromSpokenIssueAfterPhoto(String path) async {
    if (_aiAnalyzing) return;
    setState(() {
      _aiAnalyzing = true;
    });

    try {
      final library = ref.read(defectLibraryServiceProvider);
      await library.ensureLoaded();

      final issue = _spokenIssueText.trim();
      final query = ['日常巡检', _location, issue]
          .where((s) => s.trim().isNotEmpty)
          .join(' ');

      final inferred = library.suggest(query: query, limit: 1);
      final picked = inferred.isNotEmpty ? inferred.first : null;

      final merged = <String>[
        if (picked != null && picked.indicator.trim().isNotEmpty)
          picked.indicator.trim(),
        '说明：$issue',
      ].join('\n');

      if (!mounted) return;
      setState(() {
        if (picked != null) {
          _applyEntryDefaults(picked);
        }
        _descController.text = merged;
        _lastAutoFilledDesc = merged;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            picked != null ? '已根据语音描述匹配并回填，可继续修改。' : '已回填语音描述，可手动选择分类。',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('根据语音回填失败：$e')));
    } finally {
      if (mounted) {
        setState(() {
          _aiAnalyzing = false;
        });
      }
    }
  }

  Future<void> _analyzePhoto(String path) async {
    if (_aiAnalyzing) return;
    setState(() {
      _aiAnalyzing = true;
    });

    final beforeText = _descController.text.trim();
    final lastAuto = _lastAutoFilledDesc.trim();
    final userHintText =
        (lastAuto.isNotEmpty && beforeText == lastAuto) ? '' : beforeText;

    try {
      final hasNetwork = await ref.read(networkServiceProvider).hasNetwork();
      final useGemma = ref.read(useGemmaMultimodalProvider);

      final library = ref.read(defectLibraryServiceProvider);
      await library.ensureLoaded();

      const sceneHint = '日常巡检拍照（可能是缺陷照片，也可能是铭牌/送货单）';
      const hint = '优先从问题库匹配具体指标；若不匹配则给出简短可记录描述。';

      final candidateEntries = library.suggest(
        query:
            '日常巡检 $sceneHint $hint $_location ${userHintText.isEmpty ? '' : userHintText}',
        limit: 30,
      );
      final candidateLines =
          candidateEntries.map((e) => e.toPromptLine()).toList();

      if (hasNetwork && !useGemma) {
        final onlineVision = ref.read(onlineVisionServiceProvider);
        final result = await onlineVision.analyzeImageAutoStructured(
          path,
          sceneHint: sceneHint,
          hint: hint,
          defectLibraryCandidateLines: candidateLines,
        );

        if (!mounted) return;

        // Analysis is done; hide the overlay before waiting for user actions
        // (confirm / voice describe). Otherwise live ASR text will be covered.
        setState(() {
          _aiAnalyzing = false;
        });

        DefectLibraryEntry? picked;
        final matchId = result.matchId.trim();
        if (matchId.isNotEmpty) {
          picked = _lookupEntryByIdFlexible(library, matchId);
        }

        // Fallback: infer from returned text even if id lookup failed.
        // (If the model mislabels type as other, we still try local matching,
        // unless it explicitly says irrelevant.)
        if (picked == null && result.type != 'irrelevant') {
          final query = <String>[
            '日常巡检',
            _location,
            userHintText,
            result.summary,
            result.defectType,
            result.rectifySuggestion,
          ].where((s) => s.trim().isNotEmpty).join(' ');

          final inferred = library.suggest(query: query, limit: 1);
          if (inferred.isNotEmpty) picked = inferred.first;
        }

        // Preview text (not applied yet).
        final p = picked;
        final base = p?.indicator.trim() ?? '';
        final summary = result.summary.trim();
        final defectType = result.defectType.trim();
        final severity = result.severity.trim();
        final suggestion = result.rectifySuggestion.trim();

        final extraLines = <String>[];
        if (summary.isNotEmpty) extraLines.add('说明：$summary');
        if (defectType.isNotEmpty) extraLines.add('类型：$defectType');
        if (severity.isNotEmpty) extraLines.add('严重程度：$severity');
        if (suggestion.isNotEmpty) extraLines.add('整改：$suggestion');

        final mergedPreview = <String>[
          if (base.isNotEmpty) base,
          ...extraLines,
        ].join('\n');

        unawaited(ref.read(ttsServiceProvider).speak('识别完成，请确认。'));
        final action = await _showAiConfirmSheet(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p != null) ...[
                _aiSummaryLine(
                  '将填充',
                  '${p.division} / ${p.subDivision} / ${p.item} / ${p.indicator}',
                ),
                _aiSummaryLine('条目ID', p.id),
                _aiSummaryLine('级别', p.levelNormalized),
                _aiSummaryLine('整改天数', p.deadlineLabel),
              ] else ...[
                _aiSummaryLine('分类', '未命中问题库条目（可选择不填充，改为手动选择）'),
              ],
              _aiSummaryLine('类型', result.type),
              _aiSummaryLine('说明', summary),
              _aiSummaryLine('缺陷类型', defectType),
              _aiSummaryLine('严重程度', severity),
              _aiSummaryLine('整改建议', suggestion.replaceAll('；', '\n- ')),
              if (mergedPreview.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '将填入问题描述：',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    mergedPreview,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        );

        if (!mounted) return;
        if (action == _AiConfirmAction.voiceDescribe) {
          await _voiceDescribeAndFill(beforeText: beforeText);
        } else if (action == _AiConfirmAction.accept) {
          setState(() {
            if (p != null) {
              _applyEntryDefaults(p);
            }
            if (mergedPreview.trim().isNotEmpty) {
              _descController.text = mergedPreview;
              _lastAutoFilledDesc = mergedPreview;
            }
          });
        }
        return;
      }

      final gemma = ref.read(gemmaMultimodalServiceProvider);
      final result = await gemma.analyzeImageAutoStructured(
        path,
        sceneHint: sceneHint,
        hint: hint,
      );

      if (!mounted) return;

      // Analysis is done; hide the overlay before waiting for user actions.
      setState(() {
        _aiAnalyzing = false;
      });
      final text = result.text.trim();
      if (text.isNotEmpty) {
        unawaited(ref.read(ttsServiceProvider).speak('识别完成，请确认。'));
        final action = await _showAiConfirmSheet(
          body: Text(text),
          confirmLabel: '同意并填充',
          cancelLabel: '不同意',
        );
        if (!mounted) return;
        if (action == _AiConfirmAction.voiceDescribe) {
          await _voiceDescribeAndFill(beforeText: beforeText);
        } else if (action == _AiConfirmAction.accept) {
          setState(() {
            _descController.text =
                beforeText.isEmpty ? text : '$beforeText\n$text';
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('AI识别失败：$e')));
    } finally {
      if (mounted) {
        setState(() {
          _aiAnalyzing = false;
        });
      }
    }
  }

  Future<void> _toggleVoiceToText() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Web 端暂不支持语音识别，请用真机。')),
      );
      return;
    }

    final speech = ref.read(speechServiceProvider);

    if (_listening) {
      // Stop without overriding callbacks so it works for both:
      // - normal voice-to-text (callback set in startListening)
      // - voice-correction flow (callback set in _voiceDescribeAndFill)
      await speech.stopListening();
      if (!mounted) return;
      setState(() {
        _listening = false;
      });
      return;
    }

    final useOfflineSpeech = ref.read(useOfflineSpeechProvider);

    final ok = await speech.startListening(
      onPartialResult: (_) {},
      onFinalResult: (text) {
        final t = text.trim();
        if (t.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _descController.text = _descController.text.trim().isEmpty
              ? t
              : '${_descController.text.trim()}\n$t';
          _listening = false;
        });
      },
      preferOnline: !useOfflineSpeech,
    );

    if (!mounted) return;
    if (!ok) {
      final msg = speech.lastInitError ?? '语音识别启动失败';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }

    setState(() {
      _listening = true;
    });
  }

  void _save() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已暂存到本地（模拟）')),
    );
  }

  void _resetAfterSubmit() {
    setState(() {
      _photoPath = null;
      _spokenIssueText = '';
      _lastAutoFilledDesc = '';
      _clientIssueId = null;
      _descController.text = '';
      _descController.selection = const TextSelection.collapsed(offset: 0);
    });
  }

  Future<void> _submitToBackend() async {
    if (_submitting) return;
    final desc = _descController.text.trim();
    if (_item.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择分部分项/指标（或用语音匹配）')),
      );
      return;
    }
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写问题描述')),
      );
      return;
    }

    setState(() {
      _submitting = true;
    });

    _clientIssueId ??= 'issue-${DateTime.now().millisecondsSinceEpoch}';
    final backend = ref.read(backendApiServiceProvider);

    int? id;
    try {
      final deadlineDays = int.tryParse(_deadline);
      id = await backend.upsertIssueReport(
        regionText: _location,
        division: _division,
        subDivision: _subDivision,
        item: _item,
        indicator: _indicator,
        description: desc,
        severity: _level,
        deadlineDays: deadlineDays,
        responsibleUnit: _unit,
        responsiblePerson: _owner,
        libraryId: _selectedLibraryId,
        photoPath: _photoPath,
        clientRecordId: _clientIssueId!,
      );
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }

    if (!mounted) return;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提交失败：后端不可用或网络异常')),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    _resetAfterSubmit();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已提交到后端（id=$id）'),
        action: SnackBarAction(
          label: '返回首页',
          onPressed: () {
            if (!mounted) return;
            context.goNamed(HomeScreen.routeName);
          },
        ),
      ),
    );
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
      ),
      hint: const Text('请选择'),
      items: [
        for (final o in options)
          DropdownMenuItem<String>(
            value: o,
            child: Text(
              o,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final divisionOptions =
        _uniqueNonEmpty(_defectOptions.map((e) => e.division));
    final safeDivision = divisionOptions.contains(_division) ? _division : null;

    final subDivisionOptions = safeDivision == null
        ? const <String>[]
        : _uniqueNonEmpty(
            _defectOptions
                .where((e) => e.division == safeDivision)
                .map((e) => e.subDivision),
          );
    final safeSubDivision =
        subDivisionOptions.contains(_subDivision) ? _subDivision : null;

    final itemOptions = (safeDivision == null || safeSubDivision == null)
        ? const <String>[]
        : _uniqueNonEmpty(
            _defectOptions
                .where((e) =>
                    e.division == safeDivision &&
                    e.subDivision == safeSubDivision)
                .map((e) => e.item),
          );
    final safeItem = itemOptions.contains(_item) ? _item : null;

    final indicatorOptions =
        (safeDivision == null || safeSubDivision == null || safeItem == null)
            ? const <String>[]
            : _uniqueNonEmpty(
                _defectOptions
                    .where((e) =>
                        e.division == safeDivision &&
                        e.subDivision == safeSubDivision &&
                        e.item == safeItem)
                    .map((e) => e.indicator),
              );
    final safeIndicator =
        indicatorOptions.contains(_indicator) ? _indicator : null;

    void applyMatchedEntryIfAny() {
      final d = safeDivision;
      final sd = safeSubDivision;
      final it = safeItem;
      final ind = safeIndicator;
      if (d == null || sd == null || it == null || ind == null) return;

      final candidates = _defectOptions
          .where((e) =>
              e.division == d &&
              e.subDivision == sd &&
              e.item == it &&
              e.indicator == ind)
          .toList();
      if (candidates.isEmpty) return;

      setState(() {
        _applyEntryDefaults(candidates.first);
        if (_descController.text.trim().isEmpty) {
          _descController.text = candidates.first.indicator.trim();
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.goNamed(HomeScreen.routeName),
        ),
        title: const Text('记录问题'),
        actions: [
          IconButton(
            onPressed: () {
              context.pushNamed(
                RecordsScreen.routeName,
                queryParameters: const {'tab': 'issue'},
              );
            },
            icon: const Icon(Icons.table_rows),
            tooltip: '查看记录表',
          ),
          IconButton(
            onPressed: () => context.goNamed(HomeScreen.routeName),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: (_item.trim().isEmpty)
          ? GestureDetector(
              onTap: () {
                if (_sessionProcessing) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请长按麦克风开始说话，松开结束')),
                );
              },
              onLongPressStart: (_) async {
                await _startSessionListening();
              },
              onLongPressCancel: () {
                unawaited(_stopSessionListening());
              },
              onLongPressEnd: (_) {
                unawaited(_stopSessionListening());
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    child: const Icon(
                      Icons.mic,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                  if (_sessionProcessing)
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
            )
          : null,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                if (_backendReachable != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        Icon(
                          _backendReachable!
                              ? Icons.cloud_done
                              : Icons.cloud_off,
                          size: 18,
                          color: _backendReachable!
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _backendReachable!
                                ? '后端已连接（可提交到数据库）'
                                : '后端未连接（当前只能暂存/提交会失败）',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: _probeBackend,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _PhotoBox(
                              photoPath: _photoPath,
                              onTap: _takePhoto,
                              onClear: () => setState(() => _photoPath = null),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DropdownTile(
                              label: '部位',
                              value: _location,
                              options: _locationOptions,
                              onChanged: _onLocationChangedByUser,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildCascadingDropdown(
                              label: '分部',
                              value: safeDivision,
                              options: divisionOptions,
                              onChanged: (v) {
                                setState(() {
                                  _division = v ?? '';
                                  _subDivision = '';
                                  _item = '';
                                  _indicator = '';
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildCascadingDropdown(
                              label: '子分部',
                              value: safeSubDivision,
                              options: subDivisionOptions,
                              onChanged: (v) {
                                setState(() {
                                  _subDivision = v ?? '';
                                  _item = '';
                                  _indicator = '';
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildCascadingDropdown(
                              label: '分项',
                              value: safeItem,
                              options: itemOptions,
                              onChanged: (v) {
                                setState(() {
                                  _item = v ?? '';
                                  _indicator = '';
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildCascadingDropdown(
                              label: '指标',
                              value: safeIndicator,
                              options: indicatorOptions,
                              onChanged: (v) {
                                setState(() => _indicator = v ?? '');
                                applyMatchedEntryIfAny();
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _LevelToggleTile(
                              label: '问题级别',
                              value: _levelOptions.contains(_level)
                                  ? _level
                                  : _levelOptions.first,
                              options: _levelOptions,
                              onChanged: (v) => setState(() => _level = v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DropdownTile(
                              label: '整改时限',
                              value: _deadlineOptions.contains(_deadline)
                                  ? _deadline
                                  : _deadlineOptions[1],
                              options: _deadlineOptions,
                              onChanged: (v) => setState(() => _deadline = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _DropdownTile(
                              label: '责任单位',
                              value: _unit,
                              options: _unitOptions,
                              onChanged: (v) => setState(() => _unit = v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DropdownTile(
                              label: '责任人',
                              value: _owner,
                              options: _ownerOptions,
                              onChanged: (v) => setState(() => _owner = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_listening) ...[
                        Card(
                          elevation: 0,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text('正在聆听…（实时识别中）'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final speech =
                                        ref.read(speechServiceProvider);
                                    try {
                                      await speech.stopListening();
                                    } catch (_) {
                                      // ignore
                                    }
                                    if (!mounted) return;
                                    setState(() {
                                      _listening = false;
                                    });
                                  },
                                  child: const Text('点击停止'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      OutlinedButton.icon(
                        onPressed: _aiAnalyzing ? null : _toggleVoiceToText,
                        icon: Icon(_listening ? Icons.stop : Icons.mic),
                        label: Text(_listening ? '停止' : '语音转文字'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _descController,
                        minLines: 2,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: '问题描述',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _save,
                            child: const Text('暂存'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: (_aiAnalyzing || _submitting)
                                ? null
                                : _submitToBackend,
                            child: const Text('保存'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_item.trim().isEmpty &&
              (_sessionPartial.isNotEmpty || _sessionLast.isNotEmpty))
            Positioned(
              left: 16,
              right: 16,
              bottom: 110,
              child: Card(
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_sessionPartial.isNotEmpty)
                        Text('实时识别：$_sessionPartial'),
                      if (_sessionLast.isNotEmpty)
                        Text(
                          '上次识别：$_sessionLast',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (_aiAnalyzing)
            const ColoredBox(
              color: Colors.black54,
              child: Center(child: _AnalyzingIndicator()),
            ),
        ],
      ),
    );
  }
}

class _AnalyzingIndicator extends StatelessWidget {
  const _AnalyzingIndicator();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 12),
            Text('AI分析中…'),
          ],
        ),
      ),
    );
  }
}

class _DropdownTile extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _DropdownTile({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = options.contains(value)
        ? value
        : (options.isEmpty ? null : options.first);

    return DropdownButtonFormField<String>(
      isExpanded: true,
      value: safeValue,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final o in options)
          DropdownMenuItem<String>(
            value: o,
            child: Text(
              o,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        onChanged(v);
      },
    );
  }
}

class _LevelToggleTile extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _LevelToggleTile({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (final o in options)
            ChoiceChip(
              label: Text(o),
              selected: o == value,
              onSelected: (_) => onChanged(o),
            ),
        ],
      ),
    );
  }
}

class _PhotoBox extends StatelessWidget {
  final String? photoPath;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _PhotoBox({
    required this.photoPath,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('现场照片', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 1.4,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: photoPath == null
                      ? const Center(child: Icon(Icons.camera_alt, size: 36))
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: PhotoPreview(path: photoPath!),
                        ),
                ),
                if (photoPath != null)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: IconButton(
                      onPressed: onClear,
                      icon: const Icon(Icons.close),
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

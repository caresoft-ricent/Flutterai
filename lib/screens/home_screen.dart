import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/library.dart';
import '../models/region.dart';
import '../services/database_service.dart';
import '../services/gemma_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../services/gemma_multimodal_service.dart';
import '../services/procedure_acceptance_library_service.dart';
import '../services/use_gemma_multimodal_service.dart';
import '../services/use_offline_speech_service.dart';
import '../utils/constants.dart';
import 'acceptance_guide_screen.dart';
import 'issue_report_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  static const routeName = 'home';

  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _lastInput = '';
  String _partialInput = '';
  String _status = '点击下方麦克风开始说话';
  bool _isProcessing = false;
  bool _isDownloadingModel = false;

  String _pendingFinalText = '';

  Future<bool> _ensureGemmaMultimodalWithProgress() async {
    if (!mounted) return false;

    final mm = ref.read(gemmaMultimodalServiceProvider);
    final progress = ValueNotifier<int>(0);

    bool dialogShown = false;
    Future<void>? dialogFuture;
    bool finished = false;

    void showIfNeeded() {
      if (dialogShown || !mounted) return;
      dialogShown = true;
      dialogFuture = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('下载Gemma多模态模型(~3GB)'),
            content: ValueListenableBuilder<int>(
              valueListenable: progress,
              builder: (_, v, __) {
                final pct = v.clamp(0, 100).toString();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('首次启用需要下载离线多模态模型（需要HuggingFace访问授权）。'),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: v == 0 ? null : v / 100),
                    const SizedBox(height: 8),
                    Text('进度：$pct%'),
                  ],
                );
              },
            ),
          );
        },
      );
    }

    Future<void>.delayed(const Duration(milliseconds: 500)).then((_) {
      if (!mounted) return;
      if (finished) return;
      showIfNeeded();
    });

    try {
      await mm.ensureInstalled(
        onProgress: (p) {
          progress.value = p;
          if (p > 0) showIfNeeded();
        },
      );
      finished = true;
      if (!mounted) return true;
      if (dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        await dialogFuture!;
      }
      return true;
    } catch (_) {
      finished = true;
      if (mounted && dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        await dialogFuture!;
      }
      rethrow;
    } finally {
      finished = true;
      progress.dispose();
    }
  }

  Future<bool> _initSpeechWithProgress() async {
    if (!mounted) return false;
    if (_isDownloadingModel) return false;

    final speech = ref.read(speechServiceProvider);
    final progress = ValueNotifier<double>(0);

    setState(() {
      _isDownloadingModel = true;
    });

    bool dialogShown = false;
    Future<void>? dialogFuture;
    bool finished = false;

    void showIfNeeded() {
      if (dialogShown || !mounted) return;
      dialogShown = true;
      dialogFuture = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('下载语音模型(~300MB)'),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, __) {
                final pct = (v * 100).clamp(0, 100).toStringAsFixed(0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('首次运行需要下载离线语音模型，请保持网络。'),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: v == 0 ? null : v),
                    const SizedBox(height: 8),
                    Text('进度：$pct%'),
                  ],
                );
              },
            ),
          );
        },
      );
    }

    // If the download has started but progress callback hasn't fired yet,
    // show an indeterminate dialog to avoid feeling "stuck".
    Future<void>.delayed(const Duration(milliseconds: 500)).then((_) {
      if (!mounted) return;
      if (finished) return;
      showIfNeeded();
    });

    try {
      final ok = await speech.init(
        onDownloadProgress: (p) {
          progress.value = p;
          if (p > 0) {
            showIfNeeded();
          }
        },
      );
      finished = true;
      if (!mounted) return ok;
      if (dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        await dialogFuture!;
      }
      return ok;
    } catch (_) {
      finished = true;
      if (mounted && dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        await dialogFuture!;
      }
      rethrow;
    } finally {
      finished = true;
      progress.dispose();
      if (mounted) {
        setState(() {
          _isDownloadingModel = false;
        });
      }
    }
  }

  Future<void> _startListening() async {
    final speech = ref.read(speechServiceProvider);
    final useOfflineSpeech = ref.read(useOfflineSpeechProvider);
    final preferOnline = !useOfflineSpeech;

    // Online-first mode: try Xunfei directly. Only if it fails, fall back to
    // offline init + sherpa.
    if (preferOnline) {
      setState(() {
        _status = '正在连接在线语音识别…';
        _lastInput = '';
        _partialInput = '';
        _pendingFinalText = '';
      });

      final startedOnline = await speech.startListening(
        preferOnline: true,
        onDownloadProgress: (_) {},
        onPartialResult: (partial) {
          if (!mounted) return;
          setState(() {
            _partialInput = partial;
            _status = '正在说：$partial';
          });
        },
        onFinalResult: (text) {
          if (!mounted) return;
          setState(() {
            _pendingFinalText = text;
          });
        },
        finalizeOnEndpoint: false,
      );

      if (startedOnline) return;
    }

    // Offline fallback / normal mode: ensure sherpa model is ready.
    if (!speech.isReady) {
      final ok = await _initSpeechWithProgress();
      if (!ok && mounted) {
        setState(() {
          _status =
              (speech.lastInitError == null || speech.lastInitError!.isEmpty)
                  ? '语音模型未就绪：请先完成模型下载'
                  : '语音模型未就绪：${speech.lastInitError}';
        });
        if (mounted && speech.lastInitError != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('模型初始化失败：${speech.lastInitError}')),
          );
        }
        return;
      }
    }

    setState(() {
      _status = '正在监听，请说出验收指令…';
      _lastInput = '';
      _partialInput = '';
      _pendingFinalText = '';
    });

    final started = await speech.startListening(
      preferOnline: false,
      onDownloadProgress: (p) {
        // Show progress dialog only when download actually starts.
        // Home screen handles dialog via init() when invoked by startListening.
      },
      onPartialResult: (partial) {
        if (!mounted) return;
        setState(() {
          _partialInput = partial;
          _status = '正在说：$partial';
        });
      },
      // Long-press UX: do not auto-finish while finger is still holding.
      // We'll finalize and parse on release (stopListening).
      onFinalResult: (text) {
        if (!mounted) return;
        setState(() {
          _pendingFinalText = text;
        });
      },
      finalizeOnEndpoint: false,
    );

    if (!started && mounted) {
      setState(() {
        _status = preferOnline
            ? '在线识别不可用，已回落离线：请检查网络/讯飞配置/麦克风权限'
            : '语音识别未就绪：请允许麦克风权限，并完成模型下载';
      });
    }
  }

  Future<void> _stopListening() async {
    final speech = ref.read(speechServiceProvider);

    // If we are still recording/listening, always allow stopping even when
    // we're in a processing state, to avoid getting "stuck listening".
    if (_isProcessing && !speech.isListening) return;

    String finalText = '';
    await speech.stopListening(
      onFinalResult: (t) {
        finalText = t;
      },
    );

    if (!mounted) return;
    finalText = finalText.trim().isEmpty ? _pendingFinalText.trim() : finalText;
    setState(() {
      _pendingFinalText = '';
      _partialInput = '';
      _lastInput = finalText;
      _status = finalText.isEmpty ? '已停止监听' : '识别完成，正在解析意图…';
      _isProcessing = finalText.isNotEmpty;
    });

    if (finalText.isNotEmpty) {
      await _handleRecognizedText(finalText);
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _handleRecognizedText(String text) async {
    final gemma = ref.read(gemmaServiceProvider);
    final db = ref.read(databaseServiceProvider);
    final procedureLibrary =
        ref.read(procedureAcceptanceLibraryServiceProvider);
    final tts = ref.read(ttsServiceProvider);

    try {
      final base = await gemma.parseIntent(text);
      final enriched = await gemma.enrichWithLocalData(base, text);

      if (!mounted) return;

      if (enriched.intent == 'procedure_acceptance' &&
          (enriched.regionCode != null || enriched.regionText != null)) {
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

        if (region != null && library != null) {
          await tts.speak('已为您匹配到${region.name} 的 ${library.name}，开始验收引导。');

          if (!mounted) return;
          context.goNamed(
            AcceptanceGuideScreen.routeName,
            extra: {
              'region': region,
              'library': library,
            },
          );
        } else {
          await tts.speak('未能匹配到分项或位置，请重试。');
          if (!mounted) return;
          setState(() {
            _status = '未匹配到分项或位置，请重试';
          });
        }
      } else if (enriched.intent == 'report_issue') {
        await tts.speak('检测到问题上报意图，进入问题上报页面。');
        if (!mounted) return;

        String? extractIssuePhrase(String raw) {
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
          // Otherwise if it contains typical issue / safety violation keywords, keep as-is.
          if (RegExp(
            r'(不足|过大|过小|破损|开裂|渗漏|缺失|松动|锈蚀|蜂窝|麻面|空鼓|露筋|不合格|'
            r'安全帽|安全带|未佩戴|未戴安全帽|未带安全帽|不戴安全帽|未系安全带|违章|违规|隐患|临边|防护)',
          ).hasMatch(s)) {
            return s;
          }
          return null;
        }

        final spokenIssueText = extractIssuePhrase(text);

        context.goNamed(
          IssueReportScreen.routeName,
          extra: {
            'originText': text,
            // For巡检部位，优先让问题页从原始语音句子里提取更完整的位置
            // （例如“1栋2层201发现问题”中的 201 室），而不是仅使用
            // enrich 后可能丢失房间号的 regionText。
            'regionText': text,
            if (spokenIssueText != null && spokenIssueText.trim().isNotEmpty)
              'spokenIssueText': spokenIssueText.trim(),
          },
        );
      } else {
        await tts.speak('暂时无法理解您的指令，请尝试说：我要验收1栋6层的钢筋。');
        if (!mounted) return;
        setState(() {
          _status = '意图无法识别，请重试';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMultimodal = ref.watch(useGemmaMultimodalProvider);
    final useOfflineSpeech = ref.watch(useOfflineSpeechProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('河狸云AI - Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainerHighest,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('启用离线语音识别')),
                        Switch(
                          value: useOfflineSpeech,
                          onChanged: (v) async {
                            await ref
                                .read(useOfflineSpeechProvider.notifier)
                                .setEnabled(v);
                            if (!context.mounted) return;
                            setState(() {
                              _status = v ? '离线语音识别已开启' : '离线语音识别已关闭（使用讯飞在线）';
                            });
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 12),
                    Row(
                      children: [
                        const Expanded(child: Text('启用离线Gemma多模态（图片识别）')),
                        Switch(
                          value: useMultimodal,
                          onChanged: _isProcessing
                              ? null
                              : (v) async {
                                  final notifier = ref.read(
                                      useGemmaMultimodalProvider.notifier);

                                  if (v) {
                                    try {
                                      setState(() {
                                        _status = '正在准备Gemma多模态模型…';
                                      });
                                      final ok =
                                          await _ensureGemmaMultimodalWithProgress();
                                      if (!context.mounted) return;
                                      if (ok) {
                                        await notifier.setEnabled(true);
                                        if (!context.mounted) return;
                                        setState(() {
                                          _status = 'Gemma多模态已启用';
                                        });
                                      }
                                    } catch (e) {
                                      await notifier.setEnabled(false);
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Gemma多模态启用失败：$e\n提示：该模型在 HuggingFace 为受限仓库，需要先同意许可并提供 token（--dart-define=HUGGINGFACE_TOKEN=... 或 lib/app_local_secrets.dart:kHuggingfaceToken）。',
                                          ),
                                        ),
                                      );
                                      if (!context.mounted) return;
                                      setState(() {
                                        _status = '多模态启用失败，已回退规则解析';
                                      });
                                    }
                                  } else {
                                    await notifier.setEnabled(false);
                                    if (!context.mounted) return;
                                    setState(() {
                                      _status = '多模态已关闭';
                                    });
                                  }
                                },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () {
                            context.goNamed(AcceptanceGuideScreen.routeName);
                          },
                    icon: const Icon(Icons.checklist),
                    label: const Text('工序验收'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () {
                            context.go('/daily-inspection');
                          },
                    icon: const Icon(Icons.fact_check),
                    label: const Text('日常巡检'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () {
                            context.go('/supervision-check');
                          },
                    icon: const Icon(Icons.assignment_turned_in),
                    label: const Text('监督检查'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '示例指令',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ...DemoConstants.exampleCommands.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.mic, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: isDark
                  ? colorScheme.surfaceContainerHighest
                  : colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前状态',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_status),
                    if (_partialInput.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: Text(
                          '实时识别：$_partialInput',
                          key: ValueKey(_partialInput),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                    if (_lastInput.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '上次识别：$_lastInput',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Spacer(),
            if (_isProcessing)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            Center(
              child: GestureDetector(
                onTap: () {
                  if (_isProcessing) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请长按麦克风开始说话，松开结束')),
                  );
                },
                onLongPressStart: (_) async {
                  if (_isProcessing) return;
                  await _startListening();
                },
                onLongPressCancel: () {
                  // Gesture got cancelled (e.g. finger slid out / interruption).
                  unawaited(_stopListening());
                },
                onLongPressEnd: (_) async {
                  unawaited(_stopListening());
                },
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  child: const Icon(
                    Icons.mic,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

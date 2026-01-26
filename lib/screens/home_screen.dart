import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';

import '../l10n/context_l10n.dart';
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
import 'acceptance_guide_screen.dart';
import 'app_settings_screen.dart';
import 'issue_report_screen.dart';
import 'panorama_inspection_screen.dart';
import 'ai_chat_screen.dart';
import 'records_screen.dart';
import 'project_dashboard_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  static const routeName = 'home';

  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

enum _HomeStatusKind {
  tapMicToStart,
  connectingOnlineAsr,
  listeningSpeakCommand,
  speaking,
  onlineUnavailableFallback,
  asrNotReady,
  speechModelNotReadyDownloadFirst,
  speechModelNotReadyWithError,
  offlineSpeechEnabled,
  offlineSpeechDisabled,
  preparingGemmaMultimodal,
  gemmaMultimodalEnabled,
  gemmaMultimodalEnableFailedFallback,
  gemmaMultimodalDisabled,
  stoppedListening,
  intentParsing,
  notMatchedRetry,
  intentUnrecognizedRetry,
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _lastInput = '';
  String _partialInput = '';
  _HomeStatusKind _statusKind = _HomeStatusKind.tapMicToStart;
  String? _statusArg;
  bool _isProcessing = false;
  bool _isDownloadingModel = false;

  String _pendingFinalText = '';

  String _statusText(AppLocalizations l10n) {
    switch (_statusKind) {
      case _HomeStatusKind.tapMicToStart:
        return l10n.homeStatusTapMicToStart;
      case _HomeStatusKind.connectingOnlineAsr:
        return l10n.homeStatusConnectingOnlineAsr;
      case _HomeStatusKind.listeningSpeakCommand:
        return l10n.homeStatusListeningSpeakCommand;
      case _HomeStatusKind.speaking:
        return l10n.homeStatusSpeaking(_statusArg ?? '');
      case _HomeStatusKind.onlineUnavailableFallback:
        return l10n.homeStatusOnlineUnavailableFallback;
      case _HomeStatusKind.asrNotReady:
        return l10n.homeStatusAsrNotReady;
      case _HomeStatusKind.speechModelNotReadyDownloadFirst:
        return l10n.homeStatusSpeechModelNotReadyDownloadFirst;
      case _HomeStatusKind.speechModelNotReadyWithError:
        return l10n.homeStatusSpeechModelNotReadyWithError(_statusArg ?? '');
      case _HomeStatusKind.offlineSpeechEnabled:
        return l10n.homeStatusOfflineSpeechEnabled;
      case _HomeStatusKind.offlineSpeechDisabled:
        return l10n.homeStatusOfflineSpeechDisabled;
      case _HomeStatusKind.preparingGemmaMultimodal:
        return l10n.homeStatusPreparingGemmaMultimodal;
      case _HomeStatusKind.gemmaMultimodalEnabled:
        return l10n.homeStatusGemmaMultimodalEnabled;
      case _HomeStatusKind.gemmaMultimodalEnableFailedFallback:
        return l10n.homeStatusGemmaMultimodalEnableFailedFallback;
      case _HomeStatusKind.gemmaMultimodalDisabled:
        return l10n.homeStatusGemmaMultimodalDisabled;
      case _HomeStatusKind.stoppedListening:
        return l10n.homeStatusStoppedListening;
      case _HomeStatusKind.intentParsing:
        return l10n.homeStatusIntentParsing;
      case _HomeStatusKind.notMatchedRetry:
        return l10n.homeStatusNotMatchedRetry;
      case _HomeStatusKind.intentUnrecognizedRetry:
        return l10n.homeStatusIntentUnrecognizedRetry;
    }
  }

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
          final l10n = ctx.l10n;
          return AlertDialog(
            title: Text(l10n.homeDownloadGemmaTitle),
            content: ValueListenableBuilder<int>(
              valueListenable: progress,
              builder: (_, v, __) {
                final pct = v.clamp(0, 100).toString();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.homeDownloadGemmaBody),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: v == 0 ? null : v / 100),
                    const SizedBox(height: 8),
                    Text(l10n.homeProgressLabel(pct)),
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
          final l10n = ctx.l10n;
          return AlertDialog(
            title: Text(l10n.homeDownloadSpeechTitle),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, __) {
                final pct = (v * 100).clamp(0, 100).toStringAsFixed(0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.homeDownloadSpeechBody),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: v == 0 ? null : v),
                    const SizedBox(height: 8),
                    Text(l10n.homeProgressLabel(pct)),
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
    final l10n = context.l10n;

    // Online-first mode: try Xunfei directly. Only if it fails, fall back to
    // offline init + sherpa.
    if (preferOnline) {
      setState(() {
        _statusKind = _HomeStatusKind.connectingOnlineAsr;
        _statusArg = null;
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
            _statusKind = _HomeStatusKind.speaking;
            _statusArg = partial;
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
          if (speech.lastInitError == null || speech.lastInitError!.isEmpty) {
            _statusKind = _HomeStatusKind.speechModelNotReadyDownloadFirst;
            _statusArg = null;
          } else {
            _statusKind = _HomeStatusKind.speechModelNotReadyWithError;
            _statusArg = speech.lastInitError;
          }
        });
        if (mounted && speech.lastInitError != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l10n.homeSnackModelInitFailed(speech.lastInitError!),
              ),
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _statusKind = _HomeStatusKind.listeningSpeakCommand;
      _statusArg = null;
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
          _statusKind = _HomeStatusKind.speaking;
          _statusArg = partial;
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
        _statusKind = preferOnline
            ? _HomeStatusKind.onlineUnavailableFallback
            : _HomeStatusKind.asrNotReady;
        _statusArg = null;
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
      _statusKind = finalText.isEmpty
          ? _HomeStatusKind.stoppedListening
          : _HomeStatusKind.intentParsing;
      _statusArg = null;
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
    final l10n = context.l10n;

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
          await tts.speak(
            l10n.homeTtsMatchedStartAcceptance(region.name, library.name),
          );

          if (!mounted) return;
          context.goNamed(
            AcceptanceGuideScreen.routeName,
            extra: {
              'region': region,
              'library': library,
            },
          );
        } else {
          await tts.speak(l10n.homeTtsNotMatchedRetry);
          if (!mounted) return;
          setState(() {
            _statusKind = _HomeStatusKind.notMatchedRetry;
            _statusArg = null;
          });
        }
      } else if (enriched.intent == 'report_issue') {
        await tts.speak(l10n.homeTtsEnteringIssueReport);
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
        await tts.speak(l10n.homeTtsCannotUnderstandTryExample);
        if (!mounted) return;
        setState(() {
          _statusKind = _HomeStatusKind.intentUnrecognizedRetry;
          _statusArg = null;
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
    // NOTE: HomeScreen has lots of runtime strings; we incrementally migrate them to l10n.
    final l10n = context.l10n;
    final useMultimodal = ref.watch(useGemmaMultimodalProvider);
    final useOfflineSpeech = ref.watch(useOfflineSpeechProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.homeTitle),
        actions: [
          IconButton(
            onPressed: () {
              context.pushNamed(RecordsScreen.routeName);
            },
            icon: const Icon(Icons.table_rows),
            tooltip: l10n.navRecords,
          ),
          IconButton(
            onPressed: () {
              context.pushNamed(AppSettingsScreen.routeName);
            },
            icon: const Icon(Icons.settings),
            tooltip: l10n.navSettings,
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          height: 64,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  // Move a bit towards center to visually match the extended
                  // button on the right.
                  padding: const EdgeInsets.only(left: 28),
                  child: FloatingActionButton(
                    heroTag: 'fab-dashboard',
                    onPressed: _isProcessing
                        ? null
                        : () {
                            context.pushNamed(ProjectDashboardScreen.routeName);
                          },
                    tooltip: l10n.homeTooltipProjectDashboard,
                    child: const Icon(Icons.dashboard),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: FloatingActionButton.extended(
                  heroTag: 'fab-ai-chat',
                  onPressed: _isProcessing
                      ? null
                      : () {
                          context.pushNamed(AiChatScreen.routeName);
                        },
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: Text(l10n.homeLabelAiChat),
                ),
              ),
            ],
          ),
        ),
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
                        Expanded(child: Text(l10n.homeToggleOfflineSpeech)),
                        Switch(
                          value: useOfflineSpeech,
                          onChanged: (v) async {
                            await ref
                                .read(useOfflineSpeechProvider.notifier)
                                .setEnabled(v);
                            if (!context.mounted) return;
                            setState(() {
                              _statusKind = v
                                  ? _HomeStatusKind.offlineSpeechEnabled
                                  : _HomeStatusKind.offlineSpeechDisabled;
                              _statusArg = null;
                            });
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(l10n.homeToggleOfflineGemmaMultimodal),
                        ),
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
                                        _statusKind = _HomeStatusKind
                                            .preparingGemmaMultimodal;
                                        _statusArg = null;
                                      });
                                      final ok =
                                          await _ensureGemmaMultimodalWithProgress();
                                      if (!context.mounted) return;
                                      if (ok) {
                                        await notifier.setEnabled(true);
                                        if (!context.mounted) return;
                                        setState(() {
                                          _statusKind = _HomeStatusKind
                                              .gemmaMultimodalEnabled;
                                          _statusArg = null;
                                        });
                                      }
                                    } catch (e) {
                                      await notifier.setEnabled(false);
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            l10n.homeSnackGemmaMultimodalEnableFailed(
                                              e,
                                            ),
                                          ),
                                        ),
                                      );
                                      if (!context.mounted) return;
                                      setState(() {
                                        _statusKind = _HomeStatusKind
                                            .gemmaMultimodalEnableFailedFallback;
                                        _statusArg = null;
                                      });
                                    }
                                  } else {
                                    await notifier.setEnabled(false);
                                    if (!context.mounted) return;
                                    setState(() {
                                      _statusKind = _HomeStatusKind
                                          .gemmaMultimodalDisabled;
                                      _statusArg = null;
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
                    label: Text(l10n.homeButtonProcedureAcceptance),
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
                    label: Text(l10n.homeButtonDailyInspection),
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
                    label: Text(l10n.homeButtonSupervisionCheck),
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
                            context.goNamed(
                              PanoramaInspectionScreen.routeName,
                            );
                          },
                    icon: const Icon(Icons.panorama_horizontal),
                    label: Text(l10n.homeButtonPanoramaInspection),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              l10n.homeSectionExampleCommands,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ...l10n.homeExampleCommands
                .split('\n')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .map(
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
                      l10n.homeSectionCurrentStatus,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_statusText(l10n)),
                    if (_partialInput.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: Text(
                          l10n.homeRealtimeRecognition(_partialInput),
                          key: ValueKey(_partialInput),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                    if (_lastInput.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.homeLastRecognition(_lastInput),
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
                    SnackBar(
                      content: Text(l10n.homeSnackLongPressMicHint),
                    ),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/context_l10n.dart';
import '../services/backend_api_service.dart';
import '../services/ai_chat_session_store.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../services/use_offline_speech_service.dart';

class AiChatScreen extends ConsumerStatefulWidget {
  static const routeName = 'ai-chat';

  const AiChatScreen({super.key});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();

  bool _sending = false;
  bool _listening = false;
  bool _voiceProcessing = false;
  String _voicePartial = '';
  String _voicePendingFinalText = '';

  bool _aiEnabled = false;

  String? _sessionId;
  bool _sessionLoading = true;

  late final SpeechService _speech;
  late final TtsService _tts;

  final List<_ChatMessage> _messages = [];

  Map<String, dynamic>? _lastMeta;

  @override
  void initState() {
    super.initState();
    _speech = ref.read(speechServiceProvider);
    _tts = ref.read(ttsServiceProvider);
    _loadAiEnabled();
    _initSession();
  }

  Future<void> _loadAiEnabled() async {
    final v = await BackendApiService.getAiEnabled();
    if (!mounted) return;
    setState(() {
      _aiEnabled = v;
    });
  }

  Future<void> _toggleAiEnabled() async {
    final next = !_aiEnabled;
    setState(() {
      _aiEnabled = next;
    });
    await BackendApiService.setAiEnabled(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          next
              ? context.l10n.backendAiEnabledOn
              : context.l10n.backendAiEnabledOff,
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_speech.isListening) {
      _speech.cancel();
    }
    _tts.stop();
    _inputFocusNode.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initSession() async {
    try {
      final l10n = context.l10n;
      final sessions = await AiChatSessionStore.loadAll();
      final cur = await AiChatSessionStore.getCurrentId();
      final match = cur == null
          ? null
          : sessions.cast<AiChatSession?>().firstWhere(
                (s) => s?.id == cur,
                orElse: () => null,
              );

      if (!mounted) return;

      if (match != null) {
        _applySession(match);
        setState(() {
          _sessionId = match.id;
          _sessionLoading = false;
        });
        return;
      }

      final seed = _messages.map((m) => m.toJson()).toList(growable: false);
      final created = await AiChatSessionStore.upsert(
        AiChatSession.newSession(title: l10n.aiChatNewSessionTitle, seed: seed),
      );
      if (!mounted) return;
      setState(() {
        _sessionId = created.id;
        _sessionLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sessionLoading = false;
      });
    }
  }

  void _applySession(AiChatSession session) {
    final loaded = session.messages
        .map((m) => _ChatMessage.fromJson(m))
        .where((m) => m.text.trim().isNotEmpty)
        .where((m) => !_isSeedMessageText(m.text))
        .toList(growable: false);

    _messages
      ..clear()
      ..addAll(loaded);
    _lastMeta = null;
  }

  bool _isSeedMessageText(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return t.startsWith('你可以自由问：') ||
        t.startsWith('You can ask freely:') ||
        t.startsWith('يمكنك أن تسأل بحرية');
  }

  _ChatMessage _seedMessage(BuildContext context) {
    final l10n = context.l10n;
    return _ChatMessage(role: _Role.assistant, text: l10n.aiChatSeedMessage);
  }

  String _deriveSessionTitle() {
    final l10n = context.l10n;
    final firstUser = _messages.firstWhere(
      (m) => m.role == _Role.user && m.text.trim().isNotEmpty,
      orElse: () => const _ChatMessage(role: _Role.user, text: ''),
    );
    final t = firstUser.text.trim();
    if (t.isEmpty) return l10n.aiChatNewSessionTitle;
    return t.length > 16 ? '${t.substring(0, 16)}…' : t;
  }

  Future<void> _persistSession() async {
    final id = _sessionId;
    if (id == null) return;
    final title = _deriveSessionTitle();
    final session = AiChatSession(
      id: id,
      title: title,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      messages: _messages.map((m) => m.toJson()).toList(growable: false),
    );
    await AiChatSessionStore.upsert(session);
  }

  Future<void> _createNewSession() async {
    final l10n = context.l10n;
    const seed = <Map<String, dynamic>>[];
    final created = await AiChatSessionStore.upsert(
      AiChatSession.newSession(title: l10n.aiChatNewSessionTitle, seed: seed),
    );
    if (!mounted) return;
    setState(() {
      _sessionId = created.id;
      _sending = false;
      _lastMeta = null;
      _messages.clear();
    });
    await _scrollToBottom();
  }

  Future<void> _loadSessionById(String id) async {
    final sessions = await AiChatSessionStore.loadAll();
    final s = sessions.cast<AiChatSession?>().firstWhere(
          (x) => x?.id == id,
          orElse: () => null,
        );
    if (s == null) return;
    if (!mounted) return;
    setState(() {
      _sessionId = s.id;
      _sending = false;
      _sessionLoading = false;
      _applySession(s);
    });
    await AiChatSessionStore.setCurrentId(s.id);
    await _scrollToBottom();
  }

  Future<void> _showSessionSheet() async {
    final sessions = await AiChatSessionStore.loadAll();
    if (!mounted) return;

    // ignore: use_build_context_synchronously
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return _SessionSheet(
          sessions: sessions,
          currentId: _sessionId,
          onNew: () async {
            Navigator.of(context).pop();
            await _createNewSession();
          },
          onOpen: (id) async {
            Navigator.of(context).pop();
            await _loadSessionById(id);
          },
          onDelete: (id) async {
            final l10n = context.l10n;
            final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(l10n.aiChatDeleteSessionTitle),
                    content: Text(l10n.aiChatDeleteSessionBody),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: Text(l10n.commonCancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: Text(l10n.commonDelete),
                      ),
                    ],
                  ),
                ) ??
                false;
            if (!ok) return;
            await AiChatSessionStore.deleteById(id);
            if (!context.mounted) return;
            Navigator.of(context).pop();
            await _initSession();
          },
        );
      },
    );
  }

  void _showUserMessageActions(_ChatMessage m) {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(l10n.commonCopy),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: m.text));
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.commonCopiedToClipboard)),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: Text(l10n.aiChatEditAndResend),
                onTap: () {
                  Navigator.of(context).pop();
                  _controller.text = m.text;
                  _controller.selection = TextSelection.fromPosition(
                    TextPosition(offset: _controller.text.length),
                  );
                  _inputFocusNode.requestFocus();
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startVoice() async {
    if (_sending || _voiceProcessing) return;
    final speech = _speech;
    final useOfflineSpeech = ref.read(useOfflineSpeechProvider);

    setState(() {
      _voiceProcessing = true;
      _voicePartial = '';
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
          _controller.text = p;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
        });
      },
      onFinalResult: (text) {
        final t = text.trim();
        if (t.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _voicePendingFinalText = t;
          _controller.text = t;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
        });
      },
      // Long-press UX: we finish on release (stopListening).
      finalizeOnEndpoint: false,
    );

    if (!mounted) return;
    if (!ok) {
      final msg = speech.lastInitError ?? context.l10n.commonSpeechInitFailed;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      setState(() {
        _voiceProcessing = false;
        _listening = false;
      });
      return;
    }

    setState(() {
      _voiceProcessing = false;
      _listening = true;
    });
  }

  Future<void> _stopVoice({required bool submit}) async {
    final speech = _speech;
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
      _listening = false;
      _voicePartial = '';
      _voicePendingFinalText = '';
      if (finalText.isNotEmpty) {
        _controller.text = finalText;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
      }
    });

    if (submit && finalText.isNotEmpty) {
      await _send(speakReply: true);
    }
  }

  Future<void> _send({bool speakReply = false}) async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      _sending = true;
      _messages.add(_ChatMessage(role: _Role.user, text: text));
      _controller.clear();
    });

    await _persistSession();

    await _scrollToBottom();

    try {
      final api = ref.read(backendApiServiceProvider);
      final turns = _messages.toList(growable: false);
      final start = turns.length > 12 ? turns.length - 12 : 0;
      final sliced = turns.sublist(start);
      final history = sliced
          .where(
            (m) => !(m.role == _Role.user && m.text.trim() == text),
          )
          .map(
            (m) => {
              'role': m.role == _Role.user ? 'user' : 'assistant',
              'content': m.text,
            },
          )
          .toList(growable: false);
      final resp = await api.aiChat(query: text, messages: history);
      final answer = (resp['answer']?.toString() ?? '').trim();

      final metaRaw = resp['meta'];
      final meta = (metaRaw is Map)
          ? metaRaw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      _lastMeta = meta;

      String metaLine() {
        final route = (meta['route']?.toString() ?? '').trim();
        final llmRaw = meta['llm'];
        final llm = (llmRaw is Map)
            ? llmRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final used = (llm['used'] == true);
        final provider = (llm['provider']?.toString() ?? '').trim();
        final model = (llm['model']?.toString() ?? '').trim();

        final segs = <String>[];
        if (route.isNotEmpty) segs.add('route=$route');
        segs.add(used ? 'LLM=on' : 'LLM=off');
        if (provider.isNotEmpty) segs.add(provider);
        if (model.isNotEmpty) segs.add(model);
        return segs.join(' · ');
      }

      setState(() {
        _messages.add(
          _ChatMessage(
            role: _Role.assistant,
            text: answer.isEmpty ? context.l10n.aiChatEmptyResponse : answer,
            meta: metaLine(),
          ),
        );
      });
      await _persistSession();
      if (speakReply && answer.isNotEmpty) {
        await _tts.speak(answer);
      }
    } catch (e) {
      setState(() {
        _messages.add(
          _ChatMessage(
            role: _Role.assistant,
            text: context.l10n.aiChatRequestFailed(e.toString()),
          ),
        );
      });
      await _persistSession();
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
      await _scrollToBottom();
    }
  }

  Future<void> _scrollToBottom() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiChatTitle),
        leading: IconButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.commonBack,
        ),
        actions: [
          IconButton(
            onPressed: _toggleAiEnabled,
            icon: Icon(_aiEnabled ? Icons.smart_toy : Icons.smart_toy_outlined),
            tooltip: l10n.backendAiEnabledTitle,
          ),
          IconButton(
            onPressed: _sessionLoading ? null : _showSessionSheet,
            icon: const Icon(Icons.history),
            tooltip: l10n.aiChatTooltipHistory,
          ),
          IconButton(
            onPressed: _sessionLoading ? null : _createNewSession,
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: l10n.aiChatTooltipNewSession,
          ),
          IconButton(
            onPressed: () => context.push('/dashboard'),
            icon: const Icon(Icons.dashboard),
            tooltip: l10n.homeTooltipProjectDashboard,
          ),
          IconButton(
            onPressed: () async {
              try {
                final api = ref.read(backendApiServiceProvider);
                final status = await api.getAiStatus();
                if (!context.mounted) return;
                final llm = (status['llm'] is Map)
                    ? (status['llm'] as Map)
                        .map((k, v) => MapEntry(k.toString(), v))
                    : <String, dynamic>{};
                final configured = llm['configured'] == true;
                final model = (llm['model']?.toString() ?? '').trim();
                final note = (llm['note']?.toString() ?? '').trim();
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l10n.aiChatModelStatusTitle),
                    content: Text(
                      'configured: $configured\nmodel: ${model.isEmpty ? '-' : model}\n\n$note',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.commonClose),
                      ),
                    ],
                  ),
                );
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content:
                          Text(l10n.aiChatGetModelStatusFailed(e.toString()))),
                );
              }
            },
            icon: const Icon(Icons.info_outline),
            tooltip: l10n.aiChatTooltipModelStatus,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_lastMeta != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: _MetaBanner(meta: _lastMeta!),
              ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: ListView.builder(
                  controller: _scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length + 1,
                  itemBuilder: (context, i) {
                    final m = i == 0 ? _seedMessage(context) : _messages[i - 1];
                    final isUser = m.role == _Role.user;
                    final cs = Theme.of(context).colorScheme;

                    final bubble = Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      constraints: const BoxConstraints(maxWidth: 520),
                      decoration: BoxDecoration(
                        color: isUser
                            ? cs.primaryContainer
                            : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.text),
                          if (!isUser && (m.meta ?? '').trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              m.meta!,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: cs.outline),
                            ),
                          ],
                        ],
                      ),
                    );

                    return Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: isUser
                          ? GestureDetector(
                              onLongPress: () => _showUserMessageActions(m),
                              child: bubble,
                            )
                          : bubble,
                    );
                  },
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(l10n.commonSnackLongPressMicHint)),
                      );
                    },
                    onLongPressStart: (_) async {
                      await _startVoice();
                    },
                    onLongPressCancel: () {
                      _stopVoice(submit: false);
                    },
                    onLongPressEnd: (_) {
                      _stopVoice(submit: true);
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _sending
                                ? Theme.of(context).disabledColor
                                : Theme.of(context).colorScheme.primary,
                          ),
                          child: const Icon(
                            Icons.mic,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        if (_listening)
                          const Positioned.fill(
                            child: Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _inputFocusNode,
                      enabled: !_sending,
                      decoration: InputDecoration(
                        hintText: _listening
                            ? (_voicePartial.isEmpty
                                ? l10n.aiChatHintListening
                                : _voicePartial)
                            : l10n.aiChatHintAskQuestion,
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(speakReply: false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _sending ? null : () => _send(speakReply: false),
                    child:
                        Text(_sending ? l10n.aiChatSending : l10n.aiChatSend),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Role {
  user,
  assistant,
}

class _ChatMessage {
  final _Role role;
  final String text;
  final String? meta;

  const _ChatMessage({
    required this.role,
    required this.text,
    this.meta,
  });

  Map<String, dynamic> toJson() {
    return {
      'role': role == _Role.user ? 'user' : 'assistant',
      'text': text,
      if (meta != null) 'meta': meta,
    };
  }

  factory _ChatMessage.fromJson(Map<String, dynamic> json) {
    final roleStr = (json['role']?.toString() ?? '').trim();
    final role = roleStr == 'user' ? _Role.user : _Role.assistant;
    final text = (json['text']?.toString() ?? '').trim();
    final meta = (json['meta']?.toString() ?? '').trim();
    return _ChatMessage(
      role: role,
      text: text,
      meta: meta.isEmpty ? null : meta,
    );
  }
}

class _SessionSheet extends StatelessWidget {
  final List<AiChatSession> sessions;
  final String? currentId;
  final VoidCallback onNew;
  final Future<void> Function(String id) onOpen;
  final Future<void> Function(String id) onDelete;

  const _SessionSheet({
    required this.sessions,
    required this.currentId,
    required this.onNew,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.aiChatSessionsTitle,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onNew,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.aiChatTooltipNewSession),
                ),
              ],
            ),
          ),
          if (sessions.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 18),
              child: Text(l10n.aiChatSessionsEmpty),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sessions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final s = sessions[i];
                  final isCurrent = s.id == currentId;
                  final title = s.title.trim().isEmpty
                      ? l10n.aiChatUntitledSession
                      : s.title;
                  final dt = DateTime.fromMillisecondsSinceEpoch(s.updatedAtMs);
                  final time =
                      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
                      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                  return ListTile(
                    leading: Icon(
                      isCurrent
                          ? Icons.radio_button_checked
                          : Icons.chat_bubble,
                      color: isCurrent ? cs.primary : null,
                    ),
                    title: Text(title),
                    subtitle: Text(time),
                    trailing: IconButton(
                      onPressed: () async {
                        await onDelete(s.id);
                      },
                      icon: const Icon(Icons.delete_outline),
                      tooltip: l10n.commonDelete,
                    ),
                    onTap: () async {
                      await onOpen(s.id);
                    },
                  );
                },
              ),
            ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _MetaBanner extends StatelessWidget {
  final Map<String, dynamic> meta;

  const _MetaBanner({required this.meta});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final route = (meta['route']?.toString() ?? '').trim();
    final llmRaw = meta['llm'];
    final llm = (llmRaw is Map)
        ? llmRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final used = (llm['used'] == true);
    final provider = (llm['provider']?.toString() ?? '').trim();
    final model = (llm['model']?.toString() ?? '').trim();

    final label = <String>[];
    if (route.isNotEmpty) label.add('route=$route');
    label.add(used ? 'LLM=on' : 'LLM=off');
    if (provider.isNotEmpty) label.add(provider);
    if (model.isNotEmpty) label.add(model);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Text(
        label.join(' · '),
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }
}

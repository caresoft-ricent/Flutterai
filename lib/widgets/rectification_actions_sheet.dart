import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend_records.dart';
import '../services/backend_api_service.dart';
import '../screens/camera_capture_screen.dart';
import 'photo_preview.dart';

class RectificationActionsSheet extends ConsumerStatefulWidget {
  final String targetType; // issue | acceptance
  final int targetId;

  final String title;

  // Issue-only
  final bool showClose;

  // Acceptance-only
  final bool showVerify;

  const RectificationActionsSheet({
    super.key,
    required this.targetType,
    required this.targetId,
    required this.title,
    this.showClose = false,
    this.showVerify = false,
  });

  static Future<void> open(
    BuildContext context, {
    required String title,
    required String targetType,
    required int targetId,
    bool showClose = false,
    bool showVerify = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RectificationActionsSheet(
        title: title,
        targetType: targetType,
        targetId: targetId,
        showClose: showClose,
        showVerify: showVerify,
      ),
    );
  }

  @override
  ConsumerState<RectificationActionsSheet> createState() =>
      _RectificationActionsSheetState();
}

class _RectificationActionsSheetState
    extends ConsumerState<RectificationActionsSheet> {
  late Future<List<BackendRectificationAction>> _future;

  final _contentController = TextEditingController();
  bool _submitting = false;

  final List<String> _photos = [];

  String _verifyResult = 'qualified';

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<List<BackendRectificationAction>> _fetch() async {
    final api = ref.read(backendApiServiceProvider);
    if (widget.targetType == 'issue') {
      return api.listIssueActions(widget.targetId);
    }
    return api.listAcceptanceActions(widget.targetId);
  }

  Future<void> _reload() async {
    setState(() {
      _future = _fetch();
    });
    await _future;
  }

  Future<void> _addPhoto() async {
    final path = await CameraCaptureScreen.capture(context);
    final p = (path ?? '').trim();
    if (p.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _photos.add(p);
    });
  }

  Future<void> _submitAction(String actionType) async {
    if (_submitting) return;
    final content = _contentController.text.trim();
    if (content.isEmpty && _photos.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写整改说明或添加照片')));
      return;
    }

    setState(() {
      _submitting = true;
    });

    final api = ref.read(backendApiServiceProvider);
    try {
      if (widget.targetType == 'issue') {
        await api.addIssueAction(
          issueId: widget.targetId,
          actionType: actionType,
          content: content,
          photoPaths: List.unmodifiable(_photos),
          actorRole: 'responsible',
        );
      } else {
        await api.addAcceptanceAction(
          recordId: widget.targetId,
          actionType: actionType,
          content: content,
          photoPaths: List.unmodifiable(_photos),
          actorRole: 'responsible',
        );
      }

      if (!mounted) return;
      _contentController.clear();
      setState(() {
        _photos.clear();
      });
      await _reload();
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Future<void> _closeIssue() async {
    if (_submitting) return;
    final content = _contentController.text.trim();
    if (content.isEmpty && _photos.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写关闭说明或添加照片')));
      return;
    }

    setState(() {
      _submitting = true;
    });
    final api = ref.read(backendApiServiceProvider);
    try {
      final ok = await api.closeIssue(
        issueId: widget.targetId,
        content: content,
        photoPaths: List.unmodifiable(_photos),
        actorRole: 'supervisor',
      );
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('关闭失败')));
        return;
      }
      _contentController.clear();
      setState(() {
        _photos.clear();
      });
      await _reload();
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Future<void> _verifyAcceptance() async {
    if (_submitting) return;
    final remark = _contentController.text.trim();
    if (remark.isEmpty && _photos.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写复验说明或添加照片')));
      return;
    }

    setState(() {
      _submitting = true;
    });

    final api = ref.read(backendApiServiceProvider);
    try {
      final ok = await api.verifyAcceptance(
        recordId: widget.targetId,
        result: _verifyResult,
        remark: remark,
        photoPaths: List.unmodifiable(_photos),
        actorRole: 'supervisor',
      );
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('复验提交失败')));
        return;
      }
      _contentController.clear();
      setState(() {
        _photos.clear();
      });
      await _reload();
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  String _actionTypeZh(String t) {
    switch (t.trim().toLowerCase()) {
      case 'rectify':
        return '整改';
      case 'verify':
        return '复验';
      case 'close':
        return '关闭';
      case 'comment':
        return '备注';
      default:
        return t.trim().isEmpty ? '—' : t.trim();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: '退出',
                    ),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新',
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<BackendRectificationAction>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(child: Text('加载失败：${snap.error}'));
                    }
                    final items = snap.data ?? const [];
                    if (items.isEmpty) {
                      return const Center(child: Text('暂无整改/复验记录'));
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final a = items[i];
                        return Card(
                          elevation: 0,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      _actionTypeZh(a.actionType),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        a.createdAt.toString(),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                    if ((a.actorRole ?? '').trim().isNotEmpty)
                                      Text(
                                        a.actorRole!.trim(),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                  ],
                                ),
                                if ((a.content ?? '').trim().isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(a.content!.trim()),
                                ],
                                if (a.photoUrls.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: 84,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: a.photoUrls.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(width: 10),
                                      itemBuilder: (context, j) {
                                        final p = a.photoUrls[j];
                                        return ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: AspectRatio(
                                            aspectRatio: 4 / 3,
                                            child: PhotoPreview(path: p),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.showVerify) ...[
                      Row(
                        children: [
                          const Text('复验结果：'),
                          const SizedBox(width: 8),
                          DropdownButton<String>(
                            value: _verifyResult,
                            items: const [
                              DropdownMenuItem(
                                value: 'qualified',
                                child: Text('合格'),
                              ),
                              DropdownMenuItem(
                                value: 'pending',
                                child: Text('甩项'),
                              ),
                              DropdownMenuItem(
                                value: 'unqualified',
                                child: Text('不合格'),
                              ),
                            ],
                            onChanged: _submitting
                                ? null
                                : (v) {
                                    if (v == null) return;
                                    setState(() {
                                      _verifyResult = v;
                                    });
                                  },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      controller: _contentController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '填写整改/复验说明（可选）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_photos.isNotEmpty) ...[
                      SizedBox(
                        height: 84,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _photos.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, i) {
                            final p = _photos[i];
                            return Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: AspectRatio(
                                    aspectRatio: 4 / 3,
                                    child: PhotoPreview(path: p),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: IconButton(
                                    icon: const Icon(Icons.close),
                                    color: Colors.black87,
                                    onPressed: _submitting
                                        ? null
                                        : () {
                                            setState(() {
                                              _photos.removeAt(i);
                                            });
                                          },
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    OutlinedButton.icon(
                      onPressed: _submitting ? null : _addPhoto,
                      icon: const Icon(Icons.add_a_photo),
                      label: const Text('添加照片'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _submitting
                                ? null
                                : () => _submitAction('rectify'),
                            child: const Text('提交整改记录'),
                          ),
                        ),
                        if (widget.showClose) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: _submitting ? null : _closeIssue,
                              child: const Text('复验关闭'),
                            ),
                          ),
                        ],
                        if (widget.showVerify) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: _submitting ? null : _verifyAcceptance,
                              child: const Text('提交复验'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

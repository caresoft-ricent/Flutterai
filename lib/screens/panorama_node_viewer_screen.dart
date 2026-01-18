import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:panorama/panorama.dart';

import '../models/panorama_session.dart';
import '../services/panorama_recognition_service.dart';
import '../services/panorama_storage_service.dart';
import 'panorama_findings_screen.dart';

class PanoramaNodeViewerScreen extends ConsumerStatefulWidget {
  final String sessionId;
  final String nodeId;

  const PanoramaNodeViewerScreen({
    super.key,
    required this.sessionId,
    required this.nodeId,
  });

  @override
  ConsumerState<PanoramaNodeViewerScreen> createState() =>
      _PanoramaNodeViewerScreenState();
}

class _PanoramaNodeViewerScreenState
    extends ConsumerState<PanoramaNodeViewerScreen> {
  PanoramaSession? _session;
  PanoramaNode? _node;
  bool _loading = true;
  bool _recognizing = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(panoramaStorageServiceProvider);
    final s = await storage.loadSession(widget.sessionId);
    final node = s?.nodes.where((e) => e.id == widget.nodeId).firstOrNull;
    if (!mounted) return;
    setState(() {
      _session = s;
      _node = node;
      _loading = false;
    });
  }

  Future<void> _startRecognize() async {
    final s = _session;
    final n = _node;
    if (s == null || n == null) return;
    if (n.panoImagePath == null || n.panoImagePath!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有全景照片可识别')),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开始识别'),
        content: const Text(
          '识别需要联网。\n\n请先切换到可用网络（例如手机热点/移动数据），然后点击“确定”开始识别。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _recognizing = true;
    });

    try {
      final recog = ref.read(panoramaRecognitionServiceProvider);
      final findings = await recog.recognizeNode(
        s.id,
        n,
        sceneHint: '全景巡检',
      );

      final updatedNode = n.copyWith(
        status: 'done',
        findings: findings,
      );
      final updatedSession = s.copyWith(nodes: [updatedNode]);
      final storage = ref.read(panoramaStorageServiceProvider);
      await storage.saveSession(updatedSession);

      if (!mounted) return;
      setState(() {
        _session = updatedSession;
        _node = updatedNode;
        _recognizing = false;
      });

      _changed = true;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('识别完成：${findings.length} 条结果')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recognizing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('识别失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _node;
    final recognized = (n?.status == 'done') || _changed;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('查看全景图'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : (n == null
                ? const Center(child: Text('点位不存在'))
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: FilledButton(
                            onPressed: _recognizing ? null : _startRecognize,
                            child: _recognizing
                                ? const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                      SizedBox(width: 10),
                                      Text('识别中…'),
                                    ],
                                  )
                                : const Text('开始识别'),
                          ),
                        ),
                      ),
                      Expanded(
                        child: n.panoImagePath == null
                            ? const Center(child: Text('暂无全景照片'))
                            : _PanoramaImageView(path: n.panoImagePath!),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: FilledButton.tonal(
                            onPressed: !recognized
                                ? null
                                : () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => PanoramaFindingsScreen(
                                          findings: n.findings,
                                        ),
                                      ),
                                    );
                                  },
                            child: Text('已识别问题（${n.findings.length}个）'),
                          ),
                        ),
                      ),
                    ],
                  )),
      ),
    );
  }
}

class _PanoramaImageView extends StatelessWidget {
  final String path;

  const _PanoramaImageView({required this.path});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Panorama(
        sensorControl: SensorControl.None,
        minZoom: 0.8,
        maxZoom: 3.6,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (c, e, s) => const Center(child: Text('图片加载失败')),
        ),
      ),
    );
  }
}

extension _FirstOrNullExt<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}

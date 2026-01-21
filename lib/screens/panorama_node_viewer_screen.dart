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
  int _panoReloadToken = 0;

  @override
  void initState() {
    super.initState();
    _panoReloadToken = DateTime.now().microsecondsSinceEpoch;
    _load();
  }

  void _evictPanoImageFromCache() {
    final path = _node?.panoImagePath;
    if (path == null || path.trim().isEmpty) return;
    final file = File(path);
    final provider = FileImage(file);
    try {
      PaintingBinding.instance.imageCache.evict(provider);
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {
      // ignore
    }
  }

  void _forcePanoRebuild({required bool evictImage}) {
    if (!mounted) return;
    if (evictImage) {
      _evictPanoImageFromCache();
    }
    setState(() {
      _panoReloadToken = DateTime.now().microsecondsSinceEpoch;
    });
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
      _panoReloadToken = DateTime.now().microsecondsSinceEpoch;
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
        SnackBar(content: Text('识别完成：${findings.length} 条结果，可点击下方查看')),
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

  Future<void> _showDiagnostics() async {
    final n = _node;
    final path = n?.panoImagePath;
    String exists = 'N/A';
    String size = 'N/A';
    String mtime = 'N/A';
    if (path != null && path.trim().isNotEmpty) {
      final f = File(path);
      exists = f.existsSync() ? 'YES' : 'NO';
      if (f.existsSync()) {
        try {
          final st = f.statSync();
          size = '${st.size} bytes';
          mtime = st.modified.toIso8601String();
        } catch (_) {}
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全景诊断信息'),
        content: SingleChildScrollView(
          child: Text(
            'panoImagePath:\n${path ?? '(null)'}\n\n'
            'exists: $exists\n'
            'size: $size\n'
            'modified: $mtime\n\n'
            '提示：如果 exists=NO，说明本机文件已不存在（可能被清空本地数据/采集未成功/系统清理），需要重新采集。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _forcePanoRebuild(evictImage: true);
            },
            child: const Text('强制刷新'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _node;
    final recognized = ((n?.status == 'done') || _changed) &&
        (n?.findings.isNotEmpty ?? false);
    final panoPath = n?.panoImagePath;
    final panoExists = panoPath != null && panoPath.trim().isNotEmpty
        ? File(panoPath).existsSync()
        : false;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('查看全景图'),
          actions: [
            IconButton(
              tooltip: '诊断',
              onPressed: _showDiagnostics,
              icon: const Icon(Icons.info_outline),
            ),
          ],
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
                            onPressed: (_recognizing || (n.status == 'done'))
                                ? null
                                : _startRecognize,
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
                                : Text(
                                    (n.status == 'done') ? '已识别' : '开始识别',
                                  ),
                          ),
                        ),
                      ),
                      if (recognized)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '识别完成，可点击下方查看问题清单',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: n.panoImagePath == null
                            ? const Center(child: Text('暂无全景照片'))
                            : (panoExists
                                ? _PanoramaImageView(
                                    key: ValueKey(
                                      '${n.panoImagePath}|$_panoReloadToken',
                                    ),
                                    path: n.panoImagePath!,
                                    reloadToken: _panoReloadToken,
                                  )
                                : const Center(
                                    child: Text('全景照片文件不存在，请重新采集'),
                                  )),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: recognized
                              ? FilledButton(
                                  onPressed: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => PanoramaFindingsScreen(
                                          findings: n.findings,
                                        ),
                                      ),
                                    );
                                    if (!mounted) return;
                                    _forcePanoRebuild(evictImage: true);
                                  },
                                  child: Text('已识别问题（${n.findings.length}个）'),
                                )
                              : FilledButton.tonal(
                                  onPressed: null,
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
  final int reloadToken;

  const _PanoramaImageView({
    super.key,
    required this.path,
    required this.reloadToken,
  });

  @override
  Widget build(BuildContext context) {
    return _PanoramaImageViewInternal(
      key: ValueKey('pano_view|$path|$reloadToken'),
      path: path,
      reloadToken: reloadToken,
    );
  }
}

class _PanoramaImageViewInternal extends StatefulWidget {
  final String path;
  final int reloadToken;

  const _PanoramaImageViewInternal({
    super.key,
    required this.path,
    required this.reloadToken,
  });

  @override
  State<_PanoramaImageViewInternal> createState() =>
      _PanoramaImageViewInternalState();
}

class _PanoramaImageViewInternalState
    extends State<_PanoramaImageViewInternal> {
  void _evict() {
    final file = File(widget.path);
    final provider = FileImage(file);
    try {
      PaintingBinding.instance.imageCache.evict(provider);
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {
      // ignore
    }
  }

  @override
  void initState() {
    super.initState();
    // Critical: avoid ImageCache hit causing Panorama to bind a stale texture.
    _evict();
  }

  @override
  void didUpdateWidget(covariant _PanoramaImageViewInternal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.reloadToken != widget.reloadToken) {
      _evict();
    }
  }

  @override
  void dispose() {
    // Best-effort cleanup.
    _evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = File(widget.path);
    if (!file.existsSync()) {
      return const Center(child: Text('全景照片文件不存在，请重新采集'));
    }

    final panoKey = ValueKey('panorama|${widget.path}|${widget.reloadToken}');
    final imgKey = ValueKey('image|${widget.path}|${widget.reloadToken}');

    return ClipRect(
      child: Panorama(
        key: panoKey,
        sensorControl: SensorControl.None,
        minZoom: 0.8,
        maxZoom: 3.6,
        child: Image(
          key: imgKey,
          image: FileImage(file),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
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

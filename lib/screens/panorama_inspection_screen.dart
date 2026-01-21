import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/panorama_session.dart';
import '../services/insta360_osc_service.dart';
import '../services/panorama_recognition_service.dart';
import '../services/panorama_storage_service.dart';
import 'panorama_node_viewer_screen.dart';

class PanoramaInspectionScreen extends ConsumerStatefulWidget {
  static const routeName = '/panorama-inspection';

  const PanoramaInspectionScreen({super.key});

  @override
  ConsumerState<PanoramaInspectionScreen> createState() =>
      _PanoramaInspectionScreenState();
}

class _PanoramaInspectionScreenState
    extends ConsumerState<PanoramaInspectionScreen> {
  PanoramaSession? _session;
  bool _loading = true;
  String? _status;

  final TransformationController _transformController =
      TransformationController();
  ui.Size? _planImageSize;
  bool _placingPoint = false;

  static const String _prefsInsta360BaseUrlKey = 'panorama_insta360_base_url';
  bool _didInitPlanTransform = false;

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadOrCreateSingleSession();
  }

  PanoramaNode _singleNodeFor(PanoramaSession s) {
    if (s.nodes.isNotEmpty) return s.nodes.first;
    return PanoramaNode(
      id: 'node_1',
      createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      name: '节点1',
      x: null,
      y: null,
      panoImagePath: null,
      thumbnailPath: null,
      status: 'pending_capture',
      findings: const [],
    );
  }

  Future<void> _loadOrCreateSingleSession() async {
    final storage = ref.read(panoramaStorageServiceProvider);
    setState(() {
      _loading = true;
    });

    final list = await storage.listSessions();
    PanoramaSession s = list.isNotEmpty
        ? list.first
        : await storage.createNewSession(title: '全景巡检');

    var normalized = s.copyWith(nodes: [_singleNodeFor(s)]);

    // 数据自愈：重装/清缓存后，session.json 仍在但文件已丢失。
    // - 图纸文件不存在：清空 floorPlan 并回到导入阶段
    // - 全景图/缩略图不存在：清空对应路径并回到待采集
    var changed = false;

    final fp = normalized.floorPlan;
    if (fp != null) {
      final lp = fp.localPath.trim();
      final exists = lp.isNotEmpty && File(lp).existsSync();
      if (!exists) {
        normalized = normalized.copyWith(
          floorPlan: null,
          stage: 'capture',
        );
        _planImageSize = null;
        _didInitPlanTransform = false;
        changed = true;
      }
    }

    final node = normalized.nodes.first;
    if (node.panoImagePath != null && !File(node.panoImagePath!).existsSync()) {
      final repaired = node.copyWith(
        panoImagePath: null,
        thumbnailPath: null,
        status: 'pending_capture',
        findings: const [],
      );
      normalized = normalized.copyWith(nodes: [repaired], stage: 'capture');
      changed = true;
    } else if (node.thumbnailPath != null &&
        !File(node.thumbnailPath!).existsSync()) {
      final repaired = node.copyWith(thumbnailPath: null);
      normalized = normalized.copyWith(nodes: [repaired]);
      changed = true;
    }

    if (changed || normalized != s) {
      await storage.saveSession(normalized);
    }

    if (!mounted) return;
    setState(() {
      _session = normalized;
      _loading = false;
    });

    final fp2 = normalized.floorPlan;
    if (fp2 != null &&
        fp2.type == 'image' &&
        File(fp2.localPath).existsSync()) {
      await _ensurePlanImageSize(fp2.localPath);
    } else {
      if (!mounted) return;
      setState(() {
        _planImageSize = null;
      });
    }
  }

  Future<void> _importFloorPlan() async {
    final s = _session;
    if (s == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    final path = picked?.path;
    if (path == null || path.trim().isEmpty) return;

    final storage = ref.read(panoramaStorageServiceProvider);
    final copied = await storage.copyIntoSession(
      s.id,
      File(path),
      relativeTargetName: 'floor_plan${_extOf(path)}',
    );

    final updated = s.copyWith(
      floorPlan: PanoramaFloorPlan(
        localPath: copied.path,
        type: copied.path.toLowerCase().endsWith('.pdf') ? 'pdf' : 'image',
      ),
      stage: 'capture',
    );
    await storage.saveSession(updated);
    setState(() {
      _session = updated;
      _status = null;
      _placingPoint = false;
      _didInitPlanTransform = false;
      _transformController.value = Matrix4.identity();
    });

    if (updated.floorPlan?.type == 'image') {
      await _ensurePlanImageSize(updated.floorPlan!.localPath);
    }
  }

  Future<void> _ensurePlanImageSize(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      if (!mounted) return;
      setState(() {
        _planImageSize = ui.Size(img.width.toDouble(), img.height.toDouble());
      });
    } catch (_) {
      // Keep null; marker placement will be disabled.
      if (!mounted) return;
      setState(() {
        _planImageSize = null;
      });
    }
  }

  Future<void> _startCapture() async {
    final s = _session;
    if (s == null) return;
    if (s.floorPlan == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开始采集'),
        content: const Text(
          '开始采集前，请先连接全景相机 Wi‑Fi 热点。\n\n确认已连接后点击“确定”开始采集。',
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

    final baseUrl = await _resolveInsta360BaseUrl();
    if (baseUrl == null) return;

    try {
      final bytes = await _runWithCancelableProgress<Uint8List>(
        title: '正在采集',
        message: '正在连接 Insta360 并取回照片…',
        timeout: const Duration(seconds: 75),
        task: (cancelToken) async {
          final osc = ref.read(insta360OscServiceProvider);
          return osc.takePictureAndDownload(
            baseUrl: baseUrl,
            cancelToken: cancelToken,
          );
        },
      );
      await _saveCapturedBytesToSession(bytes: bytes, ext: '.jpg');
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已取消采集')),
        );
        return;
      }
      if (!mounted) return;
      final fallback = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Insta360 采集失败'),
          content: Text(
            '原因：$e\n\n请确认：\n1) 已连接相机 Wi‑Fi\n2) 相机支持 OSC(HTTP)\n'
            '3) 网关地址填写正确（例如 http://192.168.1.1）',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('改用相册模拟'),
            ),
          ],
        ),
      );
      if (fallback == true) {
        final path = await _pickFromGallery();
        if (path == null) return;
        final bytes = await File(path).readAsBytes();
        await _saveCapturedBytesToSession(bytes: bytes, ext: _extOf(path));
      }
    }
  }

  Future<void> _saveCapturedBytesToSession({
    required Uint8List bytes,
    required String ext,
  }) async {
    final s = _session;
    if (s == null) return;

    final tmpDir = await Directory.systemTemp.createTemp('pano_capture_');
    final safeExt = ext.trim().isEmpty ? '.jpg' : ext;
    final tmpPath = '${tmpDir.path}/pano$safeExt';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(bytes);

    final storage = ref.read(panoramaStorageServiceProvider);
    final node = _singleNodeFor(s);
    final oldPanoPath = node.panoImagePath;
    final oldThumbPath = node.thumbnailPath;
    final captureId = DateTime.now().millisecondsSinceEpoch;
    final copied = await storage.copyIntoSession(
      s.id,
      tmpFile,
      relativeTargetName: 'node_${node.id}_pano_$captureId$safeExt',
    );

    final recog = ref.read(panoramaRecognitionServiceProvider);
    final thumb = await recog.generateThumbnail(s.id, node.id, copied.path);

    final updatedNode = node.copyWith(
      panoImagePath: copied.path,
      thumbnailPath: thumb?.path,
      status: 'captured',
      findings: const [],
    );
    final updated = s.copyWith(
      stage: 'capture',
      nodes: [updatedNode],
    );
    await storage.saveSession(updated);

    // 成功保存新照片后，再清理上一张照片/缩略图，避免“二次采集失败导致把新旧都删掉”。
    try {
      if (oldPanoPath != null &&
          oldPanoPath.trim().isNotEmpty &&
          oldPanoPath != copied.path) {
        final f = File(oldPanoPath);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    try {
      final newThumbPath = thumb?.path;
      if (oldThumbPath != null &&
          oldThumbPath.trim().isNotEmpty &&
          oldThumbPath != newThumbPath) {
        final f = File(oldThumbPath);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _session = updated;
      _status = '已保存全景照片';
      _placingPoint = true;
    });

    // Best-effort temp cleanup.
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('全景照片已保存，请在图纸上点击采集点位置')),
    );
  }

  Future<String?> _pickFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    final path = picked?.path;
    if (path == null || path.trim().isEmpty) return null;
    return path;
  }

  Future<T> _runWithCancelableProgress<T>({
    required String title,
    required String message,
    required Duration timeout,
    required Future<T> Function(CancelToken cancelToken) task,
  }) async {
    final cancelToken = CancelToken();
    final shown = Completer<void>();
    var dialogOpen = true;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          if (!shown.isCompleted) shown.complete();
          return AlertDialog(
            title: Text(title),
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(message)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  if (!cancelToken.isCancelled) {
                    cancelToken.cancel('user_cancel');
                  }
                  dialogOpen = false;
                  Navigator.of(ctx).pop();
                },
                child: const Text('取消'),
              ),
            ],
          );
        },
      ).whenComplete(() {
        dialogOpen = false;
      }),
    );

    // Best-effort wait until dialog is mounted to avoid popping the page.
    await shown.future.timeout(const Duration(seconds: 1), onTimeout: () {});

    final timer = Timer(timeout, () {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('timeout');
      }
    });

    try {
      final result = await task(cancelToken).timeout(
        timeout + const Duration(seconds: 2),
        onTimeout: () {
          if (!cancelToken.isCancelled) {
            cancelToken.cancel('timeout');
          }
          throw TimeoutException('操作超时（${timeout.inSeconds}s）');
        },
      );
      return result;
    } finally {
      timer.cancel();
      if (dialogOpen && mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
      }
    }
  }

  Future<String?> _promptInsta360BaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return null;
    final initial =
        (prefs.getString(_prefsInsta360BaseUrlKey) ?? 'http://192.168.42.1')
            .trim();

    final controller = TextEditingController(text: initial);
    bool testing = false;
    String? testResult;

    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: const Text('连接 Insta360'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('请先连接相机 Wi‑Fi，然后填写相机网关地址：'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: '例如 http://192.168.1.1',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                if (testResult != null)
                  Text(
                    testResult!,
                    style: TextStyle(
                      color: testResult!.startsWith('OK')
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: testing ? null : () => Navigator.of(ctx).pop(null),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: testing
                    ? null
                    : () async {
                        final raw = controller.text.trim();
                        if (raw.isEmpty) return;
                        setLocal(() {
                          testing = true;
                          testResult = null;
                        });
                        try {
                          final osc = ref.read(insta360OscServiceProvider);
                          await osc.getInfo(baseUrl: raw);
                          setLocal(() {
                            testResult = 'OK：已连接到相机';
                          });
                        } catch (e) {
                          setLocal(() {
                            testResult = '失败：$e';
                          });
                        } finally {
                          setLocal(() {
                            testing = false;
                          });
                        }
                      },
                child: testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('测试连接'),
              ),
              FilledButton(
                onPressed: testing
                    ? null
                    : () {
                        final raw = controller.text.trim();
                        if (raw.isEmpty) return;
                        Navigator.of(ctx).pop(raw);
                      },
                child: const Text('开始采集'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return null;
    final normalized = _normalizeBaseUrl(result);
    await prefs.setString(_prefsInsta360BaseUrlKey, normalized);
    return normalized;
  }

  Future<String?> _resolveInsta360BaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved =
        (prefs.getString(_prefsInsta360BaseUrlKey) ?? 'http://192.168.42.1')
            .trim();
    final normalized = _normalizeBaseUrl(saved);

    // Try saved/default silently to reduce manual steps.
    try {
      final osc = ref.read(insta360OscServiceProvider);
      await osc.getInfo(baseUrl: normalized);
      return normalized;
    } catch (_) {
      // Fall back to manual config.
      return await _promptInsta360BaseUrl();
    }
  }

  String _normalizeBaseUrl(String raw) {
    final s = raw.trim();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    return 'http://$s';
  }

  Future<void> _clearLocalData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空本地数据？'),
        content: const Text('将删除全景巡检的图纸、照片、识别结果等本地数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final storage = ref.read(panoramaStorageServiceProvider);
    await storage.deleteAllSessions();
    if (!mounted) return;
    setState(() {
      _session = null;
      _status = null;
    });
    _loadOrCreateSingleSession();
  }

  String _extOf(String p) {
    final i = p.lastIndexOf('.');
    if (i < 0) return '';
    return p.substring(i);
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
        title: const Text('全景巡检'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'clear') {
                _clearLocalData();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空本地数据'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (s == null ? const SizedBox.shrink() : _buildPlanLayer(s)),
    );
  }

  Widget _buildPlanLayer(PanoramaSession s) {
    final fp = s.floorPlan;
    final buttonLabel = fp == null ? '导入图纸' : '开始采集';
    final buttonIcon = fp == null ? Icons.upload_file : Icons.play_arrow;
    final buttonAction = fp == null ? _importFloorPlan : _startCapture;

    return Stack(
      children: [
        Positioned.fill(
          child: fp == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('未导入图纸'),
                      if (_status != null) ...[
                        const SizedBox(height: 12),
                        Text(_status!),
                      ],
                    ],
                  ),
                )
              : (fp.type == 'image'
                  ? _buildInteractivePlanImage(fp.localPath)
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '已导入 PDF 图纸：\n${fp.localPath}\n\n（当前 Demo 未集成 PDF 预览）',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            minimum: const EdgeInsets.only(bottom: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: SizedBox(
                height: 44,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  onPressed: buttonAction,
                  icon: Icon(buttonIcon, size: 20),
                  label: Text(buttonLabel),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInteractivePlanImage(String path) {
    final session = _session;
    final fpSize = _planImageSize;
    final node = session == null ? null : _singleNodeFor(session);

    final markerVisible = fpSize != null && node?.x != null && node?.y != null;
    final thumbPath = node?.thumbnailPath;
    final hasThumb = thumbPath != null && thumbPath.trim().isNotEmpty;

    Widget planErrorView() {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('图纸加载失败'),
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: FilledButton(
                  onPressed: _importFloorPlan,
                  child: const Text('重新导入图纸'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) async {
        final current = _session;
        final size = _planImageSize;
        if (current == null || size == null) return;
        if (!_placingPoint) return;

        final scene = _transformController.toScene(d.localPosition);
        final nx = (scene.dx / size.width).clamp(0.0, 1.0);
        final ny = (scene.dy / size.height).clamp(0.0, 1.0);

        final storage = ref.read(panoramaStorageServiceProvider);
        final node = _singleNodeFor(current).copyWith(x: nx, y: ny);
        final updated = current.copyWith(nodes: [node]);
        await storage.saveSession(updated);
        if (!mounted) return;
        setState(() {
          _session = updated;
          _placingPoint = false;
          _status = '采集点已设置';
        });
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('采集点已设置')),
          );
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = ui.Size(constraints.maxWidth, constraints.maxHeight);
          if (fpSize != null && !_didInitPlanTransform) {
            _didInitPlanTransform = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _setInitialPlanTransform(viewport: viewport, imageSize: fpSize);
            });
          }

          return InteractiveViewer(
            constrained: false,
            boundaryMargin: const EdgeInsets.all(200),
            transformationController: _transformController,
            minScale: 0.2,
            maxScale: 8.0,
            child: fpSize == null
                ? Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (c, e, s) => planErrorView(),
                  )
                : SizedBox(
                    width: fpSize.width,
                    height: fpSize.height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Image.file(
                            File(path),
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.high,
                            errorBuilder: (c, e, s) => planErrorView(),
                          ),
                        ),
                        if (markerVisible)
                          Positioned(
                            left: (node!.x! * fpSize.width) - 24,
                            top: (node.y! * fpSize.height) - 54,
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () async {
                                final current = _session;
                                if (current == null) return;
                                final n = _singleNodeFor(current);
                                if (n.panoImagePath == null ||
                                    n.panoImagePath!.trim().isEmpty) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('该点位还没有全景照片')),
                                  );
                                  return;
                                }

                                final changed =
                                    await Navigator.of(context).push<bool>(
                                  MaterialPageRoute(
                                    builder: (_) => PanoramaNodeViewerScreen(
                                      sessionId: current.id,
                                      nodeId: n.id,
                                    ),
                                  ),
                                );

                                if (changed == true) {
                                  final storage =
                                      ref.read(panoramaStorageServiceProvider);
                                  final latest =
                                      await storage.loadSession(current.id);
                                  if (!mounted) return;
                                  if (latest != null) {
                                    setState(() {
                                      _session = latest;
                                    });
                                  }
                                }
                              },
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.location_on,
                                    color: _placingPoint
                                        ? Colors.orangeAccent
                                        : Colors.redAccent,
                                    size: 56,
                                  ),
                                  if (hasThumb) ...[
                                    const SizedBox(width: 6),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        width: 56,
                                        height: 56,
                                        color: Colors.black12,
                                        child: Image.file(
                                          File(thumbPath),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const SizedBox.shrink(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        if (_placingPoint)
                          Positioned(
                            left: 12,
                            top: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                child: Text(
                                  '点击图纸设置采集点',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          );
        },
      ),
    );
  }

  void _setInitialPlanTransform({
    required ui.Size viewport,
    required ui.Size imageSize,
  }) {
    if (viewport.width <= 0 || viewport.height <= 0) return;
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final scaleX = viewport.width / imageSize.width;
    final scaleY = viewport.height / imageSize.height;
    final scale = math.min(scaleX, scaleY) * 0.98;
    final dx = (viewport.width - imageSize.width * scale) / 2;
    final dy = (viewport.height - imageSize.height * scale) / 2;

    final m = Matrix4.identity()..scale(scale);
    m.translate(dx / scale, dy / scale);
    _transformController.value = m;
  }
}

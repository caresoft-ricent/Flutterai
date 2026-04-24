import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/yolo_detection_service.dart';

class YoloSettingsScreen extends ConsumerStatefulWidget {
  static const routeName = 'yolo-settings';

  const YoloSettingsScreen({super.key});

  @override
  ConsumerState<YoloSettingsScreen> createState() => _YoloSettingsScreenState();
}

class _YoloSettingsScreenState extends ConsumerState<YoloSettingsScreen> {
  bool _enabled = true;
  bool _yoloOnly = false;
  double _confThreshold = kDefaultConfidenceThreshold;
  double _nmsIou = kDefaultNmsIouThreshold;
  bool _loading = true;

  bool _diagRunning = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final yolo = ref.read(yoloDetectionServiceProvider);
    final enabled = await yolo.isLocalDetectionEnabled();
    final yoloOnly = await yolo.isYoloOnlyMode();
    final conf = await yolo.getConfidenceThreshold();
    final iou = await yolo.getNmsIouThreshold();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _yoloOnly = yoloOnly;
      _confThreshold = conf;
      _nmsIou = iou;
      _loading = false;
    });
  }

  Future<void> _saveEnabled(bool v) async {
    setState(() {
      _enabled = v;
    });
    await ref.read(yoloDetectionServiceProvider).setLocalDetectionEnabled(v);
  }

  Future<void> _saveConf(double v) async {
    setState(() {
      _confThreshold = v;
    });
    await ref.read(yoloDetectionServiceProvider).setConfidenceThreshold(v);
  }

  Future<void> _saveNms(double v) async {
    setState(() {
      _nmsIou = v;
    });
    await ref.read(yoloDetectionServiceProvider).setNmsIouThreshold(v);
  }

  Future<void> _runDiagnostic() async {
    setState(() => _diagRunning = true);
    try {
      final yolo = ref.read(yoloDetectionServiceProvider);
      final report = await yolo.runDiagnostic();
      if (!mounted) return;
      setState(() {}); // refresh model status
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('YOLO 诊断结果'),
          content: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _diagRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('端侧检测设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('启用端侧检测'),
                  subtitle: const Text('拍照后优先使用本地 YOLO 模型识别问题'),
                  value: _enabled,
                  onChanged: _saveEnabled,
                ),
                SwitchListTile(
                  title: const Text('仅 YOLO 模式'),
                  subtitle: const Text('只使用本地模型，不回退到云端大模型（调试用）'),
                  value: _yoloOnly,
                  onChanged: _enabled
                      ? (v) async {
                          setState(() => _yoloOnly = v);
                          await ref
                              .read(yoloDetectionServiceProvider)
                              .setYoloOnlyMode(v);
                        }
                      : null,
                ),
                const Divider(height: 0),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text('置信度阈值', style: theme.textTheme.titleSmall),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '低于此阈值的检测结果将自动转交云端大模型分析',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(160),
                    ),
                  ),
                ),
                Slider(
                  value: _confThreshold,
                  min: 0.10,
                  max: 0.95,
                  divisions: 17,
                  label: '${(_confThreshold * 100).round()}%',
                  onChanged: _enabled ? _saveConf : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('10%', style: theme.textTheme.bodySmall),
                      Text(
                        '当前: ${(_confThreshold * 100).round()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text('95%', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(height: 0),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text('NMS IoU 阈值', style: theme.textTheme.titleSmall),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '非极大值抑制阈值，用于合并重叠检测框',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(160),
                    ),
                  ),
                ),
                Slider(
                  value: _nmsIou,
                  min: 0.10,
                  max: 0.90,
                  divisions: 16,
                  label: '${(_nmsIou * 100).round()}%',
                  onChanged: _enabled ? _saveNms : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('10%', style: theme.textTheme.bodySmall),
                      Text(
                        '当前: ${(_nmsIou * 100).round()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text('90%', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(height: 0),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('模型信息', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          _infoRow('检测模型', 'YOLO (best.onnx, 9.9 MB)'),
                          _infoRow('类别数量', '10 类'),
                          _infoRow('输入尺寸', '224 × 224'),
                          _infoRow('推理时间', '~100ms (移动端)'),
                          _infoRow(
                              '模型状态',
                              ref.read(yoloDetectionServiceProvider).isReady
                                  ? '已加载 ✅'
                                  : '未加载'),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: _diagRunning ? null : _runDiagnostic,
                    icon: _diagRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ))
                        : const Icon(Icons.science),
                    label: Text(_diagRunning ? '诊断中…' : '运行模型诊断'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withAlpha(160))),
          ),
          Expanded(
              child: Text(value, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/yolo_detection_service.dart';

/// Displays a captured photo with YOLO detection bounding-box overlays.
///
/// Returns through Navigator:
/// - `'accept'`  – user accepts local results
/// - `'cloud'`   – user requests cloud re-analysis
/// - `null`      – user cancelled / popped
class DetectionResultScreen extends StatelessWidget {
  final String imagePath;
  final YoloDetectionResult result;

  const DetectionResultScreen({
    super.key,
    required this.imagePath,
    required this.result,
  });

  /// Convenience launcher.
  static Future<String?> show(
    BuildContext context, {
    required String imagePath,
    required YoloDetectionResult result,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DetectionResultScreen(
          imagePath: imagePath,
          result: result,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detections = result.detections;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('端侧检测结果'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          // --- Image with bounding boxes ---
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(imagePath),
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                    ),
                    // Overlay bounding boxes via CustomPaint.
                    CustomPaint(
                      painter: _DetectionBoxPainter(
                        detections: detections,
                        imageFile: File(imagePath),
                      ),
                      size: Size.infinite,
                    ),
                  ],
                );
              },
            ),
          ),

          // --- Detection list ---
          if (detections.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: theme.colorScheme.surfaceContainerHighest.withAlpha(30),
              child: Text(
                '检测到 ${detections.length} 个问题',
                style: theme.textTheme.titleSmall,
              ),
            ),
            SizedBox(
              height: 120,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                itemCount: detections.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final det = detections[i];
                  final color = _classColor(det.classIndex);
                  return Card(
                    color: color.withAlpha(25),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                det.className,
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '置信度: ${(det.confidence * 100).toStringAsFixed(1)}%',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '严重程度: ${kClassSeverityMap[det.className] ?? "medium"}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.search_off,
                      size: 48,
                      color: theme.colorScheme.onSurface.withAlpha(100)),
                  const SizedBox(height: 12),
                  Text(
                    '端侧模型未检测到明显问题',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '将自动使用云端大模型进行分析',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withAlpha(160)),
                  ),
                ],
              ),
            ),

          // --- Action buttons ---
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop('cloud'),
                      icon: const Icon(Icons.cloud_upload),
                      label: const Text('用大模型重新分析'),
                    ),
                  ),
                  if (detections.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop('accept'),
                        icon: const Icon(Icons.check),
                        label: const Text('使用此结果'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bounding-box painter
// ---------------------------------------------------------------------------

class _DetectionBoxPainter extends CustomPainter {
  final List<YoloDetection> detections;
  final File imageFile;

  _DetectionBoxPainter({required this.detections, required this.imageFile});

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    // We need to figure out where the image is rendered inside the widget
    // (BoxFit.contain). We'll compute the same transform.
    // For simplicity we use the widget size as the image area with contain fit.
    // The bounding boxes are normalised [0..1], so we scale them to the
    // display area that the image covers.

    // Assume the image is centered with BoxFit.contain.
    // We need actual image dimensions. We'll get them from the first call.
    // For now, use the canvas size as 1:1 mapping (the normalised coords
    // map directly to percentage of the display area).

    for (final det in detections) {
      final color = _classColor(det.classIndex);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;

      final rect = Rect.fromLTRB(
        det.x1 * size.width,
        det.y1 * size.height,
        det.x2 * size.width,
        det.y2 * size.height,
      );
      canvas.drawRect(rect, paint);

      // Label background.
      final label = '${det.className} ${(det.confidence * 100).toInt()}%';
      final textSpan = TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final bgRect = Rect.fromLTWH(
        rect.left,
        rect.top - textPainter.height - 4,
        textPainter.width + 8,
        textPainter.height + 4,
      );
      canvas.drawRect(bgRect, Paint()..color = color.withAlpha(180));
      textPainter.paint(canvas, Offset(rect.left + 4, bgRect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter oldDelegate) =>
      detections != oldDelegate.detections;
}

// ---------------------------------------------------------------------------
// Color palette for classes
// ---------------------------------------------------------------------------

Color _classColor(int classIndex) {
  const palette = [
    Color(0xFFE53935), // 刷痕明显 - red
    Color(0xFFD32F2F), // 开裂 - dark red
    Color(0xFFFB8C00), // 未打磨到位 - orange
    Color(0xFF8E24AA), // 污染 - purple
    Color(0xFF1E88E5), // 流坠 - blue
    Color(0xFF43A047), // 砂纸印明显 - green
    Color(0xFFF4511E), // 脱落 - deep orange
    Color(0xFF00897B), // 色差 - teal
    Color(0xFFFFB300), // 起皮 - amber
    Color(0xFF3949AB), // 阴阳角不方正 - indigo
  ];
  return palette[classIndex % palette.length];
}

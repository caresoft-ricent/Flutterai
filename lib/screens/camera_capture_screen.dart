import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../l10n/context_l10n.dart';

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  static Future<String?> capture(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
    );
  }

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? _controller;
  Object? _initError;
  bool _initializing = true;
  bool _capturing = false;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('no-camera');
      }

      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();

      // Enable tap-to-focus/auto exposure on devices that support it.
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      try {
        final minZoom = await controller.getMinZoomLevel();
        final maxZoom = await controller.getMaxZoomLevel();
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _currentZoom = minZoom;
        await controller.setZoomLevel(_currentZoom);
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
      }

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = e;
        _initializing = false;
      });
    }
  }

  Future<void> _setZoom(double zoom) async {
    final controller = _controller;
    if (controller == null) return;
    final next = zoom.clamp(_minZoom, _maxZoom);
    if ((next - _currentZoom).abs() < 0.01) return;
    try {
      await controller.setZoomLevel(next);
      if (!mounted) return;
      setState(() {
        _currentZoom = next;
      });
    } catch (_) {
      // Ignore devices/platforms that don't support zoom.
    }
  }

  Future<void> _setFocusAndExposure(
    Offset localPosition,
    Size viewSize,
    Size previewBoxSize,
  ) async {
    final controller = _controller;
    if (controller == null) return;

    final viewW = viewSize.width;
    final viewH = viewSize.height;
    final boxW = previewBoxSize.width;
    final boxH = previewBoxSize.height;
    if (viewW <= 0 || viewH <= 0 || boxW <= 0 || boxH <= 0) return;

    // We render a larger preview box (center-cropped) and clip it to the view.
    // Map tap position in view-space into the preview box coordinate.
    final dxBox = (localPosition.dx + (boxW - viewW) / 2) / boxW; // 0..1
    final dyBox = (localPosition.dy + (boxH - viewH) / 2) / boxH; // 0..1
    final point = Offset(
      dxBox.clamp(0.0, 1.0),
      dyBox.clamp(0.0, 1.0),
    );

    try {
      await controller.setFocusPoint(point);
    } catch (_) {}
    try {
      await controller.setExposurePoint(point);
    } catch (_) {}
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;

    setState(() {
      _capturing = true;
    });

    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.cameraCaptureTakeFailedRetry)),
      );
      setState(() {
        _capturing = false;
      });
    }
  }

  String _initErrorMessage(BuildContext context, Object? error) {
    final l10n = context.l10n;
    if (error is StateError && error.message == 'no-camera') {
      return l10n.cameraCaptureNoCamera;
    }
    return l10n.cameraCaptureInitFailed(error.toString());
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cameraCaptureTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.commonClose,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : (_initError != null)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_initErrorMessage(context, _initError)),
                  ),
                )
              : (controller == null)
                  ? Center(child: Text(l10n.cameraCaptureUnavailable))
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final viewSize = constraints.biggest;

                              final viewW = viewSize.width;
                              final viewH = viewSize.height;
                              if (viewW <= 0 || viewH <= 0) {
                                return const SizedBox.shrink();
                              }

                              // Use a cover-fit render (center crop, no stretch).
                              // Prefer controller.previewSize (more reliable on iOS)
                              // and swap w/h for portrait.
                              final previewSize = controller.value.previewSize;
                              final childW =
                                  (previewSize?.height ?? 1000).toDouble();
                              final childH = (previewSize?.width ??
                                      (1000 / controller.value.aspectRatio))
                                  .toDouble();

                              final scale =
                                  math.max(viewW / childW, viewH / childH);
                              final previewBoxSize =
                                  Size(childW * scale, childH * scale);

                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) {
                                  _setFocusAndExposure(
                                    details.localPosition,
                                    viewSize,
                                    previewBoxSize,
                                  );
                                },
                                onScaleStart: (_) {
                                  _baseZoom = _currentZoom;
                                },
                                onScaleUpdate: (details) {
                                  if (details.scale == 1.0) return;
                                  _setZoom(_baseZoom * details.scale);
                                },
                                child: ClipRect(
                                  child: SizedBox.expand(
                                    child: FittedBox(
                                      fit: BoxFit.cover,
                                      alignment: Alignment.center,
                                      child: SizedBox(
                                        width: childW,
                                        height: childH,
                                        child: CameraPreview(controller),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 24,
                          child: Center(
                            child: FloatingActionButton(
                              onPressed: _capturing ? null : _takePicture,
                              child: _capturing
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.camera_alt),
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }
}

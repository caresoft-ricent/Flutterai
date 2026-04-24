import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final yoloDetectionServiceProvider = Provider<YoloDetectionService>((ref) {
  return YoloDetectionService();
});

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// A single detected defect with bounding box and class info.
class YoloDetection {
  /// Normalized coordinates [0..1] relative to the original image.
  final double x1, y1, x2, y2;
  final int classIndex;
  final String className;
  final double confidence;

  const YoloDetection({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.classIndex,
    required this.className,
    required this.confidence,
  });

  @override
  String toString() =>
      'YoloDetection($className, conf=${confidence.toStringAsFixed(2)}, '
      'box=[${x1.toStringAsFixed(3)},${y1.toStringAsFixed(3)},'
      '${x2.toStringAsFixed(3)},${y2.toStringAsFixed(3)}])';
}

/// Aggregated result of running YOLO on an image.
class YoloDetectionResult {
  final List<YoloDetection> detections;

  /// The highest confidence across all detections (0 if empty).
  double get maxConfidence => detections.isEmpty
      ? 0.0
      : detections.map((d) => d.confidence).reduce(math.max);

  bool get hasDetections => detections.isNotEmpty;

  const YoloDetectionResult({required this.detections});
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const List<String> kYoloClasses = [
  '刷痕明显',
  '开裂',
  '未打磨到位',
  '污染',
  '流坠',
  '砂纸印明显',
  '脱落',
  '色差',
  '起皮',
  '阴阳角不方正、不顺直',
];

/// Default severity mapping from YOLO class to severity string.
const Map<String, String> kClassSeverityMap = {
  '刷痕明显': 'low',
  '开裂': 'high',
  '未打磨到位': 'low',
  '污染': 'medium',
  '流坠': 'medium',
  '砂纸印明显': 'low',
  '脱落': 'high',
  '色差': 'low',
  '起皮': 'medium',
  '阴阳角不方正、不顺直': 'medium',
};

/// Default rectification suggestions per class.
const Map<String, String> kClassRectifySuggestionMap = {
  '刷痕明显': '重新打磨后补涂面漆；检查滚筒质量；调整涂刷手法',
  '开裂': '铲除裂缝部位涂层；挂耐碱网格布重新批刮腻子；分层干燥后重涂',
  '未打磨到位': '重新打磨至平整；清理粉尘后补涂',
  '污染': '清洗污染区域；修补受损涂层；做好成品保护',
  '流坠': '打磨流坠区域至平整；控制涂刷厚度重涂',
  '砂纸印明显': '更换细目砂纸重新打磨；补涂面漆',
  '脱落': '铲除松动部位至基层；重新批刮腻子底涂面涂',
  '色差': '局部刮除后统一补涂同批次面漆；大面积色差需整墙重涂',
  '起皮': '铲除起皮层；检查基层含水率；重新施工底漆面漆',
  '阴阳角不方正、不顺直': '使用阴阳角器重新修正；补批腻子后打磨涂装',
};

const String kConfidenceThresholdKey = 'yolo_confidence_threshold';
const String kNmsIouThresholdKey = 'yolo_nms_iou_threshold';
const String kEnableLocalDetectionKey = 'yolo_enable_local_detection';
const String kYoloOnlyModeKey = 'yolo_only_mode';

const double kDefaultConfidenceThreshold = 0.45;
const double kDefaultNmsIouThreshold = 0.50;

// ImageNet normalization constants.
const _mean = [0.485, 0.456, 0.406];
const _std = [0.229, 0.224, 0.225];

const int _inputSize = 224;
const int _numClasses = 10;
const int _bboxDims = 4; // cx, cy, w, h

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class YoloDetectionService {
  OrtSession? _detSession;
  bool _ortInitialized = false;
  bool _loading = false;

  /// Last error during init, if any.
  String? lastInitError;

  /// Whether the detection model is loaded and ready.
  bool get isReady => _detSession != null;

  // -------------------------------------------------------------------------
  // Preferences
  // -------------------------------------------------------------------------

  Future<double> getConfidenceThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(kConfidenceThresholdKey) ??
        kDefaultConfidenceThreshold;
  }

  Future<void> setConfidenceThreshold(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kConfidenceThresholdKey, value.clamp(0.05, 0.99));
  }

  Future<double> getNmsIouThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(kNmsIouThresholdKey) ?? kDefaultNmsIouThreshold;
  }

  Future<void> setNmsIouThreshold(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kNmsIouThresholdKey, value.clamp(0.1, 0.95));
  }

  Future<bool> isLocalDetectionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kEnableLocalDetectionKey) ?? true;
  }

  Future<void> setLocalDetectionEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kEnableLocalDetectionKey, value);
  }

  Future<bool> isYoloOnlyMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kYoloOnlyModeKey) ?? false;
  }

  Future<void> setYoloOnlyMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kYoloOnlyModeKey, value);
  }

  // -------------------------------------------------------------------------
  // Model lifecycle
  // -------------------------------------------------------------------------

  /// Initialize ONNX Runtime and load the detection model.
  Future<void> init() async {
    if (_detSession != null || _loading) return;
    _loading = true;
    lastInitError = null;
    final sw = Stopwatch()..start();
    try {
      if (!_ortInitialized) {
        OrtEnv.instance.init();
        _ortInitialized = true;
        // ignore: avoid_print
        print('[YOLO] OrtEnv initialized (${sw.elapsedMilliseconds}ms)');
      }

      final detBytes = (await rootBundle.load('assets/models/best.onnx'))
          .buffer
          .asUint8List();
      // ignore: avoid_print
      print(
          '[YOLO] Model bytes loaded: ${detBytes.length} (${sw.elapsedMilliseconds}ms)');

      final opts = OrtSessionOptions();
      opts.setIntraOpNumThreads(2);
      opts.setInterOpNumThreads(1);
      opts.setSessionGraphOptimizationLevel(
          GraphOptimizationLevel.ortEnableAll);

      _detSession = OrtSession.fromBuffer(detBytes, opts);
      // ignore: avoid_print
      print('[YOLO] Detection model loaded OK (${sw.elapsedMilliseconds}ms). '
          'inputs=${_detSession!.inputNames} '
          'outputs=${_detSession!.outputNames}');
    } catch (e, st) {
      lastInitError = e.toString();
      // ignore: avoid_print
      print('[YOLO] *** Failed to load model: $e\n$st');
    } finally {
      sw.stop();
      _loading = false;
    }
  }

  /// Run a full diagnostic and return a human-readable report.
  Future<String> runDiagnostic() async {
    final buf = StringBuffer();
    final sw = Stopwatch()..start();

    buf.writeln('=== YOLO 诊断报告 ===');
    buf.writeln('时间: ${DateTime.now()}');
    buf.writeln('isReady (改前): $isReady');
    buf.writeln('lastInitError: $lastInitError');
    buf.writeln('');

    // Step 1: Try to load model
    if (!isReady) {
      // Reset so init() can retry
      _loading = false;
      await init();
    }
    buf.writeln('模型加载: ${isReady ? "成功 ✅" : "失败 ❌"}');
    if (lastInitError != null) {
      buf.writeln('错误: $lastInitError');
    }
    if (!isReady) {
      buf.writeln('无法继续诊断（模型未加载）');
      return buf.toString();
    }

    buf.writeln('inputNames: ${_detSession!.inputNames}');
    buf.writeln('outputNames: ${_detSession!.outputNames}');
    buf.writeln('');

    // Step 2: Try a dummy inference with a blank image
    buf.writeln('--- 空白图推理测试 ---');
    try {
      final dummyInput = Float32List(3 * _inputSize * _inputSize);
      final inputTensor = OrtValueTensor.createTensorWithDataList(
        dummyInput,
        [1, 3, _inputSize, _inputSize],
      );
      final runOpts = OrtRunOptions();
      final inputName = _detSession!.inputNames.first;
      final infSw = Stopwatch()..start();
      List<OrtValue?> outputs;
      try {
        final asyncResult =
            await _detSession!.runAsync(runOpts, {inputName: inputTensor});
        outputs =
            asyncResult ?? _detSession!.run(runOpts, {inputName: inputTensor});
      } catch (e) {
        // runAsync might not be supported; fall back to sync
        outputs = _detSession!.run(runOpts, {inputName: inputTensor});
      }
      infSw.stop();
      buf.writeln('推理耗时: ${infSw.elapsedMilliseconds}ms');

      final outVal = outputs.first;
      if (outVal != null) {
        final raw = outVal.value;
        buf.writeln('输出类型: ${raw.runtimeType}');
        if (raw is List) {
          buf.writeln('输出维度: batch=${raw.length}');
          if (raw.isNotEmpty && raw[0] is List) {
            final batch0 = raw[0] as List;
            buf.writeln('  [0] length=${batch0.length}');
            if (batch0.isNotEmpty && batch0[0] is List) {
              buf.writeln('  [0][0] length=${(batch0[0] as List).length}');
              buf.writeln(
                  '  形状: [1, ${batch0.length}, ${(batch0[0] as List).length}]');
            }
          }
        }
      } else {
        buf.writeln('输出为 null ❌');
      }

      inputTensor.release();
      for (final o in outputs) {
        o?.release();
      }
      runOpts.release();
      buf.writeln('推理测试: 成功 ✅');
    } catch (e) {
      buf.writeln('推理测试: 失败 ❌');
      buf.writeln('错误: $e');
    }

    sw.stop();
    buf.writeln('');
    buf.writeln('总耗时: ${sw.elapsedMilliseconds}ms');
    return buf.toString();
  }

  void dispose() {
    _detSession?.release();
    _detSession = null;
    if (_ortInitialized) {
      OrtEnv.instance.release();
      _ortInitialized = false;
    }
  }

  // -------------------------------------------------------------------------
  // Inference
  // -------------------------------------------------------------------------

  /// Run YOLO detection on [imageFile].
  ///
  /// Returns a [YoloDetectionResult] with all detections above the confidence
  /// threshold. If [confThreshold] is null, the stored preference value is used.
  Future<YoloDetectionResult> detect(
    File imageFile, {
    double? confThreshold,
    double? iouThreshold,
  }) async {
    final totalSw = Stopwatch()..start();
    if (_detSession == null) {
      await init();
      if (_detSession == null) {
        // ignore: avoid_print
        print(
            '[YOLO] detect() aborted: model not loaded. lastInitError=$lastInitError');
        return const YoloDetectionResult(detections: []);
      }
    }

    final confTh = confThreshold ?? await getConfidenceThreshold();
    final iouTh = iouThreshold ?? await getNmsIouThreshold();
    // ignore: avoid_print
    print('[YOLO] detect() confTh=$confTh iouTh=$iouTh');

    // Pre-process image on a separate isolate to avoid jank.
    final preprocessed = await compute(_preprocessImage, imageFile.path);
    if (preprocessed == null) {
      // ignore: avoid_print
      print('[YOLO] detect() aborted: image preprocessing returned null');
      return const YoloDetectionResult(detections: []);
    }
    // ignore: avoid_print
    print('[YOLO] Preprocessing done (${totalSw.elapsedMilliseconds}ms)');

    // Create input tensor.
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      preprocessed,
      [1, 3, _inputSize, _inputSize],
    );

    List<OrtValue?> outputs;
    final runOptions = OrtRunOptions();
    try {
      final inputName = _detSession!.inputNames.first;
      // Use async run (ORT's own thread pool) to avoid blocking UI.
      final asyncResult =
          await _detSession!.runAsync(runOptions, {inputName: inputTensor});
      outputs =
          asyncResult ?? _detSession!.run(runOptions, {inputName: inputTensor});
      // ignore: avoid_print
      print('[YOLO] Inference done (${totalSw.elapsedMilliseconds}ms)');
    } catch (e) {
      // ignore: avoid_print
      print('[YOLO] *** Inference failed: $e');
      inputTensor.release();
      runOptions.release();
      return const YoloDetectionResult(detections: []);
    }

    // Parse output.
    List<YoloDetection> detections = [];
    try {
      final outVal = outputs.first;
      if (outVal == null) return const YoloDetectionResult(detections: []);

      final rawValue = outVal.value;
      final transposed = _parseOutputToTransposed(rawValue);
      final numBoxes = transposed.isEmpty ? 0 : transposed.first.length;

      final candidates = <YoloDetection>[];
      for (int i = 0; i < numBoxes; i++) {
        double maxScore = -1;
        int maxClass = 0;
        for (int c = 0; c < _numClasses; c++) {
          final score = transposed[_bboxDims + c][i];
          if (score > maxScore) {
            maxScore = score;
            maxClass = c;
          }
        }
        if (maxScore < confTh) continue;

        final cx = transposed[0][i] / _inputSize;
        final cy = transposed[1][i] / _inputSize;
        final w = transposed[2][i] / _inputSize;
        final h = transposed[3][i] / _inputSize;

        candidates.add(YoloDetection(
          x1: (cx - w / 2).clamp(0.0, 1.0),
          y1: (cy - h / 2).clamp(0.0, 1.0),
          x2: (cx + w / 2).clamp(0.0, 1.0),
          y2: (cy + h / 2).clamp(0.0, 1.0),
          classIndex: maxClass,
          className: maxClass < kYoloClasses.length
              ? kYoloClasses[maxClass]
              : 'unknown',
          confidence: maxScore,
        ));
      }

      detections = _nms(candidates, iouTh);
    } finally {
      inputTensor.release();
      for (final o in outputs) {
        o?.release();
      }
      runOptions.release();
    }

    detections.sort((a, b) => b.confidence.compareTo(a.confidence));
    totalSw.stop();
    // ignore: avoid_print
    print('[YOLO] detect() complete: ${detections.length} detections '
        'in ${totalSw.elapsedMilliseconds}ms');
    for (final d in detections) {
      // ignore: avoid_print
      print('[YOLO]   $d');
    }
    return YoloDetectionResult(detections: detections);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Parse raw ONNX output into a 2D list [14][N].
  static List<List<double>> _parseOutputToTransposed(dynamic rawValue) {
    if (rawValue is List && rawValue.isNotEmpty) {
      final batch = rawValue[0]; // [14][N]
      if (batch is List && batch.isNotEmpty) {
        return batch.map<List<double>>((row) {
          if (row is List) {
            return row.map<double>((v) => (v as num).toDouble()).toList();
          }
          return <double>[];
        }).toList();
      }
    }
    return [];
  }

  /// Non-maximum suppression per class.
  static List<YoloDetection> _nms(
      List<YoloDetection> candidates, double iouThreshold) {
    final Map<int, List<YoloDetection>> byClass = {};
    for (final d in candidates) {
      byClass.putIfAbsent(d.classIndex, () => []).add(d);
    }

    final result = <YoloDetection>[];
    for (final group in byClass.values) {
      group.sort((a, b) => b.confidence.compareTo(a.confidence));
      final kept = <YoloDetection>[];
      for (final det in group) {
        bool suppress = false;
        for (final k in kept) {
          if (_iou(det, k) > iouThreshold) {
            suppress = true;
            break;
          }
        }
        if (!suppress) kept.add(det);
      }
      result.addAll(kept);
    }
    return result;
  }

  static double _iou(YoloDetection a, YoloDetection b) {
    final interX1 = math.max(a.x1, b.x1);
    final interY1 = math.max(a.y1, b.y1);
    final interX2 = math.min(a.x2, b.x2);
    final interY2 = math.min(a.y2, b.y2);

    final interArea =
        math.max(0.0, interX2 - interX1) * math.max(0.0, interY2 - interY1);
    if (interArea == 0) return 0;

    final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
    final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);
    return interArea / (areaA + areaB - interArea);
  }
}

// ---------------------------------------------------------------------------
// Top-level function for compute() – image pre-processing.
// ---------------------------------------------------------------------------

/// Decode, resize, and normalize image to Float32List NCHW tensor.
Float32List? _preprocessImage(String imagePath) {
  final bytes = File(imagePath).readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final resized =
      img.copyResize(decoded, width: _inputSize, height: _inputSize);

  final total = 3 * _inputSize * _inputSize;
  final data = Float32List(total);
  for (int y = 0; y < _inputSize; y++) {
    for (int x = 0; x < _inputSize; x++) {
      final pixel = resized.getPixel(x, y);
      final r = pixel.r / 255.0;
      final g = pixel.g / 255.0;
      final b = pixel.b / 255.0;
      final idx = y * _inputSize + x;
      data[0 * _inputSize * _inputSize + idx] = (r - _mean[0]) / _std[0];
      data[1 * _inputSize * _inputSize + idx] = (g - _mean[1]) / _std[1];
      data[2 * _inputSize * _inputSize + idx] = (b - _mean[2]) / _std[2];
    }
  }
  return data;
}

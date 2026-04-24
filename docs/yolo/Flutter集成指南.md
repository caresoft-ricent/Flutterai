# 验房问题识别模型 - Flutter 集成指南

## 一、模型文件

### 1.1 分类模型（Phase 1 - 图像分类）

| 文件 | 路径 | 大小 | 说明 |
|------|------|------|------|
| ONNX 模型 | `outputs/wall_classifier.onnx` | 15.3 MB | 图像分类模型 |
| 类别列表 | `outputs/classes.txt` | 118 B | 10 个问题类别 |

**类别列表：**
```
刷痕明显
开裂
未打磨到位
污染
流坠
砂纸印明显
脱落
色差
起皮
阴阳角不方正、不顺直
```

### 1.2 检测模型（Phase 2 - 目标检测）

| 文件 | 路径 | 大小 | 说明 |
|------|------|------|------|
| ONNX 模型 | `runs/detect/train/weights/best.onnx` | 9.9 MB | YOLO 检测模型 |

---

## 二、Flutter 集成方式

### 2.1 依赖配置

在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  flutter:
    sdk: flutter
  onnxruntime: ^1.16.0  # ONNX Runtime
```

### 2.2 分类模型使用示例

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart';

class WallClassifier {
  late final InferenceSession _session;
  
  // 类别列表
  static const List<String> classes = [
    '刷痕明显', '开裂', '未打磨到位', '污染', '流坠',
    '砂纸印明显', '脱落', '色差', '起皮', '阴阳角不方正、不顺直'
  ];
  
  Future<void> init() async {
    // 加载模型
    final sessionOptions = SessionOptions();
    sessionOptions.graphOptimizationLevel = GraphOptimizationLevel.ortEnableAll;
    
    final modelPath = 'assets/models/wall_classifier.onnx';
    _session = await InferenceSession.create(
      await File(modelPath).readAsBytes(),
      sessionOptions,
    );
  }
  
  /// 识别图片中的问题类型
  /// 返回: { 'class': '脱落', 'confidence': 0.95 }
  Future<Map<String, dynamic>> classify(File imageFile) async {
    // 1. 读取并预处理图片 (224x224)
    final input = await _preprocessImage(imageFile);
    
    // 2. 运行推理
    final inputs = [OrtValueTensor.createTensorWithData(input)];
    final outputs = await _session.run(
      inputs,
      ['output'],
    );
    
    // 3. 解析结果
    final result = outputs[0].value as List<double>;
    final maxIdx = result.indexOf(result.reduce((a, b) => a > b ? a : b));
    final confidence = result[maxIdx];
    
    return {
      'class': classes[maxIdx],
      'confidence': confidence,
    };
  }
  
  Future<Uint8List> _preprocessImage(File file) async {
    // 图片预处理:
    // 1. 读取图片并缩放到 224x224
    // 2. 归一化到 [0, 1]
    // 3. 转换为 RGB 通道顺序
    // 4. 转换为 NCHW 格式
    // (具体实现略)
  }
}
```

### 2.3 检测模型使用示例

```dart
import 'package:onnxruntime/onnxruntime.dart';

class WallDetector {
  late final InferenceSession _session;
  
  static const List<String> classes = [
    '刷痕明显', '开裂', '未打磨到位', '污染', '流坠',
    '砂纸印明显', '脱落', '色差', '起皮', '阴阳角不方正、不顺直'
  ];
  
  Future<void> init() async {
    final sessionOptions = SessionOptions();
    _session = await InferenceSession.create(
      await File('assets/models/best.onnx').readAsBytes(),
      sessionOptions,
    );
  }
  
  /// 检测图片中的问题区域
  /// 返回: [{ 'class': '脱落', 'bbox': [x, y, w, h], 'confidence': 0.9 }]
  Future<List<Map<String, dynamic>>> detect(File imageFile) async {
    // 1. 预处理图片
    final input = await _preprocessImage(imageFile);
    
    // 2. 运行推理
    final inputs = [OrtValueTensor.createTensorWithData(input)];
    final outputs = await _session.run(inputs, ['output']);
    
    // 3. 解析检测结果 (后处理)
    // 需要做 NMS 非极大值抑制
    // (具体实现略)
  }
}
```

---

## 三、输入输出格式

### 3.1 分类模型

| 项目 | 格式 |
|------|------|
| 输入 | RGB 图片, 224x224, float32, NCHW |
| 输出 | 10 类别概率, shape [1, 10] |

### 3.2 检测模型

| 项目 | 格式 |
|------|------|
| 输入 | RGB 图片, 224x224, float32, NCHW |
| 输出 | 检测框, shape [1, 14, 1029] (14 = 4 bbox + 10 类别 + 1 目标分数) |

---

## 四、模型下载

所有模型文件位于:
```
/Volumes/NVMe4TB/ai-agent/projects/vision-train/
├── outputs/
│   ├── wall_classifier.onnx      # 分类模型
│   └── classes.txt                # 类别列表
└── runs/detect/train/weights/
    └── best.onnx                  # 检测模型
```

复制到 Flutter 项目的 `assets/models/` 目录即可使用。

---

## 五、性能参考

| 模型 | 推理时间 (iPhone) | 模型大小 |
|------|------------------|---------|
| 分类模型 (ONNX) | ~50ms | 15.3 MB |
| 检测模型 (ONNX) | ~100ms | 9.9 MB |

---

## 六、注意事项

1. **图片预处理** - 必须使用 ImageNet 标准化:
   - 缩放: 224x224
   - 归一化: mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]

2. **Android 配置** - 在 `android/app/build.gradle` 中添加:
   ```gradle
   android {
       packagingOptions {
           pickFirst 'lib/x86_64/libonnxruntime.so'
           pickFirst 'lib/armeabi-v7a/libonnxruntime.so'
           pickFirst 'lib/arm64-v8a/libonnxruntime.so'
       }
   }
   ```

3. **iOS 配置** - 添加依赖:
   ```ruby
   pod 'onnxruntime-swift', '~> 1.16'
   ```

---

## 七、联系支持

如有集成问题，请联系 AI 团队。

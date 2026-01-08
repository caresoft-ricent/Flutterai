import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

class ModelDownloader {
  static const String asrModelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2';

  static const String vadModelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

  static const List<String> _requiredAsrFiles = [
    'encoder.onnx',
    'decoder.onnx',
    'joiner.onnx',
    'tokens.txt',
  ];

  static const String _hotwordsFileName = 'hotwords.txt';

  // Hotwords must be encodable by tokens.txt. Avoid Arabic numerals like "1"/"6"
  // because many CJK/BPE token sets don't include standalone digits.
  static const String _hotwordsContent =
      '验收\n钢筋\n合格\n不合格\n一栋\n六层\n栋\n层\n保护层\n模板\n巡检\n';

  static const String _vadFileName = 'silero_vad.onnx';

  static Future<String> ensureModel(
    String modelDir, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = Directory(modelDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final hasAll = await _hasAllRequiredFiles(modelDir);
    if (hasAll) {
      await _ensureHotwordsFile(modelDir);
      try {
        await _ensureVadModel(modelDir, onProgress: null);
      } catch (_) {
        // VAD is optional for core ASR; callers can fallback to endpoint rules.
      }
      // Best-effort cleanup in case older runs left duplicate large files.
      await _cleanupDuplicateAsrFiles(modelDir);
      return modelDir;
    }

    final tmpDir = await Directory(p.join(modelDir, '_tmp')).create();
    try {
      final tarBz2Path = p.join(tmpDir.path, 'asr.tar.bz2');

      await _downloadFile(
        url: asrModelUrl,
        savePath: tarBz2Path,
        onProgress: onProgress,
      );

      await _extractTarBz2(
        tarBz2Path: tarBz2Path,
        outputDir: modelDir,
      );

      // Some archives contain an outer folder. If required files are not
      // in modelDir root, try to locate them and move into modelDir.
      await _flattenIfNeeded(modelDir);

      // Archives may use non-canonical filenames (e.g. encoder-epoch-*.onnx).
      // Sherpa expects encoder.onnx/decoder.onnx/joiner.onnx/tokens.txt.
      final resolved = await _resolveCanonicalAsrFiles(modelDir);

      final ok = await _hasAllRequiredFiles(modelDir);
      if (!ok) {
        final hint = resolved.isEmpty
            ? ''
            : '\n已尝试自动匹配并生成标准文件名：${resolved.keys.join(', ')}';
        final candidates = await _summarizeCandidates(modelDir);
        throw Exception(
          '模型解压完成，但缺少必需文件：${_requiredAsrFiles.join(', ')}'
          '$hint'
          '\n候选文件：$candidates',
        );
      }

      await _ensureHotwordsFile(modelDir);
      try {
        await _ensureVadModel(modelDir, onProgress: null);
      } catch (_) {
        // VAD is optional for core ASR; callers can fallback to endpoint rules.
      }

      // Clean up duplicate large files created by extraction/flattening.
      await _cleanupDuplicateAsrFiles(modelDir);

      return modelDir;
    } finally {
      if (await tmpDir.exists()) {
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {
          // ignore
        }
      }
    }
  }

  static Future<Map<String, String>> _resolveCanonicalAsrFiles(
    String modelDir,
  ) async {
    final resolved = <String, String>{};

    Future<void> resolveOne({
      required String kind,
      required String targetName,
      required bool Function(String basenameLower) accept,
    }) async {
      final targetPath = p.join(modelDir, targetName);
      if (await File(targetPath).exists()) return;

      final best = await _findBestCandidate(
        modelDir,
        accept: accept,
      );
      if (best == null) return;

      await _moveOrCopy(best, targetPath);
      resolved[kind] = p.basename(best.path);
    }

    await resolveOne(
      kind: 'encoder',
      targetName: 'encoder.onnx',
      accept: (b) => b.endsWith('.onnx') && b.contains('encoder'),
    );
    await resolveOne(
      kind: 'decoder',
      targetName: 'decoder.onnx',
      accept: (b) => b.endsWith('.onnx') && b.contains('decoder'),
    );
    await resolveOne(
      kind: 'joiner',
      targetName: 'joiner.onnx',
      accept: (b) => b.endsWith('.onnx') && b.contains('joiner'),
    );
    await resolveOne(
      kind: 'tokens',
      targetName: 'tokens.txt',
      accept: (b) => b.endsWith('.txt') && b.contains('tokens'),
    );

    return resolved;
  }

  static Future<File?> _findBestCandidate(
    String modelDir, {
    required bool Function(String basenameLower) accept,
  }) async {
    final root = Directory(modelDir);
    if (!await root.exists()) return null;

    File? best;
    int bestLen = -1;

    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final path = ent.path;
      if (path.contains('${p.separator}_tmp${p.separator}')) continue;

      final nameLower = p.basename(path).toLowerCase();
      if (!accept(nameLower)) continue;

      try {
        final len = await ent.length();
        if (len > bestLen) {
          best = ent;
          bestLen = len;
        }
      } catch (_) {
        // ignore
      }
    }

    return best;
  }

  static Future<String> _summarizeCandidates(String modelDir) async {
    final root = Directory(modelDir);
    if (!await root.exists()) return '无';

    final enc = <String>[];
    final dec = <String>[];
    final joi = <String>[];
    final tok = <String>[];

    Future<void> add(List<String> list, File f) async {
      if (list.length >= 6) return;
      try {
        final len = await f.length();
        list.add('${p.basename(f.path)}(${len}B)');
      } catch (_) {
        list.add('${p.basename(f.path)}(?)');
      }
    }

    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final path = ent.path;
      if (path.contains('${p.separator}_tmp${p.separator}')) continue;
      final b = p.basename(path).toLowerCase();
      if (b.endsWith('.onnx') && b.contains('encoder')) await add(enc, ent);
      if (b.endsWith('.onnx') && b.contains('decoder')) await add(dec, ent);
      if (b.endsWith('.onnx') && b.contains('joiner')) await add(joi, ent);
      if (b.endsWith('.txt') && b.contains('tokens')) await add(tok, ent);
      if (enc.length >= 6 &&
          dec.length >= 6 &&
          joi.length >= 6 &&
          tok.length >= 6) {
        break;
      }
    }

    String fmt(List<String> xs) => xs.isEmpty ? '[]' : '[${xs.join(', ')}]';
    return 'encoder=${fmt(enc)}; decoder=${fmt(dec)}; joiner=${fmt(joi)}; tokens=${fmt(tok)}';
  }

  static Future<bool> _hasAllRequiredFiles(String modelDir) async {
    for (final f in _requiredAsrFiles) {
      final file = File(p.join(modelDir, f));
      if (!await file.exists()) return false;
      final len = await file.length();
      if (len <= 0) return false;
    }
    return true;
  }

  static Future<void> _ensureHotwordsFile(String modelDir) async {
    final f = File(p.join(modelDir, _hotwordsFileName));
    if (await f.exists()) {
      try {
        final cur = await f.readAsString();
        if (cur == _hotwordsContent) return;
      } catch (_) {
        // Fall through and rewrite.
      }
    }
    await f.writeAsString(_hotwordsContent);
  }

  static Future<void> _ensureVadModel(
    String modelDir, {
    void Function(double progress)? onProgress,
  }) async {
    final outPath = p.join(modelDir, _vadFileName);
    if (await File(outPath).exists()) return;

    await _downloadFile(
      url: vadModelUrl,
      savePath: outPath,
      onProgress: onProgress,
    );
  }

  static Future<void> _downloadFile({
    required String url,
    required String savePath,
    void Function(double progress)? onProgress,
  }) async {
    final outFile = File(savePath);
    if (!await outFile.parent.exists()) {
      await outFile.parent.create(recursive: true);
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 10),
        followRedirects: true,
      ),
    );

    await dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (onProgress == null) return;
        if (total <= 0) return;
        onProgress(received / total);
      },
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(minutes: 30),
      ),
    );
  }

  static Future<void> _extractTarBz2({
    required String tarBz2Path,
    required String outputDir,
  }) async {
    // Use streaming extraction to avoid loading ~300MB+ archives into memory.
    await extractFileToDisk(
      tarBz2Path,
      outputDir,
      asyncWrite: true,
      bufferSize: 1024 * 1024,
    );
  }

  static Future<void> _flattenIfNeeded(String modelDir) async {
    final ok = await _hasAllRequiredFiles(modelDir);
    if (ok) return;

    // Find a nested directory that contains required files.
    final root = Directory(modelDir);
    final children = await root
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();

    final byName = <String, File>{
      for (final f in children) p.basename(f.path): f,
    };

    final hasAllNested = _requiredAsrFiles.every(byName.containsKey);
    if (!hasAllNested) return;

    for (final name in _requiredAsrFiles) {
      final src = byName[name]!;
      final dstPath = p.join(modelDir, name);
      if (p.normalize(src.path) == p.normalize(dstPath)) continue;
      await _moveOrCopy(src, dstPath);
    }
  }

  static Future<void> _moveOrCopy(File src, String dstPath) async {
    final dst = File(dstPath);
    if (!await dst.parent.exists()) {
      await dst.parent.create(recursive: true);
    }
    // Try rename first to avoid duplicating large files.
    try {
      await src.rename(dstPath);
      return;
    } catch (_) {
      // Fallback to copy+delete.
    }
    await src.copy(dstPath);
    try {
      await src.delete();
    } catch (_) {
      // ignore
    }
  }

  static Future<void> _cleanupDuplicateAsrFiles(String modelDir) async {
    // Keep only canonical files in modelDir root.
    final keep = <String>{
      p.normalize(p.join(modelDir, 'encoder.onnx')),
      p.normalize(p.join(modelDir, 'decoder.onnx')),
      p.normalize(p.join(modelDir, 'joiner.onnx')),
      p.normalize(p.join(modelDir, 'tokens.txt')),
      p.normalize(p.join(modelDir, _hotwordsFileName)),
      p.normalize(p.join(modelDir, _vadFileName)),
    };

    final root = Directory(modelDir);
    if (!await root.exists()) return;

    bool shouldDelete(File f) {
      final path = p.normalize(f.path);
      if (keep.contains(path)) return false;

      final b = p.basename(path).toLowerCase();
      if (b == 'encoder.onnx' || b == 'decoder.onnx' || b == 'joiner.onnx') {
        return true;
      }

      // Delete common duplicate naming patterns, but avoid deleting VAD.
      if (b.endsWith('.onnx') && !b.contains('silero')) {
        if (b.contains('encoder') ||
            b.contains('decoder') ||
            b.contains('joiner')) {
          return true;
        }
      }

      if (b == 'tokens.txt' || b.contains('tokens') && b.endsWith('.txt')) {
        return true;
      }

      return false;
    }

    // Delete duplicate large files first.
    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      if (ent.path.contains('${p.separator}_tmp${p.separator}')) continue;
      if (!shouldDelete(ent)) continue;
      try {
        final len = await ent.length();
        // Be conservative: only delete sizable duplicates.
        if (len < 1024 * 1024) continue;
        await ent.delete();
      } catch (_) {
        // ignore
      }
    }

    // Best-effort remove empty directories (excluding root).
    try {
      final dirs = await root
          .list(recursive: true, followLinks: false)
          .where((e) => e is Directory)
          .cast<Directory>()
          .toList();
      // Delete deeper dirs first.
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        if (p.normalize(d.path) == p.normalize(modelDir)) continue;
        try {
          final any = await d.list(followLinks: false).isEmpty;
          if (any) {
            await d.delete();
          }
        } catch (_) {
          // ignore
        }
      }
    } catch (_) {
      // ignore
    }
  }
}

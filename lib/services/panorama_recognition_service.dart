import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../models/panorama_session.dart';
import '../services/defect_library_service.dart';
import '../services/online_vision_service.dart';
import '../services/panorama_storage_service.dart';

final panoramaRecognitionServiceProvider =
    Provider<PanoramaRecognitionService>((ref) {
  return PanoramaRecognitionService(ref);
});

class PanoramaRecognitionService {
  final Ref _ref;

  PanoramaRecognitionService(this._ref);

  Future<File?> generateThumbnail(
    String sessionId,
    String nodeId,
    String panoImagePath,
  ) async {
    try {
      final bytes = await File(panoImagePath).readAsBytes();
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) return null;

      // Center-crop to a wide thumbnail then resize.
      final w = decoded.width;
      final h = decoded.height;
      final cropH = (h * 0.45).round();
      final cropY = ((h - cropH) / 2).round();
      final cropped = img.copyCrop(
        decoded,
        x: 0,
        y: cropY.clamp(0, h - 1),
        width: w,
        height: cropH.clamp(1, h),
      );

      final resized = img.copyResize(cropped, width: 420);
      final outBytes = img.encodeJpg(resized, quality: 80);

      final storage = _ref.read(panoramaStorageServiceProvider);
      final outFile = await storage.createNodeFile(
        sessionId,
        nodeId,
        fileName: 'thumb.jpg',
      );
      await outFile.writeAsBytes(outBytes, flush: true);
      return outFile;
    } catch (e) {
      debugPrint('[Panorama] thumbnail failed: $e');
      return null;
    }
  }

  Map<String, img.Image> _split5Views(img.Image pano) {
    final w = pano.width;
    final h = pano.height;

    // Simple crop strategy for MVP: split equirectangular into regions.
    // Note: This is not perspective projection; later we can replace with true
    // rectilinear projection without changing callers.
    int clampInt(int v, int min, int max) =>
        v < min ? min : (v > max ? max : v);

    img.Image cropCenter(double cxN, double cyN, double wN, double hN) {
      final cw = (w * wN).round();
      final ch = (h * hN).round();
      final cx = (w * cxN).round();
      final cy = (h * cyN).round();
      final x0 = clampInt(cx - (cw ~/ 2), 0, w - 1);
      final y0 = clampInt(cy - (ch ~/ 2), 0, h - 1);
      final x1 = clampInt(x0 + cw, 1, w);
      final y1 = clampInt(y0 + ch, 1, h);
      return img.copyCrop(
        pano,
        x: x0,
        y: y0,
        width: (x1 - x0).clamp(1, w),
        height: (y1 - y0).clamp(1, h),
      );
    }

    final front = cropCenter(0.50, 0.50, 0.34, 0.55);
    final left = cropCenter(0.25, 0.50, 0.34, 0.55);
    final right = cropCenter(0.75, 0.50, 0.34, 0.55);
    final up = cropCenter(0.50, 0.20, 0.50, 0.40);
    final down = cropCenter(0.50, 0.80, 0.50, 0.40);

    // Normalize sizes to help model & costs.
    img.Image norm(img.Image i) {
      const maxDim = 1280;
      final largest = i.width > i.height ? i.width : i.height;
      if (largest <= maxDim) return i;
      final scale = maxDim / largest;
      return img.copyResize(
        i,
        width: (i.width * scale).round(),
        height: (i.height * scale).round(),
        interpolation: img.Interpolation.linear,
      );
    }

    return {
      'front': norm(front),
      'left': norm(left),
      'right': norm(right),
      'up': norm(up),
      'down': norm(down),
    };
  }

  Future<Map<String, String>> _writeViewsToDisk(
    String sessionId,
    String nodeId,
    Map<String, img.Image> views,
  ) async {
    final storage = _ref.read(panoramaStorageServiceProvider);
    final out = <String, String>{};
    for (final entry in views.entries) {
      final name = entry.key;
      final file = await storage.createNodeFile(
        sessionId,
        nodeId,
        fileName: 'view_$name.jpg',
      );
      final bytes = img.encodeJpg(entry.value, quality: 82);
      await file.writeAsBytes(bytes, flush: true);
      out[name] = file.path;
    }
    return out;
  }

  Future<List<PanoramaFinding>> recognizeNode(
    String sessionId,
    PanoramaNode node, {
    required String sceneHint,
  }) async {
    final panoPath = node.panoImagePath;
    if (panoPath == null || panoPath.trim().isEmpty) {
      throw StateError('节点没有全景照片');
    }

    final bytes = await File(panoPath).readAsBytes();
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) {
      throw StateError('全景照片无法解码');
    }

    final views = _split5Views(decoded);
    final viewPaths = await _writeViewsToDisk(sessionId, node.id, views);

    final defectLibrary = _ref.read(defectLibraryServiceProvider);
    await defectLibrary.ensureLoaded();

    final candidates = defectLibrary.suggest(
      query: '日常巡检 $sceneHint',
      limit: 30,
    );
    final candidateLines = candidates.map((e) => e.toPromptLine()).toList();

    final onlineVision = _ref.read(onlineVisionServiceProvider);

    final out = <PanoramaFinding>[];
    for (final v in ['front', 'left', 'right', 'up', 'down']) {
      final path = viewPaths[v];
      if (path == null) continue;

      final hint = '这是全景图的“$v 视角”裁切图。请只关注该视角内是否存在明显质量/安全问题。';
      final r = await onlineVision.analyzeImageAutoStructured(
        path,
        sceneHint: sceneHint,
        hint: hint,
        defectLibraryCandidateLines: candidateLines,
      );

      // If model didn't provide match_id, infer locally.
      var matchId = r.matchId.trim();
      if (r.type.trim() == 'defect' && matchId.isEmpty) {
        final inferQuery = <String>[
          '日常巡检',
          sceneHint,
          r.summary,
          r.defectType,
          r.rectifySuggestion,
        ].where((s) => s.trim().isNotEmpty).join(' ');

        final inferred = defectLibrary.suggest(query: inferQuery, limit: 1);
        if (inferred.isNotEmpty) matchId = inferred.first.id;
      }

      out.add(
        PanoramaFinding(
          view: v,
          rawJson: r.rawJson,
          type: r.type,
          summary: r.summary,
          defectType: r.defectType,
          severity: r.severity,
          rectifySuggestion: r.rectifySuggestion,
          matchId: matchId,
        ),
      );
    }

    // Deduplicate: prefer findings with matchId.
    final dedup = <String, PanoramaFinding>{};
    for (final f in out) {
      final key = f.matchId.trim().isNotEmpty
          ? 'id:${f.matchId.trim()}'
          : 't:${f.type}|d:${f.defectType}|s:${f.summary}';
      final existing = dedup[key];
      if (existing == null) {
        dedup[key] = f;
        continue;
      }
      if (existing.matchId.trim().isEmpty && f.matchId.trim().isNotEmpty) {
        dedup[key] = f;
      }
    }

    return dedup.values.toList();
  }
}

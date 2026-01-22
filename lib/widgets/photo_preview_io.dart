import 'dart:io';

import 'package:flutter/material.dart';

import '../services/backend_api_service.dart';

class PhotoPreview extends StatelessWidget {
  final String path;
  final BoxFit fit;

  const PhotoPreview({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final p = path.trim();

    String? uploadsPathFromRef(String s) {
      final v = s.trim();
      if (v.isEmpty) return null;
      if (v.startsWith('/uploads/')) return v;
      if (v.startsWith('uploads/')) return '/$v';
      if (v.startsWith('http://') || v.startsWith('https://')) {
        try {
          final uri = Uri.parse(v);
          if (uri.path.startsWith('/uploads/')) return uri.path;
        } catch (_) {
          return null;
        }
      }
      return null;
    }

    Widget netImg(String url) {
      return Image.network(
        url,
        fit: fit,
        errorBuilder: (context, error, stack) {
          return const Center(child: Text('图片预览失败'));
        },
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        },
      );
    }

    // If it's an uploads reference, always bind to current backend base URL.
    final uploadsPath = uploadsPathFromRef(p);
    if (uploadsPath != null) {
      return FutureBuilder<String>(
        future: BackendApiService.getEffectiveBaseUrl(),
        builder: (context, snap) {
          final base = (snap.data ?? '');
          if (base.isEmpty) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2));
          }
          final url = base + uploadsPath;
          return netImg(url);
        },
      );
    }

    // Other absolute URLs (non-uploads) can be loaded as-is.
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return netImg(p);
    }

    final file = File(p);
    if (!file.existsSync()) {
      return const Center(child: Text('图片文件不存在'));
    }
    return Image.file(
      file,
      fit: fit,
      errorBuilder: (context, error, stack) {
        return const Center(child: Text('图片预览失败'));
      },
    );
  }
}

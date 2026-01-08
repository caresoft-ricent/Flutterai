import 'dart:io';

import 'package:flutter/material.dart';

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
    final file = File(path);
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

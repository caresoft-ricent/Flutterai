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
    return const Center(
      child: Text(
        'Web 端不支持本地图片预览',
        textAlign: TextAlign.center,
      ),
    );
  }
}

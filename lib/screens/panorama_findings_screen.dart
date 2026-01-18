import 'package:flutter/material.dart';

import '../models/panorama_session.dart';

class PanoramaFindingsScreen extends StatelessWidget {
  final List<PanoramaFinding> findings;

  const PanoramaFindingsScreen({
    super.key,
    required this.findings,
  });

  String _viewZh(String view) {
    switch (view) {
      case 'front':
        return '正前方';
      case 'left':
        return '左侧';
      case 'right':
        return '右侧';
      case 'up':
        return '上方';
      case 'down':
        return '下方';
      default:
        return view;
    }
  }

  String _severityZh(String s) {
    switch (s.toLowerCase()) {
      case 'low':
        return '低';
      case 'medium':
        return '中';
      case 'high':
        return '高';
      default:
        return s;
    }
  }

  String _titleOf(PanoramaFinding f) {
    final t = f.type.trim();
    if (t == 'irrelevant') return '无明显问题';
    if (t == 'defect') {
      return f.defectType.trim().isNotEmpty ? f.defectType.trim() : '问题';
    }
    return t.isNotEmpty ? t : '结果';
  }

  String? _metaOf(PanoramaFinding f) {
    if (f.type.trim() == 'irrelevant') return null;
    final sev = f.severity.trim();
    if (sev.isEmpty) return null;
    return '严重程度：${_severityZh(sev)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('已识别问题（${findings.length}个）'),
      ),
      body: findings.isEmpty
          ? const Center(child: Text('暂无识别结果'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              itemCount: findings.length,
              separatorBuilder: (_, __) => const Divider(height: 16),
              itemBuilder: (ctx, i) {
                final f = findings[i];
                final view = _viewZh(f.view);
                final title = _titleOf(f);
                final meta = _metaOf(f);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '【$view】$title',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    if (meta != null) ...[
                      const SizedBox(height: 4),
                      Text(meta),
                    ],
                    if (f.summary.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(f.summary.trim()),
                    ],
                    if (f.rectifySuggestion.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('建议：${f.rectifySuggestion.trim()}'),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

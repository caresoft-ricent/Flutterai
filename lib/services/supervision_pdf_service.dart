import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/supervision_library.dart';

class SupervisionBaseInfo {
  final String projectName;
  final String phase;
  final int progressPercent;
  final DateTime createdAt;

  const SupervisionBaseInfo({
    required this.projectName,
    required this.phase,
    required this.progressPercent,
    required this.createdAt,
  });
}

class SupervisionPdfService {
  static const List<String> _cjkBaseCandidates = [
    'assets/fonts/NotoSansSC-Regular.ttf',
    'assets/fonts/NotoSansSC-VF.ttf',
  ];

  static const List<String> _cjkBoldCandidates = [
    'assets/fonts/NotoSansSC-Bold.ttf',
    'assets/fonts/NotoSansSC-Regular.ttf',
    'assets/fonts/NotoSansSC-VF.ttf',
  ];

  Future<Uint8List> buildNoticePdf({
    required SupervisionBaseInfo baseInfo,
    required List<
            ({
              String category,
              String itemTitle,
              SupervisionItemSelection selection,
            })>
        checkedItems,
  }) async {
    final doc = pw.Document();

    // Always embed a CJK font from assets to avoid garbled squares.
    // NOTE: pdf package needs a real TTF/OTF font file; system fonts are not used.
    final fonts = await _loadRequiredCjkFonts();
    final theme = pw.ThemeData.withFont(base: fonts.base, bold: fonts.bold);

    final hazards = checkedItems
        .where((e) => e.selection.hasHazard == true)
        .toList(growable: false);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: theme,
        margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 40),
        build: (context) {
          return [
            pw.Center(
              child: pw.Text(
                '责令整改通知书',
                style:
                    pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Center(
              child: pw.Text(
                '（日常监督〔${_yyyymmdd(baseInfo.createdAt)}〕001号）',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
            pw.SizedBox(height: 18),
            _kv('工程名称', baseInfo.projectName),
            _kv('施工阶段', baseInfo.phase),
            _kv('形象进度', '${baseInfo.progressPercent}%'),
            pw.SizedBox(height: 14),
            pw.Text(
              '检查情况与问题清单',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            if (hazards.isEmpty)
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey700),
                ),
                child: pw.Text('本次检查未发现隐患问题。'),
              )
            else
              pw.Table(
                border:
                    pw.TableBorder.all(color: PdfColors.grey700, width: 0.8),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(4),
                  2: const pw.FlexColumnWidth(3.2),
                },
                children: [
                  pw.TableRow(
                    decoration:
                        const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      _th('序号'),
                      _th('抽查事项'),
                      _th('问题描述'),
                    ],
                  ),
                  for (var i = 0; i < hazards.length; i++)
                    pw.TableRow(
                      children: [
                        _td('${i + 1}'),
                        _td('${hazards[i].category}\n${hazards[i].itemTitle}'),
                        _td(_hazardText(hazards[i].selection)),
                      ],
                    ),
                ],
              ),
            pw.SizedBox(height: 18),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                          '整改期限：${_yyyymmdd(baseInfo.createdAt.add(const Duration(days: 7)))} 前完成整改。'),
                      pw.SizedBox(height: 6),
                      pw.Text('请将整改结果形成《整改情况报告书》。'),
                    ],
                  ),
                ),
                pw.SizedBox(width: 12),
                _redStamp(),
              ],
            ),
          ];
        },
      ),
    );

    return doc.save();
  }

  Future<pw.Font?> _tryLoadFont(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return pw.Font.ttf(data);
    } catch (_) {
      return null;
    }
  }

  Future<({pw.Font base, pw.Font bold})> _loadRequiredCjkFonts() async {
    pw.Font? base;
    for (final p in _cjkBaseCandidates) {
      base = await _tryLoadFont(p);
      if (base != null) break;
    }

    pw.Font? bold;
    for (final p in _cjkBoldCandidates) {
      bold = await _tryLoadFont(p);
      if (bold != null) break;
    }

    if (base != null && bold != null) {
      return (base: base, bold: bold);
    }

    throw StateError(
      '缺少 PDF 中文字体资源（assets/fonts）。\n'
      '请放入开源 Noto Sans SC 的 TTF 字体文件，至少满足以下任意一种方案：\n'
      '1) assets/fonts/NotoSansSC-Regular.ttf + assets/fonts/NotoSansSC-Bold.ttf\n'
      '2) assets/fonts/NotoSansSC-VF.ttf\n'
      '并确保 pubspec.yaml 已声明 assets/fonts/。',
    );
  }

  pw.Widget _kv(String k, String v) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 86,
            child: pw.Text(
              '$k：',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Expanded(child: pw.Text(v)),
        ],
      ),
    );
  }

  pw.Widget _th(String t) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        t,
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
      ),
    );
  }

  pw.Widget _td(String t) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(t, style: const pw.TextStyle(fontSize: 10)),
    );
  }

  String _hazardText(SupervisionItemSelection s) {
    final parts = <String>[];
    if (s.selectedIndicator != null && s.selectedIndicator!.trim().isNotEmpty) {
      parts.add(s.selectedIndicator!.trim());
    }
    if (s.extraDescription.trim().isNotEmpty) {
      parts.add('补充：${s.extraDescription.trim()}');
    }
    return parts.isEmpty ? '有隐患（未选择问题项）' : parts.join('\n');
  }

  String _yyyymmdd(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  pw.Widget _redStamp() {
    const c = PdfColor.fromInt(0xFFD32F2F);
    // NOTE: pdf/widgets 的 CustomPainter API 与 Flutter 不同，
    // 这里用纯装饰实现红章（圆形边框 + 文本），避免 Canvas 兼容问题。
    // 如果后续需要更复杂的红章（五角星/环形文字），可改为使用 pdf 的绘图 API。
    return pw.Container(
      width: 110,
      height: 110,
      decoration: pw.BoxDecoration(
        shape: pw.BoxShape.circle,
        border: pw.Border.all(color: c, width: 2.2),
      ),
      child: pw.Center(
        child: pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text(
              '★',
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
                color: c,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              '监督检查\n专用章',
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: c,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

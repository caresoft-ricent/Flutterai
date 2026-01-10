import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

class SupervisionPdfPreviewScreen extends StatelessWidget {
  static const routeName = 'supervision-pdf-preview';

  final Uint8List pdfBytes;
  final String title;

  const SupervisionPdfPreviewScreen({
    super.key,
    required this.pdfBytes,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: PdfPreview(
        canChangePageFormat: false,
        canChangeOrientation: false,
        build: (format) async => pdfBytes,
      ),
    );
  }
}

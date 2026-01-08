import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_gemma/core/api/flutter_gemma.dart';

import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AcceptanceApp()));

  // Initialize Gemma in background so cold-start can render the first frame.
  unawaited(_initGemma());
}

Future<void> _initGemma() async {
  try {
    const rawToken =
        String.fromEnvironment('HUGGINGFACE_TOKEN', defaultValue: '');
    final token = rawToken.trim().isEmpty ? null : rawToken.trim();
    await FlutterGemma.initialize(huggingFaceToken: token);
    debugPrint('[Gemma] initialize: ok');
  } catch (e, st) {
    debugPrint('[Gemma] initialize: failed: $e');
    debugPrint('$st');
  }
}

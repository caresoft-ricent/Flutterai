import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;

String _insertBeforeExtension(String path, String suffix) {
  final dot = path.lastIndexOf('.');
  if (dot <= 0) return '$path$suffix';
  return '${path.substring(0, dot)}$suffix${path.substring(dot)}';
}

String assetLocaleSuffix(Locale locale) {
  final lang = locale.languageCode;
  final script = locale.scriptCode;

  // Align with our ARB naming: zh (Simplified), zh_Hant (Traditional).
  if (lang == 'zh' &&
      (script == 'Hant' || locale.toLanguageTag() == 'zh-Hant')) {
    return 'zh_Hant';
  }
  return lang;
}

Future<String> loadStringLocalized(
  String baseAssetPath, {
  required Locale locale,
}) async {
  final suffix = assetLocaleSuffix(locale);

  // Try the most specific suffix first.
  final candidates = <String>{
    _insertBeforeExtension(baseAssetPath, '_$suffix'),
    // Also try only language code for cases like en-US.
    _insertBeforeExtension(baseAssetPath, '_${locale.languageCode}'),
  }..remove(baseAssetPath);

  for (final path in candidates) {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      // Fall back to next candidate.
    }
  }

  // Default fallback.
  return rootBundle.loadString(baseAssetPath);
}

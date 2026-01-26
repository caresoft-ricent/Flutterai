import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocaleService {
  static const prefsKey = 'app_locale_override';

  static const system = 'system';

  static const supported = <Locale>[
    Locale('zh'), // zh-Hans (default)
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('en'),
    Locale('ar'),
  ];

  static String toTag(Locale locale) {
    // Keep tags stable and readable.
    final lang = locale.languageCode;
    final script = locale.scriptCode;
    final country = locale.countryCode;

    if (script != null && script.isNotEmpty) {
      return '$lang-$script';
    }
    if (country != null && country.isNotEmpty) {
      return '$lang-$country';
    }
    return lang;
  }

  static Locale? fromTag(String? tag) {
    final t = (tag ?? '').trim();
    if (t.isEmpty || t == system) return null;

    // Normalize common zh variants.
    final lower = t.toLowerCase();
    if (lower == 'zh' ||
        lower.startsWith('zh-cn') ||
        lower.startsWith('zh-hans')) {
      return const Locale('zh');
    }
    if (lower.startsWith('zh-hant') ||
        lower.startsWith('zh-tw') ||
        lower.startsWith('zh-hk')) {
      return Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    }
    if (lower.startsWith('en')) return const Locale('en');
    if (lower.startsWith('ar')) return const Locale('ar');

    // Best-effort parse (BCP-47 like: en, en-US, zh-Hant).
    final parts = t.split('-').where((p) => p.trim().isNotEmpty).toList();
    if (parts.isEmpty) return null;

    final languageCode = parts[0];
    String? scriptCode;
    String? countryCode;
    if (parts.length >= 2) {
      final p1 = parts[1];
      if (p1.length == 4) {
        scriptCode = p1[0].toUpperCase() + p1.substring(1).toLowerCase();
      } else if (p1.length == 2 || p1.length == 3) {
        countryCode = p1.toUpperCase();
      }
    }
    if (parts.length >= 3 && scriptCode == null) {
      final p2 = parts[2];
      if (p2.length == 4) {
        scriptCode = p2[0].toUpperCase() + p2.substring(1).toLowerCase();
      } else if (p2.length == 2 || p2.length == 3) {
        countryCode = p2.toUpperCase();
      }
    }

    return Locale.fromSubtags(
      languageCode: languageCode,
      scriptCode: scriptCode,
      countryCode: countryCode,
    );
  }

  static Future<Locale?> loadOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tag = prefs.getString(prefsKey);
      return fromTag(tag);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveOverride(Locale? locale) async {
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.setString(prefsKey, system);
      return;
    }
    await prefs.setString(prefsKey, toTag(locale));
  }

  static String acceptLanguageHeader(Locale? locale) {
    // Use quality values to provide a sane fallback chain.
    // For zh: we treat it as zh-Hans.
    if (locale == null) {
      return 'zh-CN,zh;q=0.9,en;q=0.8';
    }

    if (locale.languageCode == 'zh' && locale.scriptCode == 'Hant') {
      return 'zh-Hant,zh-TW;q=0.9,zh;q=0.8,en;q=0.7';
    }
    if (locale.languageCode == 'zh') {
      return 'zh-CN,zh;q=0.9,en;q=0.8';
    }
    if (locale.languageCode == 'ar') {
      return 'ar,ar-SA;q=0.9,en;q=0.8';
    }
    if (locale.languageCode == 'en') {
      return 'en,en-US;q=0.9';
    }
    return '${locale.languageCode},en;q=0.8';
  }
}

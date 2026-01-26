import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/context_l10n.dart';
import '../services/app_locale_controller.dart';
import '../services/locale_service.dart';
import 'backend_settings_screen.dart';

class AppSettingsScreen extends ConsumerWidget {
  static const routeName = 'app-settings';

  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final localeAsync = ref.watch(appLocaleControllerProvider);
    final localeOverride = localeAsync.valueOrNull;

    String currentLabel() {
      if (localeOverride == null) return l10n.languageSystem;
      if (localeOverride.languageCode == 'zh' &&
          localeOverride.scriptCode == 'Hant') {
        return l10n.languageZhHant;
      }
      if (localeOverride.languageCode == 'zh') return l10n.languageZhHans;
      if (localeOverride.languageCode == 'en') return l10n.languageEn;
      if (localeOverride.languageCode == 'ar') return l10n.languageAr;
      return LocaleService.toTag(localeOverride);
    }

    Future<void> pickLanguage() async {
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(l10n.languageSystem),
                  onTap: () => Navigator.of(ctx).pop(LocaleService.system),
                ),
                ListTile(
                  title: Text(l10n.languageZhHans),
                  onTap: () => Navigator.of(ctx).pop('zh'),
                ),
                ListTile(
                  title: Text(l10n.languageZhHant),
                  onTap: () => Navigator.of(ctx).pop('zh-Hant'),
                ),
                ListTile(
                  title: Text(l10n.languageEn),
                  onTap: () => Navigator.of(ctx).pop('en'),
                ),
                ListTile(
                  title: Text(l10n.languageAr),
                  onTap: () => Navigator.of(ctx).pop('ar'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );

      if (picked == null) return;
      final locale = LocaleService.fromTag(picked);
      await ref.read(appLocaleControllerProvider.notifier).setLocale(locale);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        children: [
          ListTile(
            title: Text(l10n.languageTitle),
            subtitle: Text(currentLabel()),
            trailing: const Icon(Icons.chevron_right),
            onTap: pickLanguage,
          ),
          const Divider(height: 0),
          ListTile(
            title: Text(l10n.backendSettingsTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(BackendSettingsScreen.routeName),
          ),
        ],
      ),
    );
  }
}

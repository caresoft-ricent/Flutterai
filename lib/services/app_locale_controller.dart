import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'locale_service.dart';

final appLocaleControllerProvider =
    AsyncNotifierProvider<AppLocaleController, Locale?>(
        AppLocaleController.new);

class AppLocaleController extends AsyncNotifier<Locale?> {
  @override
  Future<Locale?> build() async {
    return LocaleService.loadOverride();
  }

  Future<void> setLocale(Locale? locale) async {
    await LocaleService.saveOverride(locale);
    state = AsyncData(locale);
  }
}

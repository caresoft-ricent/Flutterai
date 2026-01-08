import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final useOnlineAiProvider =
    StateNotifierProvider<UseOnlineAiNotifier, bool>((ref) {
  return UseOnlineAiNotifier();
});

class UseOnlineAiNotifier extends StateNotifier<bool> {
  static const _key = 'use_online_ai';

  UseOnlineAiNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final useOfflineSpeechProvider =
    StateNotifierProvider<UseOfflineSpeechNotifier, bool>((ref) {
  return UseOfflineSpeechNotifier();
});

class UseOfflineSpeechNotifier extends StateNotifier<bool> {
  static const _key = 'use_offline_speech';
  static const _legacyKey = 'use_online_ai';

  UseOfflineSpeechNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    // New key takes precedence.
    final v = prefs.getBool(_key);
    if (v != null) {
      state = v;
      return;
    }

    // Migrate from legacy "use_online_ai" semantics:
    // legacy true  => online
    // new true     => offline
    final legacy = prefs.getBool(_legacyKey);
    if (legacy != null) {
      state = !legacy;
      await prefs.setBool(_key, state);
      return;
    }

    state = false;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final useGemmaMultimodalProvider =
    StateNotifierProvider<UseGemmaMultimodalNotifier, bool>((ref) {
  final notifier = UseGemmaMultimodalNotifier();
  notifier.load();
  return notifier;
});

class UseGemmaMultimodalNotifier extends StateNotifier<bool> {
  static const _key = 'use_gemma_multimodal';

  UseGemmaMultimodalNotifier() : super(false);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

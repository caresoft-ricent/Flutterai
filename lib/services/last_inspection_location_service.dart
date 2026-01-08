import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final lastInspectionLocationProvider =
    StateNotifierProvider<LastInspectionLocationNotifier, String?>((ref) {
  return LastInspectionLocationNotifier();
});

class LastInspectionLocationNotifier extends StateNotifier<String?> {
  static const _key = 'last_inspection_location';

  LastInspectionLocationNotifier() : super(null) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (v == null || v.trim().isEmpty) {
      state = null;
      return;
    }
    state = v.trim();
  }

  Future<void> setLocation(String location) async {
    final v = location.trim();
    if (v.isEmpty) return;
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, v);
  }

  Future<void> clear() async {
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

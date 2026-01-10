import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/supervision_library.dart';

final supervisionLibraryServiceProvider =
    Provider<SupervisionLibraryService>((ref) {
  return SupervisionLibraryService();
});

class SupervisionLibraryService {
  static const String _assetPath =
      'assets/supervision_library/daily_supervision_items.json';

  Future<SupervisionLibraryDefinition>? _loadFuture;
  SupervisionLibraryDefinition? _cached;

  Future<SupervisionLibraryDefinition> load() {
    return _loadFuture ??= _loadFromAssets();
  }

  Future<SupervisionLibraryDefinition> _loadFromAssets() async {
    final raw = await rootBundle.loadString(_assetPath);
    final decoded = json.decode(raw);
    if (decoded is! List) {
      throw StateError('$_assetPath: expected a JSON list');
    }

    final rows = <SupervisionLibraryRow>[];
    for (final it in decoded) {
      if (it is Map) {
        rows.add(SupervisionLibraryRow.fromJson(it.cast<String, dynamic>()));
      }
    }

    final sectionTitle = rows.isEmpty ? '日常监督抽查事项清单' : rows.first.section;

    // Preserve the JSON file order (first-appearance order) for categories/items/indicators.
    // The UI should follow the source file's front-to-back order.
    final grouped = <String, Map<String, List<String>>>{};
    for (final r in rows) {
      final category = r.category;
      final item = r.item;
      if (category.isEmpty || item.isEmpty) continue;
      grouped.putIfAbsent(category, () => <String, List<String>>{});
      grouped[category]!.putIfAbsent(item, () => <String>[]);

      final indicator = r.indicator.trim();
      if (indicator.isEmpty) continue;
      final list = grouped[category]![item]!;
      if (!list.contains(indicator)) {
        list.add(indicator);
      }
    }

    final categories = <SupervisionCategoryDefinition>[];
    for (final entry in grouped.entries) {
      final categoryTitle = entry.key;
      final itemsMap = entry.value;
      final itemDefs = <SupervisionItemDefinition>[];
      for (final it in itemsMap.entries) {
        itemDefs.add(
          SupervisionItemDefinition(
            category: categoryTitle,
            title: it.key,
            indicators: List<String>.from(it.value),
          ),
        );
      }
      categories.add(
        SupervisionCategoryDefinition(title: categoryTitle, items: itemDefs),
      );
    }

    final def = SupervisionLibraryDefinition(
      sectionTitle: sectionTitle,
      categories: categories,
    );

    _cached = def;
    return def;
  }

  SupervisionLibraryDefinition? get cached => _cached;
}

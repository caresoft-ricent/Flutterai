class SupervisionLibraryRow {
  final String section; // 分部
  final String category; // 子分部
  final String item; // 分项
  final String indicator; // 指标

  const SupervisionLibraryRow({
    required this.section,
    required this.category,
    required this.item,
    required this.indicator,
  });

  factory SupervisionLibraryRow.fromJson(Map<String, dynamic> json) {
    return SupervisionLibraryRow(
      section: (json['分部'] ?? '').toString().trim(),
      category: (json['子分部'] ?? '').toString().trim(),
      item: (json['分项'] ?? '').toString().trim(),
      indicator: (json['指标'] ?? '').toString().trim(),
    );
  }
}

class SupervisionItemDefinition {
  final String category;
  final String title; // 分项
  final List<String> indicators;

  const SupervisionItemDefinition({
    required this.category,
    required this.title,
    required this.indicators,
  });
}

class SupervisionCategoryDefinition {
  final String title; // 子分部
  final List<SupervisionItemDefinition> items;

  const SupervisionCategoryDefinition({
    required this.title,
    required this.items,
  });
}

class SupervisionLibraryDefinition {
  final String sectionTitle;
  final List<SupervisionCategoryDefinition> categories;

  const SupervisionLibraryDefinition({
    required this.sectionTitle,
    required this.categories,
  });
}

class SupervisionItemSelection {
  /// null = 未检查；false = 无隐患；true = 有隐患
  final bool? hasHazard;
  final String? selectedIndicator;
  final String extraDescription;
  final DateTime? lastCheckAt;

  const SupervisionItemSelection({
    required this.hasHazard,
    required this.selectedIndicator,
    required this.extraDescription,
    required this.lastCheckAt,
  });

  const SupervisionItemSelection.empty()
      : hasHazard = null,
        selectedIndicator = null,
        extraDescription = '',
        lastCheckAt = null;

  SupervisionItemSelection copyWith({
    bool? hasHazard,
    String? selectedIndicator,
    bool clearIndicator = false,
    String? extraDescription,
    DateTime? lastCheckAt,
  }) {
    return SupervisionItemSelection(
      hasHazard: hasHazard ?? this.hasHazard,
      selectedIndicator:
          clearIndicator ? null : (selectedIndicator ?? this.selectedIndicator),
      extraDescription: extraDescription ?? this.extraDescription,
      lastCheckAt: lastCheckAt ?? this.lastCheckAt,
    );
  }
}

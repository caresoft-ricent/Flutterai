class DemoConstants {
  static const exampleCommands = <String>[
    '我要验收1栋6层的钢筋',
    '发现问题',
    '3栋4层发现钢筋保护层不足',
  ];
}

enum AcceptanceResult {
  qualified,
  unqualified,
  pending,
}

extension AcceptanceResultText on AcceptanceResult {
  String get label {
    switch (this) {
      case AcceptanceResult.qualified:
        return '合格';
      case AcceptanceResult.unqualified:
        return '不合格';
      case AcceptanceResult.pending:
        return '待检测';
    }
  }
}

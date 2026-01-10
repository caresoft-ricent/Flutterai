import 'package:flutter/material.dart';

import '../models/supervision_library.dart';
import 'supervision_category_detail_screen.dart';

class SupervisionChecklistScreen extends StatefulWidget {
  final SupervisionLibraryDefinition library;
  final Map<String, Map<String, SupervisionItemSelection>> selections;

  const SupervisionChecklistScreen({
    super.key,
    required this.library,
    required this.selections,
  });

  @override
  State<SupervisionChecklistScreen> createState() =>
      _SupervisionChecklistScreenState();
}

class _SupervisionChecklistScreenState
    extends State<SupervisionChecklistScreen> {
  late Map<String, Map<String, SupervisionItemSelection>> _selections;

  @override
  void initState() {
    super.initState();
    _selections = _deepCopy(widget.selections);
  }

  Map<String, Map<String, SupervisionItemSelection>> _deepCopy(
      Map<String, Map<String, SupervisionItemSelection>> src) {
    final out = <String, Map<String, SupervisionItemSelection>>{};
    for (final e in src.entries) {
      out[e.key] = Map<String, SupervisionItemSelection>.from(e.value);
    }
    return out;
  }

  int _checkedCount(
      String categoryTitle, List<SupervisionItemDefinition> items) {
    final map = _selections[categoryTitle];
    if (map == null) return 0;
    var c = 0;
    for (final it in items) {
      final sel = map[it.title];
      if (sel != null && sel.hasHazard != null) c++;
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_selections);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('抽查事项清单（二级）'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(_selections);
              },
              child: const Text('完成'),
            ),
          ],
        ),
        body: ListView.separated(
          itemCount: widget.library.categories.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final cat = widget.library.categories[index];
            final checked = _checkedCount(cat.title, cat.items);
            final total = cat.items.length;

            return ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.blue),
              title: Text(cat.title),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$checked/$total'),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right),
                ],
              ),
              subtitle: checked > 0 ? const Text('已登记部分检查结果') : null,
              onTap: () async {
                final current = _selections[cat.title] ??
                    <String, SupervisionItemSelection>{};
                final result = await Navigator.of(context)
                    .push<Map<String, SupervisionItemSelection>>(
                  MaterialPageRoute(
                    builder: (_) => SupervisionCategoryDetailScreen(
                      category: cat,
                      initialSelections: current,
                    ),
                  ),
                );

                if (!mounted) return;
                if (result != null) {
                  setState(() {
                    _selections[cat.title] = result;
                  });
                }
              },
            );
          },
        ),
      ),
    );
  }
}

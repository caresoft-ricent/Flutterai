import 'package:flutter/material.dart';

import '../models/supervision_library.dart';

class SupervisionCategoryDetailScreen extends StatefulWidget {
  final SupervisionCategoryDefinition category;
  final Map<String, SupervisionItemSelection> initialSelections;

  const SupervisionCategoryDetailScreen({
    super.key,
    required this.category,
    required this.initialSelections,
  });

  @override
  State<SupervisionCategoryDetailScreen> createState() =>
      _SupervisionCategoryDetailScreenState();
}

class _SupervisionCategoryDetailScreenState
    extends State<SupervisionCategoryDetailScreen> {
  late Map<String, SupervisionItemSelection> _selections;

  @override
  void initState() {
    super.initState();
    _selections = Map<String, SupervisionItemSelection>.from(
      widget.initialSelections,
    );
  }

  String _fmtDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _pickIndicator(
    String itemTitle,
    List<String> options,
  ) async {
    final current = _selections[itemTitle]?.selectedIndicator;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final filtered = options
                .where((e) => query.isEmpty || e.contains(query))
                .toList(growable: false);

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    const Text(
                      '问题项选择',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '搜索',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => setModalState(() => query = v.trim()),
                      ),
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final opt in filtered)
                            RadioListTile<String>(
                              value: opt,
                              groupValue: current,
                              title: Text(opt),
                              onChanged: (v) => Navigator.of(ctx).pop(v),
                            ),
                          RadioListTile<String>(
                            value: '其他',
                            groupValue: current,
                            title: const Text('其他'),
                            onChanged: (v) => Navigator.of(ctx).pop(v),
                          ),
                          ListTile(
                            title: const Text('取消'),
                            onTap: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (!mounted) return;
    if (selected != null) {
      setState(() {
        final old =
            _selections[itemTitle] ?? const SupervisionItemSelection.empty();
        _selections[itemTitle] = old.copyWith(selectedIndicator: selected);
      });
    }
  }

  void _applyBatch(String op) {
    setState(() {
      if (op == 'all_ok') {
        for (final it in widget.category.items) {
          _selections[it.title] =
              (_selections[it.title] ?? const SupervisionItemSelection.empty())
                  .copyWith(
            hasHazard: false,
            clearIndicator: true,
            extraDescription: '',
            lastCheckAt: DateTime.now(),
          );
        }
      } else if (op == 'all_hazard') {
        for (final it in widget.category.items) {
          _selections[it.title] =
              (_selections[it.title] ?? const SupervisionItemSelection.empty())
                  .copyWith(
            hasHazard: true,
            lastCheckAt: DateTime.now(),
          );
        }
      } else if (op == 'clear') {
        _selections.clear();
      }
    });
  }

  Future<void> _showBatchSheet() async {
    final op = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.done_all),
                title: const Text('全部无隐患'),
                onTap: () => Navigator.of(ctx).pop('all_ok'),
              ),
              ListTile(
                leading: const Icon(Icons.report),
                title: const Text('全部有隐患（不选择问题项）'),
                onTap: () => Navigator.of(ctx).pop('all_hazard'),
              ),
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('清空选择'),
                onTap: () => Navigator.of(ctx).pop('clear'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (op != null) _applyBatch(op);
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
          title: Text(widget.category.title),
          actions: [
            IconButton(
              onPressed: () => Navigator.of(context).pop(_selections),
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: widget.category.items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final def = widget.category.items[index];
            final sel = _selections[def.title] ??
                const SupervisionItemSelection.empty();

            final last = sel.lastCheckAt;
            final lastText = last == null ? '—' : _fmtDate(last);

            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text('上次检查时间：$lastText',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('无隐患')),
                      ButtonSegment(value: true, label: Text('有隐患')),
                    ],
                    selected: sel.hasHazard == null
                        ? <bool>{}
                        : <bool>{sel.hasHazard!},
                    onSelectionChanged: (s) {
                      final v = s.isEmpty ? null : s.first;
                      setState(() {
                        final old = _selections[def.title] ??
                            const SupervisionItemSelection.empty();
                        _selections[def.title] = old.copyWith(
                          hasHazard: v,
                          lastCheckAt: DateTime.now(),
                          clearIndicator: v != true,
                          extraDescription:
                              v == true ? old.extraDescription : '',
                        );
                      });
                    },
                  ),
                  if (sel.hasHazard == true) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => _pickIndicator(def.title, def.indicators),
                      child: Row(
                        children: [
                          const Icon(Icons.list_alt, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sel.selectedIndicator == null ||
                                      sel.selectedIndicator!.isEmpty
                                  ? '选择问题项'
                                  : '问题项：${sel.selectedIndicator}',
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller:
                          TextEditingController(text: sel.extraDescription)
                            ..selection = TextSelection.collapsed(
                                offset: sel.extraDescription.length),
                      decoration: const InputDecoration(
                        labelText: '补充描述',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                      onChanged: (v) {
                        setState(() {
                          final old = _selections[def.title] ??
                              const SupervisionItemSelection.empty();
                          _selections[def.title] =
                              old.copyWith(extraDescription: v);
                        });
                      },
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: _showBatchSheet,
                child: const Text('批量选择'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

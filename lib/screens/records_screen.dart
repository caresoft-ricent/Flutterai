import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/backend_records.dart';
import '../services/backend_api_service.dart';
import '../widgets/photo_preview.dart';
import '../widgets/rectification_actions_sheet.dart';

class RecordsScreen extends ConsumerStatefulWidget {
  static const routeName = 'records';

  final int initialTabIndex;

  const RecordsScreen({
    super.key,
    this.initialTabIndex = 0,
  });

  @override
  ConsumerState<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends ConsumerState<RecordsScreen> {
  int _reloadToken = 0;

  void _reload() {
    setState(() {
      _reloadToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('记录表'),
          actions: [
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '验收'),
              Tab(text: '巡检'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _AcceptanceRecordsList(reloadToken: _reloadToken),
            _IssueReportsList(reloadToken: _reloadToken),
          ],
        ),
      ),
    );
  }
}

class _AcceptanceRecordsList extends ConsumerStatefulWidget {
  final int reloadToken;

  const _AcceptanceRecordsList({
    required this.reloadToken,
  });

  @override
  ConsumerState<_AcceptanceRecordsList> createState() =>
      _AcceptanceRecordsListState();
}

class _AcceptanceRecordsListState
    extends ConsumerState<_AcceptanceRecordsList> {
  late Future<List<BackendAcceptanceRecord>> _future;

  Future<List<BackendAcceptanceRecord>> _fetch() async {
    final api = ref.read(backendApiServiceProvider);
    return api.listAcceptanceRecords();
  }

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(covariant _AcceptanceRecordsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _future = _fetch();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        _future = _fetch();
        if (mounted) setState(() {});
        await _future;
      },
      child: FutureBuilder<List<BackendAcceptanceRecord>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 60),
                Center(child: Text('加载失败：${snap.error}')),
              ],
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 60),
                Center(child: Text('暂无验收记录')),
              ],
            );
          }

          final groups = AcceptanceRecordGroup.groupBySubitem(items);

          return ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: groups.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final g = groups[i];
              final c = g.counts;
              final title = [
                g.regionText,
                if ((g.item ?? '').trim().isNotEmpty) g.item!.trim(),
                if ((g.subdivision ?? '').trim().isNotEmpty)
                  g.subdivision!.trim(),
              ].where((e) => e.trim().isNotEmpty).join('｜');

              final subtitle = [
                '结果：${g.overallResultZh}',
                '指标：合格${c.qualified}/不合格${c.unqualified}/甩项${c.pending}',
                '时间：${g.latestAt}',
              ].join('  ');

              return ListTile(
                title: Text(
                  title.isEmpty ? '（未命名验收记录）' : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  context.push(
                    '/records/acceptance/${g.representativeId}',
                    extra: g,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _IssueReportsList extends ConsumerStatefulWidget {
  final int reloadToken;

  const _IssueReportsList({
    required this.reloadToken,
  });

  @override
  ConsumerState<_IssueReportsList> createState() => _IssueReportsListState();
}

class _IssueReportsListState extends ConsumerState<_IssueReportsList> {
  late Future<List<BackendIssueReport>> _future;

  Future<List<BackendIssueReport>> _fetch() async {
    final api = ref.read(backendApiServiceProvider);
    return api.listIssueReports();
  }

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(covariant _IssueReportsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _future = _fetch();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        _future = _fetch();
        if (mounted) setState(() {});
        await _future;
      },
      child: FutureBuilder<List<BackendIssueReport>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 60),
                Center(child: Text('加载失败：${snap.error}')),
              ],
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 60),
                Center(child: Text('暂无巡检问题')),
              ],
            );
          }

          return ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = items[i];
              final title = [
                r.regionText,
                if ((r.item ?? '').trim().isNotEmpty) r.item!.trim(),
                if ((r.indicator ?? '').trim().isNotEmpty) r.indicator!.trim(),
              ].where((e) => e.trim().isNotEmpty).join('｜');

              final subtitle = [
                r.description,
                if ((r.severity ?? '').trim().isNotEmpty) '严重性：${r.severity}',
                '时间：${r.clientCreatedAt ?? r.createdAt}',
              ].join('  ');

              return ListTile(
                title: Text(
                  title.isEmpty ? '（未命名巡检记录）' : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  context.push(
                    '/records/issue/${r.id}',
                    extra: r,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class AcceptanceRecordDetailScreen extends StatelessWidget {
  static const routeName = 'acceptance-record-detail';

  final AcceptanceRecordGroup group;

  const AcceptanceRecordDetailScreen({
    super.key,
    required this.group,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('验收记录详情')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _kv('位置', group.regionText),
            _kv('分部', group.division ?? ''),
            _kv('分项', group.subdivision ?? ''),
            _kv('工序', group.item ?? ''),
            _kv('综合结果', group.overallResultZh),
            _kv('时间', group.latestAt.toString()),
            const SizedBox(height: 12),
            Text(
              '指标明细',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...group.records.map(
              (r) => Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              (r.indicator ?? '').trim().isEmpty
                                  ? '（未命名指标）'
                                  : r.indicator!.trim(),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          Text(
                            r.resultZh,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color:
                                  r.result.trim().toLowerCase() == 'unqualified'
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      if (r.result.trim().toLowerCase() == 'unqualified') ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  await RectificationActionsSheet.open(
                                    context,
                                    title: '整改闭环（验收记录 #${r.id}）',
                                    targetType: 'acceptance',
                                    targetId: r.id,
                                    showVerify: true,
                                  );
                                },
                                icon: const Icon(Icons.fact_check),
                                label: const Text('整改/复验'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      if ((r.remark ?? '').trim().isNotEmpty)
                        Text('备注：${r.remark!.trim()}'),
                      const SizedBox(height: 6),
                      Text(
                        '时间：${(r.clientCreatedAt ?? r.createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if ((r.clientRecordId ?? '').trim().isNotEmpty)
                        Text(
                          '幂等ID：${r.clientRecordId}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if ((r.photoPath ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        AspectRatio(
                          aspectRatio: 4 / 3,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: PhotoPreview(path: r.photoPath!.trim()),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    final value = v.trim().isEmpty ? '—' : v.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              k,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class IssueReportDetailScreen extends ConsumerStatefulWidget {
  static const routeName = 'issue-report-detail';

  final BackendIssueReport report;

  const IssueReportDetailScreen({
    super.key,
    required this.report,
  });

  @override
  ConsumerState<IssueReportDetailScreen> createState() =>
      _IssueReportDetailScreenState();
}

class _IssueReportDetailScreenState
    extends ConsumerState<IssueReportDetailScreen> {
  late BackendIssueReport _report;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _report = widget.report;
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
    });
    final api = ref.read(backendApiServiceProvider);
    try {
      final latest = await api.getIssueReport(_report.id);
      if (!mounted) return;
      if (latest != null) {
        setState(() {
          _report = latest;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
        });
      }
    }
  }

  Future<void> _openRectification() async {
    await RectificationActionsSheet.open(
      context,
      title: '整改闭环（巡检问题 #${_report.id}）',
      targetType: 'issue',
      targetId: _report.id,
      showClose: _report.status.trim().toLowerCase() != 'closed',
    );
    if (!mounted) return;
    await _refresh();
  }

  Widget _kv(String k, String v) {
    final value = v.trim().isEmpty ? '—' : v.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              k,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('巡检记录详情'),
        actions: [
          IconButton(
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _kv('ID', _report.id.toString()),
            _kv('位置', _report.regionText),
            _kv('栋', _report.buildingNo ?? ''),
            _kv('层', _report.floorNo?.toString() ?? ''),
            _kv('区', _report.zone ?? ''),
            _kv('分部', _report.division ?? ''),
            _kv('分项', _report.subdivision ?? ''),
            _kv('问题库ID', _report.libraryId ?? ''),
            _kv('工序', _report.item ?? ''),
            _kv('指标', _report.indicator ?? ''),
            _kv('描述', _report.description),
            _kv('严重性', _report.severity ?? ''),
            _kv('整改期限(天)', _report.deadlineDays?.toString() ?? ''),
            _kv('责任单位', _report.responsibleUnit ?? ''),
            _kv('责任人', _report.responsiblePerson ?? ''),
            _kv('状态', _report.status),
            _kv(
              '时间',
              (_report.clientCreatedAt ?? _report.createdAt).toString(),
            ),
            _kv('幂等ID', _report.clientRecordId ?? ''),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openRectification,
              icon: const Icon(Icons.fact_check),
              label: Text(
                _report.status.trim().toLowerCase() == 'closed'
                    ? '查看整改闭环'
                    : '整改闭环（提交整改/复验关闭）',
              ),
            ),
            const SizedBox(height: 12),
            if ((_report.photoPath ?? '').trim().isNotEmpty) ...[
              Text(
                '照片预览',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 4 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: PhotoPreview(path: _report.photoPath!.trim()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

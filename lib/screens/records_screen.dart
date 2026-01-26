import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/context_l10n.dart';
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
    final l10n = context.l10n;
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.navRecords),
          actions: [
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: l10n.tooltipRefresh,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: l10n.tabAcceptance),
              Tab(text: l10n.tabInspection),
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

  String _acceptanceResultLabel(BuildContext context, String raw) {
    final l10n = context.l10n;
    switch (raw.trim().toLowerCase()) {
      case 'qualified':
        return l10n.acceptanceResultQualified;
      case 'unqualified':
        return l10n.acceptanceResultUnqualified;
      case 'pending':
        return l10n.acceptanceResultPending;
      default:
        return raw.trim().isEmpty ? '—' : raw.trim();
    }
  }

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
                Center(
                    child:
                        Text(context.l10n.commonLoadFailed('${snap.error}'))),
              ],
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 60),
                Center(child: Text(context.l10n.recordsEmptyAcceptance)),
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
                context.l10n.recordsSubtitleResult(
                  _acceptanceResultLabel(context, g.overallResultRaw),
                ),
                context.l10n.recordsSubtitleAcceptanceIndicators(
                  c.qualified,
                  c.unqualified,
                  c.pending,
                ),
                context.l10n.recordsSubtitleTime('${g.latestAt}'),
              ].join('  ');

              return ListTile(
                title: Text(
                  title.isEmpty ? context.l10n.recordsUnnamedAcceptance : title,
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

  String _issueSeverityLabel(BuildContext context, String raw) {
    final l10n = context.l10n;
    final v = raw.trim();
    if (v.isEmpty) return '—';
    final lower = v.toLowerCase();
    if (lower == 'severe' || v.contains('严重')) return l10n.issueSeveritySevere;
    if (lower == 'normal' || lower == 'general' || v.contains('一般')) {
      return l10n.issueSeverityNormal;
    }
    return v;
  }

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
                Center(
                    child:
                        Text(context.l10n.commonLoadFailed('${snap.error}'))),
              ],
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 60),
                Center(child: Text(context.l10n.recordsEmptyIssue)),
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
                if ((r.severity ?? '').trim().isNotEmpty)
                  context.l10n.recordsSubtitleSeverity(
                    _issueSeverityLabel(context, r.severity ?? ''),
                  ),
                context.l10n.recordsSubtitleTime(
                  '${r.clientCreatedAt ?? r.createdAt}',
                ),
              ].join('  ');

              return ListTile(
                title: Text(
                  title.isEmpty ? context.l10n.recordsUnnamedIssue : title,
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
    final l10n = context.l10n;

    String acceptanceResultLabel(String raw) {
      switch (raw.trim().toLowerCase()) {
        case 'qualified':
          return l10n.acceptanceResultQualified;
        case 'unqualified':
          return l10n.acceptanceResultUnqualified;
        case 'pending':
          return l10n.acceptanceResultPending;
        default:
          return raw.trim().isEmpty ? '—' : raw.trim();
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.acceptanceRecordDetailTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _kv(context, l10n.commonLocation, group.regionText),
            _kv(context, l10n.commonDivision, group.division ?? ''),
            _kv(context, l10n.commonItem, group.subdivision ?? ''),
            _kv(context, l10n.recordsFieldProcedure, group.item ?? ''),
            _kv(
              context,
              l10n.recordsFieldOverallResult,
              acceptanceResultLabel(group.overallResultRaw),
            ),
            _kv(context, l10n.recordsFieldTime, group.latestAt.toString()),
            const SizedBox(height: 12),
            Text(
              l10n.recordsSectionIndicators,
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
                                  ? l10n.recordsUnnamedIndicator
                                  : r.indicator!.trim(),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          Text(
                            acceptanceResultLabel(r.result),
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
                                    title: l10n
                                        .recordsRectificationTitleAcceptance(
                                            r.id),
                                    targetType: 'acceptance',
                                    targetId: r.id,
                                    showVerify: true,
                                  );
                                },
                                icon: const Icon(Icons.fact_check),
                                label:
                                    Text(l10n.recordsRectificationActionVerify),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      if ((r.remark ?? '').trim().isNotEmpty)
                        Text(l10n.recordsRemark(r.remark!.trim())),
                      const SizedBox(height: 6),
                      Text(
                        l10n.recordsSubtitleTime(
                            '${(r.clientCreatedAt ?? r.createdAt)}'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if ((r.clientRecordId ?? '').trim().isNotEmpty)
                        Text(
                          l10n.recordsClientRecordId(r.clientRecordId!),
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

  Widget _kv(BuildContext context, String k, String v) {
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
    final l10n = context.l10n;
    await RectificationActionsSheet.open(
      context,
      title: l10n.recordsRectificationTitleIssue(_report.id),
      targetType: 'issue',
      targetId: _report.id,
      showClose: _report.status.trim().toLowerCase() != 'closed',
    );
    if (!mounted) return;
    await _refresh();
  }

  String _issueStatusLabel(BuildContext context, String raw) {
    final l10n = context.l10n;
    switch (raw.trim().toLowerCase()) {
      case 'open':
        return l10n.issueStatusOpen;
      case 'closed':
        return l10n.issueStatusClosed;
      default:
        return raw.trim().isEmpty ? '—' : raw.trim();
    }
  }

  String _issueSeverityLabel(BuildContext context, String raw) {
    final l10n = context.l10n;
    final v = raw.trim();
    if (v.isEmpty) return '—';
    final lower = v.toLowerCase();
    if (lower == 'severe' || v.contains('严重')) return l10n.issueSeveritySevere;
    if (lower == 'normal' || lower == 'general' || v.contains('一般')) {
      return l10n.issueSeverityNormal;
    }
    return v;
  }

  String _responsibleUnitLabel(BuildContext context, String raw) {
    final l10n = context.l10n;
    final v = raw.trim();
    if (v.isEmpty) return '—';
    if (v == '项目部') return l10n.dailyInspectionUnitProjectDept;
    if (v == '安徽施工') return l10n.dailyInspectionUnitAnhuiConstruction;
    return v;
  }

  String _responsibleOwnerLabel(BuildContext context, String raw) {
    final l10n = context.l10n;
    final v = raw.trim();
    if (v.isEmpty) return '—';
    if (v == '木易') return l10n.dailyInspectionOwnerMuYi;
    if (v == '冯施工') return l10n.dailyInspectionOwnerFengConstruction;
    return v;
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
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.issueRecordDetailTitle),
        actions: [
          IconButton(
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.tooltipRefresh,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _kv(l10n.recordsFieldId, _report.id.toString()),
            _kv(l10n.commonLocation, _report.regionText),
            _kv(l10n.recordsFieldBuilding, _report.buildingNo ?? ''),
            _kv(l10n.recordsFieldFloor, _report.floorNo?.toString() ?? ''),
            _kv(l10n.recordsFieldZone, _report.zone ?? ''),
            _kv(l10n.commonDivision, _report.division ?? ''),
            _kv(l10n.commonItem, _report.subdivision ?? ''),
            _kv(l10n.recordsFieldLibraryId, _report.libraryId ?? ''),
            _kv(l10n.recordsFieldProcedure, _report.item ?? ''),
            _kv(l10n.commonIndicator, _report.indicator ?? ''),
            _kv(l10n.recordsFieldDescription, _report.description),
            _kv(
              l10n.recordsFieldSeverity,
              _issueSeverityLabel(context, _report.severity ?? ''),
            ),
            _kv(
              l10n.recordsFieldDeadlineDays,
              _report.deadlineDays?.toString() ?? '',
            ),
            _kv(
              l10n.recordsFieldResponsibleUnit,
              _responsibleUnitLabel(context, _report.responsibleUnit ?? ''),
            ),
            _kv(
              l10n.recordsFieldResponsiblePerson,
              _responsibleOwnerLabel(
                context,
                _report.responsiblePerson ?? '',
              ),
            ),
            _kv(
              l10n.recordsFieldStatus,
              _issueStatusLabel(context, _report.status),
            ),
            _kv(
              l10n.recordsFieldTime,
              (_report.clientCreatedAt ?? _report.createdAt).toString(),
            ),
            _kv(l10n.recordsFieldClientRecordId, _report.clientRecordId ?? ''),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openRectification,
              icon: const Icon(Icons.fact_check),
              label: Text(
                _report.status.trim().toLowerCase() == 'closed'
                    ? l10n.recordsRectificationActionView
                    : l10n.recordsRectificationActionSubmitAndClose,
              ),
            ),
            const SizedBox(height: 12),
            if ((_report.photoPath ?? '').trim().isNotEmpty) ...[
              Text(
                l10n.recordsSectionPhotoPreview,
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

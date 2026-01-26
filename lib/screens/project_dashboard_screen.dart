import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/context_l10n.dart';
import '../services/backend_api_service.dart';
import 'ai_chat_screen.dart';

class ProjectDashboardScreen extends ConsumerStatefulWidget {
  static const routeName = 'project-dashboard';

  const ProjectDashboardScreen({super.key});

  @override
  ConsumerState<ProjectDashboardScreen> createState() =>
      _ProjectDashboardScreenState();
}

class _ProjectDashboardScreenState
    extends ConsumerState<ProjectDashboardScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<Map<String, dynamic>> _fetch() async {
    final api = ref.read(backendApiServiceProvider);
    final results = await Future.wait([
      api.getDashboardSummary(limit: 10),
      api.getDashboardFocus(timeRangeDays: 14),
    ]);
    return {
      'summary': results[0],
      'focus': results[1],
    };
  }

  Future<void> _reload() async {
    setState(() {
      _future = _fetch();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardTitle),
        leading: IconButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.commonBack,
        ),
        actions: [
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.tooltipRefresh,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.pushNamed(AiChatScreen.routeName),
        icon: const Icon(Icons.chat_bubble_outline),
        label: Text(l10n.aiChatTitle),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: FutureBuilder<Map<String, dynamic>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(l10n.commonLoadFailed('${snap.error}')),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.commonRetry),
                    ),
                  ],
                );
              }

              final root = snap.data ?? const {};

              Map<String, dynamic> asMap(dynamic v) {
                if (v is Map<String, dynamic>) return v;
                if (v is Map) {
                  return v.map((k, vv) => MapEntry(k.toString(), vv));
                }
                return const {};
              }

              List<dynamic> asList(dynamic v) => v is List ? v : const [];

              int asInt(dynamic v) {
                if (v is int) return v;
                if (v is num) return v.toInt();
                return int.tryParse(v?.toString() ?? '') ?? 0;
              }

              final summary = asMap(root['summary']);
              final focus = asMap(root['focus']);

              // --- Summary (original overview) ---
              final aTotal = asInt(summary['acceptance_total']);
              final aOk = asInt(summary['acceptance_qualified']);
              final aBadAll = asInt(summary['acceptance_unqualified']);
              final aPendingAll = asInt(summary['acceptance_pending']);

              final iTotal = asInt(summary['issues_total']);
              final iOpenAll = asInt(summary['issues_open']);
              final iClosed = asInt(summary['issues_closed']);

              final topUnits = asList(summary['top_responsible_units']);

              // --- Focus Pack ---
              final meta = asMap(focus['meta']);
              final window = asMap(meta['window']);
              final metrics = asMap(focus['metrics']);
              final closure = asMap(focus['closure']);
              final dq = asMap(focus['data_quality']);

              final days = asInt(window['time_range_days']);
              final start = (window['start']?.toString() ?? '').trim();
              final end = (window['end']?.toString() ?? '').trim();

              final aBad = asInt(metrics['acceptance_unqualified_items']);
              final aPending = asInt(metrics['acceptance_pending_items']);
              final iOpen = asInt(metrics['issues_open']);
              final iSevere = asInt(metrics['issues_open_severe']);
              final iOverdue = asInt(metrics['issues_open_overdue']);

              final topFocus = asList(focus['top_focus']);
              final byBuilding = asList(focus['by_building']);

              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    l10n.dashboardSectionQualityOverview,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: l10n.dashboardKpiAcceptanceItems,
                          value: aTotal.toString(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: l10n.dashboardKpiInspectionIssues,
                          value: iTotal.toString(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: l10n.dashboardKpiAcceptanceUnqualified,
                          value: aBadAll.toString(),
                          tone: _Tone.danger,
                          subtitle:
                              l10n.dashboardSubtitleAcceptanceQualifiedPending(
                            aOk,
                            aPendingAll,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: l10n.dashboardKpiInspectionOpen,
                          value: iOpenAll.toString(),
                          subtitle:
                              l10n.dashboardSubtitleInspectionClosed(iClosed),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.dashboardSectionTopResponsibleUnits,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (topUnits.isEmpty)
                    Text(l10n.dashboardNoData)
                  else
                    ...topUnits.take(6).map((e) {
                      final m = asMap(e);
                      final name =
                          (m['responsible_unit']?.toString() ?? '').trim();
                      final cnt = asInt(m['count']);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.apartment),
                        title:
                            Text(name.isEmpty ? l10n.dashboardUnfilled : name),
                        trailing: Text(l10n.dashboardCountRows(cnt)),
                      );
                    }),
                  const SizedBox(height: 18),
                  const Divider(height: 1),
                  const SizedBox(height: 18),
                  Text(
                    l10n.dashboardSectionFocusPack,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    days > 0 && start.isNotEmpty && end.isNotEmpty
                        ? l10n.dashboardTimeWindow(days, start, end)
                        : l10n.dashboardTimeWindowDefault,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: l10n.dashboardKpiAcceptanceUnqualifiedItems,
                          value: aBad.toString(),
                          tone: _Tone.danger,
                          subtitle:
                              l10n.dashboardSubtitleAcceptancePending(aPending),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: l10n.dashboardKpiInspectionOpen,
                          value: iOpen.toString(),
                          subtitle:
                              l10n.dashboardSubtitleInspectionSevereOverdue(
                            iSevere,
                            iOverdue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.dashboardSectionTopFocus,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (topFocus.isEmpty)
                    Text(l10n.dashboardTopFocusNoEnoughData)
                  else
                    ...topFocus.take(5).map((e) {
                      final m = asMap(e);
                      final title = (m['title']?.toString() ?? '').trim();
                      final building = (m['building']?.toString() ?? '').trim();
                      final score = asInt(m['risk_score']);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.flag_outlined),
                        title: Text(title.isEmpty
                            ? (building.isEmpty
                                ? l10n.dashboardTopFocusDefaultTitle
                                : building)
                            : title),
                        subtitle: building.isEmpty
                            ? null
                            : Text(l10n.dashboardScope(building)),
                        trailing: Text(l10n.dashboardRiskScore(score)),
                      );
                    }),
                  const SizedBox(height: 12),
                  Text(
                    l10n.dashboardSectionClosureEfficiency,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.timelapse),
                    title: Text(l10n.dashboardIssueCloseDurationTitle),
                    subtitle: Text(
                      l10n.dashboardDurationStats(
                        '${closure['issue_close_days_avg'] ?? '-'}',
                        '${closure['issue_close_days_median'] ?? '-'}',
                        asInt(closure['issue_close_count']),
                      ),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.verified_outlined),
                    title: Text(l10n.dashboardAcceptanceVerifyDurationTitle),
                    subtitle: Text(
                      l10n.dashboardDurationStats(
                        '${closure['acceptance_verify_days_avg'] ?? '-'}',
                        '${closure['acceptance_verify_days_median'] ?? '-'}',
                        asInt(closure['acceptance_verify_count']),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.dashboardSectionDataQuality,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.data_object),
                    title: Text(l10n.dashboardMissingBuildingTitle),
                    subtitle: Text(
                      l10n.dashboardMissingBuildingStats(
                        asInt(dq['acceptance_missing_building']),
                        asInt(dq['issues_missing_building']),
                      ),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: Text(l10n.dashboardMissingClosureActionsTitle),
                    subtitle: Text(
                      l10n.dashboardMissingClosureActionsStats(
                        asInt(dq['issues_closed_missing_close_action']),
                        asInt(dq['acceptance_missing_verify_action']),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.dashboardSectionBuildingRisk,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (byBuilding.isEmpty)
                    Text(l10n.dashboardNoBuildingData)
                  else
                    ...byBuilding.take(8).map((e) {
                      final m = asMap(e);
                      final b = (m['building']?.toString() ?? '').trim();
                      final score = asInt(m['risk_score']);
                      final open = asInt(m['issues_open']);
                      final unq = asInt(m['acceptance_unqualified_items']);
                      final overdue = asInt(m['issues_open_overdue']);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.apartment),
                        title: Text(b.isEmpty ? l10n.dashboardUnparsed : b),
                        subtitle: Text(
                          l10n.dashboardBuildingRiskSubtitle(
                              open, unq, overdue),
                        ),
                        trailing: Text(l10n.dashboardRiskScore(score)),
                      );
                    }),
                  const SizedBox(height: 60),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _kpiCard(
    BuildContext context, {
    required String title,
    required String value,
    String? subtitle,
    _Tone tone = _Tone.neutral,
  }) {
    final cs = Theme.of(context).colorScheme;
    final bg = cs.surfaceContainerHighest;
    final fg = tone == _Tone.danger ? cs.error : cs.primary;

    return Card(
      elevation: 0,
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(color: fg, fontWeight: FontWeight.w800),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

enum _Tone {
  neutral,
  danger,
}

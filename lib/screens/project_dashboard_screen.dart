import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('项目驾驶舱'),
        leading: IconButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        actions: [
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.pushNamed(AiChatScreen.routeName),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('AI问答'),
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
                    Text('加载失败：${snap.error}'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
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
                    '质量概览',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: '验收分项',
                          value: aTotal.toString(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: '巡检问题',
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
                          title: '验收不合格',
                          value: aBadAll.toString(),
                          tone: _Tone.danger,
                          subtitle: '合格$aOk / 甩项$aPendingAll',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: '巡检未闭环',
                          value: iOpenAll.toString(),
                          subtitle: '已闭环$iClosed',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '未闭环责任单位 Top',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (topUnits.isEmpty)
                    const Text('暂无数据')
                  else
                    ...topUnits.take(6).map((e) {
                      final m = asMap(e);
                      final name =
                          (m['responsible_unit']?.toString() ?? '未填写').trim();
                      final cnt = asInt(m['count']);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.apartment),
                        title: Text(name.isEmpty ? '未填写' : name),
                        trailing: Text('$cnt 条'),
                      );
                    }),
                  const SizedBox(height: 18),
                  const Divider(height: 1),
                  const SizedBox(height: 18),
                  Text(
                    '近期关注（Focus Pack）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    days > 0 && start.isNotEmpty && end.isNotEmpty
                        ? '时间窗：近$days天（$start ~ $end）'
                        : '时间窗：近14天',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: '验收不合格分项',
                          value: aBad.toString(),
                          tone: _Tone.danger,
                          subtitle: '甩项$aPending',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _kpiCard(
                          context,
                          title: '巡检未闭环',
                          value: iOpen.toString(),
                          subtitle: '严重$iSevere / 逾期$iOverdue',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Top关注点',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (topFocus.isEmpty)
                    const Text('暂无足够数据生成关注点')
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
                            ? (building.isEmpty ? '关注点' : building)
                            : title),
                        subtitle:
                            building.isEmpty ? null : Text('范围：$building'),
                        trailing: Text('风险$score'),
                      );
                    }),
                  const SizedBox(height: 12),
                  Text(
                    '闭环效率',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.timelapse),
                    title: const Text('巡检关闭时长'),
                    subtitle: Text(
                      '均值 ${closure['issue_close_days_avg'] ?? '-'} 天 / 中位数 ${closure['issue_close_days_median'] ?? '-'} 天（${asInt(closure['issue_close_count'])} 次）',
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.verified_outlined),
                    title: const Text('验收复验时长'),
                    subtitle: Text(
                      '均值 ${closure['acceptance_verify_days_avg'] ?? '-'} 天 / 中位数 ${closure['acceptance_verify_days_median'] ?? '-'} 天（${asInt(closure['acceptance_verify_count'])} 次）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '数据质量',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.data_object),
                    title: const Text('未解析部位（building）'),
                    subtitle: Text(
                      '验收 ${asInt(dq['acceptance_missing_building'])} 条 / 巡检 ${asInt(dq['issues_missing_building'])} 条',
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: const Text('闭环动作缺失'),
                    subtitle: Text(
                      '已关闭巡检但无 close 动作 ${asInt(dq['issues_closed_missing_close_action'])} 条；验收缺 verify 动作 ${asInt(dq['acceptance_missing_verify_action'])} 条',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '楼栋风险分布',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (byBuilding.isEmpty)
                    const Text('暂无楼栋数据')
                  else
                    ...byBuilding.take(8).map((e) {
                      final m = asMap(e);
                      final b = (m['building']?.toString() ?? '未解析').trim();
                      final score = asInt(m['risk_score']);
                      final open = asInt(m['issues_open']);
                      final unq = asInt(m['acceptance_unqualified_items']);
                      final overdue = asInt(m['issues_open_overdue']);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.apartment),
                        title: Text(b.isEmpty ? '未解析' : b),
                        subtitle: Text(
                            'open $open / unqItems $unq / overdue $overdue'),
                        trailing: Text('风险$score'),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';

import 'l10n/context_l10n.dart';
import 'screens/home_screen.dart';
import 'screens/acceptance_guide_screen.dart';
import 'screens/issue_report_screen.dart';
import 'screens/supervision_check_screen.dart';
import 'screens/panorama_inspection_screen.dart';
import 'screens/backend_settings_screen.dart';
import 'screens/app_settings_screen.dart';
import 'screens/records_screen.dart';
import 'screens/project_dashboard_screen.dart';
import 'screens/ai_chat_screen.dart';
import 'models/region.dart';
import 'models/library.dart';
import 'models/backend_records.dart';
import 'services/app_locale_controller.dart';

final _routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: HomeScreen.routeName,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/acceptance',
        name: AcceptanceGuideScreen.routeName,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          final region = extra?['region'] as Region?;
          final library = extra?['library'] as LibraryItem?;
          return AcceptanceGuideScreen(
            region: region,
            library: library,
          );
        },
      ),
      GoRoute(
        path: '/issue-report',
        name: IssueReportScreen.routeName,
        builder: (context, state) => const IssueReportScreen(),
      ),
      GoRoute(
        path: '/daily-inspection',
        name: 'daily-inspection',
        builder: (context, state) => const IssueReportScreen(),
      ),
      GoRoute(
        path: '/supervision-check',
        name: SupervisionCheckScreen.routeName,
        builder: (context, state) => const SupervisionCheckScreen(),
      ),
      GoRoute(
        path: '/panorama-inspection',
        name: PanoramaInspectionScreen.routeName,
        builder: (context, state) => const PanoramaInspectionScreen(),
      ),
      GoRoute(
        path: '/settings/backend',
        name: BackendSettingsScreen.routeName,
        builder: (context, state) => const BackendSettingsScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: AppSettingsScreen.routeName,
        builder: (context, state) => const AppSettingsScreen(),
      ),
      GoRoute(
        path: '/records',
        name: RecordsScreen.routeName,
        builder: (context, state) {
          final tab = state.uri.queryParameters['tab']?.trim().toLowerCase();
          final initialIndex = tab == 'issue' ? 1 : 0;
          return RecordsScreen(initialTabIndex: initialIndex);
        },
      ),
      GoRoute(
        path: '/records/acceptance/:id',
        name: AcceptanceRecordDetailScreen.routeName,
        builder: (context, state) {
          final extra = state.extra;
          if (extra is AcceptanceRecordGroup) {
            return AcceptanceRecordDetailScreen(group: extra);
          }
          if (extra is BackendAcceptanceRecord) {
            return AcceptanceRecordDetailScreen(
              group: AcceptanceRecordGroup.single(extra),
            );
          }
          throw StateError('Missing acceptance record extra');
        },
      ),
      GoRoute(
        path: '/records/issue/:id',
        name: IssueReportDetailScreen.routeName,
        builder: (context, state) {
          final r = state.extra as BackendIssueReport;
          return IssueReportDetailScreen(report: r);
        },
      ),
      GoRoute(
        path: '/dashboard',
        name: ProjectDashboardScreen.routeName,
        builder: (context, state) => const ProjectDashboardScreen(),
      ),
      GoRoute(
        path: '/ai-chat',
        name: AiChatScreen.routeName,
        builder: (context, state) => const AiChatScreen(),
      ),
    ],
  );
});

class AcceptanceApp extends ConsumerWidget {
  const AcceptanceApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    final localeOverride = ref.watch(appLocaleControllerProvider).valueOrNull;

    return MaterialApp.router(
      onGenerateTitle: (ctx) => ctx.l10n.appTitle,
      themeMode: ThemeMode.system,
      locale: localeOverride,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeResolutionCallback: (deviceLocale, supportedLocales) {
        // If user explicitly picked a locale, always use it.
        if (localeOverride != null) return localeOverride;
        // Default: follow system locale with best-effort match.
        if (deviceLocale == null) return supportedLocales.first;

        // Normalize zh variants (especially for script=Hant).
        final lang = deviceLocale.languageCode;
        final script = deviceLocale.scriptCode;
        if (lang == 'zh') {
          if (script == 'Hant') {
            return const Locale.fromSubtags(
                languageCode: 'zh', scriptCode: 'Hant');
          }
          return const Locale('zh');
        }
        if (lang == 'ar') return const Locale('ar');
        if (lang == 'en') return const Locale('en');

        return supportedLocales.firstWhere(
          (l) => l.languageCode == deviceLocale.languageCode,
          orElse: () => supportedLocales.first,
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
      ),
      routerConfig: router,
    );
  }
}

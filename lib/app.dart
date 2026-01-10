import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/home_screen.dart';
import 'screens/acceptance_guide_screen.dart';
import 'screens/issue_report_screen.dart';
import 'screens/supervision_check_screen.dart';
import 'models/region.dart';
import 'models/library.dart';

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
    ],
  );
});

class AcceptanceApp extends ConsumerWidget {
  const AcceptanceApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);

    return MaterialApp.router(
      title: '河狸云工序验收(离线 Demo)',
      themeMode: ThemeMode.system,
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

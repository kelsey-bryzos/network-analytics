import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'design/theme.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/auth/accept_invite_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/dashboards/dashboards_list_screen.dart';
import 'features/reports/reports_list_screen.dart';
import 'features/reports/report_viewer_screen.dart';
import 'features/reports/custom_builder/custom_report_builder_screen.dart';
import 'features/library/library_screen.dart';
import 'features/explore/explore_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/help/help_screen.dart';

/// Stream the current Supabase auth state so go_router can redirect.
final authStateProvider = StreamProvider<AuthState>((ref) {
  return Supabase.instance.client.auth.onAuthStateChange;
});

final routerProvider = Provider<GoRouter>((ref) {
  // IMPORTANT: do NOT `ref.watch(authStateProvider)` here. Doing so rebuilds
  // GoRouter on every auth event (including token refreshes), which resets
  // the router to `initialLocation: '/dashboards'` and yanks the user away
  // from whatever page they were on (e.g. /settings). The `refreshListenable`
  // below already handles re-evaluating redirects on auth events without
  // recreating the router.
  return GoRouter(
    initialLocation: '/dashboards',
    refreshListenable: _AuthRefresh(ref),
    redirect: (ctx, state) {
      final loggedIn = Supabase.instance.client.auth.currentSession != null;
      final atSignIn = state.matchedLocation == '/sign-in';
      final atAcceptInvite = state.matchedLocation == '/accept-invite';
      final atWelcome = state.matchedLocation == '/welcome';
      // /accept-invite and /welcome are unauthenticated routes.
      // /accept-invite handles signed-in/signed-out states itself.
      // /welcome is shown immediately after signup before auth propagates.
      if (atAcceptInvite || atWelcome) return null;
      if (!loggedIn && !atSignIn) return '/sign-in';
      if (loggedIn && atSignIn) return '/dashboards';
      return null;
    },
    routes: [
      GoRoute(
        path: '/sign-in',
        pageBuilder: (_, __) => const NoTransitionPage(child: SignInScreen()),
      ),
      GoRoute(
        path: '/accept-invite',
        pageBuilder: (_, state) => NoTransitionPage(child: AcceptInviteScreen(
          token: state.uri.queryParameters['token'],
        )),
      ),
      GoRoute(
        path: '/welcome',
        pageBuilder: (_, state) => NoTransitionPage(child: WelcomeScreen(
          tenantName: state.uri.queryParameters['org'] ?? '',
        )),
      ),
      ShellRoute(
        builder: (ctx, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboards',
            pageBuilder: (_, __) => const NoTransitionPage(child: DashboardsListScreen()),
          ),
          GoRoute(
            path: '/reports',
            pageBuilder: (_, __) => const NoTransitionPage(child: ReportsListScreen()),
            routes: [
              GoRoute(
                path: 'new',
                pageBuilder: (_, __) =>
                    const NoTransitionPage(child: CustomReportBuilderScreen()),
              ),
              GoRoute(
                path: ':reportId',
                pageBuilder: (_, state) => NoTransitionPage(child: ReportViewerScreen(
                  reportId: Uri.decodeComponent(
                      state.pathParameters['reportId'] ?? ''),
                )),
                routes: [
                  GoRoute(
                    path: 'edit',
                    pageBuilder: (_, state) => NoTransitionPage(child: CustomReportBuilderScreen(
                      reportId: Uri.decodeComponent(
                          state.pathParameters['reportId'] ?? ''),
                    )),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (_, __) => const NoTransitionPage(child: LibraryScreen()),
          ),
          GoRoute(
            path: '/explore',
            pageBuilder: (_, state) => NoTransitionPage(child: ExploreScreen(
              reportId: state.uri.queryParameters['reportId'],
            )),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (_, __) => const NoTransitionPage(child: SettingsScreen()),
          ),
          GoRoute(
            path: '/help',
            pageBuilder: (_, __) => const NoTransitionPage(child: HelpScreen()),
          ),
        ],
      ),
    ],
    // We re-evaluate on every auth event:
    // ignore: unused_local_variable
    debugLogDiagnostics: false,
  );
});

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(this._ref) {
    _ref.listen(authStateProvider, (_, __) => notifyListeners());
  }
  final Ref _ref;
}

class OpticsApp extends ConsumerWidget {
  const OpticsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Network Analytics',
      debugShowCheckedModeBanner: false,
      theme: buildOpticsTheme(),
      routerConfig: router,
    );
  }
}

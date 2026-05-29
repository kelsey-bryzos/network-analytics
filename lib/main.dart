import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/config/env.dart';
import 'src/app.dart';

Future<void> main() async {
  // Catch errors that escape Flutter's normal error handling — both sync
  // (FlutterError.onError) and async (runZonedGuarded). On the web this is
  // mandatory; Flutter web has no console-of-last-resort by default.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _reportError(details.exception, details.stack ?? StackTrace.current);
  };

  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Use clean path URLs on web so deep links like
    // /accept-invite?token=... resolve correctly (no '#' fragment).
    usePathUrlStrategy();
    await Supabase.initialize(
      url: OpticsEnv.supabaseUrl,
      anonKey: OpticsEnv.supabaseAnonKey,
      debug: false,
    );
    runApp(const ProviderScope(child: OpticsApp()));
  }, (error, stack) {
    _reportError(error, stack);
  });
}

/// Single error sink. In dev we just print. In prod we'll forward to
/// Sentry/Logflare once §10.7 lands; for now the print still makes it into
/// the browser console (web) and the platform log (desktop), which is
/// already a huge improvement over Flutter's silent web default.
void _reportError(Object error, StackTrace stack) {
  if (kDebugMode) {
    debugPrint('🚨 Uncaught error: $error');
    debugPrint(stack.toString());
  } else {
    // ignore: avoid_print
    print('Uncaught error: $error\n$stack');
  }
}

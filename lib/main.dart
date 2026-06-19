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

/// Single error sink. In dev we log locally. In prod this intentionally avoids
/// writing raw error details to the browser console until server-side telemetry
/// is wired in.
void _reportError(Object error, StackTrace stack) {
  if (!kDebugMode) return;
  debugPrint('🚨 Uncaught error: $error');
  debugPrint(stack.toString());
}

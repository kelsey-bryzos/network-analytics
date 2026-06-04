// Cross-platform desktop update checker.
//
//   • macOS  — handled natively by Sparkle (see macos/Runner/AppDelegate.swift
//              + SUFeedURL in Info.plist). This Dart code is a no-op there.
//   • Windows — polls https://analytics.bryzos.com/updates/windows/latest.json
//               on app start. If a newer build is available, shows a
//               non-blocking dialog with a "Download Update" button that
//               opens the signed .exe installer URL in the user's browser.
//   • Web / iOS / Android — no-op (web auto-updates via Cloudflare Pages;
//                            mobile updates come through the stores).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateChecker {
  UpdateChecker._();

  /// Per-environment Windows update manifests.
  /// All feeds are served from the Prod Cloudflare Pages site under different
  /// sub-paths so a single `main` branch commit keeps every feed up to date.
  static String get _windowsManifestUrl {
    const env = String.fromEnvironment('APP_ENV', defaultValue: 'prod');
    switch (env) {
      case 'staging':
        return 'https://analytics.bryzos.com/updates/windows/staging/latest.json';
      case 'demo':
        return 'https://analytics.bryzos.com/updates/windows/demo/latest.json';
      default:
        return 'https://analytics.bryzos.com/updates/windows/latest.json';
    }
  }

  /// Call once after the app has rendered its first frame.
  /// Safe to call on every platform; only does work on Windows.
  static Future<void> checkOnStartup(BuildContext context) async {
    if (kIsWeb) return;
    if (!Platform.isWindows) return; // macOS handled by Sparkle, others n/a.

    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final resp = await http
          .get(Uri.parse(_windowsManifestUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;

      final manifest = jsonDecode(resp.body) as Map<String, dynamic>;
      final remoteBuild = (manifest['build_number'] as num?)?.toInt() ?? 0;
      if (remoteBuild <= currentBuild) return;

      final remoteVersion = manifest['version'] as String? ?? '';
      final downloadUrl = manifest['download_url'] as String?;
      final notesHtml = manifest['release_notes_html'] as String? ?? '';
      final mandatory = manifest['mandatory'] as bool? ?? false;
      if (downloadUrl == null || downloadUrl.isEmpty) return;

      if (!context.mounted) return;
      await _showUpdateDialog(
        context,
        version: remoteVersion,
        notesHtml: notesHtml,
        downloadUrl: downloadUrl,
        mandatory: mandatory,
      );
    } catch (e) {
      // Network errors, malformed JSON, offline — silently ignore. The user
      // will get prompted on the next launch with a working connection.
      debugPrint('UpdateChecker: $e');
    }
  }

  static Future<void> _showUpdateDialog(
    BuildContext context, {
    required String version,
    required String notesHtml,
    required String downloadUrl,
    required bool mandatory,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: !mandatory,
      builder: (ctx) => AlertDialog(
        title: Text('Update available — $version'),
        content: SingleChildScrollView(
          child: Text(
            notesHtml.isEmpty
                ? 'A new version of Network Analytics is available.'
                : _stripHtml(notesHtml),
          ),
        ),
        actions: [
          if (!mandatory)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Later'),
            ),
          FilledButton(
            onPressed: () async {
              await launchUrl(
                Uri.parse(downloadUrl),
                mode: LaunchMode.externalApplication,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Download Update'),
          ),
        ],
      ),
    );
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<li>'), '• ')
        .replaceAll(RegExp(r'</li>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
  }
}

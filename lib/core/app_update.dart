import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Číslo sestavení z GitHub Actions (0 = vývojová verze).
final int currentBuild =
    int.tryParse(const String.fromEnvironment('BUILD_NUMBER')) ?? 0;

/// Veřejná adresa, kde leží nejnovější webová verze i APK.
const updateBaseUrl = 'https://hincep-lab.github.io/hinkredience-login/app/';

/// Novější verze aplikace pro Android, ke stažení jedním klepnutím.
class AppUpdate {
  const AppUpdate({required this.build, required this.apkUrl});

  final int build;
  final String apkUrl;
}

/// Z `apk.json` vrátí aktualizaci, je-li novější než [current].
AppUpdate? parseAppUpdate(String body, {required int current}) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final build = (json['build'] as num?)?.toInt() ?? 0;
    final apk = json['apk'] as String? ?? '';
    if (build <= current || apk.isEmpty) return null;
    final url = Uri.parse(updateBaseUrl).resolve(apk).toString();
    if (!url.startsWith(updateBaseUrl)) return null;
    return AppUpdate(build: build, apkUrl: url);
  } catch (_) {
    return null;
  }
}

/// Zjistí, zda je venku novější APK. Jen v aplikaci pro Android – webová
/// verze se aktualizuje sama a vývojová verze (bez čísla sestavení) nic
/// nekontroluje.
final appUpdateProvider = FutureProvider<AppUpdate?>((ref) async {
  if (kIsWeb || currentBuild == 0 || !Platform.isAndroid) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(
      Uri.parse(
        '${updateBaseUrl}apk.json?t=${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return parseAppUpdate(body, current: currentBuild);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
});

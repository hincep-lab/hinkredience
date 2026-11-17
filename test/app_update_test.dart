import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/app_update.dart';

/// Napodobený systém: apk.json, složka, Wi-Fi/data, stahování, instalace.
class FakePlatform implements UpdatePlatform {
  FakePlatform(this.dir, {this.kind = 'android'});

  @override
  final String kind;
  final String dir;
  String? info;
  bool isMetered = false;
  List<int> apk = List.filled(2 * 1024 * 1024, 7);
  int downloads = 0;
  final installs = <String>[];
  String installResult = 'started';
  final notified = <int>[];
  int reloads = 0;

  @override
  Future<String?> fetchInfo() async => info;
  @override
  Future<String> directory() async => dir;
  @override
  Future<bool> metered() async => isMetered;
  @override
  Future<void> download(
    String url,
    String path,
    void Function(int, int) onProgress,
  ) async {
    downloads++;
    expect(url, '${updateBaseUrl}hinkredience.apk');
    await File(path).writeAsBytes(apk);
    onProgress(apk.length, apk.length);
  }

  @override
  Future<String> install(String path) async {
    installs.add(path);
    return installResult;
  }

  @override
  Future<void> notifyReady(int build) async => notified.add(build);
  @override
  void reload() => reloads++;
}

String infoFor(int build, List<int> apk, {String? sha, int? size}) =>
    '{"build": $build, "apk": "hinkredience.apk", '
    '"sha256": "${sha ?? sha256.convert(apk)}", "size": ${size ?? apk.length}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nová verze se nabídne jen když je novější', () {
    const body = '{"build": 45, "apk": "hinkredience.apk"}';
    final update = parseAppUpdate(body, current: 39)!;
    expect(update.build, 45);
    expect(update.apkUrl, '${updateBaseUrl}hinkredience.apk');
    expect(update.sha256, '');
    expect(parseAppUpdate(body, current: 45), isNull);
    expect(parseAppUpdate(body, current: 50), isNull);
  });

  test('vadná nebo cizí odpověď se ignoruje', () {
    expect(parseAppUpdate('nesmysl', current: 1), isNull);
    expect(parseAppUpdate('{"build": 99}', current: 1), isNull);
    expect(
      parseAppUpdate(
        '{"build": 99, "apk": "https://zlo.example/x.apk"}',
        current: 1,
      ),
      isNull,
      reason: 'stahovat jen z vlastní adresy',
    );
  });

  group('chytrá aktualizace (Android)', () {
    late Directory dir;
    late FakePlatform platform;
    late ProviderContainer container;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('upd');
      platform = FakePlatform(dir.path);
      container = ProviderContainer(
        overrides: [
          appUpdaterProvider.overrideWith(() => AppUpdater(platform, 80)),
        ],
      );
    });
    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<UpdateState> run({bool now = false}) async {
      final updater = container.read(appUpdaterProvider.notifier);
      await updater.check(); // počká na první kontrolu při startu
      if (now) await updater.downloadNow();
      return container.read(appUpdaterProvider);
    }

    test('na Wi-Fi se sama stáhne, ověří a nabídne instalaci', () async {
      platform.info = infoFor(83, platform.apk);
      File('${dir.path}/hinkredience-79.apk').writeAsBytesSync([1]);
      final s = await run();
      expect(s.phase, UpdatePhase.ready);
      expect(s.build, 83);
      expect(s.path, '${dir.path}/hinkredience-83.apk');
      expect(platform.downloads, 1);
      expect(platform.notified, [83], reason: 'oznámení „připraveno“');
      expect(File('${dir.path}/hinkredience-79.apk').existsSync(), isFalse);

      await container.read(appUpdaterProvider.notifier).install();
      expect(platform.installs, [s.path]);

      // Další kontrola už nestahuje znovu.
      await container.read(appUpdaterProvider.notifier).check();
      expect(platform.downloads, 1);
      expect(platform.notified, [83]);
    });

    test('na mobilních datech čeká na Wi-Fi, po klepnutí stáhne', () async {
      platform
        ..info = infoFor(83, platform.apk)
        ..isMetered = true;
      var s = await run();
      expect(s.phase, UpdatePhase.waitingForWifi);
      expect(platform.downloads, 0);
      s = await run(now: true);
      expect(s.phase, UpdatePhase.ready);
    });

    test('poškozené stažení se neuloží ani nenabídne', () async {
      platform.info = infoFor(83, platform.apk, sha: 'a' * 64);
      final s = await run();
      expect(s.phase, UpdatePhase.failed);
      expect(dir.listSync(), isEmpty, reason: 'vadný soubor smazán');
      expect(platform.notified, isEmpty);
    });

    test('chybějící povolení instalace se vysvětlí', () async {
      platform
        ..info = infoFor(83, platform.apk)
        ..installResult = 'permission';
      await run();
      await container.read(appUpdaterProvider.notifier).install();
      expect(
        container.read(appUpdaterProvider).message,
        contains('Instalovat neznámé aplikace'),
      );
    });

    test('bez nové verze nic', () async {
      platform.info = infoFor(80, platform.apk);
      final s = await run();
      expect(s.phase, UpdatePhase.none);
      expect(platform.downloads, 0);
    });
  });

  test('webová verze: nová verze se načte znovu', () async {
    final platform = FakePlatform('', kind: 'web')
      ..info = '{"build": 90, "apk": "hinkredience.apk"}';
    final container = ProviderContainer(
      overrides: [
        appUpdaterProvider.overrideWith(() => AppUpdater(platform, 83)),
      ],
    );
    addTearDown(container.dispose);
    final updater = container.read(appUpdaterProvider.notifier);
    await updater.check();
    expect(container.read(appUpdaterProvider).phase, UpdatePhase.webReload);
    updater.reloadNow();
    expect(platform.reloads, 1);
  });

  test('vývojová verze (bez čísla sestavení) nic nehledá', () async {
    final platform = FakePlatform('')..info = infoFor(90, [1]);
    final container = ProviderContainer(
      overrides: [
        appUpdaterProvider.overrideWith(() => AppUpdater(platform, 0)),
      ],
    );
    addTearDown(container.dispose);
    container.read(appUpdaterProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(appUpdaterProvider).phase, UpdatePhase.none);
    expect(platform.downloads, 0);
  });
}

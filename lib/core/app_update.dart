import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web_update.dart';

// Chytré aktualizace: aplikace sama zjistí novou verzi, na pozadí ji stáhne,
// ověří a pak stačí jedno klepnutí na „Nainstalovat“ (potvrzení instalace
// Android vyžaduje vždy – bez něj aplikaci nainstalovat nejde). Webová verze
// se po vydání nové verze sama znovu načte.

/// Číslo sestavení z GitHub Actions (0 = vývojová verze).
final int currentBuild =
    int.tryParse(const String.fromEnvironment('BUILD_NUMBER')) ?? 0;

/// Veřejná adresa, kde leží nejnovější webová verze i APK.
const updateBaseUrl = 'https://hincep-lab.github.io/hinkredience-login/app/';

/// Jak často se nová verze hledá (při otevření aplikace a pak nejvýš takhle).
const updateCheckInterval = Duration(hours: 1);

/// Novější verze aplikace (z `apk.json`).
class AppUpdate {
  const AppUpdate({
    required this.build,
    required this.apkUrl,
    this.sha256 = '',
    this.size = 0,
  });

  final int build;
  final String apkUrl;

  /// Kontrolní součet APK (prázdný u starších `apk.json`).
  final String sha256;

  /// Velikost APK v bajtech (0 = neznámá).
  final int size;
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
    final sha = (json['sha256'] as String? ?? '').toLowerCase();
    return AppUpdate(
      build: build,
      apkUrl: url,
      sha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

enum UpdatePhase {
  /// Žádná novější verze (nebo se ještě nehledalo).
  none,

  /// Novější verze je, ale telefon je na mobilních datech – stáhne se na
  /// Wi-Fi, nebo hned po klepnutí.
  waitingForWifi,

  /// Stahuje se na pozadí.
  downloading,

  /// Stažená a ověřená – stačí nainstalovat.
  ready,

  /// Stažení nebo ověření selhalo (zkusí se znovu při dalším otevření).
  failed,

  /// Webová verze: nová verze je venku, načte se znovu.
  webReload,
}

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.none,
    this.build = 0,
    this.size = 0,
    this.received = 0,
    this.path = '',
    this.message = '',
  });

  final UpdatePhase phase;
  final int build;
  final int size;
  final int received;

  /// Stažený soubor APK (ve fázi [UpdatePhase.ready]).
  final String path;

  /// Vysvětlení pro uživatele (chyba, potřebné povolení).
  final String message;

  double? get progress => size > 0 ? (received / size).clamp(0, 1) : null;

  UpdateState copyWith({
    UpdatePhase? phase,
    int? build,
    int? size,
    int? received,
    String? path,
    String? message,
  }) => UpdateState(
    phase: phase ?? this.phase,
    build: build ?? this.build,
    size: size ?? this.size,
    received: received ?? this.received,
    path: path ?? this.path,
    message: message ?? this.message,
  );
}

/// Co aktualizace potřebuje od systému (v testech se nahrazuje).
abstract interface class UpdatePlatform {
  /// Platforma, kde se aktualizuje (android / web / žádná).
  String get kind;

  /// Obsah `apk.json` (null = nedostupné).
  Future<String?> fetchInfo();

  /// Složka pro stažené aktualizace.
  Future<String> directory();

  /// Je připojení placené / omezené (mobilní data)?
  Future<bool> metered();

  /// Stáhne [url] do [path]; průběžně hlásí stažené bajty a celkovou velikost.
  Future<void> download(
    String url,
    String path,
    void Function(int received, int total) onProgress,
  );

  /// Otevře instalaci APK. Vrací 'started', nebo 'permission', když je
  /// potřeba nejdřív povolit instalaci z této aplikace (otevře nastavení).
  Future<String> install(String path);

  /// Oznámení „nová verze je připravená“.
  Future<void> notifyReady(int build);

  /// Webová verze: znovu načíst stránku.
  void reload();
}

/// Kontrolní součet SHA-256 souboru (po částech, bez načtení do paměti).
Future<String> fileSha256(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

class AppUpdater extends Notifier<UpdateState> {
  AppUpdater([this._platformOverride, this._currentOverride]);

  final UpdatePlatform? _platformOverride;
  final int? _currentOverride;

  /// Číslo nainstalovaného sestavení.
  int get _current => _currentOverride ?? currentBuild;
  late UpdatePlatform _platform;
  DateTime? _lastCheck;
  Future<void>? _running;
  AppUpdate? _pending;
  final _notified = <int>{};

  @override
  UpdateState build() {
    _platform = _platformOverride ?? ref.read(updatePlatformProvider);
    if (_platform.kind == 'none' || _current == 0) {
      return const UpdateState();
    }
    final lifecycle = AppLifecycleListener(onResume: _onResume);
    final timer = Timer.periodic(updateCheckInterval, (_) => check());
    ref.onDispose(() {
      lifecycle.dispose();
      timer.cancel();
    });
    Future.microtask(check);
    return const UpdateState();
  }

  void _onResume() {
    // Webová verze: nová verze se načte, jakmile se k aplikaci vrátíte.
    if (state.phase == UpdatePhase.webReload) {
      _platform.reload();
      return;
    }
    final last = _lastCheck;
    if (last == null ||
        DateTime.now().difference(last) >= updateCheckInterval) {
      check();
    }
  }

  /// Zjistí novou verzi a na Androidu ji rovnou stáhne (na Wi-Fi, nebo když
  /// [allowMobileData]).
  Future<void> check({bool allowMobileData = false}) async {
    // Běžící kontrola se nezdvojuje: počká se na ni. Klepnutí „stáhnout
    // hned“ po ní proběhne znovu, už s povolenými mobilními daty.
    while (_running != null) {
      await _running;
      if (!allowMobileData) return;
    }
    final run = _check(allowMobileData);
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
  }

  Future<void> _check(bool allowMobileData) async {
    _lastCheck = DateTime.now();
    try {
      final body = await _platform.fetchInfo();
      final update = body == null
          ? null
          : parseAppUpdate(body, current: _current);
      if (_platform.kind == 'web') {
        if (update != null) {
          state = UpdateState(
            phase: UpdatePhase.webReload,
            build: update.build,
          );
        }
        return;
      }
      final dir = await _platform.directory();
      await _cleanUp(dir, keep: update?.build);
      if (update == null) {
        if (state.phase != UpdatePhase.ready) state = const UpdateState();
        return;
      }
      _pending = update;
      final file = '$dir/hinkredience-${update.build}.apk';
      if (await _verified(file, update)) {
        _ready(update, file);
        return;
      }
      if (!allowMobileData && await _platform.metered()) {
        state = UpdateState(
          phase: UpdatePhase.waitingForWifi,
          build: update.build,
          size: update.size,
        );
        return;
      }
      await _download(update, file);
    } catch (error) {
      debugPrint('Aktualizace: $error');
    }
  }

  /// Stáhnout hned i na mobilních datech (uživatel klepl).
  Future<void> downloadNow() => check(allowMobileData: true);

  Future<void> _download(AppUpdate update, String file) async {
    final part = '$file.part';
    state = UpdateState(
      phase: UpdatePhase.downloading,
      build: update.build,
      size: update.size,
    );
    try {
      await _platform.download(update.apkUrl, part, (received, total) {
        state = state.copyWith(
          received: received,
          size: total > 0 ? total : update.size,
        );
      });
      if (!await _verified(part, update)) {
        await _delete(part);
        state = UpdateState(
          phase: UpdatePhase.failed,
          build: update.build,
          message: 'Stažený soubor nesouhlasí – zkusí se znovu.',
        );
        return;
      }
      await File(part).rename(file);
      _ready(update, file);
    } catch (error) {
      await _delete(part);
      state = UpdateState(
        phase: UpdatePhase.failed,
        build: update.build,
        message: 'Stažení se nepovedlo – zkusí se znovu.',
      );
      debugPrint('Aktualizace: stažení selhalo: $error');
    }
  }

  void _ready(AppUpdate update, String file) {
    state = UpdateState(
      phase: UpdatePhase.ready,
      build: update.build,
      size: update.size,
      path: file,
    );
    if (_notified.add(update.build)) {
      unawaited(_platform.notifyReady(update.build).catchError((_) {}));
    }
  }

  Future<bool> _verified(String path, AppUpdate update) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 1024 * 1024) return false; // APK má desítky MB
    if (update.size > 0 && length != update.size) return false;
    if (update.sha256.isNotEmpty && await fileSha256(path) != update.sha256) {
      return false;
    }
    return true;
  }

  /// Otevře instalaci stažené verze.
  Future<void> install() async {
    final path = state.path;
    if (state.phase != UpdatePhase.ready || path.isEmpty) return;
    final result = await _platform.install(path);
    state = state.copyWith(
      message: result == 'permission'
          ? 'Povolte „Instalovat neznámé aplikace“ pro HINKredience° '
                'a klepněte na Nainstalovat znovu.'
          : '',
    );
  }

  /// Webová verze: načíst novou verzi hned.
  void reloadNow() => _platform.reload();

  /// Smaže staré stažené verze (a nedokončená stahování jiných verzí).
  Future<void> _cleanUp(String dir, {int? keep}) async {
    try {
      final folder = Directory(dir);
      if (!await folder.exists()) return;
      await for (final entry in folder.list()) {
        final name = entry.uri.pathSegments.last;
        final m = RegExp(r'^hinkredience-(\d+)\.apk').firstMatch(name);
        if (m == null) continue;
        final build = int.parse(m.group(1)!);
        if (build != keep) await _delete(entry.path);
      }
    } catch (_) {}
  }

  Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// Poslední nalezená aktualizace (pro testy a zobrazení velikosti).
  AppUpdate? get pending => _pending;
}

final updatePlatformProvider = Provider<UpdatePlatform>((ref) {
  if (kIsWeb) return WebUpdatePlatform();
  if (Platform.isAndroid) return AndroidUpdatePlatform();
  return const NoUpdatePlatform();
});

final appUpdaterProvider = NotifierProvider<AppUpdater, UpdateState>(
  AppUpdater.new,
);

class NoUpdatePlatform implements UpdatePlatform {
  const NoUpdatePlatform();

  @override
  String get kind => 'none';
  @override
  Future<String?> fetchInfo() async => null;
  @override
  Future<String> directory() async => '';
  @override
  Future<bool> metered() async => false;
  @override
  Future<void> download(String url, String path, void Function(int, int) p) =>
      throw UnsupportedError('');
  @override
  Future<String> install(String path) async => '';
  @override
  Future<void> notifyReady(int build) async {}
  @override
  void reload() {}
}

/// Webová verze: `apk.json` přes prohlížeč, nová verze = znovunačtení.
class WebUpdatePlatform extends NoUpdatePlatform {
  @override
  String get kind => 'web';

  @override
  Future<String?> fetchInfo() => webFetchText(
    '${updateBaseUrl}apk.json?t=${DateTime.now().millisecondsSinceEpoch}',
  );

  @override
  void reload() => webReload();
}

/// Android: stažení přes HttpClient, instalace přes systémový instalátor
/// (MainActivity.kt, kanál cz.hink.hinkredience/update).
class AndroidUpdatePlatform implements UpdatePlatform {
  static const _channel = MethodChannel('cz.hink.hinkredience/update');
  final _notifications = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  @override
  String get kind => 'android';

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  @override
  Future<String?> fetchInfo() async {
    final client = _client();
    try {
      final request = await client.getUrl(
        Uri.parse(
          '${updateBaseUrl}apk.json?t=${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  @override
  Future<String> directory() async =>
      await _channel.invokeMethod<String>('directory') ?? '';

  @override
  Future<bool> metered() async {
    try {
      return await _channel.invokeMethod<bool>('metered') ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> download(
    String url,
    String path,
    void Function(int received, int total) onProgress,
  ) async {
    final client = _client();
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      sink = File(path).openWrite();
      var received = 0;
      var reported = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        received += chunk.length;
        // Hlásit zhruba po 1 %, ať se zbytečně nepřekresluje.
        if (received - reported > (total > 0 ? total ~/ 100 : 512 * 1024)) {
          reported = received;
          onProgress(received, total);
        }
      }
      await sink.flush();
      onProgress(received, total);
    } finally {
      await sink?.close();
      client.close();
    }
  }

  @override
  Future<String> install(String path) async =>
      await _channel.invokeMethod<String>('install', {'path': path}) ?? '';

  @override
  Future<void> notifyReady(int build) async {
    await (_ready ??= _notifications
        .initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        )
        .then((_) {}));
    await _notifications.show(
      id: 990001,
      title: 'Nová verze HINKredience° je připravená',
      body:
          'Sestavení $build je stažené. Otevřete aplikaci a klepněte '
          'na Nainstalovat.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'app_update',
          'Aktualizace aplikace',
          channelDescription: 'Když je stažená nová verze aplikace.',
          importance: Importance.defaultImportance,
        ),
      ),
    );
  }

  @override
  void reload() {}
}

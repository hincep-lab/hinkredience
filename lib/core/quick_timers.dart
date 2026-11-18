import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'cook_timer.dart';
import 'cooking_services.dart';

/// Minutky mimo režim vaření (Minutka, tabulka teplot). Běží pro celou
/// aplikaci: zvoní na kterékoli obrazovce, vydrží zavření aplikace
/// (pamatují si okamžik konce) a na Androidu se ozvou i oznámením.
class QuickTimers extends Notifier<List<CookTimer>> {
  static const _key = 'quick_timers';
  Timer? _ticker;
  final _rung = <String>{};

  @override
  List<CookTimer> build() {
    ref.onDispose(() => _ticker?.cancel());
    final restored = _load();
    final now = DateTime.now().toUtc();
    // Starší konce (aplikace byla zavřená) už ohlásilo oznámení.
    for (final t in restored) {
      if (t.isDone(now) && !t.justFinished(now)) _rung.add(t.id);
    }
    _ensureTicker(restored);
    return restored;
  }

  List<CookTimer> _load() {
    try {
      final text = ref.read(sharedPreferencesProvider).getString(_key);
      if (text == null) return const [];
      return CookTimers.fromJson(jsonDecode(text)).timers;
    } catch (_) {
      return const [];
    }
  }

  void _set(List<CookTimer> timers) {
    state = timers;
    _ensureTicker(timers);
    try {
      unawaited(
        ref
            .read(sharedPreferencesProvider)
            .setString(_key, jsonEncode(CookTimers(timers).toJson())),
      );
    } catch (_) {}
  }

  CookAlerts get _alerts => ref.read(cookAlertsProvider);

  void _ensureTicker(List<CookTimer> timers) {
    final waiting = timers.any((t) => t.isRunning && !t.acknowledged);
    if (!waiting) {
      _ticker?.cancel();
      _ticker = null;
    } else {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
  }

  /// Hlídá doběhnutí (volá se každou vteřinu; v testech ručně).
  @visibleForTesting
  void tick([DateTime? at]) {
    final now = at ?? DateTime.now().toUtc();
    var changed = false;
    for (final t in state) {
      if (t.isDone(now) && !t.acknowledged && _rung.add(t.id)) {
        changed = true;
        if (t.justFinished(now)) {
          HapticFeedback.heavyImpact();
          unawaited(_alerts.ring(t));
        }
      }
    }
    // Překreslit (zvonící minutka se ukáže v liště nad navigací).
    if (changed) state = [...state];
  }

  /// Minutky, které doběhly a čekají na potvrzení.
  List<CookTimer> ringing([DateTime? at]) =>
      CookTimers(state).ringing(at ?? DateTime.now().toUtc());

  Future<void> start(String label, Duration duration) async {
    final now = DateTime.now().toUtc();
    final timers = CookTimers(state).start(
      id: 'quick-${now.microsecondsSinceEpoch}',
      label: label,
      duration: duration,
      now: now,
    );
    _set(timers.timers);
    final started = timers.timers.last;
    // Oznámení až po spuštění – nesmí odpočet zdržet.
    unawaited(() async {
      await _alerts.requestPermission();
      await _alerts.schedule(started);
    }());
  }

  Future<void> pause(CookTimer timer) async {
    final now = DateTime.now().toUtc();
    _set(CookTimers(state).update(timer.id, (t) => t.pause(now)).timers);
    unawaited(_alerts.cancel(timer));
  }

  Future<void> resume(CookTimer timer) async {
    final now = DateTime.now().toUtc();
    final next = CookTimers(state).update(timer.id, (t) => t.resume(now));
    _set(next.timers);
    unawaited(
      _alerts.schedule(next.timers.firstWhere((t) => t.id == timer.id)),
    );
  }

  /// Zrušit, nebo potvrdit doběhnutou minutku.
  Future<void> stop(CookTimer timer) async {
    _rung.remove(timer.id);
    _set(CookTimers(state).remove(timer.id).timers);
    unawaited(_alerts.cancel(timer));
  }
}

final quickTimersProvider = NotifierProvider<QuickTimers, List<CookTimer>>(
  QuickTimers.new,
);

/// Hotové minutky do kuchyně (název, minuty).
const timerPresets = <(String, int, String)>[
  ('Vejce naměkko', 4, 'od varu'),
  ('Vejce nahniličko', 7, 'od varu'),
  ('Vejce natvrdo', 10, 'od varu'),
  ('Špagety', 9, 'al dente'),
  ('Rýže', 18, 'pod pokličkou'),
  ('Brambory', 20, 'vařené, kusy'),
  ('Knedlíky', 20, 'houskové, z vody'),
  ('Pizza', 8, 'Electrolux 300 °C'),
  ('Odpočinek masa', 10, 'po pečení'),
  ('Kynutí těsta', 45, 'v teple'),
];

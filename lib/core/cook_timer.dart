import 'dart:math' as math;

// Příprava na režim „Vaříme spolu“: časovače k jednotlivým krokům, více
// souběžných časovačů a pokračování po zavření aplikace. Samotná obrazovka
// režimu vaření přijde v Etapě 4.

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? _iso(DateTime? value) => value?.toUtc().toIso8601String();

/// Kuchyňský časovač.
///
/// Běžící časovač si pamatuje okamžik konce ([endsAt]), ne počet zbývajících
/// vteřin – díky tomu ukazuje správně i po zavření a znovuotevření aplikace.
class CookTimer {
  const CookTimer({
    required this.id,
    required this.label,
    required this.durationSeconds,
    this.stepIndex,
    this.endsAt,
    this.remainingSeconds,
    this.acknowledged = false,
  });

  final String id;
  final String label;
  final int durationSeconds;

  /// Krok receptu, ke kterému časovač patří.
  final int? stepIndex;

  /// Konec běžícího časovače; `null`, když je pozastavený.
  final DateTime? endsAt;

  /// Zbývající čas pozastaveného časovače.
  final int? remainingSeconds;

  /// Uživatel už dozvonění potvrdil.
  final bool acknowledged;

  bool get isRunning => endsAt != null;

  int remaining(DateTime now) => endsAt != null
      ? math.max(0, (endsAt!.difference(now).inMilliseconds / 1000).ceil())
      : math.max(0, remainingSeconds ?? durationSeconds);

  bool isDone(DateTime now) => endsAt != null && !now.isBefore(endsAt!);

  /// Číslo oznámení v systému (stabilní pro daný časovač).
  int get notificationId => id.hashCode & 0x3fffffff;

  CookTimer pause(DateTime now) => isRunning && !isDone(now)
      ? CookTimer(
          id: id,
          label: label,
          durationSeconds: durationSeconds,
          stepIndex: stepIndex,
          remainingSeconds: remaining(now),
        )
      : this;

  CookTimer resume(DateTime now) => isRunning
      ? this
      : CookTimer(
          id: id,
          label: label,
          durationSeconds: durationSeconds,
          stepIndex: stepIndex,
          endsAt: now.add(Duration(seconds: remaining(now))),
        );

  CookTimer acknowledge() => CookTimer(
    id: id,
    label: label,
    durationSeconds: durationSeconds,
    stepIndex: stepIndex,
    endsAt: endsAt,
    remainingSeconds: remainingSeconds,
    acknowledged: true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'duration_seconds': durationSeconds,
    'step_index': ?stepIndex,
    'ends_at': ?_iso(endsAt),
    'remaining_seconds': ?remainingSeconds,
    if (acknowledged) 'acknowledged': true,
  };

  factory CookTimer.fromJson(Map<String, dynamic> json) => CookTimer(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
    stepIndex: (json['step_index'] as num?)?.toInt(),
    endsAt: _date(json['ends_at']),
    remainingSeconds: (json['remaining_seconds'] as num?)?.toInt(),
    acknowledged: json['acknowledged'] == true,
  );
}

/// Sada souběžně běžících časovačů (např. těstoviny + omáčka + trouba).
class CookTimers {
  const CookTimers([this.timers = const []]);

  final List<CookTimer> timers;

  /// Časovače, které právě doběhly a čekají na potvrzení (zvonění).
  List<CookTimer> ringing(DateTime now) => [
    for (final t in timers)
      if (t.isDone(now) && !t.acknowledged) t,
  ];

  /// Nejbližší časovač, který doběhne (pro upozornění).
  CookTimer? nextToFinish(DateTime now) {
    CookTimer? best;
    for (final t in timers) {
      if (!t.isRunning || t.isDone(now)) continue;
      if (best == null || t.endsAt!.isBefore(best.endsAt!)) best = t;
    }
    return best;
  }

  CookTimers start({
    required String id,
    required String label,
    required Duration duration,
    required DateTime now,
    int? stepIndex,
  }) => CookTimers([
    ...timers.where((t) => t.id != id),
    CookTimer(
      id: id,
      label: label,
      durationSeconds: duration.inSeconds,
      stepIndex: stepIndex,
      endsAt: now.add(duration),
    ),
  ]);

  CookTimers update(String id, CookTimer Function(CookTimer) change) =>
      CookTimers([for (final t in timers) t.id == id ? change(t) : t]);

  CookTimers remove(String id) => CookTimers([
    for (final t in timers)
      if (t.id != id) t,
  ]);

  List<Map<String, dynamic>> toJson() => [for (final t in timers) t.toJson()];

  factory CookTimers.fromJson(Object? json) => CookTimers([
    if (json is List)
      for (final item in json)
        if (item is Map) CookTimer.fromJson(Map<String, dynamic>.from(item)),
  ]);
}

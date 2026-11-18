import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/cook_timer.dart';

void main() {
  final start = DateTime.utc(2026, 11, 15, 18);

  test('více souběžných časovačů, nejbližší a zvonící', () {
    var timers = const CookTimers()
        .start(
          id: 'testoviny',
          label: 'Těstoviny',
          duration: const Duration(minutes: 9),
          now: start,
          stepIndex: 2,
        )
        .start(
          id: 'omacka',
          label: 'Omáčka',
          duration: const Duration(minutes: 20),
          now: start,
        );
    expect(timers.timers, hasLength(2));
    expect(timers.nextToFinish(start)!.id, 'testoviny');

    final later = start.add(const Duration(minutes: 10));
    expect(timers.ringing(later).single.id, 'testoviny');
    expect(timers.nextToFinish(later)!.id, 'omacka');

    timers = timers.update('testoviny', (t) => t.acknowledge());
    expect(timers.ringing(later), isEmpty);
  });

  test('pozastavení a pokračování neztratí zbývající čas', () {
    final running = const CookTimers().start(
      id: 'a',
      label: 'Pečení',
      duration: const Duration(minutes: 30),
      now: start,
    );
    final paused = running.update(
      'a',
      (t) => t.pause(start.add(const Duration(minutes: 10))),
    );
    final timer = paused.timers.single;
    expect(timer.isRunning, isFalse);
    // Ani dlouhá pauza zbývající čas nezmění.
    expect(timer.remaining(start.add(const Duration(hours: 3))), 20 * 60);

    final resumedAt = start.add(const Duration(hours: 3));
    final resumed = timer.resume(resumedAt);
    expect(resumed.endsAt, resumedAt.add(const Duration(minutes: 20)));
  });

  test('časovač přežije zavření aplikace (uložení a načtení)', () {
    final timers = const CookTimers().start(
      id: 'a',
      label: 'Kynutí',
      duration: const Duration(hours: 1),
      now: start,
    );
    final restored = CookTimers.fromJson(timers.toJson());
    final later = start.add(const Duration(minutes: 45));
    expect(restored.timers.single.remaining(later), 15 * 60);
    expect(restored.timers.single.label, 'Kynutí');
  });
}

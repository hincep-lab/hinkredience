import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/data/kitchen_docs.dart';

import 'support.dart';

void main() {
  late TestEnvironment env;

  setUp(() async => env = await TestEnvironment.create());
  tearDown(() => env.dispose());

  test('přání: čekající nahoře, naplánovaná po termínu zmizí, sync', () async {
    final docs = await env.docs();
    MealWish wish(String title, {String? planned}) => MealWish(
      id: docs.newId(),
      title: title,
      authorName: 'Martinka',
      plannedDay: planned,
      createdAt: docs.now(),
      updatedAt: docs.now(),
    );
    final svickova = await docs.saveWish(wish('Svíčková'));
    env.advance(const Duration(minutes: 1));
    await docs.saveWish(wish('Palačinky'));
    await docs.saveWish(wish('Guláš', planned: '2026-11-20'));
    await docs.saveWish(wish('Řízek', planned: '2026-11-01'));

    expect((await docs.wishes()).map((w) => w.title), [
      'Palačinky',
      'Svíčková',
      'Guláš',
    ]);

    await docs.saveWish(svickova.copyWith(plannedDay: '2026-11-16'));
    final planned = (await docs.wishes()).firstWhere(
      (w) => w.title == 'Svíčková',
    );
    expect(planned.isPlanned, isTrue);
    expect(planned.authorName, 'Martinka');

    final dirty = await docs.dirty(DocKind.wish);
    expect(dirty.length, 4);
    expect(dirty.first.data['author_name'], 'Martinka');

    await docs.deleteWish(svickova.id);
    expect((await docs.wishes()).where((w) => w.title == 'Svíčková'), isEmpty);
  });

  test('MealWish json tam a zpět', () {
    final w = MealWish(
      id: 'w1',
      title: 'Kuře na paprice',
      recipeId: 'r1',
      note: 'v sobotu',
      authorName: 'Pájo',
      plannedDay: '2026-11-21',
      ownerId: 'u1',
      householdId: 'h1',
      createdAt: DateTime.utc(2026, 11, 15),
      updatedAt: DateTime.utc(2026, 11, 15, 1),
    );
    final back = MealWish.fromJson(w.toJson());
    expect(back.toJson(), w.toJson());
    expect(back.copyWith(plannedDay: null).isPlanned, isFalse);
  });
}

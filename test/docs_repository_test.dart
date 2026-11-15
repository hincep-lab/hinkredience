import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/shopping.dart';
import 'package:hinkredience/data/docs_repository.dart';
import 'package:hinkredience/data/kitchen_docs.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/features/cooking/cooking_screen.dart'
    show formatCountdown, suggestedTimerMinutes;

import 'support.dart';

void main() {
  late TestEnvironment env;
  late DocsRepository docs;

  setUp(() async {
    env = await TestEnvironment.create();
    docs = await env.docs();
  });
  tearDown(() => env.dispose());

  CookingSession session(String id, {String status = SessionStatus.finished}) =>
      CookingSession(
        id: id,
        recipeId: 'recipe-1',
        recipeTitle: 'Pizza',
        status: status,
        cookedAt: env.now,
        updatedAt: env.now,
      );

  test(
    'deník: dokončená vaření, rozvařený recept zvlášť a jen v telefonu',
    () async {
      await docs.saveSession(session('a'));
      env.advance(const Duration(days: 1));
      await docs.saveSession(
        session('b')
            .copyWith(cookedAt: env.now, rating: 5.0, wentWell: 'Kůrka'),
      );
      await docs.saveSession(session('c', status: SessionStatus.inProgress));
      final diary = await docs.diary();
      expect(diary.map((s) => s.id), ['b', 'a']);
      expect(diary.first.wentWell, 'Kůrka');
      expect((await docs.openSession())!.id, 'c');
      expect(
        await docs.dirtyCount(),
        2,
        reason: 'rozvařený recept se neodesílá',
      );

      await docs.deleteSession('a');
      expect((await docs.diary()).map((s) => s.id), ['b']);
      expect(
        (await docs.dirty(DocKind.session))
            .firstWhere((d) => d.id == 'a')
            .deletedAt,
        isNotNull,
      );
    },
  );

  test('stav vaření přežije zavření aplikace', () async {
    final now = DateTime.utc(2026, 11, 15, 18);
    final timers = const CookTimers().start(
      id: 't',
      label: 'Kynutí',
      duration: const Duration(minutes: 30),
      now: now,
    );
    await docs.saveSession(
      session('c', status: SessionStatus.inProgress).copyWith(
        stepIndex: 3,
        resumedAt: now,
        activeSeconds: 120,
        timers: timers.timers,
      ),
    );
    final reopened = (await env.docs('test.db')).openSession();
    final restored = (await reopened)!;
    expect(restored.stepIndex, 3);
    expect(
      restored.timers.single.remaining(now.add(const Duration(minutes: 10))),
      20 * 60,
    );
    expect(restored.elapsedSeconds(now.add(const Duration(minutes: 1))), 180);
  });

  test('plán vaření na týden, seřazený podle dne a jídla', () async {
    Future<void> meal(String id, String day, String type) => docs.saveMeal(
      MealPlanEntry(
        id: id,
        day: day,
        mealType: type,
        title: id,
        updatedAt: env.now,
      ),
    );
    await meal('vecere', '2026-11-16', MealType.dinner);
    await meal('snidane', '2026-11-16', MealType.breakfast);
    await meal('utery', '2026-11-17', MealType.lunch);
    await meal('jiny-tyden', '2026-11-24', MealType.lunch);
    final week = await docs.plan(
      from: DateTime(2026, 11, 16),
      to: DateTime(2026, 11, 22),
    );
    expect(week.map((e) => e.id), ['snidane', 'vecere', 'utery']);
    expect(weekStart(DateTime(2026, 11, 19)), DateTime(2026, 11, 16));
  });

  test('nákupní seznam: sloučení se uloží, nakoupené jdou na konec', () async {
    await docs.addToShopping(const [
      ShoppingDraft(name: 'Mouka', quantity: 500, unit: 'g', source: 'Buchty'),
      ShoppingDraft(name: 'Mléko', quantity: 1, unit: 'l'),
    ]);
    final merge = await docs.addToShopping(const [
      ShoppingDraft(name: 'mouka', quantity: 250, unit: 'g', source: 'Lívance'),
    ]);
    expect(merge.merged, 1);
    var items = await docs.shopping();
    final flour = items.firstWhere((i) => i.name == 'Mouka');
    expect(flour.quantity, 750);
    expect(flour.sources, ['Buchty', 'Lívance']);
    await docs.saveShoppingItem(flour.copyWith(checked: true));
    items = await docs.shopping();
    expect(items.map((i) => i.name), ['Mléko', 'Mouka']);
    await docs.deleteShoppingItems([items.last.id]);
    expect((await docs.shopping()).map((i) => i.name), ['Mléko']);
  });

  test(
    'změna ze serveru zachová fotky v telefonu, starší nepřepíše novější',
    () async {
      final local = await docs.saveSession(
        session('a').copyWith(
          photos: const [
            RecipePhoto(id: 'p', localPath: 'photos/session-a/p.jpg'),
          ],
        ),
      );
      await docs.markClean('a', local.updatedAt);
      expect(
        await docs.applyRemote(
          kind: DocKind.session,
          id: 'a',
          data: {
            ...local.toJson(),
            'notes': 'Ze serveru',
            'photos': [
              {'id': 'p', 'remote_path': 'u/session-a/p.jpg'},
            ],
          },
          updatedAt: env.now.add(const Duration(minutes: 5)),
        ),
        isTrue,
      );
      final merged = (await docs.session('a'))!;
      expect(merged.notes, 'Ze serveru');
      expect(merged.photos.single.localPath, 'photos/session-a/p.jpg');
      expect(merged.photos.single.remotePath, 'u/session-a/p.jpg');

      env.advance(const Duration(hours: 1));
      await docs.saveSession(merged.copyWith(notes: 'Moje novější'));
      expect(
        await docs.applyRemote(
          kind: DocKind.session,
          id: 'a',
          data: {...local.toJson(), 'notes': 'Starší'},
          updatedAt: env.now.subtract(const Duration(minutes: 30)),
        ),
        isFalse,
      );
      expect((await docs.session('a'))!.notes, 'Moje novější');
    },
  );

  test('časovač ke kroku podle délky nebo textu postupu', () {
    expect(
      suggestedTimerMinutes(
        const RecipeStep(id: 'a', instruction: 'Peč', durationMinutes: 25),
      ),
      25,
    );
    expect(
      suggestedTimerMinutes(
        const RecipeStep(id: 'b', instruction: 'Nech kynout 2 hodiny.'),
      ),
      120,
    );
    expect(
      suggestedTimerMinutes(
        const RecipeStep(id: 'c', instruction: 'Promíchej.'),
      ),
      isNull,
    );
    expect(formatCountdown(65), '01:05');
    expect(formatCountdown(3725), '1:02:05');
  });
}

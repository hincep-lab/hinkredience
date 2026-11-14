import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';

import 'support.dart';

void main() {
  late TestEnvironment env;
  late RecipeRepository repository;

  setUp(() async {
    env = await TestEnvironment.create();
    repository = await env.repository();
  });

  tearDown(() => env.dispose());

  test('nový recept se uloží jako verze 1 a čeká na odeslání', () async {
    final created = await repository.create(sampleRecipe());

    expect(created.currentVersion, 1);
    expect(created.createdAt, env.now);
    final loaded = await repository.getById('recipe-1');
    expect(loaded!.title, 'Žebra BBQ');
    expect(loaded.ingredients, hasLength(4));
    expect(loaded.steps[1].temperatureC, 150);
    expect(await repository.dirtyCount(), 1);

    final versions = await repository.versions('recipe-1');
    expect(versions.single.versionNumber, 1);
    expect(versions.single.changeSummary, 'Původní postup');
  });

  test('česká diakritika projde databází beze změny', () async {
    const text =
        'Příliš žluťoučký kůň úpěl ďábelské ódy – ŘEŘICHA, šťáva, 180 °C';
    await repository.create(sampleRecipe().copyWith(title: text, notes: text));
    final loaded = await repository.getById('recipe-1');
    expect(loaded!.title, text);
    expect(loaded.notes, text);
  });

  test('úprava vytvoří novou verzi a původní zachová', () async {
    final created = await repository.create(sampleRecipe());
    env.advance(const Duration(days: 1));
    final updated = await repository.update(
      created.copyWith(notes: 'Solit den předem.'),
      changeSummary: 'Upravené solení',
    );

    expect(updated.currentVersion, 2);
    expect(updated.updatedAt, env.now);
    expect(updated.createdAt, created.createdAt);

    final versions = await repository.versions('recipe-1');
    expect(versions.map((v) => v.versionNumber), [2, 1]);
    expect(versions.first.changeSummary, 'Upravené solení');
    expect(versions.first.snapshot['notes'], 'Solit den předem.');
    expect(versions.last.snapshot['notes'], 'Přikrýt alobalem.');
  });

  test('oblíbené a hodnocení nevytvářejí novou verzi', () async {
    await repository.create(sampleRecipe());
    await repository.setFavorite('recipe-1', true);
    await repository.setRating('recipe-1', 4.5);

    final loaded = await repository.getById('recipe-1');
    expect(loaded!.isFavorite, isTrue);
    expect(loaded.rating, 4.5);
    expect(loaded.currentVersion, 1);
    expect(await repository.versions('recipe-1'), hasLength(1));
  });

  test('smazání přesune do koše a obnovení vrátí zpět', () async {
    await repository.create(sampleRecipe());
    await repository.softDelete('recipe-1');
    expect((await repository.getById('recipe-1'))!.isDeleted, isTrue);
    // Recept z databáze nezmizel – historie zůstává.
    expect(await repository.versions('recipe-1'), hasLength(1));

    await repository.restore('recipe-1');
    final restored = await repository.getById('recipe-1');
    expect(restored!.isDeleted, isFalse);
    expect(restored.ingredients, hasLength(4));
  });

  test('duplikát má nové id, vlastní historii a nesdílí oblíbenost', () async {
    await repository.create(sampleRecipe());
    await repository.setFavorite('recipe-1', true);
    final copy = await repository.duplicate('recipe-1');

    expect(copy!.id, isNot('recipe-1'));
    expect(copy.title, 'Žebra BBQ (kopie)');
    expect(copy.isFavorite, isFalse);
    expect(copy.currentVersion, 1);
    expect(copy.ingredients.map((i) => i.name), contains('BBQ omáčka'));
    expect(copy.ingredients.first.id, isNot('i1'));
    expect(await repository.getAll(), hasLength(2));
    expect(await repository.duplicate('neexistuje'), isNull);
  });

  test('změny vyvolají událost pro obnovení obrazovek', () async {
    final events = <void>[];
    final subscription = repository.changes.listen(events.add);
    await repository.create(sampleRecipe());
    await repository.setFavorite('recipe-1', true);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
    await subscription.cancel();
  });

  test('vlastní kategorie se ukládají bez duplicit', () async {
    await repository.addCustomCategory('  Sous-vide ');
    await repository.addCustomCategory('Sous-vide');
    await repository.addCustomCategory('');
    expect(await repository.customCategories(), ['Sous-vide']);
  });

  group('synchronizace', () {
    test('markClean neoznačí recept, který se mezitím změnil', () async {
      final created = await repository.create(sampleRecipe());
      env.advance(const Duration(minutes: 1));
      await repository.setFavorite('recipe-1', true);

      await repository.markClean('recipe-1', created.updatedAt);
      expect(await repository.dirtyCount(), 1);

      final current = await repository.getById('recipe-1');
      await repository.markClean('recipe-1', current!.updatedAt);
      expect(await repository.dirtyCount(), 0);
    });

    test('nový recept ze serveru se uloží jako odeslaný', () async {
      final applied = await repository.applyRemote(sampleRecipe(id: 'remote'));
      expect(applied, isTrue);
      expect(await repository.dirtyCount(), 0);
      expect((await repository.getById('remote'))!.title, 'Žebra BBQ');
    });

    test('novější neodeslaná místní úprava se nepřepíše', () async {
      final local = await repository.create(sampleRecipe());
      final remote = local.copyWith(
        title: 'Starší ze serveru',
        updatedAt: env.now.subtract(const Duration(hours: 1)),
      );
      expect(await repository.applyRemote(remote), isFalse);
      expect((await repository.getById('recipe-1'))!.title, 'Žebra BBQ');
      expect(await repository.dirtyCount(), 1);
    });

    test('novější úprava ze serveru vyhrává', () async {
      final local = await repository.create(sampleRecipe());
      final remote = local.copyWith(
        title: 'Novější ze serveru',
        updatedAt: env.now.add(const Duration(hours: 1)),
      );
      expect(await repository.applyRemote(remote), isTrue);
      expect(
        (await repository.getById('recipe-1'))!.title,
        'Novější ze serveru',
      );
      expect(await repository.dirtyCount(), 0);
    });

    test('server nepřepíše cestu k fotce v telefonu', () async {
      final local = await repository.create(
        sampleRecipe().copyWith(
          photos: const [
            RecipePhoto(id: 'p1', localPath: 'photos/recipe-1/p1.jpg'),
          ],
        ),
      );
      await repository.markClean('recipe-1', local.updatedAt);
      final remote = local.copyWith(
        updatedAt: env.now.add(const Duration(minutes: 5)),
        photos: const [RecipePhoto(id: 'p1', remotePath: 'u/recipe-1/p1.jpg')],
      );
      await repository.applyRemote(remote);
      final photo = (await repository.getById('recipe-1'))!.photos.single;
      expect(photo.localPath, 'photos/recipe-1/p1.jpg');
      expect(photo.remotePath, 'u/recipe-1/p1.jpg');
    });

    test('recepty vytvořené bez účtu se po přihlášení převezmou', () async {
      final local = await env.repository('local.db');
      await local.create(sampleRecipe(id: 'offline-1', title: 'Guláš'));
      await local.addCustomCategory('Zvěřina');

      final count = await repository.importFrom(local, ownerId: 'user-1');
      expect(count, 1);
      final imported = await repository.getById('offline-1');
      expect(imported!.ownerId, 'user-1');
      expect(imported.title, 'Guláš');
      expect(await repository.versions('offline-1'), hasLength(1));
      expect(await repository.customCategories(), ['Zvěřina']);
      expect(await repository.dirtyCount(), 1);

      // Opakovaný import nic nezdvojí.
      expect(await repository.importFrom(local, ownerId: 'user-1'), 0);
    });
  });
}

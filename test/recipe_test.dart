import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/remote_store.dart';
import 'package:hinkredience/features/home/home_screen.dart';
import 'package:hinkredience/features/recipes/recipe_detail_screen.dart';
import 'package:hinkredience/features/recipes/recipes_screen.dart';

import 'support.dart';

void main() {
  test('recept přežije převod do JSON a zpět včetně diakritiky', () {
    final recipe = sampleRecipe().copyWith(
      title: 'Příliš žluťoučký kůň – 180 °C',
      rating: 4.5,
      isFavorite: true,
      photos: const [
        RecipePhoto(
          id: 'p1',
          localPath: 'photos/r/p1.jpg',
          remotePath: 'u/r/p1.jpg',
        ),
      ],
    );
    final decoded = Recipe.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(recipe.toJson())) as Map),
    );
    expect(decoded.title, 'Příliš žluťoučký kůň – 180 °C');
    expect(decoded.rating, 4.5);
    expect(decoded.isFavorite, isTrue);
    expect(decoded.ingredients.map((i) => i.name), [
      'Vepřová žebra',
      'BBQ omáčka',
      'Hořčice plnotučná',
      'Sůl',
    ]);
    expect(decoded.ingredients.last.quantity, isNull);
    expect(decoded.steps[1].temperatureC, 150);
    expect(decoded.steps[1].durationMinutes, 180);
    expect(decoded.photos.single.localPath, 'photos/r/p1.jpg');
    expect(decoded.createdAt, recipe.createdAt);
  });

  test('copyWith umí hodnotu smazat i ponechat', () {
    final recipe = sampleRecipe().copyWith(rating: 4.0);
    expect(recipe.copyWith(title: 'Jiný').rating, 4.0);
    expect(recipe.copyWith(rating: null).rating, isNull);
  });

  test('celkový čas se dopočítá z přípravy a vaření', () {
    expect(sampleRecipe().effectiveTotalMinutes, 660);
    expect(
      sampleRecipe().copyWith(totalMinutes: 700).effectiveTotalMinutes,
      700,
    );
  });

  test('přepočet porcí u surovin', () {
    final ribs = sampleRecipe().ingredients.first;
    expect(ribs.amountLabel(fromServings: 4, toServings: 4), '2 kg');
    expect(ribs.amountLabel(fromServings: 4, toServings: 6), '3 kg');
    expect(ribs.amountLabel(fromServings: 4, toServings: 1), '500 g');
    expect(sampleRecipe().ingredients.last.amountLabel(toServings: 8), '');
  });

  test('přepočet: lžíce zlomkem, vejce na celé kusy, rozsah v poznámce', () {
    const mustard = Ingredient(
      id: 'a',
      name: 'Hořčice',
      quantity: 2,
      unit: 'lžíce',
      note: 'nebo 2–3 lžíce dijonské',
    );
    expect(mustard.amountLabel(fromServings: 4, toServings: 3), '1 ½ lžíce');
    expect(
      mustard.noteLabel(fromServings: 4, toServings: 8),
      'nebo 4–6 lžíce dijonské',
    );
    expect(mustard.noteLabel(fromServings: 4, toServings: 4), mustard.note);

    const eggs = Ingredient(id: 'b', name: 'Vejce', quantity: 3, unit: 'ks');
    expect(eggs.amountLabel(fromServings: 4, toServings: 8), '6 ks');
    expect(
      eggs.amountLabel(fromServings: 4, toServings: 2),
      '2 ks (přesně 1,5)',
    );

    const garlic = Ingredient(id: 'c', name: '2–3 stroužky česneku');
    expect(
      garlic.nameLabel(fromServings: 4, toServings: 8),
      '4–6 stroužky česneku',
    );
    expect(
      mustard.nameLabel(fromServings: 4, toServings: 8),
      'Hořčice',
      reason: 'název suroviny s množstvím se nemění',
    );
  });

  test('výtěžnost v kusech a nová pole přežijí uložení do JSON', () {
    final dumplings = sampleRecipe().copyWith(
      servings: 12,
      yieldUnit: 'ks',
      restMinutes: 60,
      steps: const [
        RecipeStep(
          id: 's1',
          instruction: 'Nech kynout.',
          durationMinutes: 60,
          kind: 'passive',
        ),
        RecipeStep(
          id: 's2',
          instruction: 'Nakrájej housky.',
          durationMinutes: 10,
          parallel: true,
        ),
      ],
    );
    expect(dumplings.yieldText, '12 ks');
    final restored = Recipe.fromJson(dumplings.toJson());
    expect(restored.yieldUnit, 'ks');
    expect(restored.restMinutes, 60);
    expect(restored.steps.first.kind, 'passive');
    expect(restored.steps.last.parallel, isTrue);
    expect(restored.toShareText(), contains('Výtěžnost: 12 ks'));
  });

  test('starší recept bez nových polí se načte s výchozími hodnotami', () {
    final json = sampleRecipe().toJson()
      ..remove('yield_unit')
      ..remove('rest_minutes');
    for (final step in json['steps'] as List) {
      (step as Map)
        ..remove('kind')
        ..remove('parallel');
    }
    final recipe = Recipe.fromJson(json);
    expect(recipe.yieldUnit, 'porce');
    expect(recipe.yieldText, '4 porce');
    expect(recipe.restMinutes, 0);
    expect(recipe.steps.every((s) => s.kind == '' && !s.parallel), isTrue);
    expect(recipe.effectiveTotalMinutes, 660, reason: 'čas se nezmění');
  });

  test('celkový čas zahrne kynutí a marinování popsané jen v postupu', () {
    final pizza = sampleRecipe().copyWith(
      prepMinutes: 14,
      cookMinutes: 20,
      steps: const [
        RecipeStep(id: 's1', instruction: 'Zadělej těsto.'),
        RecipeStep(id: 's2', instruction: 'Nech kynout 20 hodin v lednici.'),
        RecipeStep(id: 's3', instruction: 'Vytvaruj a peč na kameni.'),
      ],
    );
    expect(pizza.effectiveTotalMinutes, 1234, reason: 'ne 34 minut');
    expect(pizza.timeBreakdown.passive, 1200);
    expect(pizza.toShareText(), contains('Celkový čas: 20 h 34 min'));

    final chicken = sampleRecipe().copyWith(
      prepMinutes: 20,
      cookMinutes: 120,
      steps: const [
        RecipeStep(id: 's1', instruction: 'Kuře nalož na 6 hodin do lednice.'),
        RecipeStep(id: 's2', instruction: 'Peč 2 hodiny při 180 °C.'),
      ],
    );
    expect(chicken.effectiveTotalMinutes, 500, reason: 'ne 140 minut');
    expect(chicken.timeBreakdown.cook, 120, reason: 'pečení jen jednou');
  });

  test('vyhledávání ignoruje diakritiku a hledá i v surovinách', () {
    final recipe = sampleRecipe();
    expect(recipe.matches('zebra'), isTrue);
    expect(recipe.matches('ŽEBRA bbq'), isTrue);
    expect(recipe.matches('horcice'), isTrue);
    expect(recipe.matches('maso'), isTrue);
    expect(recipe.matches('losos'), isFalse);
    expect(recipe.matches('  '), isTrue);
  });

  test('text pro sdílení obsahuje suroviny i postup', () {
    final text = sampleRecipe().toShareText();
    expect(text, contains('Žebra BBQ'));
    expect(text, contains('• 2 kg Vepřová žebra'));
    expect(text, contains('• Sůl'));
    expect(text, contains('2. Přikryjte alobalem a pečte.'));
    expect(text, contains('Celkový čas: 11 h'));
  });

  test('export neobsahuje cesty v telefonu ani vlastníka', () {
    final recipe = sampleRecipe(ownerId: 'user-1').copyWith(
      photos: const [RecipePhoto(id: 'p1', localPath: 'photos/r/p1.jpg')],
    );
    final json = jsonEncode(recipeExportJson(recipe));
    expect(json, isNot(contains('photos/r/p1.jpg')));
    expect(json, isNot(contains('user-1')));
    expect(json, contains('hinkredience.recipe'));
    expect(exportFileName('Svíčková na smetaně'), 'svickova-na-smetane');
    expect(exportFileName('???'), 'recept');
  });

  test('filtr: oblíbené, kategorie, nové', () {
    final a = sampleRecipe(id: 'a', title: 'Žebra BBQ');
    final b = sampleRecipe(
      id: 'b',
      title: 'Čočková polévka',
      category: 'Polévky',
    ).copyWith(isFavorite: true, createdAt: DateTime.utc(2026, 11, 10));
    final c = sampleRecipe(id: 'c', title: 'Bábovka', category: 'Pečení');
    final all = [a, b, c];

    expect(filterRecipes(all, filter: RecipeFilter.all).map((r) => r.title), [
      'Bábovka',
      'Čočková polévka',
      'Žebra BBQ',
    ]);
    expect(
      filterRecipes(all, filter: RecipeFilter.favorites).map((r) => r.id),
      ['b'],
    );
    expect(
      filterRecipes(
        all,
        filter: RecipeFilter.all,
        category: 'Maso',
      ).map((r) => r.id),
      ['a'],
    );
    expect(filterRecipes(all, filter: RecipeFilter.newest).first.id, 'b');
    expect(
      filterRecipes(
        all,
        filter: RecipeFilter.all,
        query: 'polevka',
      ).map((r) => r.id),
      ['b'],
    );
  });

  test('doporučení: oblíbené a nejlépe hodnocené napřed', () {
    final plain = sampleRecipe(id: 'plain');
    final rated = sampleRecipe(id: 'rated').copyWith(rating: 5.0);
    final favorite = sampleRecipe(id: 'fav').copyWith(isFavorite: true);
    expect(recommendRecipes([plain, rated, favorite]).map((r) => r.id), [
      'fav',
      'rated',
      'plain',
    ]);
  });

  test('řádek ze serveru se převede na recept se seřazenými částmi', () {
    final change = remoteChangeFromRow({
      'id': 'r1',
      'owner_id': 'user-1',
      'title': 'Kuře na paprice',
      'servings': 4,
      'photos': [
        {'id': 'p1', 'remote_path': 'user-1/r1/p1.jpg'},
      ],
      'created_at': '2026-11-01T10:00:00+00:00',
      'updated_at': '2026-11-02T10:00:00+00:00',
      'synced_at': '2026-11-02T10:00:05.123456+00:00',
      'deleted_at': null,
      'recipe_ingredients': [
        {
          'id': 'i2',
          'position': 1,
          'name': 'Smetana 31 %',
          'quantity': 250,
          'unit': 'ml',
        },
        {
          'id': 'i1',
          'position': 0,
          'name': 'Kuřecí stehna',
          'quantity': 1.2,
          'unit': 'kg',
        },
      ],
      'recipe_steps': [
        {'id': 's1', 'position': 0, 'instruction': 'Osmahněte cibuli.'},
      ],
      'recipe_versions': [
        {
          'id': 'v1',
          'version_number': 1,
          'snapshot': {'title': 'Kuře na paprice'},
          'change_summary': 'Původní postup',
          'created_at': '2026-11-01T10:00:00+00:00',
        },
      ],
    });
    expect(change.recipe.title, 'Kuře na paprice');
    expect(change.recipe.ingredients.map((i) => i.name), [
      'Kuřecí stehna',
      'Smetana 31 %',
    ]);
    expect(change.recipe.ingredients.first.quantity, 1.2);
    expect(change.recipe.photos.single.remotePath, 'user-1/r1/p1.jpg');
    expect(change.recipe.photos.single.localPath, isNull);
    expect(change.versions.single.versionNumber, 1);
    expect(change.syncedAt.isAfter(change.recipe.updatedAt), isTrue);
  });
}

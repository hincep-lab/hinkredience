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
    expect(ribs.amountLabel(fromServings: 4, toServings: 1), '0,5 kg');
    expect(sampleRecipe().ingredients.last.amountLabel(toServings: 8), '');
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

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/personalization.dart';
import 'package:hinkredience/data/kitchen_docs.dart';
import 'package:hinkredience/data/recipe.dart';

void main() {
  final saturday = DateTime(2026, 11, 14, 12);
  final tuesday = DateTime(2026, 11, 17, 12);

  Recipe recipe(
    String id, {
    String title = 'Recept',
    bool favorite = false,
    double? rating,
    int cook = 30,
    List<String> ingredients = const [],
    String step = '',
  }) => Recipe(
    id: id,
    title: title,
    createdAt: saturday,
    updatedAt: saturday,
    isFavorite: favorite,
    rating: rating,
    cookMinutes: cook,
    ingredients: [
      for (var i = 0; i < ingredients.length; i++)
        Ingredient(id: '$id-$i', name: ingredients[i], quantity: 1, unit: 'ks'),
    ],
    steps: step.isEmpty
        ? const []
        : [RecipeStep(id: '$id-s', instruction: step)],
  );

  CookingSession cooked(
    String recipeId,
    DateTime at, {
    double? rating,
    String toImprove = '',
    String notes = '',
  }) => CookingSession(
    id: '$recipeId-${at.millisecondsSinceEpoch}',
    recipeId: recipeId,
    recipeTitle: recipeId,
    status: SessionStatus.finished,
    cookedAt: at,
    updatedAt: at,
    rating: rating,
    toImprove: toImprove,
    notes: notes,
  );

  final pavel = TasteProfile.fromLabels(
    const [
      'Výraznější chuť',
      'Dobře ochucené maso',
      'Obliba pomalého vaření',
      'Obliba sous-vide',
      'Experimentování',
      'Recepty vhodné pro rodinu',
      'Možnost přípravy bez chilli',
    ],
    equipment: const ['Gorenje BPSAX6747A08BGWI', 'Rohnson R-2844'],
  );

  test('chutě z „Kuchyně a chutě“', () {
    expect(pavel.slowCooking, isTrue);
    expect(pavel.sousVide, isTrue);
    expect(pavel.noChilli, isTrue);
    expect(pavel.family, isTrue);
    expect(pavel.meat, isTrue);
    expect(TasteProfile.fromLabels(const ['Přesné gramáže']).sousVide, isFalse);
  });

  test('bez deníku a chutí: oblíbené, pak hodnocené', () {
    final result = recommend(
      recipes: [
        recipe('plain'),
        recipe('rated', rating: 5),
        recipe('fav', favorite: true),
      ],
      now: tuesday,
    );
    expect(result.map((r) => r.recipe.id), ['fav', 'rated', 'plain']);
  });

  test('doporučení podle deníku, chutí, vybavení a dne', () {
    final result = recommend(
      recipes: [
        recipe('vcera', favorite: true),
        recipe('davno', ingredients: const ['Hovězí líčka']),
        recipe(
          'sv',
          title: 'Sous-vide krkovice',
          cook: 240,
          step: 'Vložte do lázně Rohnson na 64 °C.',
        ),
        recipe('palive', ingredients: const ['Chilli paprička']),
      ],
      diary: [
        cooked('vcera', saturday.subtract(const Duration(days: 1))),
        cooked('davno', saturday.subtract(const Duration(days: 60)), rating: 5),
      ],
      profile: pavel,
      now: saturday,
    );
    expect(result.first.recipe.id, 'sv');
    expect(result.first.reasons.first, 'Sous-vide');
    expect(result.first.reasons, contains('Víkend – čas na delší vaření'));
    expect(result.first.reasons, contains('Na Rohnson R-2844'));
    expect(result.last.recipe.id, 'vcera', reason: 'vařilo se včera');
    final old = result.firstWhere((r) => r.recipe.id == 'davno');
    expect(old.reasons.first, 'Dlouho jste nevařili (2 měsíce)');
    expect(old.reasons, contains('Minule se povedlo'));
    final hot = result.firstWhere((r) => r.recipe.id == 'palive');
    expect(hot.reasons, contains('Jde i bez chilli'));
  });

  test('ve všední den rychlé recepty napřed', () {
    final result = recommend(
      recipes: [recipe('dlouhy', cook: 300), recipe('rychly', cook: 25)],
      now: tuesday,
    );
    expect(result.first.recipe.id, 'rychly');
    expect(result.first.reasons, ['Rychlé na všední den']);
  });

  test('pálivé suroviny a varianta bez chilli', () {
    for (final name in [
      'Chilli paprička',
      'Feferonky',
      'Pálivá paprika mletá',
      'Kajenský pepř',
      'Sriracha',
      'Jalapeño',
    ]) {
      expect(isChilliIngredient(name), isTrue, reason: name);
    }
    for (final name in [
      'Sladká paprika mletá',
      'Červená paprika',
      'Černý pepř',
      'Paprikový olej',
      'Cibule',
    ]) {
      expect(isChilliIngredient(name), isFalse, reason: name);
    }
    final hot = recipe(
      'h',
      ingredients: const ['Cibule', 'Chilli paprička', 'Pálivá paprika mletá'],
    );
    expect(recipeHasChilli(hot), isTrue);
    final mild = withoutChilli(hot);
    expect(mild.ingredients.map((i) => i.name), [
      'Cibule',
      'Sladká paprika mletá',
    ]);
    expect(mild.ingredients.last.note, 'místo pálivé');
    expect(recipeHasChilli(mild), isFalse);
    expect(hot.ingredients.length, 3, reason: 'původní recept se nemění');
  });

  test('připomínka z deníku: nejnovější zápis s radou', () {
    final diary = [
      cooked(
        'r',
        saturday.subtract(const Duration(days: 30)),
        toImprove: 'Víc soli a kratší pečení',
        rating: 4,
      ),
      cooked('r', saturday.subtract(const Duration(days: 2))),
      cooked('jiny', saturday, toImprove: 'Nic'),
    ];
    final reminder = diaryReminder('r', diary)!;
    expect(reminder.toImprove, 'Víc soli a kratší pečení');
    expect(reminder.times, 2);
    expect(reminder.rating, 4);
    expect(diaryReminder('r', [cooked('r', saturday)]), isNull);
  });
}

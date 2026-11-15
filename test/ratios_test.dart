import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/ratios.dart';
import 'package:hinkredience/data/recipe.dart';

void main() {
  const meat = Ingredient(
    id: 'm',
    name: 'Kuřecí stehna s kostí',
    quantity: 800,
    unit: 'g',
  );
  const onion = Ingredient(id: 'o', name: 'Cibule', quantity: 200, unit: 'g');
  const cream = Ingredient(
    id: 'c',
    name: 'Smetana 31 %',
    quantity: 0.5,
    unit: 'l',
  );
  const salt = Ingredient(id: 's', name: 'Sůl');
  final recipe = Recipe(
    id: 'r',
    title: 'Kuře na paprice',
    servings: 4,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    ingredients: const [meat, onion, cream, salt],
  );

  test('skutečné množství přepočítá porce (i jiná jednotka)', () {
    expect(
      servingsForActual(
        ingredient: meat,
        recipeServings: 4,
        actual: 1.2,
        actualUnit: 'kg',
      ),
      6,
    );
    expect(
      servingsForActual(ingredient: meat, recipeServings: 4, actual: 730),
      3.65,
    );
    expect(
      servingsForActual(
        ingredient: meat,
        recipeServings: 4,
        actual: 2,
        actualUnit: 'ks',
      ),
      isNull,
      reason: 'kusy nejde převést na gramy',
    );
    expect(
      servingsForActual(ingredient: salt, recipeServings: 4, actual: 5),
      isNull,
    );
  });

  test('poměry vůči hlavní surovině', () {
    expect(mainIngredient(recipe), meat);
    expect(ratioBaseLabel(meat), 'na 100 g');
    final perOnion = ratioPer(onion, meat)!;
    expect(perOnion.quantity, 25);
    expect(perOnion.unit, 'g');
    expect(ratioPer(salt, meat), isNull);
  });

  test('suroviny v kroku i se skloňováním', () {
    const step = RecipeStep(
      id: 's1',
      instruction: 'Přidejte cibuli a zalijte smetanou.',
    );
    expect(ingredientsInStep(step, recipe.ingredients), [onion, cream]);
    const other = RecipeStep(id: 's2', instruction: 'Podávejte s knedlíkem.');
    expect(ingredientsInStep(other, recipe.ingredients), isEmpty);
  });
}

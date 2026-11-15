import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/recipe_text.dart';

void main() {
  test('text receptu s nadpisy, porcemi, časy a teplotou', () {
    final recipe = parseRecipeText('''Kuře na paprice
Na 4 porce

Suroviny:
- 1,5 kg kuřecích stehen
- 2 cibule
- 500 ml smetany (31 %)
- ½ lžičky pepře
- sůl podle chuti

Postup:
1. Maso osolte a opečte dozlatova, asi 10 minut.
2. Přidejte cibuli a duste 1 hodinu při 160 °C.
''')!;
    expect(recipe.title, 'Kuře na paprice');
    expect(recipe.servings, 4);
    expect(recipe.ingredients.map((i) => i.name), [
      'kuřecích stehen',
      'cibule',
      'smetany',
      'pepře',
      'sůl podle chuti',
    ]);
    expect(recipe.ingredients.first.quantity, 1.5);
    expect(recipe.ingredients.first.unit, 'kg');
    expect(recipe.ingredients[2].note, '31 %');
    expect(recipe.ingredients[3].quantity, 0.5);
    expect(recipe.ingredients.last.quantity, isNull);
    expect(recipe.steps.length, 2);
    expect(recipe.steps.first.durationMinutes, 10);
    expect(recipe.steps.last.durationMinutes, 60);
    expect(recipe.steps.last.temperatureC, 160);
  });

  test('text z fotky bez nadpisů', () {
    final recipe = parseRecipeText(
      'BRAMBOROVÁ KAŠE\n1 kg brambor\n100 g másla\n200 ml mléka\n'
      'Brambory oloupejte a uvařte doměkka v osolené vodě, asi 20 min.\n'
      'Rozmačkejte s máslem a teplým mlékem.',
    )!;
    expect(recipe.title, 'BRAMBOROVÁ KAŠE');
    expect(recipe.ingredients.length, 3);
    expect(recipe.steps.length, 2);
  });

  test('text bez receptu', () {
    expect(parseRecipeText(''), isNull);
    expect(parseRecipeText('Ahoj, jak se máš?'), isNull);
  });
}

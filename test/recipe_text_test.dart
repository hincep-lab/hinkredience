import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/ocr_common.dart';
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

  test('text přečtený z fotky: odrážky, šum a záměny písmen', () {
    // Skutečný výstup čtečky textu z fotky receptu (Tesseract, čeština).
    const ocr = r'''
Z o EEEEEEENEE
Kuře na paprice
4 porce » 60 minut
Suroviny:
« 800 g kuřecích stehen
* 2 cibule
+ 2 |žíce sladké papriky
« 1 lžíce hladké mouky
« 250 ml smetany ke šlehání
* 300 ml vody
* 2 Ižíce oleje
+ sůl podle chuti
Postup:
1. Cibuli nakrájejte nadrobno a osmahněte na oleji.
2. Přidejte kuřecí stehna a opečte je ze všech stran.
3. Zasypte paprikou, krátce promíchejte a podlijte vodou.
4. Duste pod pokličkou asi 40 minut doměkka.
5. Smetanu rozmíchejte s moukou, vlijte do omáčky
a povařte 5 minut. Osolte a podávejte s knedlíkem.
o EEE''';
    final r = parseRecipeText(ocr)!;
    expect(r.title, 'Kuře na paprice');
    expect(r.servings, 4);
    expect(
      r.ingredients.map(
        (i) => '${i.quantity ?? ''} ${i.unit} ${i.name}'.trim(),
      ),
      [
        '800.0 g kuřecích stehen',
        '2.0 ks cibule',
        '2.0 lžíce sladké papriky',
        '1.0 lžíce hladké mouky',
        '250.0 ml smetany ke šlehání',
        '300.0 ml vody',
        '2.0 lžíce oleje',
        'sůl podle chuti',
      ],
    );
    expect(r.steps.length, 5);
    expect(
      r.steps.last.instruction,
      'Smetanu rozmíchejte s moukou, vlijte do omáčky a povařte 5 minut. '
      'Osolte a podávejte s knedlíkem.',
    );
    expect(r.steps[3].durationMinutes, 40);
  });

  test('formát obrázku podle hlavičky', () {
    expect(imageFormatOf([0xFF, 0xD8, 0xFF, 0xE0]), 'jpeg');
    expect(imageFormatOf([0x89, 0x50, 0x4E, 0x47, 0x0D]), 'png');
    expect(
      imageFormatOf([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65]),
      'heic',
    );
    expect(imageFormatOf('tohle není obrázek'.codeUnits), isNull);
    expect(imageFormatOf([]), isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/equipment_fit.dart';
import 'package:hinkredience/core/personalization.dart';
import 'package:hinkredience/data/recipe.dart';

/// Vybavení přesně tak, jak je uložené v aplikaci (Kuchyně a chutě).
const kitchen = [
  Appliance(
    name: 'Gorenje BPSAX6747A08BGWI',
    kind: 'trouba',
    detail:
        'SteamAssist – přídavná pára · Teploty až 300 °C · Teplotní sonda · '
        'AutoBake · Pizza program',
  ),
  Appliance(
    name: 'Fabini Mattia 26 cm / 5,5 l',
    kind: 'hrnec',
    detail: 'Vaření · Dušení',
  ),
  Appliance(
    name: 'Fabini nerezová pánev 26 cm',
    kind: 'pánev',
    detail: 'Restování · Opékání',
  ),
  Appliance(
    name: 'ETA Gratussino III Maxo',
    kind: 'kuchyňský robot',
    detail: 'Hnětení těsta · Míchání',
  ),
  Appliance(
    name: 'Electrolux Pizza Expert Kit E9OOPE01',
    kind: 'pizza sada',
    detail: 'Pečení pizzy na kameni',
  ),
  Appliance(
    name: 'Tesla EliteCook K70',
    kind: 'multifunkční hrnec',
    detail: 'Vaření v multifunkčním hrnci',
  ),
];

Recipe recipe(
  String title, {
  List<String> tags = const [],
  List<String> steps = const [],
  List<double?> temps = const [],
  List<String> equipment = const [],
  int cook = 0,
}) => Recipe(
  id: title,
  title: title,
  tags: tags,
  equipment: equipment,
  cookMinutes: cook,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  steps: [
    for (final (i, text) in steps.indexed)
      RecipeStep(
        id: 's$i',
        instruction: text,
        temperatureC: i < temps.length ? temps[i] : null,
      ),
  ],
);

void main() {
  test('vybavení se pozná z uloženého názvu, druhu a schopností', () {
    final oven = kitchen[0];
    expect(oven.isOven, isTrue);
    expect(oven.hasSteam, isTrue);
    expect(oven.hasProbe, isTrue);
    expect(oven.hasPizzaProgram, isTrue);
    expect(oven.maxTemperature, 300);
    expect(kitchen[1].isPot, isTrue);
    expect(kitchen[1].litres, 5.5);
    expect(kitchen[2].isPan, isTrue);
    expect(kitchen[2].isPot, isFalse);
    expect(kitchen[3].isMixer, isTrue);
    expect(kitchen[4].isPizzaStone, isTrue);
    expect(kitchen[5].isMultiCooker, isTrue);
    expect(kitchen[5].isPot, isFalse);
  });

  test('pečivo: robot na těsto, pára a trouba', () {
    final fit = equipmentFit(
      recipe(
        'Domácí máslové rohlíky',
        tags: ['Trouba'],
        steps: [
          'Hněť těsto 10 minut do hladka.',
          'Nech kynout 60 minut.',
          'Peč na 220 °C dozlatova.',
        ],
        temps: [null, null, 220],
      ),
      kitchen,
    );
    expect(fit.fits, isTrue);
    final texts = fit.tips.map((t) => t.text).join(' | ');
    expect(texts, contains('ETA Gratussino III Maxo'));
    expect(texts, contains('SteamAssist'));
    expect(texts, contains('Gorenje'));
  });

  test('maso s teplotou uvnitř: teplotní sonda', () {
    final fit = equipmentFit(
      recipe(
        'Kuře naplacato',
        tags: ['Trouba'],
        steps: ['Pečte, až prsa uvnitř dosáhnou 74 °C.'],
      ),
      kitchen,
    );
    expect(fit.tips.map((t) => t.text).join(), contains('sonda'));
  });

  test('pizza: kámen Electrolux a pizza program', () {
    final fit = equipmentFit(
      recipe('Pizza Margherita', steps: ['Pečte na 300 °C.'], temps: [300]),
      kitchen,
    );
    final texts = fit.tips.map((t) => t.text).join(' | ');
    expect(texts, contains('Electrolux Pizza Expert Kit'));
    expect(texts, contains('pizza program'));
    expect(fit.fits, isTrue);
  });

  test('co chybí: vaflovač, sous-vide, větší hrnec, vyšší teplota', () {
    expect(equipmentFit(recipe('Vafle', tags: ['Vaflovač']), kitchen).missing, [
      'Vaflovač',
    ]);
    expect(
      equipmentFit(
        recipe('Losos sous-vide', tags: ['Sous-vide', 'Pánev']),
        kitchen,
      ).missing.single,
      startsWith('Sous-vide'),
    );
    final pho = equipmentFit(
      recipe(
        'Phở bò',
        tags: ['Pomalé vaření'],
        equipment: ['Velký hrnec aspoň 8–10 l'],
      ),
      kitchen,
    );
    expect(pho.missing.single, contains('Hrnec aspoň 8 l'));
    final hot = equipmentFit(
      recipe('Neapolská pizza', steps: ['Pečte na 450 °C.'], temps: [450]),
      kitchen,
    );
    expect(hot.missing.single, contains('450 °C'));
  });

  test('dušení: hrnec Fabini a multifunkční hrnec Tesla', () {
    final fit = equipmentFit(
      recipe('Guláš', tags: ['Hrnec'], steps: ['Duste 2 hodiny doměkka.']),
      kitchen,
    );
    final texts = fit.tips.map((t) => t.text).join(' | ');
    expect(texts, contains('Fabini Mattia'));
    expect(texts, contains('Tesla EliteCook K70'));
  });

  test('bez uloženého vybavení se nic nepředstírá', () {
    expect(equipmentFit(recipe('Vafle', tags: ['Vaflovač']), []).isEmpty, true);
  });

  test('doporučení: recept, na který chybí vybavení, je níž', () {
    final waffles = recipe('Vafle', tags: ['Vaflovač']);
    final bread = recipe(
      'Rohlíky',
      tags: ['Trouba'],
      steps: ['Hněť těsto 10 minut.', 'Peč na 220 °C.'],
      temps: [null, 220],
    );
    final profile = TasteProfile.fromLabels(const [], appliances: kitchen);
    final result = recommend(
      recipes: [waffles, bread],
      diary: const [],
      profile: profile,
      now: DateTime.utc(2026, 11, 18, 12),
    );
    expect(result.first.recipe.title, 'Rohlíky');
    expect(result.first.reasons, contains('Využije ETA Gratussino'));
  });
}

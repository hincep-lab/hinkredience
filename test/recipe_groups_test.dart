import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/recipe_groups.dart';
import 'package:hinkredience/data/recipe.dart';

Recipe r(
  String title, {
  String category = '',
  List<String> ingredients = const [],
  List<String> steps = const [],
  List<String> temperatures = const [],
  List<String> tags = const [],
  int prep = 0,
  int cook = 0,
  int rest = 0,
  int total = 0,
}) => Recipe(
  id: title,
  title: title,
  category: category,
  prepMinutes: prep,
  cookMinutes: cook,
  restMinutes: rest,
  totalMinutes: total,
  temperatures: temperatures,
  tags: tags,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  ingredients: [
    for (final (i, name) in ingredients.indexed)
      Ingredient(id: 'i$i', name: name),
  ],
  steps: [
    for (final (i, text) in steps.indexed)
      RecipeStep(id: 's$i', instruction: text),
  ],
);

void main() {
  test('je přesně 11 skupin podle zadání', () {
    expect(recipeGroups.map((g) => g.label), [
      'Hovězí maso',
      'Vepřové maso',
      'Drůbež a králík',
      'Ryby',
      'Polévky',
      'Omáčky',
      'Těstoviny a rýže',
      'Bezmasá jídla',
      'Přílohy',
      'Sladká jídla a dezerty',
      'Pečivo a těsta',
    ]);
  });

  test('zařazení podle kategorie, názvu a surovin (skutečné recepty)', () {
    String g(Recipe recipe) => groupOf(recipe).id;
    expect(
      g(r('Pomalu pečený králík s vepřovou krkovicí', category: 'Maso')),
      'drubez',
    );
    expect(
      g(r('Vepřová panenka sous-vide 58 °C', category: 'Maso')),
      'veprove',
    );
    expect(g(r('Svíčková na smetaně', category: 'Maso')), 'hovezi');
    expect(
      g(
        r(
          'Sekaná pečeně s bramborovou kaší',
          category: 'Maso',
          ingredients: ['Mleté maso'],
        ),
      ),
      'hovezi',
    );
    expect(g(r('Kuře na paprice 2.0', category: 'Omáčky')), 'omacky');
    expect(g(r('Losos sous-vide 43 °C', category: 'Ryby')), 'ryby');
    expect(g(r('Kuřecí vývar s nudlemi', category: 'Polévky')), 'polevky');
    expect(g(r('Máslová tvarohová bábovka', category: 'Dezerty')), 'sladka');
    expect(g(r('Krupičná kaše', category: 'Sladká jídla')), 'sladka');
    expect(g(r('Domácí máslové rohlíky', category: 'Pečivo')), 'pecivo');
    expect(g(r('Těstoviny carbonara', category: 'Těstoviny')), 'testoviny');
    expect(g(r('Babiččin okurkový salát', category: 'Přílohy')), 'prilohy');
    expect(g(r('Smažený sýr', category: 'Bezmasá jídla')), 'bezmasa');
    expect(
      g(
        r(
          'Zapečený květák s bramborem',
          category: 'Zapékaná jídla',
          ingredients: ['Květák', 'Sýr'],
        ),
      ),
      'bezmasa',
    );
    expect(
      g(
        r(
          'Bramborová musaka',
          category: 'Zapékaná jídla',
          ingredients: ['Mleté maso', 'Brambory'],
        ),
      ),
      'hovezi',
    );
    expect(g(r('Kuřecí řízky', category: 'Drůbež')), 'drubez');
    // Okurky nejsou kuře.
    expect(
      g(
        r(
          'Znojemská pečeně',
          category: 'Maso',
          ingredients: ['Hovězí kýta', 'Sterilované okurky'],
        ),
      ),
      'hovezi',
    );
    expect(g(r('Špagety po boloňsku', category: 'Těsta')), 'testoviny');
    expect(g(r('Pizza Margherita', category: 'Pizza')), 'pecivo');
  });

  test('způsob přípravy se pozná z textu, „opečte“ není trouba', () {
    final pan = r('Plátky', steps: ['Maso opečte na pánvi.']);
    expect(prepMethodsOf(pan), {PrepMethod.pan});
    final oven = r('Pečená stehna', temperatures: ['Trouba 200 °C']);
    expect(prepMethodsOf(oven), contains(PrepMethod.oven));
    final tomatoes = r('Boloňská', ingredients: ['Rajčata z plechovky']);
    expect(prepMethodsOf(tomatoes), isNot(contains(PrepMethod.oven)));
    final sv = r('Losos', steps: ['Vařte sous-vide při 43 °C.']);
    expect(prepMethodsOf(sv), contains(PrepMethod.sousVide));
    final slow = r('Trhaná krkovice', cook: 660);
    expect(prepMethodsOf(slow), contains(PrepMethod.slow));
    // Dlouhé kynutí není pomalé vaření.
    final dough = r('Buchty', prep: 50, cook: 35, rest: 95);
    expect(prepMethodsOf(dough), isNot(contains(PrepMethod.slow)));
  });

  test('časové filtry počítají i čekání a nevymýšlejí neznámý čas', () {
    expect(
      matchesTime(r('Rychlé', prep: 10, cook: 15), TimeFilter.upTo30),
      isTrue,
    );
    expect(
      matchesTime(r('Kynuté', prep: 20, cook: 20, rest: 60), TimeFilter.upTo60),
      isFalse,
    );
    expect(
      matchesTime(r('Kynuté', prep: 20, cook: 20, rest: 60), TimeFilter.h1to3),
      isTrue,
    );
    final unknown = r('Bez času');
    for (final t in TimeFilter.values) {
      expect(matchesTime(unknown, t), isFalse, reason: t.label);
      expect(
        matchesTime(unknown, t, mode: TimeMode.active),
        isFalse,
        reason: t.label,
      );
    }
    expect(timeLabelOf(unknown), 'Čas neuveden');
    expect(totalMinutesOf(unknown), isNull);
  });

  test('hranice časových pásem', () {
    bool hit(int minutes, TimeFilter f) => f.accepts(minutes);
    expect(hit(15, TimeFilter.upTo15), isTrue);
    expect(hit(16, TimeFilter.upTo15), isFalse);
    expect(hit(30, TimeFilter.upTo30), isTrue);
    expect(hit(60, TimeFilter.upTo60), isTrue);
    expect(hit(60, TimeFilter.h1to3), isFalse);
    expect(hit(61, TimeFilter.h1to3), isTrue);
    expect(hit(180, TimeFilter.h1to3), isTrue);
    expect(hit(180, TimeFilter.over3), isFalse);
    expect(hit(181, TimeFilter.over3), isTrue);
  });

  // Skutečná data receptu z databáze (Losos sous-vide 43 °C).
  Recipe losos({List<String> tags = const []}) => Recipe(
    id: 'losos',
    title: 'Losos sous-vide 43 °C',
    category: 'Ryby',
    prepMinutes: 10,
    cookMinutes: 32,
    tags: tags,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    ingredients: const [Ingredient(id: 'i', name: 'Losos')],
    steps: const [
      RecipeStep(
        id: 's0',
        instruction:
            'Lososa osušte, lehce osolte, přidejte kopr, salotku na platky, '
            'zlutou kuru z citronu a vložte do sáčku vhodného pro sous-vide.',
      ),
      RecipeStep(
        id: 's1',
        instruction: 'Připravujte ve vodní lázni při 43 °C po dobu 30 minut.',
        durationMinutes: 30,
      ),
      RecipeStep(
        id: 's2',
        instruction:
            'Opatrně vyjměte, osušte a krátce opečte na rozpálené pánvi, '
            'přibližně minutu na straně, aby se nerozpadl.',
        durationMinutes: 2,
      ),
      RecipeStep(id: 's3', instruction: 'Ihned podávejte.'),
    ],
  );

  test('Losos sous-vide: 42 min celkem, Sous-vide + Do 60 min ho najde', () {
    // Dřív se krok „ve vodní lázni 30 minut“ počítal jako ruční práce
    // a přičetl se k vaření → 62 min a filtr Do 60 min recept vynechal.
    final fish = losos();
    expect(fish.timeBreakdown.cook, 32);
    expect(fish.timeBreakdown.active, 10);
    expect(totalMinutesOf(fish), 42);
    expect(inferPrepMethods(fish), {PrepMethod.sousVide, PrepMethod.pan});

    const filters = RecipeFilters(
      prep: {PrepMethod.sousVide},
      times: {TimeFilter.upTo60},
    );
    expect(filters.apply([fish]), [fish]);
    expect(
      filters.apply([
        losos(tags: const ['Sous-vide', 'Pánev']),
      ]),
      hasLength(1),
    );
    expect(
      const RecipeFilters(
        prep: {PrepMethod.sousVide},
        times: {TimeFilter.upTo30},
      ).reasonsAgainst(fish),
      ['celkový čas 42 min'],
    );
  });

  test('Vepřová panenka sous-vide: přes 2 hodiny celkem', () {
    final pork = r(
      'Vepřová panenka sous-vide 58 °C',
      prep: 15,
      cook: 125,
      steps: [
        'Panenku očistěte, osolte, opepřete a zavakuujte.',
        'Vařte ve vodní lázni sous-vide při 58 °C po dobu 2 hodin.',
        'Vyjměte, osušte a na rozpálené pánvi krátce opečte.',
      ],
    );
    expect(totalMinutesOf(pork), 140);
    expect(matchesTime(pork, TimeFilter.upTo60), isFalse);
    expect(matchesTime(pork, TimeFilter.h1to3), isTrue);
    expect(prepMethodsOf(pork), {PrepMethod.sousVide, PrepMethod.pan});
  });

  test('Trhaná krkovice: hodiny pečení, ale krátká aktivní práce', () {
    final pulled = r(
      'Trhaná vepřová krkovice – pomalé pečení',
      prep: 20,
      cook: 660,
      rest: 10,
    );
    expect(matchesTime(pulled, TimeFilter.over3), isTrue);
    expect(matchesTime(pulled, TimeFilter.upTo30), isFalse);
    expect(
      matchesTime(pulled, TimeFilter.upTo30, mode: TimeMode.active),
      isTrue,
    );
    expect(timeLabelOf(pulled, mode: TimeMode.active), 'aktivně 20 min');
    const byActive = RecipeFilters(
      times: {TimeFilter.upTo30},
      timeMode: TimeMode.active,
    );
    expect(byActive.apply([pulled]), [pulled]);
    expect(prepMethodsOf(pulled), contains(PrepMethod.slow));
  });

  test('uložené způsoby přípravy mají přednost před odhadem', () {
    final fish = losos(tags: const ['Sous-vide']);
    expect(prepMethodsOf(fish), {PrepMethod.sousVide});
    expect(savedPrepMethods(fish), {PrepMethod.sousVide});
    // Recept bez uloženého způsobu přípravy se odhadne z postupu.
    expect(savedPrepMethods(losos()), isEmpty);
    expect(prepMethodsOf(losos()), contains(PrepMethod.pan));
    // Jeden recept může mít víc způsobů přípravy.
    final both = r('Zapečené', tags: ['Trouba', 'Pánev']);
    expect(prepMethodsOf(both), {PrepMethod.oven, PrepMethod.pan});
  });

  test('vaflovač není trouba, špekáček není pekáč', () {
    expect(
      inferPrepMethods(
        r('Vafle', steps: ['Pečte ve vyhřátém vaflovači 5 minut.']),
      ),
      isNot(contains(PrepMethod.oven)),
    );
    expect(
      inferPrepMethods(r('Guláš', ingredients: ['Špekáček'])),
      isNot(contains(PrepMethod.oven)),
    );
  });

  test('příležitost jen ze štítků, v jedné skupině OR, mezi skupinami AND', () {
    final kids = r('Kaše', tags: ['Pro děti'], prep: 5, cook: 10);
    final party = r('Svíčková', tags: ['Slavnostní jídlo'], cook: 200);
    final none = r('Guláš', cook: 120);
    final all = [kids, party, none];
    expect(const RecipeFilters(occasions: {'Pro děti'}).apply(all), [kids]);
    expect(
      const RecipeFilters(occasions: {'Pro děti', 'Slavnostní jídlo'})
          .apply(all),
      [kids, party],
    );
    expect(
      const RecipeFilters(
        occasions: {'Pro děti', 'Slavnostní jídlo'},
        times: {TimeFilter.h1to3, TimeFilter.over3},
      ).apply(all),
      [party],
    );
    expect(const RecipeFilters(query: 'gulas').apply(all), [none]);
    expect(const RecipeFilters(tag: 'pro deti').apply(all), [kids]);
  });

  test('Drůbež a králík + Pro děti + Do 60 minut', () {
    final chickenKids = r(
      'Kuřecí karbanátky',
      category: 'Drůbež a králík',
      tags: ['Pro děti'],
      prep: 25,
      cook: 30,
    );
    final chickenSlow = r(
      'Pečené kuře',
      category: 'Drůbež a králík',
      tags: ['Pro děti'],
      prep: 30,
      cook: 110,
    );
    final porkKids = r(
      'Vepřový řízek',
      category: 'Vepřové maso',
      tags: ['Pro děti'],
      prep: 15,
      cook: 25,
    );
    final chickenAdults = r(
      'Kuřecí kari',
      category: 'Drůbež a králík',
      prep: 15,
      cook: 25,
    );
    final all = [chickenKids, chickenSlow, porkKids, chickenAdults];
    const filters = RecipeFilters(
      groups: {'drubez'},
      occasions: {'Pro děti'},
      times: {TimeFilter.upTo60},
    );
    expect(filters.apply(all), [chickenKids]);
    expect(filters.count, 3);
    // Proč ostatní nevyhovují – každému chybí právě jedna podmínka.
    final misses = {
      for (final (recipe, reason) in filters.nearMisses(all))
        recipe.title: reason,
    };
    expect(misses['Pečené kuře'], 'celkový čas 2 h 20 min');
    expect(misses['Vepřový řízek'], 'patří do kategorie Vepřové maso');
    expect(misses['Kuřecí kari'], 'nemá štítek Pro děti');
    expect(misses.containsKey('Kuřecí karbanátky'), isFalse);
    // Dvě kategorie = kterákoli z nich.
    expect(
      const RecipeFilters(
        groups: {'drubez', 'veprove'},
        occasions: {'Pro děti'},
        times: {TimeFilter.upTo60},
      ).apply(all),
      [chickenKids, porkKids],
    );
    expect(filters.cleared().isEmpty, isTrue);
  });

  test('recept bez času vysvětlí, proč chybí', () {
    final unknown = r('Bez času', tags: ['Sous-vide']);
    const filters = RecipeFilters(
      prep: {PrepMethod.sousVide},
      times: {TimeFilter.upTo60},
    );
    expect(filters.apply([unknown]), isEmpty);
    expect(filters.reasonsAgainst(unknown), ['čas neuveden']);
  });

  test('štítky: stejné bez diakritiky, starší „Na víc dní“ platí', () {
    expect(occasionTags, hasLength(7));
    expect(sameTag('pro deti', 'Pro děti'), isTrue);
    expect(hasTag(r('Guláš', tags: ['Na víc dní']), 'Na více dní'), isTrue);
    expect(toggleTag(['Pro děti'], 'pro deti', false), isEmpty);
    expect(toggleTag(['Pro děti'], 'Trouba', true), ['Pro děti', 'Trouba']);
    expect(toggleTag(['Trouba'], 'Trouba', true), ['Trouba']);
    expect(PrepMethod.fromTag('sous-vide'), PrepMethod.sousVide);
    expect(PrepMethod.fromTag('Grilovačka'), isNull);
  });

  test('hledání prohledává i štítky', () {
    expect(r('Kaše', tags: ['Pro děti']).matches('pro deti'), isTrue);
  });

  test('počty ve skupinách a skloňování', () {
    final counts = groupCounts([
      r('Svíčková', category: 'Maso'),
      r('Guláš hovězí', category: 'Maso'),
      r('Vývar', category: 'Polévky'),
    ]);
    expect(counts['hovezi'], 2);
    expect(counts['polevky'], 1);
    expect(counts.values.reduce((a, b) => a + b), 3);
    expect(receptyCount(1), '1 recept');
    expect(receptyCount(3), '3 recepty');
    expect(receptyCount(5), '5 receptů');
    expect(receptyCount(0), '0 receptů');
  });

  test('štítky se ukládají do JSON a zpět', () {
    final recipe = r('Kaše', tags: ['Pro děti', 'Nepálivé']);
    expect(Recipe.fromJson(recipe.toJson()).tags, ['Pro děti', 'Nepálivé']);
    final legacy = r('Bez štítků').toJson()..remove('tags');
    expect(Recipe.fromJson(legacy).tags, isEmpty);
    expect(
      tagCounts([
        recipe,
        r('Jiné', tags: ['pro děti']),
      ]).first.value,
      2,
    );
  });
}

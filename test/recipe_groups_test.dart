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
      matchesTime(r('Kynuté', prep: 20, cook: 20, rest: 60), TimeFilter.longer),
      isTrue,
    );
    final unknown = r('Bez času');
    for (final t in TimeFilter.values) {
      expect(matchesTime(unknown, t), isFalse, reason: t.label);
    }
  });

  test('příležitost jen ze štítků, filtry se kombinují', () {
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
        time: TimeFilter.longer,
      ).apply(all),
      [party],
    );
    expect(const RecipeFilters(query: 'gulas').apply(all), [none]);
    expect(const RecipeFilters(tag: 'pro deti').apply(all), [kids]);
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

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/sale_dishes.dart';

PriceOffer offer(
  String chain,
  String product,
  double price, {
  double? regular,
  bool verified = true,
  DateTime? validTo,
}) => PriceOffer(
  id: '$chain-$product-$price',
  chain: chain,
  product: product,
  price: price,
  regularPrice: regular,
  validTo: validTo ?? DateTime(2026, 11, 22),
  sourceUrl: 'https://www.$chain.cz/letak',
  verified: verified,
);

void main() {
  final today = DateTime(2026, 11, 17);

  test('položky z letáku se zařadí do správných skupin', () {
    expect(groupOf('Vepřová krkovice bez kosti'), 'veprove');
    expect(groupOf('Vepřová plec'), 'veprove');
    expect(groupOf('Vepřová šunka nejvyšší jakosti'), 'sunka');
    expect(groupOf('Mleté vepřové maso'), 'mlete');
    expect(groupOf('Kuřecí prsní řízky'), 'kure');
    expect(groupOf('Kuřecí šunka'), 'sunka');
    expect(groupOf('Kuřecí paštika'), isNull);
    expect(groupOf('Hovězí zadní bez kosti'), 'hovezi');
    expect(groupOf('Smetana ke šlehání 31 %'), 'smetana');
    expect(groupOf('Zakysaná smetana'), 'smetana');
    expect(groupOf('Eidam 30 %'), 'syr');
    expect(groupOf('Brambory konzumní 2 kg'), 'brambory');
    expect(groupOf('Bramborové chips'), isNull);
    expect(groupOf('Špagety'), 'testoviny');
    expect(groupOf('Máslo 82 %'), 'maslo');
    expect(groupOf('Pomazánkové máslo'), isNull);
    expect(groupOf('Krmivo pro psy s kuřecím'), isNull);
    expect(groupOf('Prací gel'), isNull);
  });

  test('z vepřového, smetany a brambor v akci navrhne zapečené maso', () {
    final dishes = dishesFromSales([
      offer('penny', 'Vepřová plec', 119.9, regular: 159.9),
      offer('lidl', 'Smetana ke šlehání 31 %', 24.9, regular: 34.9),
      offer('albert', 'Brambory konzumní 2 kg', 29.9),
      offer('tesco', 'Eidam 30 %', 99.9),
    ], today);
    expect(dishes, isNotEmpty);
    final first = dishes.first;
    expect(first.dish.id, 'zapecene-veprove');
    expect(
      first.onSale.keys,
      containsAll(['veprove', 'brambory', 'smetana', 'syr']),
    );
    expect(first.savings, closeTo(50, 0.01));
    // Kuřecí jídla bez kuřecího v akci se nenabízejí.
    expect(
      dishes.where(
        (d) => d.dish.main.contains('kure') && d.dish.main.length == 1,
      ),
      isEmpty,
    );
  });

  test('neověřené a prošlé akce se nepočítají', () {
    final dishes = dishesFromSales([
      offer('penny', 'Vepřová plec', 119.9, verified: false),
      offer('lidl', 'Kuřecí prsa', 99.9, validTo: DateTime(2026, 11, 10)),
    ], today);
    expect(dishes, isEmpty);
  });

  test('ve skupině se bere nejlevnější akce', () {
    final groups = offersByGroup([
      offer('penny', 'Kuřecí stehna', 79.9),
      offer('lidl', 'Kuřecí prsní řízky', 149.9),
    ], today);
    expect(groups['kure']!.first.chain, 'penny');
  });

  test('hledá se nejvýš 20 slov a všechna jídla mají známé skupiny', () {
    final terms = saleSearchTerms();
    expect(terms.length, lessThanOrEqualTo(20));
    expect(terms, containsAll(['vepřové', 'smetana', 'brambory', 'kuřecí']));
    for (final dish in saleDishes) {
      expect(dish.steps, isNotEmpty, reason: dish.title);
      for (final g in [...dish.groups, ...dish.main]) {
        expect(saleGroupById(g), isNotNull, reason: '${dish.title}: $g');
      }
      for (final m in dish.main) {
        expect(dish.groups, contains(m), reason: '${dish.title}: $m');
      }
    }
  });

  test('jídlo jde uložit jako recept', () {
    var n = 0;
    final recipe = dishToRecipe(
      saleDishes.first,
      newId: () => 'id${n++}',
      now: DateTime.utc(2026, 11, 17),
    );
    expect(recipe.title, saleDishes.first.title);
    expect(recipe.servings, 4);
    expect(recipe.ingredients.length, saleDishes.first.ingredients.length);
    expect(recipe.steps.length, saleDishes.first.steps.length);
    expect(recipe.temperatures, ['Trouba 180 °C']);
    expect(
      {recipe.id, ...recipe.ingredients.map((i) => i.id)}.length,
      1 + recipe.ingredients.length,
    );
  });
}

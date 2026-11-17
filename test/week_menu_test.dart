import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/sale_dishes.dart';
import 'package:hinkredience/core/week_menu.dart';
import 'package:hinkredience/data/kitchen_docs.dart';

PriceOffer offer(String chain, String product, double price) => PriceOffer(
  id: '$chain-$product',
  chain: chain,
  product: product,
  price: price,
  validTo: DateTime(2026, 11, 22),
  sourceUrl: '',
  verified: true,
);

void main() {
  final today = DateTime(2026, 11, 17); // úterý
  final candidates = dishesFromSales([
    offer('tesco', 'Vepřová pečeně bez kosti', 79.9),
    offer('tesco', 'Brambory 2 kg', 29.9),
    offer('jip', 'Kuřecí prsní řízky', 99.9),
    offer('albert', 'Mleté vepřové maso', 89.9),
    offer('coop', 'Hovězí plec', 199.9),
    offer('penny', 'Slanina', 39.9),
  ], today);

  test('obědy a večeře jdou za sebou', () {
    final slots = menuSlots(today, days: 2);
    expect(slots.map(slotLabel), [
      'Út oběd',
      'Út večeře',
      'St oběd',
      'St večeře',
    ]);
    expect(menuSlots(today, days: 1, firstMeal: MealType.dinner).length, 1);
  });

  test('jedno vaření = 6 porcí na oběd, večeři a další oběd', () {
    final menu = buildWeekMenu(candidates, today);
    expect(menu.portions, 6);
    // 14 jídel po 3 → 5 vaření (poslední na 2 jídla).
    expect(menu.cooks.length, 5);
    expect(cookLabel(menu.cooks.first), 'Út oběd – St oběd');
    expect(menu.cooks.last.slots.length, 2);
    expect(menu.missing, isEmpty);
    // Žádné jídlo dvakrát a každé má svůj obchod.
    final titles = menu.cooks.map((c) => c.item.dish.title).toSet();
    expect(titles.length, menu.cooks.length);
    for (final c in menu.cooks) {
      expect(c.item.chain, isNotNull);
    }
    // Sousední vaření nemají stejnou hlavní surovinu, pokud je z čeho vybrat.
    for (var i = 1; i < menu.cooks.length; i++) {
      expect(
        menu.cooks[i].item.mainGroup,
        isNot(menu.cooks[i - 1].item.mainGroup),
      );
    }
  });

  test('vyměnit jídlo dá jiné, které v týdnu ještě není', () {
    final menu = buildWeekMenu(candidates, today);
    final swapped = swapCook(menu, 1, candidates);
    final before = menu.cooks[1].item.dish.title;
    final after = swapped.cooks[1].item.dish.title;
    expect(after, isNot(before));
    expect(swapped.cooks[1].slots, menu.cooks[1].slots);
    final others = [
      for (final (i, c) in swapped.cooks.indexed)
        if (i != 1) c.item.dish.title,
    ];
    expect(others, isNot(contains(after)));
  });

  test('málo návrhů: zbylá jídla bez návrhu', () {
    final few = candidates.take(2).toList();
    final menu = buildWeekMenu(few, today);
    expect(menu.cooks.length, 2);
    expect(menu.missing.length, 14 - 6);
    expect(identical(swapCook(menu, 0, few), menu), isTrue);
  });

  test('2 jídla na vaření', () {
    final menu = buildWeekMenu(candidates, today, mealsPerCook: 2, portions: 6);
    expect(menu.cooks.length, 7);
    expect(cookLabel(menu.cooks.first), 'Út oběd – Út večeře');
  });
}

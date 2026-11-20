import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/sale_dishes.dart';
import 'package:hinkredience/core/sale_ideas.dart';

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
    // Jiné výrobky a hotová jídla se surovinou v názvu.
    for (final p in [
      'Brambory marcipánové Schluckwerder',
      'Americké brambory mražené Marquise',
      'Vývar Cibule Bistro',
      'Rýže Protein Müller Riso',
      'Koření Špagety Vitana',
      'Boloňské špagety Penny To Go',
      'Těstoviny plněné mražené Pelmeni Povar',
      'Hovězí burger Bio',
      'Hovězí carpaccio',
      'Hovězí trhané maso bourbon Sous vide',
      'Kuřecí maso ve sklenici Pikok',
      'Vepřové maso ve vlastní šťávě Hamé',
      'Vejce v aspiku Delika',
      'Mléko kefírové Pilos',
      'Sýr tavený Veselá kráva',
      'Sýr Žervé Karlova Koruna',
    ]) {
      expect(groupOf(p), isNull, reason: p);
    }
    expect(groupOf('Brambory konzumní pozdní'), 'brambory');
    expect(groupOf('Cibule kuchyňská žlutá'), 'cibule');
    expect(groupOf('Rýže basmati Lagris'), 'ryze');
    expect(groupOf('Těstoviny Tesco'), 'testoviny');
    expect(groupOf('Hovězí kližka bez kosti'), 'hovezi');
    expect(groupOf('Sýr Eidam 30% Pilos'), 'syr');
    expect(groupOf('Madeta Madeland sýr 45 % plátky'), 'syr');
    expect(groupOf('Sýr Mozzarella Galbani'), 'syr');
    expect(groupOf('Sýr Romadur Madeta'), isNull);
    expect(groupOf('Sýr Hermelín Král sýrů'), isNull);
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
      offer('penny', 'Smetana ke šlehání 31 %', 24.9, regular: 34.9),
      offer('penny', 'Brambory konzumní 2 kg', 29.9),
      offer('penny', 'Eidam 30 %', 99.9),
    ], today);
    expect(dishes, isNotEmpty);
    final first = dishes.first;
    expect(first.dish.id, 'zapecene-veprove');
    expect(first.chain, 'penny');
    expect(first.validTo, DateTime(2026, 11, 22));
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

  test('akce z různých obchodů se v jednom jídle nemíchají', () {
    final dishes = dishesFromSales([
      offer('tesco', 'Vepřová pečeně bez kosti', 79.9, regular: 198.9),
      offer('albert', 'Smetana ke šlehání', 24.9),
      offer('albert', 'Brambory 2 kg', 29.9),
    ], today);
    final zapecene = dishes.where((d) => d.dish.id == 'zapecene-veprove');
    expect(zapecene.length, 1);
    expect(zapecene.first.chain, 'tesco');
    expect(zapecene.first.onSale.keys, ['veprove']);
    // V Albertu není hlavní surovina (maso), takže se tam nenabízí.
    expect(
      dishes.where(
        (d) => d.chain == 'albert' && d.dish.main.contains('veprove'),
      ),
      isEmpty,
    );
  });

  test('popisek platnosti akce', () {
    expect(validityLabel(DateTime(2026, 11, 17), today), 'akce končí dnes');
    expect(validityLabel(DateTime(2026, 11, 18), today), 'akce končí zítra');
    expect(validityLabel(DateTime(2026, 11, 20), today), 'akce do pá 20. 11.');
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
    expect(allSaleDishes.length, greaterThanOrEqualTo(55));
    expect(allSaleDishes.map((d) => d.id).toSet().length, allSaleDishes.length);
    expect(
      allSaleDishes.map((d) => d.title).toSet().length,
      allSaleDishes.length,
    );
    for (final dish in allSaleDishes) {
      expect(dish.main, isNotEmpty, reason: dish.title);
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

  test('návrh od Gemini ukáže jen skutečné akce', () {
    final ideas = SaleIdeas.fromJson({
      'model': 'gemini-3.5-flash-lite',
      'rejected': ['Palačinky: nevyužívá žádnou akci'],
      'ideas': [
        {
          'title': 'Vepřová pečeně na cibulce',
          'category': 'Maso',
          'minutes': 120,
          'temperature_c': 170,
          'ingredients': [
            {
              'name': 'Vepřová pečeně',
              'quantity': 1,
              'unit': 'kg',
              'offer': {
                'id': '1',
                'chain': 'tesco',
                'product': 'Vepřová pečeně bez kosti',
                'price': 79.9,
                'regular_price': 198.9,
                'valid_to': '2026-11-17',
              },
            },
            {'name': 'Cibule', 'quantity': 3, 'unit': 'ks', 'offer': null},
            {'name': 'Sůl', 'quantity': null, 'unit': ''},
          ],
          'steps': ['Maso osolte.', 'Pečte.'],
        },
        {
          'title': 'Bez akce',
          'ingredients': [
            {'name': 'Mouka'},
          ],
          'steps': ['Nic.'],
        },
      ],
    });
    expect(ideas.ideas.length, 1);
    final idea = ideas.ideas.first;
    expect(idea.onSale.length, 1);
    expect(idea.onSale.values.first.price, 79.9);
    expect(idea.onSale.values.first.verified, isTrue);
    expect(idea.savings, closeTo(119, 0.01));
    expect(idea.dish.temperature, 170);
    expect(idea.dish.ingredients.length, 3);
    expect(ideas.rejected.length, 1);
  });

  test('cena zlevněného zboží na recept za celá balení', () {
    PriceOffer pack(String product, double price, double qty, String unit) =>
        PriceOffer(
          id: product,
          chain: 'tesco',
          product: product,
          price: price,
          packQty: qty,
          packUnit: unit,
          validTo: DateTime(2026, 11, 22),
          sourceUrl: '',
          verified: true,
        );
    final maso = pack('Vepřová pečeně bez kosti', 79.9, 1, 'kg');
    final brambory = pack('Brambory', 29.9, 2, 'kg');
    final smetana = pack('Smetana ke šlehání', 24.9, 200, 'ml');
    expect(salePacks(700, 'g', maso), 1);
    expect(salePacks(1050, 'g', maso), 2);
    expect(salePacks(1, 'kg', brambory), 1);
    expect(salePacks(250, 'ml', smetana), 2);
    expect(salePacks(null, '', smetana), 1);
    expect(salePacks(2, 'lžíce', smetana), 1);

    final item = dishesFromSales([
      maso,
      brambory,
      smetana,
    ], today).firstWhere((d) => d.dish.id == 'zapecene-veprove');
    // 4 porce: 700 g masa (1 kg), 1 kg brambor (2 kg), 250 ml smetany (2×200 ml).
    expect(saleCost(item).total, closeTo(79.9 + 29.9 + 2 * 24.9, 0.001));
    // 6 porcí: 1050 g masa → 2 balení, 1,5 kg brambor → 1 balení, 375 ml → 2.
    expect(
      saleCost(item, servings: 6).total,
      closeTo(2 * 79.9 + 29.9 + 2 * 24.9, 0.001),
    );
  });
}

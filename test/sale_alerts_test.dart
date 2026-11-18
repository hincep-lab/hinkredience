import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/sale_alerts.dart';

void main() {
  final today = DateTime(2026, 11, 18);

  PriceOffer offer(
    String id,
    String chain,
    String product,
    double price, {
    double? pack,
    String unit = '',
    bool verified = true,
    String kind = 'promo',
    DateTime? to,
  }) => PriceOffer(
    id: id,
    chain: chain,
    product: product,
    price: price,
    packQty: pack,
    packUnit: unit,
    verified: verified,
    kind: kind,
    validTo: to ?? DateTime(2026, 11, 22),
    sourceUrl: 'https://www.kupi.cz/x',
  );

  final offers = [
    offer('l', 'lidl', 'Máslo Milkpol', 29.9, pack: 250, unit: 'g'),
    offer('p', 'penny', 'Máslo Jihočeské Madeta', 32.9, pack: 250, unit: 'g'),
    offer('m', 'penny', 'Margarín máslová příchuť', 19.9, pack: 250, unit: 'g'),
    offer('u', 'tesco', 'Máslo Tesco', 19.9, verified: false),
    offer('k', 'albert', 'Kuřecí stehna', 59.9, pack: 1, unit: 'kg'),
    offer('c', 'albert', 'Máslo Česká chuť', 9.9, kind: 'loyalty'),
  ];

  test('nejlevnější ověřená akce za položku, bez margarínu a bez karty', () {
    final a = saleAlerts(
      offers: offers,
      watched: ['máslo', 'Máslo', 'kuřecí stehna', 'rohlíky'],
      seen: const {},
      today: today,
    );
    expect(a.map((n) => n.title), [
      'Máslo je v akci',
      'Kuřecí stehna je v akci',
    ]);
    expect(
      a.first.body,
      'Máslo Milkpol: Lidl 29,90 Kč · 250 g · do 22. 11. '
      '(v akci ve 2 obchodech)',
    );
  });

  test('s kartou Můj Albert se počítá i věrnostní cena', () {
    final a = saleAlerts(
      offers: offers,
      watched: ['máslo'],
      seen: const {},
      today: today,
      cards: {'albert'},
    );
    expect(a.single.body, startsWith('Máslo Česká chuť: Albert 9,90 Kč'));
  });

  test('už ohlášené a prošlé akce znovu ne', () {
    expect(
      saleAlerts(
        offers: [
          offer('l', 'lidl', 'Máslo Milkpol', 29.9),
          offer('x', 'lidl', 'Máslo staré', 9.9, to: DateTime(2026, 11, 17)),
        ],
        watched: ['máslo'],
        seen: {'l'},
        today: today,
      ),
      isEmpty,
    );
  });

  test('víc než tři položky: poslední oznámení je shrnutí', () {
    final many = [
      for (final n in ['Máslo', 'Mléko', 'Vejce', 'Mouka', 'Cukr'])
        offer(n, 'lidl', '$n výběrové', 10),
    ];
    final a = saleAlerts(
      offers: many,
      watched: ['máslo', 'mléko', 'vejce', 'mouka', 'cukr'],
      seen: const {},
      today: today,
    );
    expect(a.length, 3);
    expect(a.last.title, 'Další zboží ze seznamu v akci');
    expect(a.last.body, 'vejce, mouka, cukr');
  });
}

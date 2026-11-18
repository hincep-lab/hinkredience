import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/sale_alerts_runner.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/family_alerts.dart';
import 'package:hinkredience/core/sale_alerts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Alerts implements FamilyAlerts {
  final shown = <({String title, String body})>[];
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show(List<({String title, String body})> n) async =>
      shown.addAll(n);
}

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

  test('hlídané zboží s cenou „pod … Kč“', () {
    final a = saleAlerts(
      offers: offers,
      watched: ['máslo'],
      seen: const {},
      today: today,
      maxPrice: {'máslo': 30},
    );
    expect(a.single.body, startsWith('Máslo Milkpol: Lidl 29,90 Kč'));
    expect(
      saleAlerts(
        offers: offers,
        watched: ['máslo'],
        seen: const {},
        today: today,
        maxPrice: {'máslo': 25},
      ),
      isEmpty,
    );
  });

  test('hlídané zboží se uloží a načte', () {
    final raw = WatchItem.encode([
      const WatchItem('Máslo', maxPrice: 30),
      const WatchItem('Krkovice'),
    ]);
    final back = WatchItem.decode(raw);
    expect(
      [for (final w in back) '${w.name}|${w.maxPrice}'],
      ['Máslo|30.0', 'Krkovice|null'],
    );
    expect(WatchItem.decode('nesmysl'), isEmpty);
  });

  test('kontrola: poprvé jen zapamatovat, pak ohlásit jen nové', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await saveWatchItems(prefs, [const WatchItem('kuřecí stehna')]);
    final alerts = _Alerts();
    var list = [offers[0]];
    Future<int> run(DateTime t) => runSaleAlerts(
      prefs: prefs,
      loadOffers: () async => list,
      alerts: alerts,
      now: t,
      shopping: ['máslo'],
    );
    expect(await run(DateTime(2026, 11, 18, 8)), 0, reason: 'poprvé ticho');
    list = [offers[0], offers[4]];
    expect(await run(DateTime(2026, 11, 18, 8, 10)), 0, reason: 'za 10 min ne');
    expect(await run(DateTime(2026, 11, 18, 9)), 1);
    expect(alerts.shown.single.title, 'Kuřecí stehna je v akci');
    expect(await run(DateTime(2026, 11, 18, 10)), 0, reason: 'už ohlášeno');
    await prefs.setBool(saleAlertsKey, false);
    list = [...list, offer('n', 'lidl', 'Kuřecí stehna XXL', 49.9)];
    expect(await run(DateTime(2026, 11, 18, 11)), 0, reason: 'vypnuto');
  });
}

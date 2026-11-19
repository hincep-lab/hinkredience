import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/stores.dart';

void main() {
  final today = DateTime(2026, 11, 16);
  final items = [
    const BuyItem(id: '1', name: 'Máslo', quantity: 500, unit: 'g'),
    const BuyItem(id: '2', name: 'Mléko', quantity: 2, unit: 'l'),
    const BuyItem(id: '3', name: 'Šafrán'),
  ];
  PriceOffer offer(
    String chain,
    String product,
    double price, {
    bool verified = true,
    DateTime? validTo,
    double? pack,
    String unit = '',
    String? store,
  }) => PriceOffer(
    id: '$chain-$product',
    chain: chain,
    storeId: store,
    product: product,
    price: price,
    packQty: pack,
    packUnit: unit,
    validTo: validTo ?? DateTime(2026, 11, 18),
    sourceUrl: 'https://www.$chain.cz/akce',
    verified: verified,
  );
  ReceiptPrice receipt(
    String store,
    String product,
    double price, {
    double? pack,
    String unit = '',
    DateTime? on,
  }) => ReceiptPrice(
    id: '$store-$product',
    storeId: store,
    product: product,
    price: price,
    packQty: pack,
    packUnit: unit,
    boughtOn: on ?? DateTime(2026, 11, 10),
    updatedAt: DateTime.utc(2026),
  );

  test('porovnání: ověřené akce a účtenky, neověřené a prošlé ne', () {
    final r = computeBestBuy(
      items: items,
      offers: [
        offer('penny', 'Máslo 250 g', 39.9, pack: 250, unit: 'g'),
        offer('lidl', 'Máslo Pilos 250 g', 29.9, verified: false),
        offer('albert', 'Mléko 1 l', 9.9, validTo: DateTime(2026, 11, 15)),
      ],
      receipts: [
        receipt('tesco-hradecka', 'MLEKO POLOTUC 1L', 22.9, pack: 1, unit: 'l'),
        receipt('tesco-hradecka', 'MASLO 250G', 54.9, pack: 250, unit: 'g'),
        receipt('penny-nadrazni', 'Mleko 1l', 21.9, pack: 1, unit: 'l'),
        // Příliš stará účtenka se nepočítá.
        receipt('lidl-hradecka', 'Mléko', 5, on: DateTime(2026, 1, 1)),
      ],
      today: today,
    );
    expect(r.singleStore!.store.id, 'penny-nadrazni');
    expect(r.singleStore!.total, 123.6); // 2× 39,90 + 2× 21,90
    expect(r.singleStore!.missing.map((i) => i.name), ['Šafrán']);
    expect(r.storePlans.map((p) => p.store.id), [
      'penny-nadrazni',
      'tesco-hradecka',
    ]);
    // Úspora proti nejvyšším známým cenám (Tesco): 2×15 + 2×1 = 32.
    expect(r.savingsSingle, 32);
    expect(r.combinationTotal, 123.6);
    expect(r.combinationMissing.map((i) => i.name), ['Šafrán']);
  });

  test('štítek u položky podle režimu: jeden obchod jen vybraný obchod', () {
    final r = computeBestBuy(
      items: items.take(2).toList(),
      offers: [
        offer('penny', 'Máslo 250 g', 39.9, pack: 250, unit: 'g'),
        offer('penny', 'Mléko 1 l', 19.9, pack: 1, unit: 'l'),
        offer('lidl', 'Mléko 1 l', 14.9, pack: 1, unit: 'l'),
      ],
      receipts: const [],
      today: today,
    );
    expect(r.singleStore!.store.chain, 'penny');
    // Jeden obchod: mléko z Penny, i když Lidl je levnější.
    expect(r.tagOffer('2', multiStore: false)!.chain, 'penny');
    expect(r.tagOffer('1', multiStore: false)!.chain, 'penny');
    // Více obchodů: mléko z Lidlu.
    expect(r.tagOffer('2', multiStore: true)!.chain, 'lidl');
    // Položka mimo plán štítek nemá.
    expect(r.tagOffer('3', multiStore: false), isNull);
  });

  test('kombinace prodejen a seskupení', () {
    final r = computeBestBuy(
      items: items.take(2).toList(),
      offers: [offer('penny', 'Máslo 250 g', 39.9, pack: 250, unit: 'g')],
      receipts: [
        receipt('tesco-hradecka', 'Máslo 250 g', 54.9, pack: 250, unit: 'g'),
        receipt('albert-tgm', 'Mléko 1 l', 18.9, pack: 1, unit: 'l'),
        receipt('penny-nadrazni', 'Mléko 1 l', 21.9, pack: 1, unit: 'l'),
      ],
      today: today,
    );
    expect(r.combinationTotal, 79.8 + 37.8);
    final groups = r.combinationByStore;
    expect(groups.keys.map((s) => s.id).toSet(), {
      'penny-nadrazni',
      'albert-tgm',
    });
    // Albert T. G. Masaryka je samostatná prodejna, Hrádecká cenu nemá.
    expect(r.storePlans.any((p) => p.store.id == 'albert-hradecka'), isFalse);
    expect(r.savingsCombination, closeTo(30 + 6, 0.001));
  });

  test('akce řetězce platí ve všech jeho sušických prodejnách', () {
    final r = computeBestBuy(
      items: [items.first],
      offers: [offer('coop', 'Máslo', 45)],
      receipts: const [],
      today: today,
    );
    expect(r.storePlans.map((p) => p.store.id).toSet(), {
      'coop-namesti',
      'coop-nadrazni',
      'coop-lerchova',
      'coop-smetanova',
    });
  });

  test('štítek: nejlevnější ověřená akce; neověřené zvlášť', () {
    final offers = [
      offer('penny', 'Máslo 250 g', 39.9, pack: 250, unit: 'g'),
      offer('lidl', 'Máslo 250 g', 29.9, verified: false),
    ];
    expect(bestOfferFor(items.first, offers, today)!.offer.chain, 'penny');
    expect(
      unverifiedOffersFor(items.first, offers, today).single.chain,
      'lidl',
    );
  });

  test('balení, shoda názvů, oficiální weby', () {
    expect(packsNeeded(items.first, 250, 'g'), 2);
    expect(packsNeeded(items[1], 1, 'l'), 2);
    expect(packsNeeded(const BuyItem(id: 'x', name: 'Cibule'), 1, 'kg'), 1);
    expect(packsNeeded(items.first, 1, 'ks'), 1);
    expect(productMatches('Máslo', 'MASLO TRAD. 250G'), isTrue);
    expect(productMatches('Kuřecí stehna', 'Kuřecí stehenní řízky'), isTrue);
    expect(productMatches('Mléko', 'Máslo'), isFalse);
    expect(productMatches('', 'Máslo'), isFalse);
    expect(
      productMatches('Kuřecí prsní řízky – 1 kg', 'Kuřecí prsní řízek 1 kg'),
      isTrue,
    );
    expect(
      productMatches(
        'Vepřová pečeně bez kosti – 1 kg',
        'Vepřové pečeně bez kosti',
      ),
      isTrue,
    );
    expect(productMatches('Máslo – 250 g', 'Máslo 250 g'), isTrue);
    expect(productMatches('Maso', 'Máslo'), isFalse);
    // Jiný výrobek, který má surovinu jen v názvu.
    expect(productMatches('Brambory', 'Brambory marcipánové'), isFalse);
    expect(productMatches('Cibule', 'Vývar Cibule Bistro'), isFalse);
    expect(productMatches('Špagety', 'Koření Špagety Vitana'), isFalse);
    expect(productMatches('Kuřecí prsa', 'Šunka kuřecí prsní'), isFalse);
    expect(productMatches('Kuřecí vývar', 'Vývar kuřecí Bistro'), isTrue);
    expect(productMatches('Brambory', 'Brambory konzumní 2 kg'), isTrue);
    expect(productMatches('Kořenová zelenina', 'Kořenová zelenina'), isTrue);
    expect(czStem('rizky'), czStem('rizek'));
    expect(productKey('Máslo Tatra 250 g'), productKey('tatra MÁSLO'));
    expect(chainById('lidl')!.isOfficial('https://www.lidl.cz/c/akce'), isTrue);
    expect(chainById('lidl')!.isOfficial('https://lidl.cz.evil.com/'), isFalse);
    expect(
      chainById('penny')!.isOfficial('https://www.kupi.cz/penny'),
      isFalse,
    );
    expect(susiceStores.length, 10);
    expect(susiceStores.where((s) => s.chain == 'albert').length, 2);
  });

  test('neúplné ceny: součet není cenou celého nákupu', () {
    final list = [
      const BuyItem(
        id: 'a',
        name: 'Kuřecí prsní řízky',
        quantity: 1,
        unit: 'kg',
      ),
      const BuyItem(
        id: 'b',
        name: 'Vepřová pečeně bez kosti',
        quantity: 1,
        unit: 'kg',
      ),
      const BuyItem(id: 'c', name: 'Máslo', quantity: 250, unit: 'g'),
    ];
    final offers = [
      offer('penny', 'Kuřecí prsní řízky', 109.9, pack: 1, unit: 'kg'),
      offer('penny', 'Máslo Boni', 29.9, pack: 250, unit: 'g'),
      offer('albert', 'Madeta Jihočeské máslo', 34.9, pack: 250, unit: 'g'),
    ];
    final r = computeBestBuy(
      items: list,
      offers: offers,
      receipts: const [],
      today: today,
    );
    expect(r.singleStore!.store.chain, 'penny');
    expect(r.singleStore!.complete, isFalse);
    expect(r.singleStore!.missing.single.name, 'Vepřová pečeně bez kosti');
    expect(r.combinationComplete, isFalse);
    expect(r.savingsCombination, 5.0, reason: 'máslo: 34,90 − 29,90');

    final full = computeBestBuy(
      items: list,
      offers: [
        ...offers,
        offer('penny', 'Vepřová pečeně', 119.9, pack: 1, unit: 'kg'),
      ],
      receipts: const [],
      today: today,
    );
    expect(full.singleStore!.complete, isTrue);
    expect(full.singleStore!.total, closeTo(259.7, 0.001));
    expect(full.combinationComplete, isTrue);
  });

  test('shoda jako na serveru: máslo × máslový, bez kosti × s kostí', () {
    expect(productMatches('Máslo', 'Chléb toustový máslový'), isFalse);
    expect(productMatches('Máslo', 'Perla máslová příchuť'), isFalse);
    expect(productMatches('Máslo', 'MÁSLO BONI 250 g'), isTrue);
    expect(
      productMatches('Vepřová pečeně bez kosti', 'VEPŘOVÁ PEČENĚ ve vakuu'),
      isTrue,
    );
    expect(
      productMatches('Vepřová pečeně bez kosti', 'Vepřová pečeně s kostí'),
      isFalse,
    );
    expect(
      productMatches('Vepřová pečeně bez kosti', 'Vepřová krkovice bez kosti'),
      isFalse,
    );
    expect(
      productMatches('Kuřecí prsní řízky', 'Kuřecí stehenní řízky'),
      isFalse,
    );
    expect(
      chainById('jip')!.isOfficial('https://www.jip-potraviny.cz/x'),
      isTrue,
    );
    expect(
      chainById('coop')!.isOfficial('https://www.zkdsusice.cz/letak_tuty'),
      isTrue,
    );
  });
}

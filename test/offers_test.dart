import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/offer_browse.dart';

// Akce: druh ceny, věrnostní karty, budoucí a prošlé akce, duplicity,
// cena za kg a výpočet nákupu. Testovací data odpovídají skutečným
// letákům 18.–24. 11. 2026 (jen jako vstup testu, ne jako akce v aplikaci).

void main() {
  final today = DateTime(2026, 11, 18);

  PriceOffer offer(
    String id,
    String chain,
    String product,
    double price, {
    double? regular,
    double? pack,
    String unit = '',
    String kind = 'promo',
    String loyalty = '',
    bool verified = true,
    DateTime? from,
    DateTime? to,
    String conditions = '',
  }) => PriceOffer(
    id: id,
    chain: chain,
    product: product,
    price: price,
    regularPrice: regular,
    packQty: pack,
    packUnit: unit,
    kind: kind,
    loyalty: loyalty,
    verified: verified,
    conditions: conditions,
    validFrom: from ?? DateTime(2026, 11, 18),
    validTo: to ?? DateTime(2026, 11, 24),
    sourceUrl: 'https://www.$chain.cz/letak',
  );

  final albertApp = offer(
    'a1',
    'albert',
    'Česká chuť Máslo 82%',
    27.9,
    regular: 54.9,
    pack: 250,
    unit: 'g',
    kind: 'loyalty',
    loyalty: 'Můj Albert',
    conditions: 's Aplikací',
  );
  final albertPlain = offer(
    'a2',
    'albert',
    'Česká chuť Máslo 82%',
    32.9,
    regular: 54.9,
    pack: 250,
    unit: 'g',
    conditions: 'bez Aplikace',
  );
  final pennyButter = offer(
    'p1',
    'penny',
    'Máslo Boni',
    44.9,
    pack: 250,
    unit: 'g',
  );
  final tescoRegular = offer(
    't0',
    'tesco',
    'Zlatý Sýr Cheddar plátky',
    51.9,
    pack: 100,
    unit: 'g',
    kind: 'regular',
    conditions: 'běžná cena',
  );
  final tescoClub = offer(
    't1',
    'tesco',
    'Zlatý Sýr Cheddar plátky',
    34.9,
    regular: 51.9,
    pack: 100,
    unit: 'g',
    kind: 'loyalty',
    loyalty: 'Clubcard',
    verified: false,
  );
  final eggsLater = offer(
    't2',
    'tesco',
    'Tesco Čerstvá vejce',
    29.9,
    regular: 59.9,
    pack: 10,
    unit: 'ks',
    from: DateTime(2026, 11, 20),
    to: DateTime(2026, 11, 22),
  );
  final expired = offer('x', 'lidl', 'Máslo', 19.9, to: DateTime(2026, 11, 17));

  group('cena a sleva', () {
    test('cena za kg / l / ks', () {
      expect(albertApp.unitPrice, (price: 111.6, unit: 'kg'));
      expect(unitPriceOf(24.9, 1, 'l'), (price: 24.9, unit: 'l'));
      expect(unitPriceOf(21.9, 1.5, 'l')!.price, 14.6);
      expect(unitPriceOf(29.9, 10, 'ks'), (price: 2.99, unit: 'ks'));
      expect(unitPriceOf(89.9, 1, 'kg'), (price: 89.9, unit: 'kg'));
      expect(unitPriceOf(10, null, 'g'), isNull);
      expect(unitPriceOf(10, 3, 'balení'), isNull);
    });

    test('sleva jen proti známé původní ceně', () {
      expect(albertApp.discountPercent, 49);
      expect(albertPlain.discountPercent, 40);
      expect(pennyButter.discountPercent, isNull, reason: 'bez původní ceny');
      expect(offer('z', 'penny', 'X', 50, regular: 40).discountPercent, isNull);
    });

    test('druh ceny ze serveru (JSON) i výchozí pro starší řádky', () {
      final j = albertApp.toJson();
      expect(j['kind'], 'loyalty');
      expect(j['loyalty'], 'Můj Albert');
      final back = PriceOffer.fromJson(j);
      expect([back.needsLoyalty, back.loyalty], [true, 'Můj Albert']);
      final old = PriceOffer.fromJson({
        'id': 'o',
        'chain': 'penny',
        'product': 'Máslo',
        'price': 30,
        'valid_to': '2026-11-24',
      });
      expect(
        [old.kind, old.isRegular, old.needsLoyalty],
        ['promo', false, false],
      );
    });
  });

  group('obrazovka Akce', () {
    final all = [
      albertApp,
      albertPlain,
      pennyButter,
      tescoRegular,
      tescoClub,
      eggsLater,
      expired,
      // Dvojitý záznam téže akce (jiné id) se ukáže jednou.
      offer('p1-dup', 'penny', 'Máslo  Boni', 44.9, pack: 250, unit: 'g'),
    ];

    test('běžná cena a prošlá akce se nezobrazí, budoucí zvlášť', () {
      final b = browseOffers(all, today);
      final ids = [for (final o in b.current) o.id];
      expect(ids, isNot(contains('t0')), reason: 'běžná cena není akce');
      expect(ids, isNot(contains('x')), reason: 'prošlá akce');
      expect(ids, isNot(contains('t2')), reason: 'budoucí akce jde zvlášť');
      expect([for (final o in b.upcoming) o.id], ['t2']);
      expect(eggsLater.startsAfter(today), isTrue);
      expect(eggsLater.startsAfter(DateTime(2026, 11, 20)), isFalse);
    });

    test('duplicity jen jednou; ověřené první, pak největší sleva', () {
      final b = browseOffers(all, today);
      expect([for (final o in b.current) o.id], ['a1', 'a2', 'p1', 't1']);
    });

    test('filtry: obchod, druh potraviny, sleva, jen ověřené', () {
      expect(
        browseOffers(
          all,
          today,
          filter: const OfferFilter(chains: {'penny'}),
        ).current.map((o) => o.id),
        ['p1'],
      );
      expect(
        browseOffers(
          all,
          today,
          filter: const OfferFilter(groups: {'maslo'}),
        ).current.map((o) => o.id),
        ['a1', 'a2', 'p1'],
      );
      expect(
        browseOffers(
          all,
          today,
          filter: const OfferFilter(minDiscount: 45),
        ).current.map((o) => o.id),
        ['a1'],
        reason: 'bez původní ceny nelze slevu doložit',
      );
      expect(
        browseOffers(
          all,
          today,
          filter: const OfferFilter(verifiedOnly: true),
        ).current.map((o) => o.id),
        isNot(contains('t1')),
      );
      expect(const OfferFilter(chains: {'a'}, minDiscount: 20).count, 2);
    });

    test('přidat do nákupu: přesné zboží a balení', () {
      final s = shoppingFromOffer(albertApp, 'Albert');
      expect(s.name, 'Česká chuť Máslo 82%');
      expect([s.quantity, s.unit], [250, 'g']);
      expect(s.note, 'akce Albert · Můj Albert');
    });

    test('stav stahování: varování jen když poslední pokus selhal', () {
      final u = chainUpdates([
        {
          'chain': 'lidl',
          'ran_at': '2026-11-18T08:00:00Z',
          'ok': false,
          'error': 'HTTP 403',
        },
        {'chain': 'lidl', 'ran_at': '2026-11-17T08:00:00Z', 'ok': true},
        {'chain': 'penny', 'ran_at': '2026-11-18T09:00:00Z', 'ok': true},
        {'chain': 'penny', 'ran_at': '2026-11-18T07:00:00Z', 'ok': false},
      ]);
      expect(u['lidl']!.failing, isTrue);
      expect(u['lidl']!.error, 'HTTP 403');
      expect(u['lidl']!.lastOk, DateTime.utc(2026, 11, 17, 8).toLocal());
      expect(u['penny']!.failing, isFalse);
    });
  });

  group('nákup', () {
    const butter = BuyItem(id: 'm', name: 'Máslo', quantity: 500, unit: 'g');
    final offers = [albertApp, albertPlain, pennyButter, tescoRegular];

    test('bez karty se počítá cena bez aplikace; s kartou věrnostní', () {
      final none = computeBestBuy(
        items: [butter],
        offers: offers,
        receipts: const [],
        today: today,
        loyaltyChains: const {},
      );
      final best = none.combination.single;
      expect(
        [best.store.chain, best.offer!.id, best.packs, best.cost],
        ['albert', 'a2', 2, 65.8],
      );
      final withApp = computeBestBuy(
        items: [butter],
        offers: offers,
        receipts: const [],
        today: today,
        loyaltyChains: const {'albert'},
      );
      expect(withApp.combination.single.offer!.id, 'a1');
      expect(withApp.combination.single.cost, 55.8);
    });

    test('běžná cena a neověřená akce do výpočtu nejdou', () {
      const cheddar = BuyItem(id: 'c', name: 'Cheddar plátky');
      final r = computeBestBuy(
        items: [cheddar],
        offers: [tescoRegular, tescoClub],
        receipts: const [],
        today: today,
        loyaltyChains: const {'tesco'},
      );
      expect(r.combination, isEmpty);
      expect(r.combinationMissing.single.id, 'c');
      expect(unverifiedOffersFor(cheddar, [tescoRegular, tescoClub], today), [
        tescoClub,
      ]);
    });

    test('budoucí akce se do dnešního nákupu nepočítá', () {
      const eggs = BuyItem(id: 'v', name: 'Vejce', quantity: 10, unit: 'ks');
      expect(bestOfferFor(eggs, [eggsLater], today), isNull);
      expect(
        bestOfferFor(eggs, [eggsLater], DateTime(2026, 11, 21))?.cost,
        29.9,
      );
    });

    test('úspora jen ze skutečných cen ve dvou obchodech', () {
      final r = computeBestBuy(
        items: [butter],
        offers: offers,
        receipts: const [],
        today: today,
        loyaltyChains: const {},
      );
      // Albert 2 × 32,90 = 65,80; Penny 2 × 44,90 = 89,80.
      expect(r.savingsCombination, 24.0);
    });
  });
}

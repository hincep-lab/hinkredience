import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/kitchen_providers.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/offer_browse.dart';
import 'package:hinkredience/core/shopping.dart';
import 'package:hinkredience/features/kitchen/offers_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

// Obrazovka Akce na úzkém telefonu (360 px) a propojení s nákupem.

class _Offers extends PriceOffersNotifier {
  _Offers(this.list);
  final List<PriceOffer> list;
  @override
  Future<List<PriceOffer>> build() async => list;
}

class _Updates extends PriceUpdatesNotifier {
  _Updates(this.map);
  final Map<String, ChainUpdate> map;
  @override
  Future<Map<String, ChainUpdate>> build() async => map;
}

void main() {
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);

  PriceOffer offer(
    String id,
    String chain,
    String product,
    double price, {
    double? regular,
    String kind = 'promo',
    String loyalty = '',
    bool verified = true,
    int startsIn = 0,
  }) => PriceOffer(
    id: id,
    chain: chain,
    product: product,
    price: price,
    regularPrice: regular,
    packQty: 250,
    packUnit: 'g',
    kind: kind,
    loyalty: loyalty,
    verified: verified,
    validFrom: day.add(Duration(days: startsIn)),
    validTo: day.add(const Duration(days: 6)),
    sourceUrl: 'https://www.$chain.cz/letak',
  );

  final offers = [
    offer(
      'a1',
      'albert',
      'Česká chuť Máslo 82% s velmi dlouhým názvem pro úzký displej',
      27.9,
      regular: 54.9,
      kind: 'loyalty',
      loyalty: 'Můj Albert',
    ),
    offer('a2', 'albert', 'Česká chuť Máslo 82%', 32.9, regular: 54.9),
    offer('t0', 'tesco', 'Zlatý Sýr Cheddar', 51.9, kind: 'regular'),
    offer('t1', 'tesco', 'Zlatý Sýr Cheddar', 34.9, verified: false),
    offer(
      't2',
      'tesco',
      'Tesco Čerstvá vejce',
      29.9,
      regular: 59.9,
      startsIn: 2,
    ),
  ];

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3; // 360 × 780 bodů
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      // Automatické stažení letáků právě proběhlo.
      'offers_auto_refresh_at': DateTime.now().toIso8601String(),
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        retry: (retryCount, error) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          priceServiceProvider.overrideWithValue(null),
          priceOffersProvider.overrideWith(() => _Offers(offers)),
          priceUpdatesProvider.overrideWith(
            () => _Updates({
              'lidl': ChainUpdate(
                lastOk: now.subtract(const Duration(days: 2)),
                lastFail: now.subtract(const Duration(hours: 1)),
                error: 'HTTP 403',
              ),
              'penny': ChainUpdate(
                lastOk: now.subtract(const Duration(minutes: 30)),
              ),
            }),
          ),
          shoppingListsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: const MaterialApp(
          locale: Locale('cs'),
          supportedLocales: [Locale('cs')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: OffersScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Akce na telefonu: karty, budoucí akce, varování, filtry', (
    tester,
  ) async {
    await pump(tester);
    expect(tester.takeException(), isNull, reason: 'nic nepřetéká');
    expect(find.textContaining('Letáky aktualizovány'), findsOneWidget);
    expect(find.byKey(const ValueKey('offers-warning-lidl')), findsOneWidget);
    expect(
      find.textContaining('Lidl: leták se nepodařilo stáhnout'),
      findsOneWidget,
    );

    // Běžná cena se jako akce neukazuje, neověřená je označená.
    expect(find.byKey(const ValueKey('offer-t0')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('offer-t1')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('offer-t1')),
        matching: find.text('Neověřeno'),
      ),
      findsOneWidget,
    );
    // Budoucí akce zvlášť s „Platí od“.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('offer-t2')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Brzy v akci'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('offer-t2')),
        matching: find.textContaining('Platí od'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('věrnostní cena: bez karty upozornění, sleva a cena za kg', (
    tester,
  ) async {
    await pump(tester);
    final card = find.byKey(const ValueKey('offer-a1'));
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('Jen s Můj Albert'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('kartu nemáte')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('−49 %')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('111,60 Kč/kg')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Přidat do nákupu')),
      findsOneWidget,
    );
  });

  testWidgets('filtr obchodu a „Jen ověřené“', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('filter-chain-tesco')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-a1')), findsNothing);
    expect(find.byKey(const ValueKey('offer-t1')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('filter-verified')),
      find.byKey(const PageStorageKey('offers-discount-row')),
      const Offset(-200, 0),
    );
    await tester.tap(find.byKey(const ValueKey('filter-verified')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offer-t1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('přidání akce do nákupu: položka najde právě tuto akci', () async {
    final env = await TestEnvironment.create();
    addTearDown(env.dispose);
    final docs = await env.docs();
    final a2 = offers[1];
    final s = shoppingFromOffer(a2, 'Albert');
    await docs.addToShopping([
      ShoppingDraft(
        name: s.name,
        quantity: s.quantity,
        unit: s.unit,
        note: s.note,
      ),
    ]);
    final items = await docs.shopping();
    expect(items.single.name, 'Česká chuť Máslo 82%');
    expect([items.single.quantity, items.single.unit], [250, 'g']);
    final r = computeBestBuy(
      items: [
        for (final i in items)
          BuyItem(id: i.id, name: i.name, quantity: i.quantity, unit: i.unit),
      ],
      offers: offers,
      receipts: const [],
      today: day,
      loyaltyChains: const {},
    );
    expect(r.combination.single.offer!.id, 'a2');
    expect(r.combination.single.packs, 1);
    expect(r.combination.single.cost, 32.9);
  });
}

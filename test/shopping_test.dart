import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/kitchen_math.dart';
import 'package:hinkredience/core/shopping.dart';
import 'package:hinkredience/data/kitchen_docs.dart';
import 'package:hinkredience/features/kitchen/shopping_screen.dart'
    show recipeShoppingDrafts;

void main() {
  final now = DateTime.utc(2026, 11, 15);
  var ids = 0;
  String newId() => 'i${++ids}';

  test(
    'stejné suroviny se sečtou i přes g/kg, nesčitatelné zůstanou zvlášť',
    () {
      final first = mergeShopping(
        existing: const [],
        additions: const [
          ShoppingDraft(
            name: 'Mouka hladká',
            quantity: 500,
            unit: 'g',
            source: 'Buchty',
          ),
          ShoppingDraft(
            name: 'Vejce',
            quantity: 3,
            unit: 'ks',
            source: 'Buchty',
          ),
          ShoppingDraft(name: 'Sůl', source: 'Buchty'),
        ],
        newId: newId,
        now: now,
      );
      expect(first.added, 3);
      final second = mergeShopping(
        existing: first.changed,
        additions: const [
          ShoppingDraft(
            name: 'mouka hladká',
            quantity: 1,
            unit: 'kg',
            source: 'Knedlíky',
          ),
          ShoppingDraft(
            name: 'Vejce',
            quantity: 2,
            unit: 'ks',
            source: 'Knedlíky',
          ),
          ShoppingDraft(
            name: 'Vejce',
            quantity: 100,
            unit: 'g',
            source: 'Těstoviny',
          ),
          ShoppingDraft(name: 'Sůl', source: 'Knedlíky'),
        ],
        newId: newId,
        now: now,
      );
      expect(second.added, 1, reason: 'jen vejce v gramech je nová položka');
      expect(second.merged, 3);
      final flour = second.changed.firstWhere((i) => i.name == 'Mouka hladká');
      expect(formatTotalAmount(flour.quantity, flour.unit), '1,5 kg');
      expect(flour.sources, ['Buchty', 'Knedlíky']);
      final eggs = second.changed.firstWhere((i) => i.unit == 'ks');
      expect(eggs.quantity, 5);
    },
  );

  test('nakoupené položky se nemění, přibude nová', () {
    final bought = ShoppingItem(
      id: 'x',
      name: 'Mléko',
      quantity: 1000,
      unit: 'ml',
      checked: true,
      createdAt: now,
      updatedAt: now,
    );
    final result = mergeShopping(
      existing: [bought],
      additions: const [ShoppingDraft(name: 'Mléko', quantity: 0.5, unit: 'l')],
      newId: newId,
      now: now,
    );
    expect(result.added, 1);
    expect(result.changed.single.id, isNot('x'));
    expect(result.changed.single.quantity, 500);
  });

  test('ručně psané položky', () {
    ShoppingDraft p(String text) => parseShoppingText(text);
    expect(
      [
        p('2 kg brambor').name,
        p('2 kg brambor').quantity,
        p('2 kg brambor').unit,
      ],
      ['brambor', 2, 'kg'],
    );
    expect([p('mléko 1 l').name, p('mléko 1 l').unit], ['mléko', 'l']);
    expect(
      [p('3 cibule').name, p('3 cibule').quantity, p('3 cibule').unit],
      ['cibule', 3, 'ks'],
    );
    expect([p('chleba').name, p('chleba').quantity], ['chleba', null]);
    expect(
      [p('mouka 500g').name, p('mouka 500g').quantity, p('mouka 500g').unit],
      ['mouka', 500, 'g'],
    );
    expect(p('   ').name, '');
  });

  test('kategorie surovin pro „Kuře na paprice“', () {
    const expected = {
      'Kuřecí stehna s kostí': ShoppingCategory.meat,
      'Cibule': ShoppingCategory.vegetables,
      'Červená paprika': ShoppingCategory.vegetables,
      'Smetana 31 %': ShoppingCategory.dairy,
      'Sladká paprika mletá': ShoppingCategory.spices,
      'Máslo': ShoppingCategory.dairy,
      'Hladká mouka': ShoppingCategory.other,
      'Kuřecí vývar': ShoppingCategory.other,
      'Demi-glace': ShoppingCategory.other,
      'Paprikový olej': ShoppingCategory.other,
      'Řepkový olej': ShoppingCategory.other,
      'Bobkový list': ShoppingCategory.spices,
      'Nové koření': ShoppingCategory.spices,
      'Černý pepř': ShoppingCategory.spices,
      'Sůl': ShoppingCategory.spices,
      'Cukr': ShoppingCategory.other,
    };
    for (final entry in expected.entries) {
      expect(guessCategory(entry.key), entry.value, reason: entry.key);
    }
  });

  test('návrh sloučení: 200 g + 300 g cibule = 500 g', () {
    final existing = [
      ShoppingItem(
        id: 'a',
        name: 'Cibule',
        quantity: 200,
        unit: 'g',
        createdAt: now,
        updatedAt: now,
      ),
    ];
    final proposals = planShoppingMerge(
      existing: existing,
      additions: const [
        ShoppingDraft(name: 'Mrkev', quantity: 1, unit: 'ks'),
        ShoppingDraft(name: 'cibule', quantity: 300, unit: 'g'),
      ],
    );
    expect(proposals.single.draftIndex, 1);
    expect(proposals.single.resultQuantity, 500);
    expect(proposals.single.describe(), contains('500 g'));
  });

  test('přepočet porcí: recept na 4, nákup na 6', () {
    final drafts = recipeShoppingDrafts(
      title: 'Kuře na paprice',
      recipeServings: 4,
      servings: 6,
      ingredients: const [
        (name: 'Kuřecí stehna s kostí', quantity: 1.5, unit: 'kg'),
        (name: 'Sůl', quantity: null, unit: ''),
      ],
    );
    expect(drafts.first.quantity, 2.25);
    expect(drafts.first.category, ShoppingCategory.meat);
    expect(drafts.last.quantity, isNull);
    expect(drafts.first.source, 'Kuře na paprice');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/kitchen_math.dart';
import 'package:hinkredience/core/shopping.dart';
import 'package:hinkredience/data/kitchen_docs.dart';

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
}

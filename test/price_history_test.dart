import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';

void main() {
  PriceOffer offer(
    String id,
    String chain,
    double price, {
    double pack = 250,
    bool verified = true,
    String kind = 'promo',
  }) => PriceOffer(
    id: id,
    chain: chain,
    product: 'Máslo',
    price: price,
    packQty: pack,
    packUnit: 'g',
    verified: verified,
    kind: kind,
    validTo: DateTime(2026, 11, 10),
    sourceUrl: 'https://www.kupi.cz/x',
  );

  test('bývá i levněji (cena za kg, i jiné balení)', () {
    final now = offer('now', 'penny', 34.9);
    final note = priceHistoryNote(now, [
      offer('a', 'lidl', 29.9),
      offer('b', 'albert', 45.9, pack: 500),
      offer('c', 'tesco', 19.9, verified: false),
      offer('d', 'tesco', 9.9, kind: 'regular'),
    ]);
    expect(note!.best, isFalse);
    expect(note.text, 'Bývá i levněji: 91,80 Kč za kg (Albert, do 10. 11.).');
  });

  test('nejlevnější známá cena', () {
    final now = offer('now', 'lidl', 22.9);
    final note = priceHistoryNote(now, [offer('a', 'lidl', 29.9), now]);
    expect(note!.best, isTrue);
    expect(note.text, contains('dřív nejlevněji 119,60 Kč za kg – Lidl'));
  });

  test('bez dřívějších akcí nic', () {
    final now = offer('now', 'lidl', 22.9);
    expect(priceHistoryNote(now, [now]), isNull);
  });
}

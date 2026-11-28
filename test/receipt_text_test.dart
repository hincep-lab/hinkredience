import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/receipt_text.dart';

void main() {
  test('účtenka: položky, množství, slevy, obchod a datum', () {
    final r = parseReceiptText('''
PENNY MARKET s.r.o.
Nádražní 1213, Sušice
MLEKO POLOTUC. 1L        43,80 A
2 x 21,90
MASLO 250G               54,90 B
SLEVA                   -15,00
Rohlík                    3,90 A
MEZISOUČET               ...
CELKEM                   102,60
Karta VISA              102,60
DPH 12%                  10,99
15.11.2026 18:22
''');
    expect(r.storeId, 'penny-nadrazni');
    expect(r.date, DateTime(2026, 11, 15));
    expect(r.lines.map((l) => '${l.product}=${l.price}'), [
      'MLEKO POLOTUC. 1L=21.9',
      'MASLO 250G=39.9',
      'Rohlík=3.9',
    ]);
    expect(r.lines.first.packQty, 1);
    expect(r.lines.first.packUnit, 'l');
    expect(r.lines[1].packQty, 250);
    expect(r.lines[1].packUnit, 'g');
  });

  test('Albert: prodejna jen když je adresa jasná', () {
    expect(
      guessReceiptStore('ALBERT Supermarket\nT. G. Masaryka 23'),
      'albert-tgm',
    );
    expect(guessReceiptStore('Albert Hrádecká 31 Sušice'), 'albert-hradecka');
    expect(guessReceiptStore('Albert Česká republika'), isNull);
    expect(guessReceiptStore('COOP TIP Lerchova 926'), 'coop-lerchova');
    expect(guessReceiptStore('neznámý obchod'), isNull);
  });

  test('bez cen nic', () {
    expect(parseReceiptText('Děkujeme za nákup').lines, isEmpty);
  });

  test('elektronická účtenka Albert (PDF): slevy, vážené zboží, prodejna', () {
    for (final file in [
      'test/fixtures/albert_eucetenka_pdfium.txt',
      'test/fixtures/albert_eucetenka_raw.txt',
    ]) {
      final r = parseReceiptText(File(file).readAsStringSync());
      expect(r.storeId, 'albert-hradecka', reason: file);
      expect(r.date, DateTime(2026, 11, 14), reason: file);
      final byName = {for (final l in r.lines) l.product: l};
      expect(byName.length, 8, reason: file);
      // Sleva 730 Kč z 1199 Kč.
      expect(byName['Fabini rendlík lucca']!.price, 469, reason: file);
      expect(byName['Rohlík43gr']!.price, 3.5);
      expect(byName['Rohlík43gr']!.packQty, 43);
      expect(byName['Rohlík43gr']!.packUnit, 'g');
      // Vážené: cena za 1 kg, ne za 0,797 kg.
      final chicken = byName['Kuřecí prsní řízky']!;
      expect(chicken.price, 229);
      expect(chicken.packQty, 1);
      expect(chicken.packUnit, 'kg');
      expect(byName['Pepsi zero 2,25l']!.packUnit, 'l');
      // Zaokrouhlení ani kredity nejsou položky.
      expect(
        byName.keys.any((k) => k.toLowerCase().contains('zaokrouhl')),
        isFalse,
      );
    }
  });
}

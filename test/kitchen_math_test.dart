import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/kitchen_math.dart';

void main() {
  group('nepřepočítané množství', () {
    test('zobrazí se přesně, jak bylo zadané', () {
      expect(formatAmount(800, 'g'), '800 g');
      expect(formatAmount(0.25, 'l'), '0,25 l');
      expect(formatAmount(2, 'ks'), '2 ks');
      expect(formatAmount(3, ''), '3');
      expect(formatAmount(null, 'špetka'), 'špetka');
      expect(
        formatAmount(1.3, 'lžíce'),
        '1,3 lžíce',
        reason: 'neobvyklá hodnota se nezaokrouhluje na zlomek',
      );
    });

    test('lžíce a kusy se píšou kuchyňským zlomkem', () {
      expect(formatAmount(0.5, 'lžičky'), '½ lžičky');
      expect(formatAmount(1.5, 'lžíce'), '1 ½ lžíce');
      expect(formatAmount(0.25, 'hrnku'), '¼ hrnku');
      expect(formatAmount(0.75, 'ks'), '¾ ks');
    });
  });

  group('inteligentní zaokrouhlování gramáží', () {
    test('krok roste s množstvím', () {
      expect(formatAmount(250, 'g', factor: 4 / 3), '335 g');
      expect(formatAmount(7, 'g', factor: 1.5), '11 g');
      expect(formatAmount(7, 'g', factor: 0.5), '3,5 g');
      expect(formatAmount(1, 'g', factor: 0.25), '0,3 g');
      expect(formatAmount(330, 'ml', factor: 2.5), '830 ml');
      expect(roundMetric(283.33), 285);
      expect(roundMetric(1283.33), 1280);
      expect(roundMetric(2633), 2650);
      expect(roundMetric(0.04), 0.1, reason: 'nikdy na nulu');
    });

    test('gramy a kilogramy, mililitry a litry se převádějí', () {
      expect(formatAmount(800, 'g', factor: 1.5), '1,2 kg');
      expect(formatAmount(1.2, 'kg', factor: 0.5), '600 g');
      expect(formatAmount(2, 'kg', factor: 1.5), '3 kg');
      expect(formatAmount(1.25, 'kg', factor: 2), '2,5 kg');
      expect(formatAmount(0.25, 'l', factor: 3), '750 ml');
      expect(formatAmount(500, 'ml', factor: 3), '1,5 l');
    });

    test('dkg a dl zůstávají v jednotce uživatele', () {
      expect(formatAmount(2, 'dl', factor: 1.5), '3 dl');
      expect(formatAmount(15, 'dkg', factor: 1.5), '23 dkg');
    });
  });

  group('kuchyňské zlomky', () {
    test('přepočet lžic a hrnků', () {
      expect(formatAmount(1, 'lžíce', factor: 0.5), '½ lžíce');
      expect(formatAmount(1, 'lžíce', factor: 1 / 3), '⅓ lžíce');
      expect(formatAmount(2, 'lžíce', factor: 0.75), '1 ½ lžíce');
      expect(formatAmount(1, 'lžička', factor: 0.25), '¼ lžička');
      expect(formatAmount(1, 'hrnek', factor: 1.75), '1 ¾ hrnek');
      expect(formatAmount(1, 'ČL', factor: 0.5), '½ ČL');
      expect(formatAmount(3, 'lžíce', factor: 5), '15 lžíce');
    });

    test('formatFraction', () {
      expect(formatFraction(0.5), '½');
      expect(formatFraction(0.33), '⅓');
      expect(formatFraction(0.66), '⅔');
      expect(formatFraction(2), '2');
      expect(formatFraction(2.97), '3');
      expect(formatFraction(1.26), '1 ¼');
      expect(formatFraction(0.02), '⅛', reason: 'nikdy nula');
      expect(formatFraction(0.3, halvesOnly: true), '½');
      expect(formatFraction(12.4), '12');
    });
  });

  group('vejce a kusové suroviny', () {
    test('vejce vycházejí na celé kusy, nejméně jedno', () {
      expect(formatAmount(2, 'ks', factor: 2, name: 'vejce'), '4 ks');
      expect(
        formatAmount(3, 'ks', factor: 0.5, name: 'Vejce'),
        '2 ks (přesně 1,5)',
      );
      expect(
        formatAmount(1, 'ks', factor: 0.25, name: 'Vejce'),
        '1 ks (přesně 0,3)',
      );
      expect(formatAmount(4, '', factor: 1.5, name: 'žloutky'), '6');
      expect(formatAmount(3, 'vejce', factor: 1.5), '5 vejce (přesně 4,5)');
    });

    test('ostatní kusy jdou po polovinách a nikdy na nulu', () {
      expect(formatAmount(1, 'ks', factor: 1.5, name: 'Cibule'), '1 ½ ks');
      expect(
        formatAmount(3, 'stroužky', factor: 0.5, name: 'česnek'),
        '1 ½ stroužky',
      );
      expect(formatAmount(1, 'ks', factor: 0.25, name: 'Citron'), '½ ks');
      expect(formatAmount(2, 'ks', factor: 0.7, name: 'Mrkev'), '1 ½ ks');
      expect(formatAmount(12, 'ks', factor: 1.5, name: 'Knedlíky'), '18 ks');
    });

    test('rozpoznání vajec a druhu jednotky', () {
      expect(isEggLike('Vaječné žloutky'), isTrue);
      expect(isEggLike('Hovězí'), isFalse);
      expect(isEggLike('Svejkovice'), isFalse);
      expect(unitKind('čl'), UnitKind.measure);
      expect(unitKind('cl'), UnitKind.volume);
      expect(unitKind('l'), UnitKind.volume);
      expect(unitKind('lžic'), UnitKind.measure);
      expect(unitKind('balení'), UnitKind.count);
      expect(unitKind(''), UnitKind.count);
      expect(unitKind('cm'), UnitKind.other);
    });
  });

  group('rozsahy v poznámkách', () {
    test('přepočítají se obě meze', () {
      expect(scaleRangesInText('nebo 2–3 lžíce', 2), 'nebo 4–6 lžíce');
      expect(
        scaleRangesInText('podle chuti 10–15 g', 1.5),
        'podle chuti 15–23 g',
      );
      expect(scaleRangesInText('800–900 g', 2), '1,6–1,8 kg');
      expect(scaleRangesInText('2 až 3 ks', 0.5), '1–1 ½ ks');
      expect(scaleRangesInText('2-3', 2, fallbackUnit: 'stroužky'), '4–6');
      expect(
        scaleRangesInText('2–3 větší', 2, fallbackUnit: 'ks'),
        '4–6 větší',
      );
      expect(scaleRangesInText('1–2 ks', 0.5, name: 'vejce'), '1 ks');
    });

    test('čas, teplota a rozměry se nemění', () {
      expect(
        scaleRangesInText('péct 10–15 minut při 160–170 °C', 2),
        'péct 10–15 minut při 160–170 °C',
      );
      expect(
        scaleRangesInText('plátky 3–4 mm silné', 3),
        'plátky 3–4 mm silné',
      );
      expect(
        scaleRangesInText('nechat 2–3 hodiny, přidat 1–2 lžíce', 2),
        'nechat 2–3 hodiny, přidat 2–4 lžíce',
      );
    });

    test('ve volném textu jen rozsahy se známou jednotkou', () {
      expect(
        scaleRangesInText('verze 2–3 a 1–2 lžíce cukru', 2, requireUnit: true),
        'verze 2–3 a 2–4 lžíce cukru',
      );
    });

    test('bez přepočtu zůstává text beze změny', () {
      expect(scaleRangesInText('beze změny 2–3', 1), 'beze změny 2–3');
    });
  });

  test('výtěžnost slovy', () {
    expect(yieldLabel(1, ''), '1 porce');
    expect(yieldLabel(4, 'porce'), '4 porce');
    expect(yieldLabel(5, ''), '5 porcí');
    expect(yieldLabel(2.5, ''), '2,5 porce');
    expect(yieldLabel(12, 'ks'), '12 ks');
    expect(YieldUnit.normalize('Kusy'), 'ks');
    expect(YieldUnit.normalize(null), 'porce');
    expect(YieldUnit.normalize('cokoli'), 'porce');
  });
}

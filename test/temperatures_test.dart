import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/temperatures.dart';

void main() {
  test('tabulka teplot je úplná a rozumná', () {
    expect(temperatureGroups.first, 'Hovězí');
    expect(temperatureGroups, contains('Drůbež'));
    for (final guide in temperatureGuides) {
      expect(guide.coreC, inInclusiveRange(40, 100), reason: guide.name);
      if (guide.sousVideC != null) {
        expect(guide.sousVideC, inInclusiveRange(45, 90), reason: guide.name);
      }
      if (guide.group == 'Drůbež' && guide.sousVideC != null) {
        expect(
          guide.sousVideC,
          greaterThanOrEqualTo(57),
          reason: 'drůbež sous-vide s bezpečnou teplotou: ${guide.name}',
        );
      }
    }
    final chicken = temperatureGuides.firstWhere(
      (g) => g.name == 'Kuřecí prsa',
    );
    expect(chicken.coreC, greaterThanOrEqualTo(70));
  });

  test('časy čitelně', () {
    expect(formatGuideMinutes(45), '45 min');
    expect(formatGuideMinutes(90), '1 h 30 min');
    expect(formatGuideMinutes(1440), '24 h');
  });
}

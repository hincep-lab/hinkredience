import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/formatters.dart';

void main() {
  group('formatQuantity', () {
    test('celá čísla bez desetinných míst', () {
      expect(formatQuantity(2), '2');
      expect(formatQuantity(200), '200');
    });

    test('desetinná čárka a nejvýše dvě místa', () {
      expect(formatQuantity(0.5), '0,5');
      expect(formatQuantity(1.25), '1,25');
      expect(formatQuantity(1.333333), '1,33');
      expect(formatQuantity(2.999), '3');
    });
  });

  group('parseQuantity', () {
    test('čárka i tečka', () {
      expect(parseQuantity('1,5'), 1.5);
      expect(parseQuantity('1.5'), 1.5);
      expect(parseQuantity(' 200 '), 200);
    });

    test('zlomky', () {
      expect(parseQuantity('1/2'), 0.5);
      expect(parseQuantity('3/4'), 0.75);
      expect(parseQuantity('1/0'), isNull);
    });

    test('neplatný vstup', () {
      expect(parseQuantity(''), isNull);
      expect(parseQuantity('špetka'), isNull);
      expect(parseQuantity('1/2/3'), isNull);
    });
  });

  group('scaleQuantity', () {
    test('přepočet ze 4 na 6 porcí', () {
      expect(scaleQuantity(2, fromServings: 4, toServings: 6), 3);
      expect(scaleQuantity(200, fromServings: 4, toServings: 2), 100);
    });

    test('bez množství zůstává null', () {
      expect(scaleQuantity(null, fromServings: 4, toServings: 8), isNull);
    });

    test('nulový výchozí počet porcí nic nerozbije', () {
      expect(scaleQuantity(5, fromServings: 0, toServings: 8), 5);
    });
  });

  test('formatMinutes', () {
    expect(formatMinutes(0), '0 min');
    expect(formatMinutes(45), '45 min');
    expect(formatMinutes(60), '1 h');
    expect(formatMinutes(90), '1 h 30 min');
    expect(formatMinutes(660), '11 h');
  });

  test('foldForSearch odstraní českou diakritiku', () {
    expect(foldForSearch('Svíčková na smetaně'), 'svickova na smetane');
    expect(
      foldForSearch('Příliš žluťoučký kůň úpěl ďábelské ódy'),
      'prilis zlutoucky kun upel dabelske ody',
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/data/price_service.dart';
import 'package:hinkredience/features/kitchen/best_buy_panel.dart';

void main() {
  final json = {
    'provider': 'gemini',
    'scanned': 3,
    'cached': 0,
    'found': 2,
    'verified': 1,
    'unverified': 1,
    'saved': 2,
    'duplicates': 0,
    'rejected': 1,
    'errors': ['search:model_unavailable', 'lidl: HTTP 403'],
    'diag': [
      {
        'chain': 'penny',
        'name': 'Penny',
        'cached': false,
        'pages': [
          {
            'url': 'https://www.penny.cz/nabidky',
            'status': 200,
            'chars': 5400,
            'matched': ['Máslo – 250 g'],
            'note': '',
          },
        ],
        'ai': [
          {
            'mode': 'stránka',
            'model': 'gemini-3.5-flash-lite',
            'status': 'ok',
            'offers': 2,
          },
        ],
        'offers': [
          {
            'product': 'Máslo 250 g',
            'price': 39.9,
            'valid_to': '2026-11-17',
            'source': 'www.penny.cz',
            'verified': true,
            'reason': 'cena je na oficiální stránce u produktu',
            'saved': 'uloženo',
          },
        ],
        'rejected': [
          {'product': 'Máslo 250 g', 'reason': 'chybí platnost'},
        ],
        'errors': <String>[],
      },
    ],
  };

  test('výsledek hledání: počty, chyby a problém vyhledávání', () {
    final r = PriceRefresh.fromJson(json);
    expect(r.saved, 2);
    expect(r.rejected, 1);
    expect(r.searchProblem, 'model_unavailable');
    expect(r.chainErrors, ['lidl: HTTP 403']);
    expect(refreshMessage(r), startsWith('Nalezeno 2 · uloženo 2'));
  });

  test('nic nenalezeno: zpráva řekne konkrétní příčinu', () {
    final r = PriceRefresh.fromJson({
      'provider': 'gemini',
      'scanned': 3,
      'errors': [
        'penny: model gemini-2.5-flash-lite není pro tento klíč dostupný',
      ],
    });
    expect(refreshMessage(r), contains('Problém: penny: model'));
    expect(
      refreshMessage(const PriceRefresh(scanned: 3)),
      contains('na stránkách akcí obchodů není'),
    );
  });

  testWidgets('diagnostika ukáže stránku, AI, nabídky i odmítnuté', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PriceDiagnostics(
            result: PriceRefresh.fromJson(json),
            onRetry: () => retried = true,
          ),
        ),
      ),
    );
    expect(find.text('Penny'), findsOneWidget);
    expect(
      find.textContaining('Stránka www.penny.cz: 5400 znaků'),
      findsOneWidget,
    );
    expect(find.textContaining('✓ Máslo 250 g 39,90 Kč'), findsOneWidget);
    expect(
      find.textContaining('✗ Máslo 250 g: chybí platnost'),
      findsOneWidget,
    );
    expect(find.textContaining('nové klíče'), findsOneWidget);
    await tester.ensureVisible(
      find.text('Hledat znovu (bez dnešní mezipaměti)'),
    );
    await tester.tap(find.text('Hledat znovu (bez dnešní mezipaměti)'));
    expect(retried, isTrue);
  });
}

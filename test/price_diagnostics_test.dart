import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/data/price_service.dart';
import 'package:hinkredience/features/kitchen/best_buy_panel.dart';

void main() {
  final json = {
    'version': 'letaky-2',
    'provider': 'gemini',
    'scanned': 3,
    'cached': 0,
    'found': 2,
    'verified': 1,
    'unverified': 1,
    'saved': 2,
    'duplicates': 0,
    'rejected': 1,
    'errors': ['lidl: HTTP 403'],
    'gemini': {
      'configured': true,
      'model': 'gemini-3.5-flash-lite',
      'calls': 2,
      'ok': true,
      'error': '',
    },
    'diag': [
      {
        'chain': 'albert',
        'name': 'Albert',
        'cached': false,
        'sources': [
          {
            'kind': 'leták',
            'title': 'Albert akční leták',
            'url': 'https://letaky.albert.cz/46sm_akcni_letak/page/1',
            'valid_from': '2026-11-11',
            'valid_to': '2026-11-17',
            'size': 45,
            'text': true,
            'picked': [3, 23],
          },
        ],
        'pages': [
          {
            'url': 'https://www.albert.cz/aktualni-letaky',
            'status': 200,
            'chars': 5400,
            'matched': <String>[],
            'note': '',
          },
          {
            'url': 'https://letaky.albert.cz/x/spreads.json',
            'status': 503,
            'chars': 0,
            'matched': <String>[],
            'note': 'HTTP 503',
          },
        ],
        'ai': [
          {
            'mode': 'leták',
            'model': 'gemini-3.5-flash-lite',
            'status': 'ok',
            'pages': 'Albert akční leták, str. 3, 23',
            'offers': 2,
          },
        ],
        'offers': [
          {
            'product': 'Madeta Jihočeské máslo',
            'price': 34.9,
            'pack': '250 g',
            'conditions': 's aplikací',
            'valid_to': '2026-11-17',
            'source': 'letaky.albert.cz',
            'verified': true,
            'reason': 'cena stojí v textu letáku u názvu zboží (str. 3)',
            'saved': 'uloženo',
          },
        ],
        'rejected': [
          {'product': 'Máslová makovka', 'reason': 'jiné zboží než „Máslo“'},
        ],
        'errors': <String>[],
      },
    ],
  };

  test('výsledek hledání: počty, chyby a stav Gemini', () {
    final r = PriceRefresh.fromJson(json);
    expect(r.saved, 2);
    expect(r.rejected, 1);
    expect(r.chainErrors, ['lidl: HTTP 403']);
    expect(refreshMessage(r), startsWith('Nalezeno 2 · uloženo 2'));
    expect(geminiStatusText(r), contains('FUNGUJE – 2 čtení'));
  });

  test('nic nenalezeno: zpráva řekne konkrétní příčinu; stav Gemini', () {
    final r = PriceRefresh.fromJson({
      'version': 'letaky-2',
      'provider': 'gemini',
      'scanned': 3,
      'errors': ['penny: model gemini-x není pro tento klíč dostupný'],
      'gemini': {
        'configured': true,
        'model': 'gemini-x',
        'calls': 1,
        'ok': false,
        'error': 'model gemini-x není pro tento klíč dostupný',
      },
    });
    expect(refreshMessage(r), contains('Problém: penny: model'));
    expect(geminiStatusText(r), contains('NEFUNGUJE – model gemini-x'));
    expect(
      refreshMessage(const PriceRefresh(scanned: 3)),
      contains('v aktuálních letácích obchodů není'),
    );
    expect(geminiStatusText(const PriceRefresh()), contains('stará verze'));
    expect(
      geminiStatusText(PriceRefresh.fromJson({'version': 'letaky-2'})),
      contains('chybí GEMINI_API_KEY'),
    );
  });

  testWidgets('diagnostika ukáže zdroj, čtení, nabídky i odmítnuté', (
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
    expect(find.text('Albert'), findsOneWidget);
    expect(
      find.textContaining(
        'Zdroj: Albert akční leták, platí 11. 11. – 17. 11., 45 stran, '
        'čteny strany 3, 23',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Stahování letaky.albert.cz: nestaženo (HTTP 503)'),
      findsOneWidget,
    );
    expect(find.textContaining('Čtení letáku'), findsOneWidget);
    expect(
      find.textContaining(
        '✓ Madeta Jihočeské máslo 34,90 Kč / 250 g (s aplikací) do 17. 11.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('✗ Máslová makovka: jiné zboží'),
      findsOneWidget,
    );
    expect(find.textContaining('Google Gemini'), findsOneWidget);
    await tester.ensureVisible(find.text('Hledat znovu (bez mezipaměti)'));
    await tester.tap(find.text('Hledat znovu (bez mezipaměti)'));
    expect(retried, isTrue);
  });
}

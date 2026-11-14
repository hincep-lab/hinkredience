import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/app_config.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/app/router.dart';
import 'package:hinkredience/core/app_theme.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/data/ai_service.dart';
import 'package:hinkredience/data/photo_store.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:hinkredience/features/more/chatgpt_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_models_test.dart' show draftJson;
import 'ai_service_test.dart' show FakeAiBackend;
import 'support.dart';

/// Sestaví aplikaci; [backend] zapne AI kuchaře nad maketou serveru.
Future<void> pumpAiApp(
  WidgetTester tester, {
  required String location,
  FakeAiBackend? backend,
  List<Recipe> recipes = const [],
  bool aiEnabled = true,
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({'ai_enabled': aiEnabled});
  final prefs = await SharedPreferences.getInstance();
  final router = createRouter(initialLocation: location);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      retry: (retryCount, error) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appConfigProvider.overrideWithValue(AppConfig.load(prefs)),
        photoStoreProvider.overrideWithValue(PhotoStore(Directory.systemTemp)),
        recipeRepositoryProvider.overrideWith(
          (ref) => Completer<RecipeRepository>().future,
        ),
        allRecipesProvider.overrideWith((ref) => Stream.value(recipes)),
        if (backend != null)
          aiServiceProvider.overrideWithValue(AiService(backend)),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.dark(),
        locale: const Locale('cs'),
        supportedLocales: const [Locale('cs')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Texty na obrazovce – do zprávy o selhání, aby bylo vidět, co tam je.
String shownTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .join(' | ');

/// Posune seznam na obrazovce tak, aby byl vidět [finder].
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byType(ListView),
    const Offset(0, -250),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bez účtu AI kuchař vysvětlí, co je potřeba', (tester) async {
    await pumpAiApp(tester, location: Routes.home);
    await tester.tap(find.text('AI kuchař'));
    await tester.pumpAndSettle();
    expect(find.text('AI kuchař potřebuje účet'), findsOneWidget);
    expect(find.text('Otevřít nastavení'), findsOneWidget);
  });

  testWidgets('hledání bez účtu nepředstírá funkčnost', (tester) async {
    await pumpAiApp(tester, location: Routes.webSearch);
    expect(find.text('AI kuchař potřebuje účet'), findsOneWidget);
    expect(find.text('Hledat recepty'), findsNothing);
  });

  testWidgets('import bez účtu nepředstírá funkčnost', (tester) async {
    await pumpAiApp(tester, location: Routes.importRecipe);
    expect(find.text('AI kuchař potřebuje účet'), findsOneWidget);
    expect(find.text('Převést na recept'), findsNothing);
  });

  testWidgets('chat: odešle zprávu a ukáže odpověď s návrhem receptu', (
    tester,
  ) async {
    final backend = FakeAiBackend(
      (body) => {
        'conversation_id': 'k1',
        'reply': 'Navrhuji krémové kuře na paprice.',
        'recipe': draftJson(title: 'Kuře na paprice'),
        'change_summary': '',
        'sources': <Object>[],
      },
    );
    await pumpAiApp(tester, location: Routes.ai, backend: backend);
    expect(find.text('Tvůj kuchařský parťák s pamětí'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Vymysli oběd z kuřete.');
    await tester.tap(find.byTooltip('Odeslat'));
    await tester.pumpAndSettle();

    expect(backend.requests.single['message'], 'Vymysli oběd z kuřete.');
    expect(find.text('Vymysli oběd z kuřete.'), findsOneWidget);
    expect(find.text('Navrhuji krémové kuře na paprice.'), findsOneWidget);
    expect(find.text('Kuře na paprice'), findsOneWidget);
    expect(find.textContaining('prohlédnout a uložit'), findsOneWidget);

    // Návrh se neuloží sám – nejdřív se otevře ke kontrole.
    await tester.tap(find.text('Kuře na paprice'));
    await tester.pumpAndSettle();
    expect(find.text('Návrh receptu'), findsOneWidget);
    expect(find.text('Hovězí zadní'), findsOneWidget);
    await scrollTo(tester, find.text('Uložit do kuchařky'));
    expect(find.text('Uložit do kuchařky'), findsOneWidget);
  });

  testWidgets('chat: chyba serveru se ukáže a zpráva se neztratí', (
    tester,
  ) async {
    final backend = FakeAiBackend(
      (body) => throw aiErrorFromResponse(503, {
        'error': {
          'code': 'ai_not_configured',
          'message': 'Chybí tajemství OPENAI_API_KEY.',
        },
      }),
    );
    await pumpAiApp(tester, location: Routes.ai, backend: backend);
    await tester.enterText(find.byType(TextField), 'Ahoj');
    await tester.tap(find.byTooltip('Odeslat'));
    await tester.pumpAndSettle();

    expect(find.text('AI ještě není nastavená'), findsOneWidget);
    expect(find.text('Chybí tajemství OPENAI_API_KEY.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Ahoj',
    );
  });

  testWidgets('hledání: výsledky se zdroji a výběr pro naši verzi', (
    tester,
  ) async {
    final backend = FakeAiBackend(
      (body) => body['action'] == 'search'
          ? {
              'results': [
                {
                  'title': 'Svíčková podle babičky',
                  'url': 'https://www.recepty.cz/svickova',
                  'site': 'recepty.cz',
                  'summary': 'Poctivá klasika.',
                  'ingredients': ['hovězí zadní 800 g'],
                  'method': 'Péct pomalu.',
                  'temperatures': ['160 °C'],
                  'total_minutes': 240,
                  'rating': 4.7,
                  'rating_count': 312,
                  'verified': true,
                },
                {
                  'title': 'Rychlá svíčková',
                  'url': 'https://kucharka.example/rychla',
                  'site': 'kucharka.example',
                  'summary': '',
                  'ingredients': <String>[],
                  'method': '',
                  'temperatures': <String>[],
                  'total_minutes': null,
                  'rating': null,
                  'rating_count': null,
                  'verified': false,
                },
              ],
              'comparison': {
                'ingredients': 'Liší se kořenovou zeleninou.',
                'method': '',
                'temperatures_times': '',
                'ratings': '',
              },
              'dropped_unverified': 1,
            }
          : {
              'summary': 'Spojeno z obou.',
              'changes': <Object>[],
              'recipe': draftJson(title: 'Naše svíčková'),
              'sources': [
                {'url': 'https://www.recepty.cz/svickova', 'title': 'Svíčková'},
              ],
            },
    );
    await pumpAiApp(tester, location: Routes.webSearch, backend: backend);
    await tester.enterText(find.byType(TextField).first, 'svíčková');
    await tester.tap(find.text('Hledat recepty'));
    await tester.pumpAndSettle();

    expect(
      find.text('Nalezené recepty (2)'),
      findsOneWidget,
      reason: shownTexts(tester),
    );
    expect(find.text('Svíčková podle babičky'), findsOneWidget);
    expect(find.text('Otevřít na recepty.cz'), findsOneWidget);
    expect(
      find.text('Otevřít na kucharka.example (odkaz neověřen)'),
      findsOneWidget,
    );
    expect(find.textContaining('★ 4,7 (312)'), findsOneWidget);
    expect(find.textContaining('Vyřazeno výsledků'), findsOneWidget);
    expect(find.text('Vyberte recepty pro naši verzi'), findsOneWidget);

    await tester.tap(find.text('Svíčková podle babičky'));
    await tester.pumpAndSettle();
    expect(find.text('Vytvořit naši verzi (1)'), findsOneWidget);

    await tester.tap(find.text('Vytvořit naši verzi (1)'));
    await tester.pumpAndSettle();
    expect(backend.requests.last['action'], 'our_version');
    expect(find.text('Naše verze'), findsOneWidget);
    expect(find.text('Naše svíčková'), findsOneWidget);
    await scrollTo(tester, find.text('Uložit do kuchařky'));
    expect(find.text('Uložit do kuchařky'), findsOneWidget);
  });

  testWidgets('import: krátký text se neodešle', (tester) async {
    final backend = FakeAiBackend((body) => {'recipe': draftJson()});
    await pumpAiApp(tester, location: Routes.importRecipe, backend: backend);
    await tester.enterText(find.byType(TextField), 'guláš');
    await tester.tap(find.text('Převést na recept'));
    await tester.pumpAndSettle();
    expect(backend.requests, isEmpty);
    expect(find.text('Vložte celý text receptu.'), findsOneWidget);
  });

  testWidgets('import z textu otevře návrh ke kontrole', (tester) async {
    final backend = FakeAiBackend(
      (body) => {
        'recipe': draftJson(title: 'Hovězí guláš'),
        'message': 'Zkontroluj množství papriky.',
        'source_url': null,
      },
    );
    await pumpAiApp(tester, location: Routes.importRecipe, backend: backend);
    await tester.enterText(
      find.byType(TextField),
      'Hovězí guláš: 800 g hovězího, 3 cibule, paprika. Dusit 2 hodiny.',
    );
    await tester.tap(find.text('Převést na recept'));
    await tester.pumpAndSettle();

    expect(backend.requests.single['action'], 'import');
    expect(find.text('Importovaný recept'), findsOneWidget);
    expect(find.text('Hovězí guláš'), findsOneWidget);
    expect(find.text('Zkontroluj množství papriky.'), findsOneWidget);
  });

  testWidgets('vypnutá AI: detail receptu AI akce nenabízí', (tester) async {
    await pumpAiApp(
      tester,
      location: Routes.recipe('recipe-1'),
      recipes: [sampleRecipe()],
      aiEnabled: false,
    );
    await tester.tap(find.byTooltip('Další možnosti'));
    await tester.pumpAndSettle();
    expect(find.text('Duplikovat'), findsOneWidget);
    expect(find.text('Vylepšit s AI'), findsNothing);
    expect(find.text('Najdi lepší postup'), findsNothing);
  });

  testWidgets('vypnutá AI: dlaždice jsou označené a kuchařka funguje dál', (
    tester,
  ) async {
    await pumpAiApp(tester, location: Routes.home, aiEnabled: false);
    expect(find.text('Vypnuto'), findsNWidgets(3));
    expect(find.text('Recepty'), findsWidgets);
  });

  testWidgets('zapnutá AI: dlaždice nejsou označené jako vypnuté', (
    tester,
  ) async {
    await pumpAiApp(tester, location: Routes.home);
    expect(find.text('Vypnuto'), findsNothing);
  });

  testWidgets('nastavení: AI je ve výchozím stavu vypnutá a jde zapnout', (
    tester,
  ) async {
    await pumpAiApp(tester, location: Routes.more, aiEnabled: false);
    await scrollTo(tester, find.text('AI funkce v aplikaci'));
    expect(find.textContaining('Vypnuto – aplikace neodesílá'), findsOneWidget);

    await tester.tap(find.text('AI funkce v aplikaci'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Zapnuto – AI kuchař'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ai_enabled'), isTrue);
  });

  testWidgets('propojení s ChatGPT ukáže adresu MCP serveru', (tester) async {
    expect(
      mcpServerUrl('https://projekt.supabase.co/'),
      'https://projekt.supabase.co/functions/v1/mcp',
    );
    expect(mcpServerUrl('  '), '');

    await pumpAiApp(tester, location: Routes.chatGpt);
    expect(find.text('Propojení s ChatGPT'), findsOneWidget);
    expect(find.text('Jak propojit'), findsOneWidget);
    expect(find.textContaining('Nejdřív nastavte připojení'), findsOneWidget);
  });

  testWidgets('detail receptu nabízí AI akce', (tester) async {
    await pumpAiApp(
      tester,
      location: Routes.recipe('recipe-1'),
      recipes: [sampleRecipe()],
    );
    await tester.tap(find.byTooltip('Další možnosti'));
    await tester.pumpAndSettle();
    expect(find.text('Vylepšit s AI'), findsOneWidget);
    expect(find.text('Najdi lepší postup'), findsOneWidget);
    expect(find.text('Najít podobné na internetu'), findsOneWidget);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hinkredience/app/app_config.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/app/router.dart';
import 'package:hinkredience/core/app_theme.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/core/screen_wake.dart';
import 'package:hinkredience/data/docs_repository.dart';
import 'package:hinkredience/data/photo_store.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:hinkredience/features/photos/photo_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// Sestaví aplikaci nad pevným seznamem receptů (bez databáze a sítě).
/// Zaznamenává zapínání a vypínání nevypínání displeje.
class FakeScreenWake implements ScreenWake {
  final calls = <bool>[];

  bool? get last => calls.isEmpty ? null : calls.last;

  @override
  Future<void> keepOn(bool on) async => calls.add(on);
}

var screenWake = FakeScreenWake();

Future<GoRouter> pumpApp(
  WidgetTester tester, {
  required String location,
  List<Recipe> recipes = const [],
  Map<String, Object> preferences = const {},
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(preferences);
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
        // Databáze se v těchto testech nepoužívá – čeká se na ni „věčně“.
        recipeRepositoryProvider.overrideWith(
          (ref) => Completer<RecipeRepository>().future,
        ),
        docsRepositoryProvider.overrideWith(
          (ref) => Completer<DocsRepository>().future,
        ),
        allRecipesProvider.overrideWith((ref) => Stream.value(recipes)),
        screenWakeProvider.overrideWithValue(screenWake),
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
  return router;
}

void main() {
  setUp(() => screenWake = FakeScreenWake());

  testWidgets('hlavní obrazovka zdraví a nabízí první recept', (tester) async {
    await pumpApp(tester, location: Routes.home);

    expect(find.text('Ahoj Pájo 👋'), findsOneWidget);
    expect(find.text('Co dnes společně uvaříme?'), findsOneWidget);
    expect(find.text('Co dnes uvaříme?'), findsOneWidget);
    expect(find.text('AI kuchař'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Přidej první recept'),
      find.byType(CustomScrollView),
      const Offset(0, -200),
    );
    expect(find.text('Přidej první recept'), findsOneWidget);
    expect(find.text('Domů'), findsOneWidget);
  });

  testWidgets('oslovení se bere z nastavení', (tester) async {
    await pumpApp(
      tester,
      location: Routes.home,
      preferences: {'greeting_name': 'Martinko'},
    );
    expect(find.text('Ahoj Martinko 👋'), findsOneWidget);
  });

  testWidgets('hlavní obrazovka doporučuje uložené recepty', (tester) async {
    await pumpApp(
      tester,
      location: Routes.home,
      recipes: [
        sampleRecipe(),
        sampleRecipe(id: 'r2', title: 'Svíčková'),
      ],
    );
    expect(find.text('Moje sbírka · 2'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Doporučené recepty'),
      find.byType(CustomScrollView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Doporučené recepty'), findsOneWidget);
    expect(find.text('Žebra BBQ'), findsOneWidget);
    expect(find.text('Přidej první recept'), findsNothing);
  });

  testWidgets('plán, nákup a deník jsou funkční, AI je poctivě vypnutá', (
    tester,
  ) async {
    await pumpApp(tester, location: Routes.home);
    expect(find.text('Brzy'), findsNothing);
    // AI je placená a ve výchozím stavu vypnutá.
    expect(find.text('Vypnuto'), findsNWidgets(3));

    await tester.tap(find.text('Plán vaření'));
    await tester.pumpAndSettle();
    expect(find.text('Snídaně'), findsWidgets);
    expect(find.byTooltip('Nakoupit na tento týden'), findsOneWidget);
  });

  testWidgets('seznam receptů: kategorie, hledání bez diakritiky', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.recipes,
      recipes: [
        sampleRecipe(),
        sampleRecipe(
          id: 'r2',
          title: 'Svíčková na smetaně',
          category: 'Omáčky',
        ),
      ],
    );

    // Výchozí pohled: dlaždice kategorií.
    expect(find.text('Maso'), findsOneWidget);
    expect(find.text('Zavařování'), findsOneWidget);
    expect(find.text('Žebra BBQ'), findsNothing);

    await tester.enterText(find.byType(TextField), 'svickova');
    await tester.pumpAndSettle();
    expect(find.text('Svíčková na smetaně'), findsOneWidget);
    expect(find.text('Žebra BBQ'), findsNothing);

    await tester.enterText(find.byType(TextField), 'losos');
    await tester.pumpAndSettle();
    expect(find.text('Nic jsme nenašli'), findsOneWidget);
  });

  testWidgets('klepnutí na kategorii vyfiltruje recepty', (tester) async {
    await pumpApp(
      tester,
      location: Routes.recipes,
      recipes: [
        sampleRecipe(),
        sampleRecipe(
          id: 'r2',
          title: 'Svíčková na smetaně',
          category: 'Omáčky',
        ),
      ],
    );
    await tester.tap(find.text('Maso'));
    await tester.pumpAndSettle();
    expect(find.text('Žebra BBQ'), findsOneWidget);
    expect(find.text('Svíčková na smetaně'), findsNothing);
  });

  testWidgets('záložka Oblíbené ukazuje jen oblíbené', (tester) async {
    await pumpApp(
      tester,
      location: Routes.favorites,
      recipes: [
        sampleRecipe(),
        sampleRecipe(id: 'r2', title: 'Svíčková').copyWith(isFavorite: true),
      ],
    );
    expect(find.text('Svíčková'), findsOneWidget);
    expect(find.text('Žebra BBQ'), findsNothing);
  });

  testWidgets('detail receptu přepočítává porce', (tester) async {
    await pumpApp(
      tester,
      location: Routes.recipe('recipe-1'),
      recipes: [sampleRecipe()],
    );

    expect(find.text('Žebra BBQ'), findsOneWidget);
    expect(find.text('Suroviny (4 porce)'), findsOneWidget);
    expect(find.text('2 kg'), findsOneWidget);
    expect(find.text('200 ml'), findsOneWidget);

    await tester.tap(find.byTooltip('Více porcí'));
    await tester.pump();
    await tester.tap(find.byTooltip('Více porcí'));
    await tester.pumpAndSettle();
    expect(find.text('Suroviny (6 porcí)'), findsOneWidget);
    expect(find.text('3 kg'), findsOneWidget);
    expect(find.text('300 ml'), findsOneWidget);

    await tester.tap(find.text('Postup'));
    await tester.pumpAndSettle();
    expect(find.text('Přikryjte alobalem a pečte.'), findsOneWidget);
    expect(find.text('150 °C'), findsOneWidget);
    expect(find.text('3 h'), findsOneWidget);
  });

  testWidgets('detail ukáže skutečný celkový čas včetně kynutí', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.recipe('recipe-1'),
      recipes: [
        sampleRecipe().copyWith(
          title: 'Pizza',
          servings: 6,
          yieldUnit: 'ks',
          prepMinutes: 14,
          cookMinutes: 20,
          steps: const [
            RecipeStep(id: 's1', instruction: 'Zadělej těsto.'),
            RecipeStep(id: 's2', instruction: 'Nech kynout 20 hodin.'),
          ],
        ),
      ],
    );
    expect(find.text('Suroviny (6 ks)'), findsOneWidget);
    expect(find.byTooltip('Více kusů'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Celkem'),
      find.byType(Scrollable).first,
      const Offset(0, -250),
    );
    // V záhlaví receptu i v rozpisu času.
    expect(find.text('20 h 34 min'), findsWidgets);
    expect(find.text('Čekání'), findsOneWidget);
    expect(find.text('20 h'), findsOneWidget);
    expect(find.text('34 min'), findsNothing);
  });

  testWidgets('koš: vysypání se nejdřív zeptá', (tester) async {
    await pumpApp(
      tester,
      location: Routes.trash,
      recipes: [
        sampleRecipe().copyWith(deletedAt: DateTime(2026, 11, 1)),
        sampleRecipe(id: 'r2', title: 'Svíčková'),
      ],
    );
    expect(find.text('Žebra BBQ'), findsOneWidget);
    expect(find.text('Svíčková'), findsNothing);
    expect(find.byTooltip('Smazat natrvalo'), findsOneWidget);

    await tester.tap(find.text('Vysypat'));
    await tester.pumpAndSettle();
    expect(find.text('Vysypat koš?'), findsOneWidget);
    expect(find.textContaining('Natrvalo se smaže 1 recept '), findsOneWidget);
    expect(find.textContaining('nejde vrátit'), findsOneWidget);

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(find.text('Vysypat koš?'), findsNothing);
    expect(find.text('Žebra BBQ'), findsOneWidget);
  });

  testWidgets('prázdný koš tlačítko Vysypat nenabízí', (tester) async {
    await pumpApp(tester, location: Routes.trash, recipes: [sampleRecipe()]);
    expect(find.text('Vysypat'), findsNothing);
  });

  testWidgets('neexistující recept ukáže srozumitelnou zprávu', (tester) async {
    await pumpApp(tester, location: Routes.recipe('nic'));
    expect(find.text('Recept nenalezen'), findsOneWidget);
  });

  testWidgets('obrazovka Více bez připojení ukazuje místní režim', (
    tester,
  ) async {
    await pumpApp(tester, location: Routes.more);
    expect(find.text('Bez účtu'), findsOneWidget);
    expect(
      find.text('Vypnuto – připojení k Supabase není nastavené.'),
      findsOneWidget,
    );
    expect(find.text('Propojení s ChatGPT'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Koš'),
      find.byType(ListView),
      const Offset(0, -250),
    );
    expect(find.text('Koš'), findsOneWidget);
  });

  testWidgets(
    'otevřený recept nevypíná obrazovku, po odchodu se uspávání vrátí',
    (tester) async {
      final router = await pumpApp(
        tester,
        location: Routes.recipes,
        recipes: [sampleRecipe()],
      );
      expect(
        screenWake.calls,
        isEmpty,
        reason: 'seznam receptů displej nedrží',
      );

      router.push(Routes.recipe('recipe-1'));
      await tester.pumpAndSettle();
      expect(screenWake.last, isTrue);

      // Menu nad receptem displej nevypne.
      await tester.tap(find.byTooltip('Další možnosti'));
      await tester.pumpAndSettle();
      expect(screenWake.last, isTrue);
      await tester.tapAt(const Offset(10, 600));
      await tester.pumpAndSettle();
      expect(screenWake.last, isTrue);

      // Aplikace v pozadí → běžné uspávání; po návratu znovu zapnuto.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(screenWake.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(screenWake.last, isTrue);

      // Jiná obrazovka navrch (správa fotek) → vypnuto, zpět → zapnuto.
      router.push(Routes.recipePhotos('recipe-1'));
      await tester.pumpAndSettle();
      expect(screenWake.last, isFalse);
      router.pop();
      await tester.pumpAndSettle();
      expect(screenWake.last, isTrue);

      // Odchod z receptu → běžné uspávání.
      router.pop();
      await tester.pumpAndSettle();
      expect(screenWake.last, isFalse);
      expect(screenWake.calls, [true, false, true, false, true, false]);
    },
  );

  testWidgets('vypnuté nevypínání obrazovky v nastavení se respektuje', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.recipe('recipe-1'),
      recipes: [sampleRecipe()],
      preferences: {'keep_screen_on': false},
    );
    expect(screenWake.calls, isEmpty);
  });

  testWidgets(
    'přepínač v nastavení je ve výchozím stavu zapnutý a jde vypnout',
    (tester) async {
      await pumpApp(tester, location: Routes.more);
      final tile = find.widgetWithText(
        SwitchListTile,
        'Nevypínat obrazovku při vaření',
      );
      await tester.dragUntilVisible(
        tile,
        find.byType(ListView),
        const Offset(0, -250),
      );
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    },
  );

  testWidgets('kroky postupu jde odškrtnout jako hotové', (tester) async {
    await pumpApp(
      tester,
      location: Routes.recipe('recipe-1'),
      recipes: [sampleRecipe()],
    );
    await tester.tap(find.text('Postup'));
    await tester.pumpAndSettle();
    final step = find.text('Přikryjte alobalem a pečte.');
    await Scrollable.ensureVisible(tester.element(step), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(step);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.text('Přikryjte alobalem a pečte.'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('správa fotek: druhou fotku jde nastavit jako hlavní', (
    tester,
  ) async {
    List<RecipePhoto>? changed;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          photoStoreProvider.overrideWithValue(
            PhotoStore(Directory.systemTemp),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PhotoListEditor(
              recipeId: 'r',
              photos: const [
                RecipePhoto(id: 'a'),
                RecipePhoto(id: 'b'),
              ],
              onChanged: (photos) => changed = photos,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Hlavní'), findsOneWidget);
    await tester.tap(find.byTooltip('Možnosti fotky').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit jako hlavní'));
    await tester.pumpAndSettle();
    expect(changed!.map((p) => p.id), ['b', 'a']);
  });

  testWidgets('stav synchronizace bez účtu: jen v telefonu, s vysvětlením', (
    tester,
  ) async {
    await pumpApp(tester, location: Routes.recipes);
    await tester.tap(find.byTooltip('Jen v telefonu'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Připojení k Supabase není nastavené'),
      findsOneWidget,
    );
  });
}

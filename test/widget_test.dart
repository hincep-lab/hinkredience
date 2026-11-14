import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/app_config.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/app/router.dart';
import 'package:hinkredience/core/app_theme.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/data/photo_store.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// Sestaví aplikaci nad pevným seznamem receptů (bez databáze a sítě).
Future<void> pumpApp(
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
        allRecipesProvider.overrideWith((ref) => Stream.value(recipes)),
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

void main() {
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

  testWidgets('funkce dalších etap jsou poctivě označené', (tester) async {
    await pumpApp(tester, location: Routes.home);
    expect(find.text('Brzy'), findsNWidgets(3));

    await tester.tap(find.text('Plán vaření'));
    await tester.pumpAndSettle();
    expect(find.text('Připravujeme – Etapa 4'), findsOneWidget);
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
    expect(find.text('Koš'), findsOneWidget);
  });
}

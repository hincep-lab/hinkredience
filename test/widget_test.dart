import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hinkredience/app/app_config.dart';
import 'package:hinkredience/app/kitchen_providers.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/app/router.dart';
import 'package:hinkredience/core/app_theme.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/core/screen_wake.dart';
import 'package:hinkredience/data/docs_repository.dart';
import 'package:hinkredience/data/kitchen_docs.dart';
import 'package:hinkredience/data/photo_store.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:hinkredience/features/kitchen/wishes.dart';
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

/// Klepne na tlačítko ve vodorovné řadě filtrů: řadu posune na začátek
/// a pak po kouscích, dokud tlačítko není vidět (jako prstem).
Future<void> tapPill(WidgetTester tester, Finder finder, String row) async {
  final scrollable = find
      .descendant(
        of: find.byKey(PageStorageKey(row)),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.ensureVisible(scrollable);
  await tester.pumpAndSettle();
  await tester.drag(scrollable, const Offset(3000, 0));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(finder, 120, scrollable: scrollable);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const prepRow = 'home-prep-row';
const timeRow = 'home-filter-row-Podle času';
const occasionRow = 'home-filter-row-Podle příležitosti';

Future<GoRouter> pumpApp(
  WidgetTester tester, {
  required String location,
  List<Recipe> recipes = const [],
  Map<String, Object> preferences = const {},
  List<ShoppingList> shoppingLists = const [],
  List<ShoppingItem> shoppingItems = const [],
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
        shoppingListsProvider.overrideWith(
          (ref) => Stream.value([
            for (final list in shoppingLists)
              ShoppingListSummary(
                list: list,
                remaining: shoppingItems
                    .where((i) => i.listId == list.id && !i.checked)
                    .length,
                total: shoppingItems.where((i) => i.listId == list.id).length,
              ),
          ]),
        ),
        shoppingListProvider.overrideWith(
          (ref, id) =>
              Stream.value(shoppingLists.where((l) => l.id == id).firstOrNull),
        ),
        shoppingItemsProvider.overrideWith(
          (ref, id) => Stream.value([
            for (final i in shoppingItems)
              if (i.listId == id) i,
          ]),
        ),
        shoppingProvider.overrideWith((ref) => Stream.value(shoppingItems)),
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
    expect(find.text('Co dobrého dnes uvaříme?'), findsOneWidget);
    expect(find.text('Hledat recept, surovinu nebo štítek…'), findsOneWidget);
    expect(find.text('HINKredience°'), findsOneWidget);
    expect(find.text('Moje kuchařka'), findsOneWidget);
    expect(find.text('Kategorie receptů'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Přidej první recept'),
      find.byKey(const Key('home-scroll')),
      const Offset(0, -200),
    );
    expect(find.text('Přidej první recept'), findsOneWidget);
    for (final label in [
      'Domů',
      'Recepty',
      'Nákupní seznam',
      'Plánování',
      'Oblíbené',
      'Štítky',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('oslovení se bere z nastavení', (tester) async {
    await pumpApp(
      tester,
      location: Routes.home,
      preferences: {'greeting_name': 'Martinko'},
    );
    expect(find.text('Ahoj Martinko 👋'), findsOneWidget);
  });

  testWidgets('kategorie na hlavní obrazovce mají skutečné počty receptů', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.home,
      recipes: [
        sampleRecipe(),
        sampleRecipe(id: 'r2', title: 'Svíčková'),
        sampleRecipe(
          id: 'r3',
          title: 'Bramborová polévka',
          category: 'Polévky',
        ).copyWith(isFavorite: true),
      ],
    );
    expect(find.text('Vepřové maso'), findsOneWidget);
    expect(find.text('Hovězí maso'), findsOneWidget);
    expect(find.text('Polévky'), findsOneWidget);
    expect(find.text('1 recept'), findsNWidgets(3));
    expect(find.text('0 receptů'), findsNWidgets(8));

    await tester.dragUntilVisible(
      find.text('Oblíbené recepty'),
      find.byKey(const Key('home-scroll')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bramborová polévka'), findsWidgets);

    await tester.dragUntilVisible(
      find.text('Doporučujeme dnes'),
      find.byKey(const Key('home-scroll')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Doporučujeme dnes'), findsOneWidget);
    expect(find.text('Přidej první recept'), findsNothing);
  });

  testWidgets('hledání a filtry na hlavní obrazovce se kombinují', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.home,
      recipes: [
        sampleRecipe(),
        sampleRecipe(id: 'r2', title: 'Svíčková na smetaně'),
        Recipe(
          id: 'r3',
          title: 'Rychlá omeleta',
          category: 'Bezmasá jídla',
          prepMinutes: 5,
          cookMinutes: 10,
          tags: const ['Rychlá večeře'],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          ingredients: const [Ingredient(id: 'i', name: 'Vejce')],
          steps: const [
            RecipeStep(id: 's', instruction: 'Na pánvi usmažte vejce.'),
          ],
        ),
      ],
    );
    await tester.enterText(find.byType(TextField), 'smetan');
    await tester.pumpAndSettle();
    expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
    expect(find.text('Svíčková na smetaně'), findsOneWidget);

    await tester.tap(find.byTooltip('Vymazat hledání'));
    await tester.pumpAndSettle();
    await tapPill(tester, find.text('Pánev'), prepRow);
    expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
    expect(find.text('Rychlá omeleta'), findsOneWidget);

    // Kombinace: pánev + trouba = kterýkoli z nich; + do 30 min zúží.
    await tapPill(tester, find.text('Trouba'), prepRow);
    expect(find.text('Nalezeno: 3 recepty'), findsOneWidget);
    await tapPill(tester, find.byKey(const Key('time-upTo30')), timeRow);
    expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
    expect(find.text('Rychlá omeleta'), findsOneWidget);

    // Jednotlivý filtr jde odebrat jedním klepnutím.
    await tester.ensureVisible(
      find.byKey(const Key('remove-filter-Do 30 min')),
    );
    await tester.tap(find.byKey(const Key('remove-filter-Do 30 min')));
    await tester.pumpAndSettle();
    expect(find.text('Nalezeno: 3 recepty'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('clear-all-filters')));
    await tester.tap(find.byKey(const Key('clear-all-filters')));
    await tester.pumpAndSettle();
    expect(find.text('Kategorie receptů'), findsOneWidget);
  });

  testWidgets(
    'Sous-vide + Do 60 minut najde lososa; prázdný výsledek vysvětlí',
    (tester) async {
      final losos = Recipe(
        id: 'losos',
        title: 'Losos sous-vide 43 °C',
        category: 'Ryby',
        prepMinutes: 10,
        cookMinutes: 32,
        tags: const ['Sous-vide', 'Pánev'],
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        ingredients: const [Ingredient(id: 'i', name: 'Losos')],
        steps: const [
          RecipeStep(
            id: 's1',
            instruction:
                'Připravujte ve vodní lázni při 43 °C po dobu 30 minut.',
            durationMinutes: 30,
          ),
          RecipeStep(
            id: 's2',
            instruction: 'Krátce opečte na rozpálené pánvi.',
            durationMinutes: 2,
          ),
        ],
      );
      await pumpApp(
        tester,
        location: Routes.home,
        recipes: [losos, sampleRecipe()],
      );
      await tapPill(tester, find.text('Sous-vide'), prepRow);
      await tapPill(tester, find.byKey(const Key('time-upTo60')), timeRow);
      expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
      expect(find.text('Losos sous-vide 43 °C'), findsOneWidget);
      expect(find.text('Ryby · 42 min'), findsOneWidget);

      // Do 15 minut už losos nesplní – aplikace řekne proč.
      await tapPill(tester, find.byKey(const Key('time-upTo60')), timeRow);
      await tapPill(tester, find.byKey(const Key('time-upTo15')), timeRow);
      expect(find.text('Nalezeno: 0 receptů'), findsOneWidget);
      await tester.ensureVisible(find.text('Téměř vyhovují'));
      expect(find.text('Nevyhovuje: celkový čas 42 min'), findsOneWidget);

      // Aktivní práce lososa je 10 minut → vyhoví.
      await tester.ensureVisible(find.byKey(const Key('time-mode-active')));
      await tester.tap(find.byKey(const Key('time-mode-active')));
      await tester.pumpAndSettle();
      expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
      expect(find.text('Ryby · aktivně 10 min'), findsOneWidget);
    },
  );

  testWidgets('kategorie na hlavní obrazovce se kombinuje s příležitostí', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.home,
      recipes: [
        sampleRecipe(),
        Recipe(
          id: 'k',
          title: 'Kuřecí karbanátky',
          category: 'Drůbež a králík',
          prepMinutes: 25,
          cookMinutes: 30,
          tags: const ['Pro děti'],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        Recipe(
          id: 'c',
          title: 'Kuřecí kari',
          category: 'Drůbež a králík',
          prepMinutes: 15,
          cookMinutes: 25,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
    );
    final home = find.byKey(const Key('home-scroll'));
    await tester.dragUntilVisible(
      find.text('Drůbež a králík'),
      home,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drůbež a králík'));
    await tester.pumpAndSettle();
    expect(find.text('Nalezeno: 2 recepty'), findsOneWidget);
    await tester.drag(home, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tapPill(tester, find.text('Pro děti'), occasionRow);
    await tapPill(tester, find.byKey(const Key('time-upTo60')), timeRow);
    expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
    expect(find.text('Kuřecí karbanátky'), findsOneWidget);
    expect(find.text('Kuřecí kari'), findsNothing);
  });

  testWidgets('recept bez času ukazuje „Čas neuveden“', (tester) async {
    await pumpApp(
      tester,
      location: Routes.home,
      recipes: [
        Recipe(
          id: 'x',
          title: 'Salát bez času',
          category: 'Přílohy',
          tags: const ['Rychlá večeře'],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
    );
    await tapPill(tester, find.text('Rychlá večeře'), occasionRow);
    expect(find.text('Přílohy · Čas neuveden'), findsOneWidget);
  });

  testWidgets('plán, nákup a deník jsou funkční, AI je poctivě vypnutá', (
    tester,
  ) async {
    await pumpApp(tester, location: Routes.home);
    expect(find.text('Brzy'), findsNothing);
    await tester.dragUntilVisible(
      find.text('Další funkce'),
      find.byKey(const Key('home-scroll')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    // AI je placená a ve výchozím stavu vypnutá (import funguje i bez ní).
    expect(find.text('Vypnuto'), findsNWidgets(2));

    await tester.tap(find.text('Plánování'));
    await tester.pumpAndSettle();
    expect(find.text('Snídaně'), findsWidgets);
    expect(find.byTooltip('Nakoupit na tento týden'), findsOneWidget);
  });

  testWidgets('záložka Štítky ukazuje příležitosti a způsoby přípravy', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.tags,
      recipes: [
        sampleRecipe().copyWith(tags: const ['Pro děti', 'Grilovačka']),
      ],
    );
    expect(find.text('Pro děti · 1'), findsOneWidget);
    expect(find.text('Trouba · 1'), findsOneWidget);
    expect(find.text('Grilovačka · 1'), findsOneWidget);
    await tester.tap(find.text('Pro děti · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Žebra BBQ'), findsOneWidget);
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

    // Výchozí pohled: fotografické karty 11 skupin.
    expect(find.text('Vepřové maso'), findsOneWidget);
    expect(find.text('Pečivo a těsta'), findsOneWidget);
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
    await tester.tap(find.text('Vepřové maso'));
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

  testWidgets('menu Více: nástroje do kuchyně a minutka', (tester) async {
    await pumpApp(tester, location: Routes.more);
    for (final label in [
      'Minutka',
      'Co mám doma',
      'Akce v Sušici',
      'Recepty z akcí',
      'Plán vaření',
      'Teploty',
      'Převody',
      'Deník',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Minutka'));
    await tester.pumpAndSettle();
    expect(find.text('Rychlý start'), findsOneWidget);
    expect(find.text('Vejce natvrdo'), findsOneWidget);
  });

  testWidgets('recepty z akcí bez uložených akcí poradí, co dělat', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: Routes.saleRecipes,
      recipes: [sampleRecipe()],
    );
    expect(
      find.text('Zatím nejsou uložené žádné ověřené akce.'),
      findsOneWidget,
    );
    expect(find.text('Klepněte na Najít akce'), findsOneWidget);
    expect(find.text('Najít akce'), findsOneWidget);
  });

  testWidgets('akce bez přihlášení: žádné vymyšlené akce, jen výzva', (
    tester,
  ) async {
    await pumpApp(tester, location: Routes.offers);
    expect(find.text('Akce v Sušici'), findsOneWidget);
    expect(find.text('Letáky se zatím nestáhly.'), findsOneWidget);
    expect(find.text('Zatím žádné uložené akce'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-offer-a1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('převody: hrnek mouky na gramy', (tester) async {
    await pumpApp(tester, location: Routes.converter);
    expect(find.text('≈ 140 g'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Kolik').first, '2');
    await tester.pump();
    expect(find.text('≈ 280 g'), findsOneWidget);
  });

  testWidgets('co mám doma: najde recept a řekne, co chybí', (tester) async {
    await pumpApp(tester, location: Routes.pantry, recipes: [sampleRecipe()]);
    await tester.enterText(find.byType(TextField).first, 'žebra');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Žebra BBQ'), findsOneWidget);
    expect(
      find.text('Chybí: BBQ omáčka, Hořčice plnotučná'),
      findsOneWidget,
      reason: 'sůl je základ',
    );
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

  group('nákupní seznamy', () {
    final now = DateTime.utc(2026, 11, 15);
    final kure = ShoppingList(
      id: 'l1',
      name: 'Kuře na paprice',
      createdAt: now,
      updatedAt: now,
    );
    final tyden = ShoppingList(
      id: 'l2',
      name: 'Týden',
      householdId: 'rodina',
      createdAt: now,
      updatedAt: now,
    );
    ShoppingItem item(
      String id,
      String name, {
      double? quantity,
      String unit = '',
      bool checked = false,
      String note = '',
      String listId = 'l1',
    }) => ShoppingItem(
      id: id,
      listId: listId,
      name: name,
      quantity: quantity,
      unit: unit,
      checked: checked,
      note: note,
      createdAt: now,
      updatedAt: now,
    );
    final items = [
      item('1', 'Kuřecí stehna s kostí', quantity: 1500, unit: 'g'),
      item('2', 'Cibule', quantity: 300, unit: 'g'),
      item('3', 'Máslo', quantity: 60, unit: 'g', checked: true),
      item('4', 'Sůl', note: 'podle chuti'),
      item('5', 'Mléko', quantity: 1, unit: 'l', listId: 'l2'),
    ];

    testWidgets('záložka Nákupy ukazuje seznamy a kolik zbývá', (tester) async {
      await pumpApp(
        tester,
        location: Routes.shopping,
        shoppingLists: [kure, tyden],
        shoppingItems: items,
      );
      expect(find.text('Nákupy'), findsWidgets);
      expect(find.text('Kuře na paprice'), findsOneWidget);
      expect(find.text('Zbývá koupit 3 z 4'), findsOneWidget);
      expect(find.text('Zbývá koupit 1 z 1'), findsOneWidget);
      expect(find.byIcon(Icons.group_outlined), findsOneWidget);
      expect(find.text('Nový seznam'), findsOneWidget);
    });

    testWidgets('prázdná záložka Nákupy nabídne založení', (tester) async {
      await pumpApp(tester, location: Routes.shopping);
      expect(find.text('Zatím žádný nákupní seznam'), findsOneWidget);
    });

    testWidgets('seznam: kategorie, množství, koupené zvlášť, odstranění', (
      tester,
    ) async {
      await pumpApp(
        tester,
        location: Routes.shoppingList('l1'),
        shoppingLists: [kure, tyden],
        shoppingItems: items,
      );
      expect(find.text('Kuře na paprice'), findsOneWidget);
      expect(find.text('Maso a ryby'), findsOneWidget);
      expect(find.text('Zelenina a ovoce'), findsOneWidget);
      expect(find.text('Mléčné výrobky a vejce'), findsOneWidget);
      expect(find.text('Koření'), findsOneWidget);
      expect(find.text('1,5 kg'), findsOneWidget);
      expect(find.text('podle chuti'), findsOneWidget);
      expect(
        find.text('Mléko'),
        findsNothing,
        reason: 'patří do jiného seznamu',
      );
      expect(find.text('Odstranit nakoupené (1)'), findsOneWidget);
      expect(find.text('Přidat položku'), findsOneWidget);
      final butter = tester.widget<Text>(find.text('Máslo'));
      expect(butter.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('nejvýhodnější nákup: kompaktní panel jde skrýt', (
      tester,
    ) async {
      await pumpApp(
        tester,
        location: Routes.shoppingList('l1'),
        shoppingLists: [kure],
        shoppingItems: items,
      );
      expect(
        find.text('Nejvýhodnější nákup – ceny zatím neznám'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Skrýt nejvýhodnější nákup'));
      await tester.pumpAndSettle();
      expect(
        find.text('Nejvýhodnější nákup – ceny zatím neznám'),
        findsNothing,
      );
      expect(
        find.text('Maso a ryby'),
        findsOneWidget,
        reason: 'seznam zůstává',
      );
      await tester.tap(find.byTooltip('Zobrazit nejvýhodnější nákup'));
      await tester.pumpAndSettle();
      expect(
        find.text('Nejvýhodnější nákup – ceny zatím neznám'),
        findsOneWidget,
      );
    });

    testWidgets('formulář položky odhadne kategorii podle názvu', (
      tester,
    ) async {
      await pumpApp(
        tester,
        location: Routes.shoppingList('l1'),
        shoppingLists: [kure],
        shoppingItems: items,
      );
      await tester.tap(find.text('Přidat položku'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Smetana 31 %');
      await tester.pump();
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Mléčné výrobky a vejce'),
      );
      expect(chip.selected, isTrue);
      expect(find.text('Přidat a další'), findsOneWidget);
    });
  });

  testWidgets('recept s chilli jde zobrazit a uložit bez chilli', (
    tester,
  ) async {
    final hot = sampleRecipe().copyWith(
      ingredients: const [
        Ingredient(id: 'i1', name: 'Vepřová žebra', quantity: 2, unit: 'kg'),
        Ingredient(id: 'i2', name: 'Chilli paprička', quantity: 2, unit: 'ks'),
      ],
    );
    await pumpApp(tester, location: Routes.recipe('recipe-1'), recipes: [hot]);
    final toggle = find.widgetWithText(SwitchListTile, 'Bez chilli');
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('Pálivé: Chilli paprička'), findsOneWidget);
    expect(find.textContaining('Chilli paprička'), findsWidgets);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Uložit jako recept bez chilli'), findsOneWidget);
    expect(
      find.textContaining('Zobrazeno bez: Chilli paprička'),
      findsOneWidget,
    );
    expect(find.textContaining('2 ks'), findsNothing);
  });

  testWidgets('Nabídka → Plán vaření otevře plán, ne černou obrazovku', (
    tester,
  ) async {
    final router = await pumpApp(tester, location: Routes.home);
    router.push(Routes.more);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Plán vaření'));
    await tester.tap(find.text('Plán vaření'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Na co mám chuť'), findsOneWidget);
    expect(find.text('Plánování'), findsOneWidget);
  });

  testWidgets('Mám chuť má vlastní obrazovku v nabídce i na hlavní', (
    tester,
  ) async {
    final router = await pumpApp(tester, location: Routes.home);
    router.push(Routes.more);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mám chuť'));
    await tester.tap(find.text('Mám chuť'));
    await tester.pumpAndSettle();
    expect(find.text('Na co mám chuť'), findsOneWidget);
    expect(find.byKey(const Key('add-wish')), findsOneWidget);
  });

  testWidgets('přání „Mám chuť“ jde smazat viditelným tlačítkem', (
    tester,
  ) async {
    final wish = MealWish(
      id: 'w1',
      title: 'Domácí máslové rohlíky',
      authorName: 'Marti',
      createdAt: DateTime.utc(2026, 11, 15),
      updatedAt: DateTime.utc(2026, 11, 15),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          wishesProvider.overrideWith((ref) => Stream.value([wish])),
          householdProvider.overrideWith((ref) async => null),
        ],
        child: const MaterialApp(home: Scaffold(body: WishesSection())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Domácí máslové rohlíky'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-wish-w1')));
    await tester.pumpAndSettle();
    expect(find.text('Smazat přání?'), findsOneWidget);
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(find.text('Smazat přání?'), findsNothing);
  });
}

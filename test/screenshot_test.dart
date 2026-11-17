// Vykreslí domovskou obrazovku na rozměrech Samsung Galaxy S24 Ultra
// a iPhone 13 mini se skutečnými fonty a uloží PNG do build/screenshots
// (v CI se nahrají jako artefakt pro vizuální porovnání s předlohou).
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/app_config.dart';
import 'package:hinkredience/app/kitchen_providers.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/app/router.dart';
import 'package:hinkredience/core/app_theme.dart';
import 'package:hinkredience/core/material.dart';
import 'package:hinkredience/core/sale_dishes.dart';
import 'package:hinkredience/data/docs_repository.dart';
import 'package:hinkredience/data/photo_store.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('${dir.path}/$f');
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
    }
    await loader.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

List<Recipe> _recipes() {
  var n = 0;
  final now = DateTime.utc(2026, 11, 17);
  final list = [
    for (final dish in allSaleDishes)
      dishToRecipe(dish, newId: () => 'id${n++}', now: now),
  ];
  // Pár oblíbených jako v předloze.
  const fav = {
    'Svíčková na smetaně',
    'Lasagne s masovým ragú',
    'Pečená kuřecí stehna s bramborami',
    'Bramboráky s kysaným zelím',
  };
  return [
    for (final r in list)
      fav.contains(r.title) ? r.copyWith(isFavorite: true) : r,
    Recipe(
      id: 'losos',
      title: 'Losos sous-vide 43 °C',
      category: 'Ryby',
      prepMinutes: 10,
      cookMinutes: 32,
      tags: const ['Sous-vide', 'Pánev', 'Rychlá večeře'],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      steps: const [
        RecipeStep(
          id: 's1',
          instruction: 'Připravujte ve vodní lázni při 43 °C po dobu 30 minut.',
          durationMinutes: 30,
        ),
        RecipeStep(
          id: 's2',
          instruction: 'Krátce opečte na rozpálené pánvi.',
          durationMinutes: 2,
        ),
      ],
    ),
  ];
}

Future<void> _shot(
  WidgetTester tester, {
  required String name,
  required Size logical,
  required double dpr,
  double scrollBy = 0,
  List<Finder> taps = const [],
}) async {
  tester.view.physicalSize = logical * dpr;
  tester.view.devicePixelRatio = dpr;
  tester.view.padding = FakeViewPadding(top: 40 * dpr, bottom: 24 * dpr);
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({'greeting_name': 'Pájo'});
  final prefs = await SharedPreferences.getInstance();
  final router = createRouter(initialLocation: Routes.home);
  addTearDown(router.dispose);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: ProviderScope(
        retry: (retryCount, error) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appConfigProvider.overrideWithValue(AppConfig.load(prefs)),
          photoStoreProvider.overrideWithValue(
            PhotoStore(Directory.systemTemp),
          ),
          recipeRepositoryProvider.overrideWith(
            (ref) => Completer<RecipeRepository>().future,
          ),
          docsRepositoryProvider.overrideWith(
            (ref) => Completer<DocsRepository>().future,
          ),
          allRecipesProvider.overrideWith((ref) => Stream.value(_recipes())),
          shoppingProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          locale: const Locale('cs'),
          supportedLocales: const [Locale('cs')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Obrázky z assetů se dekódují mimo falešný čas testu.
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
  });
  await tester.pumpAndSettle();
  for (final finder in taps) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }
  if (scrollBy != 0) {
    await tester.drag(
      find.byKey(const Key('home-scroll')),
      Offset(0, -scrollBy),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
    await tester.pumpAndSettle();
  }
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  final out = File('build/screenshots/$name.png')..createSync(recursive: true);
  out.writeAsBytesSync(bytes!);
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('snímek: Galaxy S24 Ultra', (tester) async {
    await _shot(
      tester,
      name: 'home_s24_ultra',
      logical: const Size(412, 891),
      dpr: 2,
    );
    expect(find.text('Kategorie receptů'), findsOneWidget);
  });

  testWidgets('snímek: Galaxy S24 Ultra – níž', (tester) async {
    await _shot(
      tester,
      name: 'home_s24_ultra_scrolled',
      logical: const Size(412, 891),
      dpr: 2,
      scrollBy: 700,
    );
  });

  testWidgets('snímek: iPhone 13 mini', (tester) async {
    await _shot(
      tester,
      name: 'home_iphone13mini',
      logical: const Size(375, 812),
      dpr: 2,
    );
    expect(find.text('Štítky'), findsOneWidget);
  });

  testWidgets('snímek: filtry Sous-vide + Do 60 min (S24 Ultra)', (
    tester,
  ) async {
    await _shot(
      tester,
      name: 'filters_s24_ultra',
      logical: const Size(412, 891),
      dpr: 2,
      taps: [find.text('Sous-vide'), find.byKey(const Key('time-upTo60'))],
      scrollBy: 260,
    );
    expect(find.text('Nalezeno: 1 recept'), findsOneWidget);
  });

  testWidgets('snímek: prázdný výsledek s vysvětlením (iPhone 13 mini)', (
    tester,
  ) async {
    await _shot(
      tester,
      name: 'filters_empty_iphone13mini',
      logical: const Size(375, 812),
      dpr: 2,
      taps: [find.text('Sous-vide'), find.byKey(const Key('time-upTo15'))],
      scrollBy: 300,
    );
    expect(find.text('Nalezeno: 0 receptů'), findsOneWidget);
  });
}

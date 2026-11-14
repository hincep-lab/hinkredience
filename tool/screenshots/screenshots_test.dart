// Generuje snímky obrazovek do docs/screenshots (pro README a kontrolu designu).
//
// Spuštění:  flutter test tool/screenshots --update-goldens
// Nejde o běžný test – záměrně leží mimo složku test/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../test/support.dart';

Future<void> loadFonts() async {
  final manifest =
      json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest) {
    final loader = FontLoader((entry as Map)['family'] as String);
    for (final font in entry['fonts'] as List) {
      loader.addFont(rootBundle.load((font as Map)['asset'] as String));
    }
    await loader.load();
  }
  final fonts = p.join(
    Platform.environment['FLUTTER_ROOT']!,
    'bin',
    'cache',
    'artifacts',
    'material_fonts',
  );
  final roboto = FontLoader('Roboto');
  for (final name in ['Regular', 'Medium', 'Bold', 'Italic', 'Black']) {
    final bytes = File(p.join(fonts, 'Roboto-$name.ttf')).readAsBytesSync();
    roboto.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await roboto.load();
}

final recipes = [
  sampleRecipe().copyWith(rating: 5.0, isFavorite: true),
  sampleRecipe(
    id: 'r2',
    title: 'Svíčková na smetaně',
    category: 'Omáčky',
  ).copyWith(
    description: 'Nedělní klasika s karlovarským knedlíkem',
    rating: 4.5,
    prepMinutes: 40,
    cookMinutes: 150,
  ),
  sampleRecipe(id: 'r3', title: 'Kuře na paprice', category: 'Drůbež').copyWith(
    description: 'Krémové, jemné, vhodné i pro děti',
    prepMinutes: 15,
    cookMinutes: 45,
    isFavorite: true,
  ),
  sampleRecipe(id: 'r4', title: 'Domácí pizza', category: 'Pizza').copyWith(
    description: 'Těsto zrající 48 hodin',
    prepMinutes: 30,
    cookMinutes: 6,
    temperatures: const ['Trouba 300 °C'],
  ),
];

Future<void> shoot(
  WidgetTester tester,
  String name, {
  required String location,
  List<Recipe> data = const [],
  Future<void> Function()? before,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
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
        allRecipesProvider.overrideWith((ref) => Stream.value(data)),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: AppTheme.dark(),
        locale: const Locale('cs'),
        supportedLocales: const [Locale('cs')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
      ),
    ),
  );
  // Obrázky z assets se v testech načítají jen ve skutečném čase.
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
  if (before != null) await before();
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../docs/screenshots/$name.png'),
  );
}

void main() {
  setUpAll(loadFonts);

  testWidgets('úvod', (tester) async {
    await shoot(tester, '01-uvod', location: Routes.splash, settle: false);
    // Úvodní obrazovka čeká 1,4 s a pak přechází dál – necháme časovač doběhnout.
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('prihlaseni', (tester) async {
    await shoot(tester, '02-prihlaseni', location: Routes.auth);
  });

  testWidgets('domu', (tester) async {
    await shoot(tester, '03-domu', location: Routes.home, data: recipes);
  });

  testWidgets('domu-prazdna', (tester) async {
    await shoot(tester, '04-domu-prazdna-kucharka', location: Routes.home);
  });

  testWidgets('kategorie', (tester) async {
    await shoot(
      tester,
      '05-kategorie',
      location: Routes.recipes,
      data: recipes,
    );
  });

  testWidgets('seznam', (tester) async {
    await shoot(
      tester,
      '06-recepty',
      location: Routes.recipes,
      data: recipes,
      before: () async {
        await tester.tap(find.text('Vše'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('detail', (tester) async {
    await shoot(
      tester,
      '07-detail',
      location: Routes.recipe('recipe-1'),
      data: recipes,
    );
  });

  testWidgets('postup', (tester) async {
    await shoot(
      tester,
      '08-postup',
      location: Routes.recipe('recipe-1'),
      data: recipes,
      before: () async {
        await tester.tap(find.text('Postup'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('vice', (tester) async {
    await shoot(tester, '09-vice', location: Routes.more, data: recipes);
  });
}

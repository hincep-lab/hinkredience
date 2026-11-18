import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/core/conversions.dart';
import 'package:hinkredience/core/cook_timer.dart';
import 'package:hinkredience/core/cooking_services.dart';
import 'package:hinkredience/core/pantry.dart';
import 'package:hinkredience/core/quick_timers.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:shared_preferences/shared_preferences.dart';

Recipe recipe(String title, List<String> ingredients) => Recipe(
  id: title,
  title: title,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  ingredients: [
    for (final (i, name) in ingredients.indexed)
      Ingredient(id: '$title-$i', name: name),
  ],
);

class RecordingAlerts implements CookAlerts {
  final rung = <String>[];
  final scheduled = <String>[];
  final cancelled = <String>[];
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> schedule(CookTimer timer) async => scheduled.add(timer.label);
  @override
  Future<void> cancel(CookTimer timer) async => cancelled.add(timer.label);
  @override
  Future<void> ring(CookTimer timer) async => rung.add(timer.label);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('převody', () {
    test('hrnky a lžíce na gramy podle suroviny', () {
      expect(toGrams(1, 'hrnek (250 ml)', 'Mouka hladká'), closeTo(140, 0.01));
      expect(toGrams(1, 'hrnek (250 ml)', 'Cukr krupice'), closeTo(200, 0.01));
      expect(toGrams(1, 'lžíce', 'Máslo'), closeTo(14.25, 0.01));
      expect(toGrams(2, 'dl', 'Mléko'), closeTo(206, 0.01));
      expect(
        fromGrams(140, 'hrnek (250 ml)', 'Mouka hladká'),
        closeTo(1, 1e-9),
      );
      expect(toGrams(1, 'hrnek (250 ml)', 'Neznámá'), isNull);
      expect(toGrams(-1, 'lžíce', 'Máslo'), isNull);
    });

    test('teploty a zápis', () {
      expect(celsiusToFahrenheit(180), 356);
      expect(fahrenheitToCelsius(350), closeTo(176.7, 0.1));
      expect(fanFromConventional(200), 180);
      expect(gasMarks[4], 180);
      expect(formatConverted(140.4), '140');
      expect(formatConverted(6.26), '6,3');
      expect(formatConverted(0.5, grams: false), '½');
    });
  });

  group('co mám doma', () {
    final recipes = [
      recipe('Palačinky', ['Hladká mouka', 'Mléko', 'Vejce', 'Sůl']),
      recipe('Svíčková', ['Hovězí zadní', 'Smetana', 'Mrkev', 'Celer']),
      recipe('Míchaná vejce', ['Vejce', 'Máslo', 'Sůl', 'Pepř']),
      recipe('Kuře na paprice', ['Kuřecí stehna', 'Paprika', 'Smetana']),
    ];

    test('nejdřív recepty, kterým chybí nejméně', () {
      final m = matchPantry(recipes, ['vejce', 'máslo', 'mouka', 'mléko']);
      expect(m.map((x) => x.recipe.title), ['Míchaná vejce', 'Palačinky']);
      expect(m.first.missing, isEmpty, reason: 'sůl a pepř jsou základy');
      expect(m[1].missing, isEmpty);
    });

    test('chybějící suroviny a bez základů', () {
      final m = matchPantry(recipes, ['vejce'], withStaples: false);
      expect(m.map((x) => x.recipe.title), ['Míchaná vejce', 'Palačinky']);
      expect(m.first.missing.map((i) => i.name), ['Máslo', 'Sůl', 'Pepř']);
      expect(m.first.coverage, 0.25);
    });

    test('shoda podle slov, ne podle kousku textu', () {
      expect(pantryHas('kuře', 'Kuřecí stehna'), isTrue);
      expect(pantryHas('mouka', 'Hladká mouka'), isTrue);
      expect(pantryHas('maso', 'Máslo'), isFalse);
      final m = matchPantry(recipes, ['smetana']);
      expect(m.map((x) => x.recipe.title), ['Kuře na paprice', 'Svíčková']);
      expect(matchPantry(recipes, const ['  ']), isEmpty);
    });
  });

  group('minutky', () {
    late ProviderContainer container;
    late RecordingAlerts alerts;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      alerts = RecordingAlerts();
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          cookAlertsProvider.overrideWithValue(alerts),
        ],
      );
    });
    tearDown(() => container.dispose());

    test('zazvoní jednou, vydrží restart, potvrzení ji zruší', () async {
      final timers = container.read(quickTimersProvider.notifier);
      await timers.start('Vejce natvrdo', const Duration(minutes: 10));
      await Future<void>.delayed(Duration.zero);
      final timer = container.read(quickTimersProvider).single;
      expect(alerts.scheduled, ['Vejce natvrdo']);

      final end = timer.endsAt!;
      timers.tick(end.subtract(const Duration(seconds: 5)));
      expect(alerts.rung, isEmpty);
      timers.tick(end.add(const Duration(seconds: 1)));
      timers.tick(end.add(const Duration(seconds: 2)));
      expect(alerts.rung, ['Vejce natvrdo'], reason: 'jen jednou');
      expect(timers.ringing(end.add(const Duration(seconds: 3))), hasLength(1));

      // Po „restartu“ aplikace se minutka načte z uložených dat.
      final again = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          cookAlertsProvider.overrideWithValue(alerts),
        ],
      );
      addTearDown(again.dispose);
      expect(again.read(quickTimersProvider).single.label, 'Vejce natvrdo');

      await timers.stop(timer);
      expect(container.read(quickTimersProvider), isEmpty);
      expect(alerts.cancelled, ['Vejce natvrdo']);
    });

    test('pozastavená minutka nezvoní', () async {
      final timers = container.read(quickTimersProvider.notifier);
      await timers.start('Rýže', const Duration(minutes: 18));
      final timer = container.read(quickTimersProvider).single;
      await timers.pause(timer);
      timers.tick(DateTime.now().toUtc().add(const Duration(hours: 1)));
      expect(alerts.rung, isEmpty);
      expect(container.read(quickTimersProvider).single.isRunning, isFalse);
      await timers.resume(container.read(quickTimersProvider).single);
      expect(container.read(quickTimersProvider).single.isRunning, isTrue);
    });
  });

  test('hotové minutky mají rozumné časy', () {
    for (final (name, minutes, _) in timerPresets) {
      expect(minutes, inInclusiveRange(1, 120), reason: name);
    }
  });
}

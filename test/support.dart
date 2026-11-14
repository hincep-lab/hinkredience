import 'dart:io';

import 'package:hinkredience/data/app_database.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Testovací prostředí se skutečnou databází SQLite v dočasné složce.
class TestEnvironment {
  TestEnvironment._(this.directory);

  final Directory directory;
  final _databases = <AppDatabase>[];
  var _now = DateTime.utc(2026, 11, 14, 12);
  var _ids = 0;

  static Future<TestEnvironment> create() async {
    sqfliteFfiInit();
    return TestEnvironment._(
      await Directory.systemTemp.createTemp('hinkredience_test_'),
    );
  }

  /// Posune testovací hodiny.
  void advance(Duration duration) => _now = _now.add(duration);

  DateTime get now => _now;

  Future<RecipeRepository> repository([String name = 'test.db']) async {
    final database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: p.join(directory.path, name),
    );
    _databases.add(database);
    final prefix = name.replaceAll('.db', '');
    return RecipeRepository(
      database,
      clock: () => _now,
      newId: () => '$prefix-id-${++_ids}',
    );
  }

  Future<void> dispose() async {
    for (final database in _databases) {
      await database.close();
    }
    await directory.delete(recursive: true);
  }
}

Recipe sampleRecipe({
  String id = 'recipe-1',
  String title = 'Žebra BBQ',
  String category = 'Maso',
  String? ownerId,
}) => Recipe(
  id: id,
  ownerId: ownerId,
  title: title,
  description: 'Pomalá příprava, dokonalá chuť',
  category: category,
  servings: 4,
  prepMinutes: 30,
  cookMinutes: 630,
  temperatures: const ['Trouba 150 °C'],
  equipment: const ['Trouba'],
  notes: 'Přikrýt alobalem.',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
  ingredients: const [
    Ingredient(id: 'i1', name: 'Vepřová žebra', quantity: 2, unit: 'kg'),
    Ingredient(id: 'i2', name: 'BBQ omáčka', quantity: 200, unit: 'ml'),
    Ingredient(id: 'i3', name: 'Hořčice plnotučná', quantity: 2, unit: 'lžíce'),
    Ingredient(id: 'i4', name: 'Sůl'),
  ],
  steps: const [
    RecipeStep(id: 's1', instruction: 'Žebra osolte a potřete hořčicí.'),
    RecipeStep(
      id: 's2',
      instruction: 'Přikryjte alobalem a pečte.',
      durationMinutes: 180,
      temperatureC: 150,
    ),
  ],
);

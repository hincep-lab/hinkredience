import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'recipe.dart';

/// Správa receptů nad místní databází.
///
/// Každá změna označí recept jako „dirty“ (čeká na odeslání) a po úspěšné
/// synchronizaci se příznak smaže. Úpravy obsahu vytvářejí novou verzi
/// v historii; původní stav tak zůstává vždy zachován.
class RecipeRepository {
  RecipeRepository(
    this._database, {
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _database;
  final DateTime Function() _clock;
  final String Function() _newId;
  final _changes = StreamController<void>.broadcast();

  Database get _db => _database.db;

  /// Událost při každé změně dat – obrazovky se podle ní obnovují.
  Stream<void> get changes => _changes.stream;

  String newId() => _newId();

  DateTime now() => _clock();

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();

  // ---------------------------------------------------------------- čtení

  /// Všechny recepty včetně smazaných (koš), nejnovější úpravy první.
  Future<List<Recipe>> getAll() async {
    final rows = await _db.query('recipes', orderBy: 'updated_at DESC');
    return [for (final row in rows) _fromRow(row)];
  }

  Future<Recipe?> getById(String id) async {
    final rows = await _db.query('recipes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<List<RecipeVersion>> versions(String recipeId) async {
    final rows = await _db.query(
      'recipe_versions',
      where: 'recipe_id = ?',
      whereArgs: [recipeId],
      orderBy: 'version_number DESC',
    );
    return [for (final row in rows) _versionFromRow(row)];
  }

  // ---------------------------------------------------------------- zápis

  /// Uloží nový recept jako verzi 1.
  Future<Recipe> create(Recipe draft) async {
    final now = _clock();
    final recipe = draft.copyWith(
      currentVersion: 1,
      createdAt: now,
      updatedAt: now,
      deletedAt: null,
    );
    await _db.transaction((txn) async {
      await _put(txn, recipe, dirty: true);
      await _putVersion(txn, recipe, 'Původní postup', now);
    });
    _notify();
    return recipe;
  }

  /// Uloží úpravu obsahu receptu a zapíše novou verzi do historie.
  Future<Recipe> update(Recipe edited, {String changeSummary = ''}) async {
    final now = _clock();
    final recipe = edited.copyWith(
      currentVersion: edited.currentVersion + 1,
      updatedAt: now,
    );
    await _db.transaction((txn) async {
      await _put(txn, recipe, dirty: true);
      await _putVersion(txn, recipe, changeSummary, now);
    });
    _notify();
    return recipe;
  }

  /// Drobná změna bez nové verze (oblíbené, hodnocení, fotky, koš).
  Future<Recipe?> _touch(String id, Recipe Function(Recipe) change) async {
    final current = await getById(id);
    if (current == null) return null;
    final recipe = change(current).copyWith(updatedAt: _clock());
    await _put(_db, recipe, dirty: true);
    _notify();
    return recipe;
  }

  Future<void> setFavorite(String id, bool favorite) =>
      _touch(id, (r) => r.copyWith(isFavorite: favorite));

  Future<void> setRating(String id, double? rating) =>
      _touch(id, (r) => r.copyWith(rating: rating));

  Future<void> setPhotos(String id, List<RecipePhoto> photos) =>
      _touch(id, (r) => r.copyWith(photos: photos));

  /// Přesune recept do koše. Dá se obnovit pomocí [restore].
  Future<void> softDelete(String id) =>
      _touch(id, (r) => r.copyWith(deletedAt: _clock()));

  Future<void> restore(String id) =>
      _touch(id, (r) => r.copyWith(deletedAt: null));

  /// Vytvoří kopii receptu s novým názvem a vlastní historií.
  Future<Recipe?> duplicate(String id, {String? ownerId}) async {
    final source = await getById(id);
    if (source == null) return null;
    final copy = source.copyWith(
      id: _newId(),
      ownerId: ownerId ?? source.ownerId,
      title: '${source.title} (kopie)',
      isFavorite: false,
      lastCookedAt: null,
      // Fotky kopie sdílí stejné soubory, ale mají vlastní záznamy.
      photos: [for (final p in source.photos) p.copyWith(id: _newId())],
      ingredients: [
        for (final i in source.ingredients) i.copyWith(id: _newId()),
      ],
      steps: [for (final s in source.steps) s.copyWith(id: _newId())],
    );
    return create(copy);
  }

  // ----------------------------------------------------------- kategorie

  Future<List<String>> customCategories() async {
    final rows = await _db.query(
      'custom_categories',
      orderBy: 'position, name',
    );
    return [for (final row in rows) row['name'] as String];
  }

  Future<void> addCustomCategory(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _db.insert('custom_categories', {
      'name': trimmed,
      'position': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    _notify();
  }

  // ------------------------------------------------------- synchronizace

  Future<List<Recipe>> dirtyRecipes() async {
    final rows = await _db.query(
      'recipes',
      where: 'dirty = 1',
      orderBy: 'updated_at ASC',
    );
    return [for (final row in rows) _fromRow(row)];
  }

  Future<int> dirtyCount() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM recipes WHERE dirty = 1',
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// Označí recept jako odeslaný – jen pokud se mezitím znovu nezměnil.
  Future<void> markClean(String id, DateTime updatedAt) async {
    await _db.update(
      'recipes',
      {'dirty': 0},
      where: 'id = ? AND updated_at = ?',
      whereArgs: [id, updatedAt.toUtc().toIso8601String()],
    );
  }

  /// Doplní fotkám cesty v úložišti, aniž by změnil čas úpravy receptu.
  Future<void> savePhotoUploads(String id, List<RecipePhoto> photos) async {
    final current = await getById(id);
    if (current == null) return;
    final byId = {for (final p in photos) p.id: p};
    final merged = [
      for (final p in current.photos)
        byId[p.id]?.remotePath != null
            ? p.copyWith(remotePath: byId[p.id]!.remotePath)
            : p,
    ];
    await _db.update(
      'recipes',
      {'data': jsonEncode(current.copyWith(photos: merged).toJson())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<RecipeVersion>> dirtyVersions() async {
    final rows = await _db.query(
      'recipe_versions',
      where: 'dirty = 1',
      orderBy: 'created_at ASC',
    );
    return [for (final row in rows) _versionFromRow(row)];
  }

  Future<void> markVersionClean(String id) async {
    await _db.update(
      'recipe_versions',
      {'dirty': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Zapíše stav ze serveru. Platí pravidlo „poslední úprava vyhrává“:
  /// neodeslaná místní změna, která je novější, se nepřepíše.
  /// Vrací `true`, pokud byl místní záznam změněn.
  Future<bool> applyRemote(
    Recipe remote, {
    List<RecipeVersion> versions = const [],
  }) async {
    var applied = false;
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'recipes',
        where: 'id = ?',
        whereArgs: [remote.id],
      );
      if (rows.isEmpty) {
        await _put(txn, remote, dirty: false);
        applied = true;
      } else {
        final local = _fromRow(rows.first);
        final localDirty = rows.first['dirty'] == 1;
        final localIsNewer = !remote.updatedAt.isAfter(local.updatedAt);
        if (!(localDirty && localIsNewer)) {
          // Cesty k fotkám v telefonu server nezná – zachováme je.
          final localPaths = {for (final p in local.photos) p.id: p.localPath};
          final merged = remote.copyWith(
            photos: [
              for (final p in remote.photos)
                p.copyWith(localPath: localPaths[p.id]),
            ],
          );
          await _put(txn, merged, dirty: false);
          applied = true;
        }
      }
      for (final version in versions) {
        await txn.insert('recipe_versions', {
          'id': version.id,
          'recipe_id': version.recipeId,
          'version_number': version.versionNumber,
          'snapshot': jsonEncode(version.snapshot),
          'change_summary': version.changeSummary,
          'created_at': version.createdAt.toUtc().toIso8601String(),
          'dirty': 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    if (applied) _notify();
    return applied;
  }

  /// Převezme recepty z jiné místní databáze (např. vytvořené před přihlášením)
  /// a přiřadí je účtu [ownerId]. Vrací počet převzatých receptů.
  Future<int> importFrom(
    RecipeRepository other, {
    required String ownerId,
  }) async {
    final recipes = await other.getAll();
    var count = 0;
    for (final recipe in recipes) {
      if (await getById(recipe.id) != null) continue;
      await _db.transaction((txn) async {
        await _put(txn, recipe.copyWith(ownerId: ownerId), dirty: true);
        for (final version in await other.versions(recipe.id)) {
          await txn.insert('recipe_versions', {
            'id': version.id,
            'recipe_id': version.recipeId,
            'version_number': version.versionNumber,
            'snapshot': jsonEncode(version.snapshot),
            'change_summary': version.changeSummary,
            'created_at': version.createdAt.toUtc().toIso8601String(),
            'dirty': 1,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });
      count++;
    }
    for (final category in await other.customCategories()) {
      await addCustomCategory(category);
    }
    if (count > 0) _notify();
    return count;
  }

  Future<String?> getMeta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) async {
    await _db.insert('meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------------------------------------------------------- pomocné

  Future<void> _put(
    DatabaseExecutor executor,
    Recipe recipe, {
    required bool dirty,
  }) async {
    await executor.insert('recipes', {
      'id': recipe.id,
      'data': jsonEncode(recipe.toJson()),
      'updated_at': recipe.updatedAt.toUtc().toIso8601String(),
      'deleted_at': recipe.deletedAt?.toUtc().toIso8601String(),
      'dirty': dirty ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _putVersion(
    DatabaseExecutor executor,
    Recipe recipe,
    String summary,
    DateTime now,
  ) async {
    await executor.insert('recipe_versions', {
      'id': _newId(),
      'recipe_id': recipe.id,
      'version_number': recipe.currentVersion,
      'snapshot': jsonEncode(recipe.toJson()),
      'change_summary': summary,
      'created_at': now.toUtc().toIso8601String(),
      'dirty': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Recipe _fromRow(Map<String, Object?> row) => Recipe.fromJson(
    Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
  );

  RecipeVersion _versionFromRow(Map<String, Object?> row) => RecipeVersion(
    id: row['id'] as String,
    recipeId: row['recipe_id'] as String,
    versionNumber: row['version_number'] as int,
    snapshot: Map<String, dynamic>.from(
      jsonDecode(row['snapshot'] as String) as Map,
    ),
    changeSummary: (row['change_summary'] as String?) ?? '',
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
  );
}

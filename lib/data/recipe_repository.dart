import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'recipe.dart';

/// Výsledek trvalého smazání receptů z koše.
class PurgeResult {
  const PurgeResult({required this.recipes, required this.orphanPhotoPaths});

  /// Smazané recepty.
  final List<Recipe> recipes;

  /// Cesty fotografií v telefonu, které už žádný recept nepoužívá.
  final List<String> orphanPhotoPaths;
}

/// Výsledek zapsání receptu ze serveru.
enum RemoteApply { applied, skipped, conflict }

/// Souběžná úprava: recept se změnil na serveru i v telefonu.
class RecipeConflict {
  const RecipeConflict({
    required this.recipe,
    required this.versions,
    required this.detectedAt,
    this.legacySchema = false,
  });

  /// Podoba receptu na serveru.
  final Recipe recipe;
  final List<RecipeVersion> versions;
  final DateTime detectedAt;
  final bool legacySchema;

  factory RecipeConflict.fromJson(String id, Map<String, dynamic> json) =>
      RecipeConflict(
        recipe: Recipe.fromJson(
          Map<String, dynamic>.from(json['recipe'] as Map),
        ),
        legacySchema: json['legacy_schema'] == true,
        detectedAt:
            DateTime.tryParse(json['detected_at'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        versions: [
          for (final v in (json['versions'] as List?) ?? const [])
            RecipeVersion(
              id: (v as Map)['id'] as String,
              recipeId: id,
              versionNumber: (v['version_number'] as num).toInt(),
              snapshot: Map<String, dynamic>.from(v['snapshot'] as Map),
              changeSummary: v['change_summary'] as String? ?? '',
              createdAt: DateTime.parse(v['created_at'] as String).toUtc(),
            ),
        ],
      );
}

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

  /// Štítky (způsob přípravy, příležitosti, vlastní) – bez nové verze.
  Future<void> setTags(String id, List<String> tags) =>
      _touch(id, (r) => r.copyWith(tags: tags));

  Future<void> setRating(String id, double? rating) =>
      _touch(id, (r) => r.copyWith(rating: rating));

  Future<void> setPhotos(String id, List<RecipePhoto> photos) =>
      _touch(id, (r) => r.copyWith(photos: photos));

  /// Zapíše, kdy se recept naposledy vařil (bez nové verze).
  Future<void> markCooked(String id, DateTime at) =>
      _touch(id, (r) => r.copyWith(lastCookedAt: at));

  /// Přesune recept do koše. Dá se obnovit pomocí [restore].
  Future<void> softDelete(String id) =>
      _touch(id, (r) => r.copyWith(deletedAt: _clock()));

  Future<void> restore(String id) =>
      _touch(id, (r) => r.copyWith(deletedAt: null));

  /// Natrvalo smaže recepty z koše včetně historie verzí. Smazání na serveru
  /// proběhne při příští synchronizaci (viz [pendingPurges]).
  ///
  /// Bez [ids] vysype celý koš. Recepty, které v koši nejsou, se nikdy
  /// nesmažou – trvalé smazání vždy předchází přesun do koše.
  ///
  /// Fotografie, které používá i jiný recept (kopie sdílí soubory
  /// s originálem), se k smazání nenabídnou.
  Future<PurgeResult> purgeDeleted({Iterable<String>? ids}) async {
    final wanted = ids?.toSet();
    late PurgeResult result;
    await _db.transaction((txn) async {
      result = await _purgeRows(
        txn,
        (r) => r.isDeleted && (wanted == null || wanted.contains(r.id)),
        queueRemote: true,
      );
    });
    if (result.recipes.isNotEmpty) _notify();
    return result;
  }

  /// Recept natrvalo smazaný na jiném zařízení (náhrobek ze serveru).
  /// Smaže se i tady – bez ohledu na to, jestli byl v koši – a server už
  /// nic dalšího nepotřebuje.
  Future<PurgeResult> applyTombstone(String id) async {
    late PurgeResult result;
    await _db.transaction((txn) async {
      result = await _purgeRows(txn, (r) => r.id == id, queueRemote: false);
      // Případné čekající smazání je tím vyřízené.
      await txn.delete(
        'meta',
        where: 'key IN (?, ?, ?)',
        whereArgs: [
          '$_purgePrefix$id',
          '$_conflictPrefix$id',
          '$_basePrefix$id',
        ],
      );
    });
    if (result.recipes.isNotEmpty) _notify();
    return result;
  }

  Future<PurgeResult> _purgeRows(
    Transaction txn,
    bool Function(Recipe) goes, {
    required bool queueRemote,
  }) async {
    final purged = <Recipe>[];
    final orphanLocal = <String>{};
    final all = [for (final row in await txn.query('recipes')) _fromRow(row)];
    final keptLocal = <String>{};
    final keptRemote = <String>{};
    for (final recipe in all.where((r) => !goes(r))) {
      for (final photo in recipe.photos) {
        if (photo.localPath != null) keptLocal.add(photo.localPath!);
        if (photo.remotePath != null) keptRemote.add(photo.remotePath!);
      }
    }
    for (final recipe in all.where(goes)) {
      await txn.delete('recipes', where: 'id = ?', whereArgs: [recipe.id]);
      await txn.delete(
        'recipe_versions',
        where: 'recipe_id = ?',
        whereArgs: [recipe.id],
      );
      await txn.delete(
        'meta',
        where: 'key IN (?, ?)',
        whereArgs: ['$_conflictPrefix${recipe.id}', '$_basePrefix${recipe.id}'],
      );
      if (queueRemote) {
        await txn.insert('meta', {
          'key': '$_purgePrefix${recipe.id}',
          'value': jsonEncode([
            for (final photo in recipe.photos)
              for (final path in [photo.remotePath, photo.thumbPath])
                if (path != null && !keptRemote.contains(photo.remotePath))
                  path,
          ]),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final photo in recipe.photos) {
        final path = photo.localPath;
        if (path != null && !keptLocal.contains(path)) orphanLocal.add(path);
      }
      purged.add(recipe);
    }
    return PurgeResult(recipes: purged, orphanPhotoPaths: orphanLocal.toList());
  }

  static const _purgePrefix = 'purge:';
  static const _conflictPrefix = 'conflict:';

  /// Čas poslední úpravy receptu, kterou známe ze serveru (základ pro
  /// rozpoznání souběžných úprav na dvou místech).
  static const _basePrefix = 'base:';

  /// Trvale smazané recepty, které je ještě potřeba smazat na serveru:
  /// id receptu → cesty jeho fotografií v úložišti.
  Future<Map<String, List<String>>> pendingPurges() async {
    final rows = await _db.query(
      'meta',
      where: 'key LIKE ?',
      whereArgs: ['$_purgePrefix%'],
    );
    return {
      for (final row in rows)
        (row['key'] as String).substring(_purgePrefix.length): [
          for (final path in jsonDecode(row['value'] as String) as List)
            path as String,
        ],
    };
  }

  /// Server už recept smazal – záznam o čekajícím smazání se odstraní.
  Future<void> clearPurge(String id) async {
    await _db.delete('meta', where: 'key = ?', whereArgs: ['$_purgePrefix$id']);
  }

  /// Vytvoří kopii receptu s novým názvem a vlastní historií.
  /// [transform] upraví obsah kopie (např. varianta bez chilli).
  Future<Recipe?> duplicate(
    String id, {
    String? ownerId,
    String? title,
    Recipe Function(Recipe source)? transform,
  }) async {
    final found = await getById(id);
    if (found == null) return null;
    final source = transform == null ? found : transform(found);
    final copy = source.copyWith(
      id: _newId(),
      ownerId: ownerId ?? source.ownerId,
      title: title ?? '${source.title} (kopie)',
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

  /// Čeká recept na odeslání?
  Future<bool> isDirty(String id) async {
    final rows = await _db.query(
      'recipes',
      columns: ['dirty'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isNotEmpty && rows.first['dirty'] == 1;
  }

  Future<int> dirtyCount() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM recipes WHERE dirty = 1',
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// Označí recept jako odeslaný – jen pokud se mezitím znovu nezměnil.
  Future<void> markClean(String id, DateTime updatedAt) async {
    final stamp = updatedAt.toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await txn.update(
        'recipes',
        {'dirty': 0},
        where: 'id = ? AND updated_at = ?',
        whereArgs: [id, stamp],
      );
      // Server teď má tuto podobu receptu.
      await txn.insert('meta', {
        'key': '$_basePrefix$id',
        'value': stamp,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Fotku stáhnutou do mezipaměti zapíše k receptu (bez nové verze, bez
  /// odesílání na server – jde jen o cestu v tomto telefonu).
  Future<void> saveCachedPhoto(
    String recipeId,
    String photoId,
    String localPath,
  ) async {
    final current = await getById(recipeId);
    if (current == null) return;
    var changed = false;
    final photos = [
      for (final p in current.photos)
        if (p.id == photoId && p.localPath != localPath)
          () {
            changed = true;
            return p.copyWith(localPath: localPath);
          }()
        else
          p,
    ];
    if (!changed) return;
    await _db.update(
      'recipes',
      {'data': jsonEncode(current.copyWith(photos: photos).toJson())},
      where: 'id = ?',
      whereArgs: [recipeId],
    );
    _notify();
  }

  /// Doplní fotkám cesty v úložišti, aniž by změnil čas úpravy receptu.
  Future<void> savePhotoUploads(String id, List<RecipePhoto> photos) async {
    final current = await getById(id);
    if (current == null) return;
    final byId = {for (final p in photos) p.id: p};
    final merged = [
      for (final p in current.photos)
        byId[p.id]?.remotePath != null
            ? p.copyWith(
                remotePath: byId[p.id]!.remotePath,
                thumbPath: byId[p.id]!.thumbPath,
              )
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

  /// Zapíše stav ze serveru.
  ///
  /// - Recept bez neodeslaných změn se aktualizuje.
  /// - Neodeslaná místní úprava se nikdy nepřepíše. Pokud se recept mezitím
  ///   změnil i na serveru, vznikne konflikt, který rozhodne uživatel
  ///   ([resolveConflict]); do té doby se recept neodesílá.
  ///
  /// [legacySchema] znamená, že server ještě nemá sloupce pro výtěžnost,
  /// čekání a druh kroků; místní hodnoty těchto polí se pak zachovají.
  Future<RemoteApply> applyRemote(
    Recipe remote, {
    List<RecipeVersion> versions = const [],
    bool legacySchema = false,
  }) async {
    var applied = false;
    var conflict = false;
    await _db.transaction((txn) async {
      // Recept natrvalo smazaný v tomto telefonu se ze serveru nevrací.
      final purge = await txn.query(
        'meta',
        where: 'key = ?',
        whereArgs: ['$_purgePrefix${remote.id}'],
      );
      if (purge.isNotEmpty) return;
      final rows = await txn.query(
        'recipes',
        where: 'id = ?',
        whereArgs: [remote.id],
      );
      Future<void> setBase() => txn.insert('meta', {
        'key': '$_basePrefix${remote.id}',
        'value': remote.updatedAt.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      if (rows.isEmpty) {
        await _put(txn, remote, dirty: false);
        await setBase();
        applied = true;
      } else {
        final local = _fromRow(rows.first);
        final localDirty = rows.first['dirty'] == 1;
        final baseRows = await txn.query(
          'meta',
          where: 'key = ?',
          whereArgs: ['$_basePrefix${remote.id}'],
        );
        final base = baseRows.isEmpty
            ? null
            : DateTime.tryParse(baseRows.first['value'] as String);
        final sameAsLocal = remote.updatedAt.isAtSameMomentAs(local.updatedAt);
        final remoteUnchanged =
            base != null && remote.updatedAt.isAtSameMomentAs(base);

        if (localDirty && (sameAsLocal || remoteUnchanged)) {
          // Server má jen to, co už známe – neodeslaná místní úprava platí.
          await setBase();
        } else if (localDirty) {
          // Recept se změnil na serveru (ChatGPT, druhý telefon) a zároveň
          // tady. Nic se nepřepíše: místní úprava zůstává, verze ze serveru
          // se uloží stranou a uživatel rozhodne, kterou ponechat.
          await txn.insert('meta', {
            'key': '$_conflictPrefix${remote.id}',
            'value': jsonEncode({
              'recipe': remote.toJson(),
              'legacy_schema': legacySchema,
              'versions': [
                for (final v in versions)
                  {
                    'id': v.id,
                    'version_number': v.versionNumber,
                    'snapshot': v.snapshot,
                    'change_summary': v.changeSummary,
                    'created_at': v.createdAt.toUtc().toIso8601String(),
                  },
              ],
              'detected_at': _clock().toUtc().toIso8601String(),
            }),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          conflict = true;
          return;
        } else {
          await _put(
            txn,
            _mergeRemote(local, remote, legacySchema: legacySchema),
            dirty: false,
          );
          await setBase();
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
    if (applied || conflict) _notify();
    return conflict
        ? RemoteApply.conflict
        : (applied ? RemoteApply.applied : RemoteApply.skipped);
  }

  /// Spojí stav ze serveru s místními údaji, které server nezná.
  Recipe _mergeRemote(
    Recipe local,
    Recipe remote, {
    required bool legacySchema,
  }) {
    // Cesty k fotkám v telefonu server nezná – zachováme je.
    final localPaths = {for (final p in local.photos) p.id: p.localPath};
    var merged = remote.copyWith(
      photos: [
        for (final p in remote.photos) p.copyWith(localPath: localPaths[p.id]),
      ],
    );
    if (legacySchema) {
      final localSteps = {for (final s in local.steps) s.id: s};
      merged = merged.copyWith(
        yieldUnit: local.yieldUnit,
        restMinutes: local.restMinutes,
        steps: [
          for (final s in merged.steps)
            RecipeStep(
              id: s.id,
              instruction: s.instruction,
              durationMinutes: s.durationMinutes,
              temperatureC: s.temperatureC,
              kind: localSteps[s.id]?.kind ?? s.kind,
              parallel: localSteps[s.id]?.parallel ?? s.parallel,
            ),
        ],
      );
    }
    return merged;
  }

  // -------------------------------------------------------------- konflikty

  /// Recepty, u kterých čeká na rozhodnutí souběžná úprava ze serveru.
  Future<Map<String, RecipeConflict>> conflicts() async {
    final rows = await _db.query(
      'meta',
      where: 'key LIKE ?',
      whereArgs: ['$_conflictPrefix%'],
    );
    final result = <String, RecipeConflict>{};
    for (final row in rows) {
      final id = (row['key'] as String).substring(_conflictPrefix.length);
      try {
        result[id] = RecipeConflict.fromJson(
          id,
          Map<String, dynamic>.from(jsonDecode(row['value'] as String) as Map),
        );
      } catch (_) {
        // Poškozený záznam – raději ho zahodíme, než aby blokoval odesílání.
        await _db.delete('meta', where: 'key = ?', whereArgs: [row['key']]);
      }
    }
    return result;
  }

  /// Vyřeší souběžnou úpravu. Žádná z obou podob se neztratí: ta, která se
  /// nepoužije, zůstane jako verze v historii receptu.
  ///
  /// [keepLocal] = ponechat úpravu z tohoto telefonu, jinak použít verzi
  /// ze serveru.
  Future<Recipe?> resolveConflict(String id, {required bool keepLocal}) async {
    final conflict = (await conflicts())[id];
    final local = await getById(id);
    if (conflict == null || local == null) return local;
    final now = _clock();
    late Recipe result;
    await _db.transaction((txn) async {
      final localVersions = [
        for (final row in await txn.query(
          'recipe_versions',
          where: 'recipe_id = ?',
          whereArgs: [id],
        ))
          (row: row, version: _versionFromRow(row)),
      ];
      final remoteNumbers = {
        for (final v in conflict.versions) v.versionNumber,
      };
      final remoteIds = {for (final v in conflict.versions) v.id};
      var maxNumber = [
        local.currentVersion,
        conflict.recipe.currentVersion,
        for (final v in conflict.versions) v.versionNumber,
        for (final v in localVersions) v.version.versionNumber,
      ].fold(0, (a, b) => a > b ? a : b);

      // Neodeslané místní verze, jejichž čísla mezitím obsadil server,
      // dostanou nová čísla – jinak by se při odeslání ztratily.
      for (final entry in localVersions) {
        final v = entry.version;
        if (entry.row['dirty'] == 1 &&
            remoteNumbers.contains(v.versionNumber) &&
            !remoteIds.contains(v.id)) {
          await txn.update(
            'recipe_versions',
            {'version_number': ++maxNumber},
            where: 'id = ?',
            whereArgs: [v.id],
          );
        }
      }
      for (final v in conflict.versions) {
        await txn.insert('recipe_versions', {
          'id': v.id,
          'recipe_id': id,
          'version_number': v.versionNumber,
          'snapshot': jsonEncode(v.snapshot),
          'change_summary': v.changeSummary,
          'created_at': v.createdAt.toUtc().toIso8601String(),
          'dirty': 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      final remote = _mergeRemote(
        local,
        conflict.recipe,
        legacySchema: conflict.legacySchema,
      );
      final (discarded, kept, discardedNote, keptNote) = keepLocal
          ? (
              remote,
              local,
              'Verze z jiného zařízení (nahrazena úpravou z telefonu)',
              'Ponechána úprava z tohoto telefonu',
            )
          : (
              local,
              remote,
              'Neodeslaná úprava z tohoto telefonu (nahrazena)',
              'Použita verze z jiného zařízení',
            );
      await _putVersion(
        txn,
        discarded.copyWith(currentVersion: ++maxNumber),
        discardedNote,
        now,
      );
      result = kept.copyWith(currentVersion: ++maxNumber, updatedAt: now);
      await _putVersion(txn, result, keptNote, now);
      await _put(txn, result, dirty: true);
      await txn.delete(
        'meta',
        where: 'key = ?',
        whereArgs: ['$_conflictPrefix$id'],
      );
    });
    _notify();
    return result;
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

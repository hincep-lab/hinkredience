import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/kitchen_math.dart';
import '../core/recipe_time.dart';
import 'recipe.dart';

/// Výsledek stažení změn ze serveru.
class RemoteChange {
  const RemoteChange({
    required this.recipe,
    required this.syncedAt,
    this.versions = const [],
    this.legacySchema = false,
  });

  final Recipe recipe;

  /// Serverový čas změny – slouží jako kurzor pro příští stažení.
  final DateTime syncedAt;
  final List<RecipeVersion> versions;

  /// Server ještě nemá sloupce přidané migrací 07 (výtěžnost, čekání, druh
  /// kroků). Místní hodnoty těchto polí se pak při stažení nepřepisují.
  final bool legacySchema;
}

/// Záznam o natrvalo smazaném receptu.
class Tombstone {
  const Tombstone(this.recipeId, this.purgedAt);

  final String recipeId;
  final DateTime purgedAt;
}

/// Server odmítl recept, protože byl na jiném zařízení natrvalo smazán.
class RecipePurgedException implements Exception {
  const RecipePurgedException(this.recipeId);

  final String recipeId;

  @override
  String toString() => 'Recept byl natrvalo smazán na jiném zařízení.';
}

/// Vzdálené úložiště receptů. Rozhraní existuje proto, aby šla synchronizace
/// testovat bez skutečného serveru.
abstract interface class RemoteStore {
  /// Id přihlášeného uživatele, nebo `null`.
  String? get userId;

  Future<void> pushRecipe(Recipe recipe);

  Future<void> pushVersion(RecipeVersion version);

  /// Recepty změněné po [since] (včetně smazaných), od nejstarší změny.
  Future<List<RemoteChange>> pullRecipes({DateTime? since});

  /// Nahraje fotografii (nebo její náhled, když [thumbnail]) a vrátí cestu
  /// v úložišti. Opakované nahrání téže fotky soubor jen přepíše.
  Future<String> uploadPhoto({
    required String recipeId,
    required String photoId,
    required File file,
    bool thumbnail = false,
  });

  /// Stáhne fotografii z úložiště (pro mezipaměť v telefonu).
  Future<Uint8List> downloadPhoto(String remotePath);

  /// Recepty natrvalo smazané po [since] (náhrobky), od nejstaršího.
  /// Server bez migrace 08 vrací prázdný seznam.
  Future<List<Tombstone>> pullTombstones({DateTime? since});

  /// Dočasná adresa pro zobrazení fotografie.
  Future<String?> signedPhotoUrl(String remotePath);

  /// Natrvalo smaže recept (včetně surovin, kroků a historie) a jeho
  /// fotografie. Smazání neexistujícího receptu není chyba.
  Future<void> deleteRecipe(String id, List<String> photoPaths);
}

/// Implementace nad Supabase (PostgreSQL + Storage).
class SupabaseRemoteStore implements RemoteStore {
  SupabaseRemoteStore(this._client);

  final SupabaseClient _client;

  static const photoBucket = 'recipe-photos';

  @override
  String? get userId => _client.auth.currentUser?.id;

  @override
  Future<void> pushRecipe(Recipe recipe) async {
    final uid = userId;
    if (uid == null) throw StateError('Nepřihlášený uživatel.');
    final owner = recipe.ownerId ?? uid;
    final row = <String, dynamic>{
      'id': recipe.id,
      'owner_id': owner,
      'household_id': recipe.householdId,
      'visibility': recipe.visibility,
      'title': recipe.title,
      'description': recipe.description,
      'category': recipe.category,
      'servings': recipe.servings,
      'yield_unit': YieldUnit.normalize(recipe.yieldUnit),
      'prep_minutes': recipe.prepMinutes,
      'cook_minutes': recipe.cookMinutes,
      'rest_minutes': recipe.restMinutes,
      'total_minutes': recipe.totalMinutes,
      'temperatures': recipe.temperatures,
      'equipment': recipe.equipment,
      'notes': recipe.notes,
      'rating': recipe.rating,
      'is_favorite': recipe.isFavorite,
      'photos': [
        for (final photo in recipe.photos)
          if (photo.remotePath != null) photo.toRemoteJson(),
      ],
      'source_url': recipe.sourceUrl,
      'current_version': recipe.currentVersion,
      'last_cooked_at': recipe.lastCookedAt?.toUtc().toIso8601String(),
      'created_at': recipe.createdAt.toUtc().toIso8601String(),
      'updated_at': recipe.updatedAt.toUtc().toIso8601String(),
      'deleted_at': recipe.deletedAt?.toUtc().toIso8601String(),
    };

    Future<void> writeRow() async {
      if (owner == uid) {
        await _client.from('recipes').upsert(row);
      } else {
        // Sdílený recept jiného člena domácnosti: smíme ho upravit, ne založit.
        final shared = Map<String, dynamic>.from(row)..remove('owner_id');
        await _client.from('recipes').update(shared).eq('id', recipe.id);
      }
    }

    // Server bez migrace 07 nové sloupce nezná; recept se pak odešle bez
    // nich, aby synchronizace fungovala i před spuštěním migrace.
    var legacy = _legacySchema;
    if (legacy) {
      row
        ..remove('yield_unit')
        ..remove('rest_minutes');
    }
    try {
      await writeRow();
    } on PostgrestException catch (error) {
      if (isPurgedError(error)) throw RecipePurgedException(recipe.id);
      if (legacy || !isMissingColumnError(error)) rethrow;
      legacy = _legacySchema = true;
      row
        ..remove('yield_unit')
        ..remove('rest_minutes');
      await writeRow();
    }

    await _client
        .from('recipe_ingredients')
        .delete()
        .eq('recipe_id', recipe.id);
    if (recipe.ingredients.isNotEmpty) {
      await _client.from('recipe_ingredients').insert([
        for (var i = 0; i < recipe.ingredients.length; i++)
          {
            'id': recipe.ingredients[i].id,
            'recipe_id': recipe.id,
            'position': i,
            'name': recipe.ingredients[i].name,
            'quantity': recipe.ingredients[i].quantity,
            'unit': recipe.ingredients[i].unit,
            'note': recipe.ingredients[i].note,
          },
      ]);
    }

    await _client.from('recipe_steps').delete().eq('recipe_id', recipe.id);
    if (recipe.steps.isNotEmpty) {
      await _client.from('recipe_steps').insert([
        for (var i = 0; i < recipe.steps.length; i++)
          {
            'id': recipe.steps[i].id,
            'recipe_id': recipe.id,
            'position': i,
            'instruction': recipe.steps[i].instruction,
            'duration_minutes': recipe.steps[i].durationMinutes,
            'temperature_c': recipe.steps[i].temperatureC,
            if (!legacy) 'kind': StepKind.normalize(recipe.steps[i].kind),
            if (!legacy) 'parallel': recipe.steps[i].parallel,
          },
      ]);
    }
  }

  /// Zjištěno, že server nemá sloupce z migrace 07. Platí do restartu
  /// aplikace; po spuštění migrace se nové sloupce začnou používat samy.
  bool _legacySchema = false;

  @override
  Future<void> deleteRecipe(String id, List<String> photoPaths) async {
    if (photoPaths.isNotEmpty) {
      try {
        await _client.storage.from(photoBucket).remove(photoPaths);
      } on StorageException {
        // Fotografie mohla být smazána už dřív; recept smažeme i tak.
      }
    }
    await _client.from('recipes').delete().eq('id', id);
  }

  @override
  Future<void> pushVersion(RecipeVersion version) async {
    await _client
        .from('recipe_versions')
        .upsert(
          {
            'id': version.id,
            'recipe_id': version.recipeId,
            'version_number': version.versionNumber,
            'snapshot': version.snapshot,
            'change_summary': version.changeSummary,
            'created_at': version.createdAt.toUtc().toIso8601String(),
          },
          onConflict: 'recipe_id,version_number',
          ignoreDuplicates: true,
        );
  }

  @override
  Future<List<RemoteChange>> pullRecipes({DateTime? since}) async {
    final base = _client
        .from('recipes')
        .select(
          '*, recipe_ingredients(*), recipe_steps(*), recipe_versions(*)',
        );
    final filtered = since == null
        ? base
        : base.gt('synced_at', since.toUtc().toIso8601String());
    final List<Map<String, dynamic>> rows = await filtered.order(
      'synced_at',
      ascending: true,
    );
    return [for (final row in rows) remoteChangeFromRow(row)];
  }

  @override
  Future<String> uploadPhoto({
    required String recipeId,
    required String photoId,
    required File file,
    bool thumbnail = false,
  }) async {
    final uid = userId;
    if (uid == null) throw StateError('Nepřihlášený uživatel.');
    final path = '$uid/$recipeId/$photoId${thumbnail ? '_t' : ''}.jpg';
    await _client.storage
        .from(photoBucket)
        .upload(
          path,
          file,
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'image/jpeg',
          ),
        );
    return path;
  }

  @override
  Future<Uint8List> downloadPhoto(String remotePath) =>
      _client.storage.from(photoBucket).download(remotePath);

  @override
  Future<List<Tombstone>> pullTombstones({DateTime? since}) async {
    try {
      final base = _client
          .from('recipe_tombstones')
          .select('recipe_id, purged_at');
      final filtered = since == null
          ? base
          : base.gt('purged_at', since.toUtc().toIso8601String());
      final List<Map<String, dynamic>> rows = await filtered.order(
        'purged_at',
        ascending: true,
      );
      return [
        for (final row in rows)
          Tombstone(
            row['recipe_id'] as String,
            DateTime.parse(row['purged_at'] as String).toUtc(),
          ),
      ];
    } on PostgrestException catch (error) {
      // Server ještě nemá migraci 08 – náhrobky zatím neexistují.
      if (isMissingTableError(error)) return const [];
      rethrow;
    }
  }

  @override
  Future<String?> signedPhotoUrl(String remotePath) async {
    try {
      return await _client.storage
          .from(photoBucket)
          .createSignedUrl(remotePath, 3600);
    } catch (_) {
      return null;
    }
  }
}

/// Odmítl server recept jako natrvalo smazaný (migrace 08)?
bool isPurgedError(PostgrestException error) =>
    '${error.hint} ${error.message}'.contains('hink_recipe_purged') ||
    error.message.contains('natrvalo smazán');

/// Chybí na serveru tabulka (starší databáze bez migrace)?
bool isMissingTableError(PostgrestException error) {
  final text = '${error.code} ${error.message}'.toLowerCase();
  return text.contains('pgrst205') ||
      text.contains('42p01') ||
      (text.contains('could not find the table')) ||
      (text.contains('relation') && text.contains('does not exist'));
}

/// Hlásí server, že tabulka nemá některý z odesílaných sloupců?
bool isMissingColumnError(PostgrestException error) {
  final text = '${error.code} ${error.message}'.toLowerCase();
  return text.contains('pgrst204') ||
      text.contains('42703') ||
      (text.contains('column') &&
          (text.contains('could not find') || text.contains('does not exist')));
}

/// Převede řádek tabulky `recipes` (s vnořenými surovinami, kroky a verzemi)
/// na doménový objekt. Samostatná funkce kvůli testům.
RemoteChange remoteChangeFromRow(Map<String, dynamic> row) {
  List<Map<String, dynamic>> nested(String key) {
    final list = [
      for (final item in (row[key] as List?) ?? const [])
        Map<String, dynamic>.from(item as Map),
    ];
    list.sort(
      (a, b) => ((a['position'] as num?) ?? 0).compareTo(
        (b['position'] as num?) ?? 0,
      ),
    );
    return list;
  }

  final recipe = Recipe.fromJson({
    ...row,
    'photos': [
      for (final photo in (row['photos'] as List?) ?? const [])
        {
          'id': (photo as Map)['id'],
          'remote_path': photo['remote_path'],
          'thumb_path': ?photo['thumb_path'],
        },
    ],
    'ingredients': nested('recipe_ingredients'),
    'steps': nested('recipe_steps'),
  });

  final versions = [
    for (final item in (row['recipe_versions'] as List?) ?? const [])
      RecipeVersion(
        id: (item as Map)['id'] as String,
        recipeId: recipe.id,
        versionNumber: (item['version_number'] as num).toInt(),
        snapshot: Map<String, dynamic>.from(item['snapshot'] as Map),
        changeSummary: (item['change_summary'] as String?) ?? '',
        createdAt: DateTime.parse(item['created_at'] as String).toUtc(),
      ),
  ];

  return RemoteChange(
    recipe: recipe,
    syncedAt: DateTime.parse(row['synced_at'] as String).toUtc(),
    versions: versions,
    legacySchema: !row.containsKey('yield_unit'),
  );
}

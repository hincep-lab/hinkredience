import 'photo_store.dart';
import 'recipe.dart';
import 'recipe_repository.dart';
import 'remote_store.dart';

/// Výsledek jedné synchronizace.
class SyncResult {
  const SyncResult({
    this.pulled = 0,
    this.pushed = 0,
    this.photosUploaded = 0,
    this.errors = const [],
  });

  final int pulled;
  final int pushed;
  final int photosUploaded;
  final List<String> errors;

  bool get ok => errors.isEmpty;
}

/// Obousměrná synchronizace místní databáze se serverem.
///
/// 1. Stáhne změny ze serveru (pravidlo „poslední úprava vyhrává“).
/// 2. Nahraje fotografie a odešle místní změny.
/// 3. Odešle nové záznamy historie verzí.
///
/// Chyba u jednoho receptu nezastaví ostatní; neodeslané změny zůstávají
/// označené a odešlou se příště.
class SyncService {
  SyncService({
    required this.repository,
    required this.remote,
    required this.photos,
  });

  final RecipeRepository repository;
  final RemoteStore remote;
  final PhotoStore photos;

  static const _cursorKey = 'sync_cursor';

  Future<SyncResult> sync() async {
    final uid = remote.userId;
    if (uid == null) {
      return const SyncResult(errors: ['Pro synchronizaci se přihlaste.']);
    }
    final errors = <String>[];
    var pulled = 0;
    var pushed = 0;
    var photosUploaded = 0;

    // 1) Stažení změn
    try {
      final cursorText = await repository.getMeta('$_cursorKey:$uid');
      final cursor = cursorText == null ? null : DateTime.tryParse(cursorText);
      final changes = await remote.pullRecipes(since: cursor);
      var newest = cursor;
      for (final change in changes) {
        final applied = await repository.applyRemote(
          change.recipe,
          versions: change.versions,
        );
        if (applied) pulled++;
        if (newest == null || change.syncedAt.isAfter(newest)) {
          newest = change.syncedAt;
        }
      }
      if (newest != null && newest != cursor) {
        await repository.setMeta(
          '$_cursorKey:$uid',
          newest.toUtc().toIso8601String(),
        );
      }
    } catch (error) {
      errors.add('Stažení změn se nepodařilo: $error');
      // Bez úspěšného stažení neodesíláme – mohli bychom přepsat novější data.
      return SyncResult(errors: errors);
    }

    // 2) Odeslání místních změn
    for (final recipe in await repository.dirtyRecipes()) {
      try {
        final uploaded = <RecipePhoto>[];
        for (final photo in recipe.photos) {
          if (photo.remotePath != null) continue;
          final file = photos.localFile(photo);
          if (file == null) continue;
          final path = await remote.uploadPhoto(
            recipeId: recipe.id,
            photoId: photo.id,
            file: file,
          );
          uploaded.add(photo.copyWith(remotePath: path));
          photosUploaded++;
        }
        var toPush = recipe.ownerId == null
            ? recipe.copyWith(ownerId: uid)
            : recipe;
        if (uploaded.isNotEmpty) {
          await repository.savePhotoUploads(recipe.id, uploaded);
          final byId = {for (final p in uploaded) p.id: p};
          toPush = toPush.copyWith(
            photos: [for (final p in toPush.photos) byId[p.id] ?? p],
          );
        }
        await remote.pushRecipe(toPush);
        await repository.markClean(recipe.id, recipe.updatedAt);
        pushed++;
      } catch (error) {
        errors.add('„${recipe.title}“ se nepodařilo odeslat: $error');
      }
    }

    // 3) Historie verzí
    for (final version in await repository.dirtyVersions()) {
      try {
        await remote.pushVersion(version);
        await repository.markVersionClean(version.id);
      } catch (error) {
        errors.add(
          'Verzi ${version.versionNumber} se nepodařilo odeslat: $error',
        );
        break;
      }
    }

    return SyncResult(
      pulled: pulled,
      pushed: pushed,
      photosUploaded: photosUploaded,
      errors: errors,
    );
  }
}

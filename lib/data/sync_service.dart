import 'dart:async';
import 'dart:io';

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
    this.photosCached = 0,
    this.purged = 0,
    this.removedRemotely = 0,
    this.conflicts = 0,
    this.offline = false,
    this.errors = const [],
  });

  final int pulled;
  final int pushed;
  final int photosUploaded;

  /// Fotky stažené do telefonu, aby byly k dispozici i bez internetu.
  final int photosCached;

  /// Počet receptů natrvalo smazaných na serveru (vysypaný koš).
  final int purged;

  /// Recepty smazané tady, protože je jiné zařízení natrvalo smazalo.
  final int removedRemotely;

  /// Recepty čekající na rozhodnutí o souběžné úpravě.
  final int conflicts;

  /// Synchronizace selhala, protože není připojení k internetu.
  final bool offline;
  final List<String> errors;

  bool get ok => errors.isEmpty;
}

/// Je chyba způsobená chybějícím připojením (a ne chybou dat)?
bool isOfflineError(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  if (error is HttpException) return true;
  final text = '$error';
  return const [
    'SocketException',
    'Failed host lookup',
    'Connection refused',
    'Connection reset',
    'Connection closed',
    'Network is unreachable',
    'No address associated',
    'TimeoutException',
    'ClientException',
    'HandshakeException',
  ].any(text.contains);
}

/// Obousměrná synchronizace místní databáze se serverem.
///
/// 0. Odešle trvalá smazání (vysypaný koš) a převezme smazání z jiných
///    zařízení (náhrobky).
/// 1. Stáhne změny ze serveru. Neodeslanou místní úpravu nikdy nepřepíše;
///    při souběžné úpravě vznikne konflikt k rozhodnutí.
/// 2. Nahraje nové fotky (i náhledy) a odešle místní změny.
/// 3. Odešle nové záznamy historie verzí.
/// 4. Stáhne do telefonu fotky, které tu ještě nejsou (pro offline režim).
///
/// Chyba u jednoho receptu nezastaví ostatní; neodeslané změny zůstávají
/// označené a odešlou se příště.
class SyncService {
  SyncService({
    required this.repository,
    required this.remote,
    required this.photos,
    this.maxPhotoDownloads = 40,
  });

  final RecipeRepository repository;
  final RemoteStore remote;
  final PhotoStore photos;

  /// Kolik fotek se nejvýše stáhne při jedné synchronizaci.
  final int maxPhotoDownloads;

  static const _cursorKey = 'sync_cursor';
  static const _tombstoneCursorKey = 'tombstone_cursor';

  Future<SyncResult> sync() async {
    final uid = remote.userId;
    if (uid == null) {
      return const SyncResult(errors: ['Pro synchronizaci se přihlaste.']);
    }
    final errors = <String>[];
    var offline = false;
    var pulled = 0;
    var pushed = 0;
    var photosUploaded = 0;
    var purged = 0;
    var removedRemotely = 0;

    void fail(String message, Object error) {
      if (isOfflineError(error)) {
        offline = true;
        if (!errors.contains(_offlineMessage)) errors.add(_offlineMessage);
      } else {
        errors.add('$message: $error');
      }
    }

    Future<int> conflictCount() async => (await repository.conflicts()).length;

    // 0a) Trvalá smazání z tohoto telefonu. Probíhají první, aby se smazaný
    //     recept při stažení změn nevrátil.
    for (final entry in (await repository.pendingPurges()).entries) {
      try {
        await remote.deleteRecipe(entry.key, entry.value);
        await repository.clearPurge(entry.key);
        purged++;
      } catch (error) {
        fail('Trvalé smazání na serveru se nepodařilo', error);
        if (offline) break;
      }
    }
    if (offline) {
      return SyncResult(
        purged: purged,
        offline: true,
        conflicts: await conflictCount(),
        errors: errors,
      );
    }

    // 0b) Trvalá smazání z jiných zařízení.
    try {
      final cursorText = await repository.getMeta('$_tombstoneCursorKey:$uid');
      final cursor = cursorText == null ? null : DateTime.tryParse(cursorText);
      DateTime? newest = cursor;
      for (final tombstone in await remote.pullTombstones(since: cursor)) {
        // Neodeslané úpravy smazaného receptu se nezahodí – zůstanou jako
        // nový recept (kopie), který se normálně odešle.
        await _rescueUnsent(tombstone.recipeId);
        final result = await repository.applyTombstone(tombstone.recipeId);
        if (result.recipes.isNotEmpty) {
          removedRemotely++;
          await photos.deleteFiles(result.orphanPhotoPaths);
        }
        if (newest == null || tombstone.purgedAt.isAfter(newest)) {
          newest = tombstone.purgedAt;
        }
      }
      if (newest != null && newest != cursor) {
        await repository.setMeta(
          '$_tombstoneCursorKey:$uid',
          newest.toUtc().toIso8601String(),
        );
      }
    } catch (error) {
      fail('Načtení smazaných receptů se nepodařilo', error);
    }

    // 1) Stažení změn
    try {
      final cursorText = await repository.getMeta('$_cursorKey:$uid');
      final cursor = cursorText == null ? null : DateTime.tryParse(cursorText);
      final changes = await remote.pullRecipes(since: cursor);
      var newest = cursor;
      for (final change in changes) {
        final outcome = await repository.applyRemote(
          change.recipe,
          versions: change.versions,
          legacySchema: change.legacySchema,
        );
        if (outcome == RemoteApply.applied) pulled++;
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
      fail('Stažení změn se nepodařilo', error);
      // Bez úspěšného stažení neodesíláme – mohli bychom přepsat novější data.
      return SyncResult(
        purged: purged,
        removedRemotely: removedRemotely,
        offline: offline,
        conflicts: await conflictCount(),
        errors: errors,
      );
    }

    // 2) Odeslání místních změn (kromě receptů s nerozhodnutým konfliktem)
    final conflicted = (await repository.conflicts()).keys.toSet();
    for (final recipe in await repository.dirtyRecipes()) {
      if (conflicted.contains(recipe.id)) continue;
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
          String? thumbPath;
          final thumb = await photos.ensureThumbnail(photo.localPath!);
          if (thumb != null) {
            thumbPath = await remote.uploadPhoto(
              recipeId: recipe.id,
              photoId: photo.id,
              file: thumb,
              thumbnail: true,
            );
          }
          uploaded.add(photo.copyWith(remotePath: path, thumbPath: thumbPath));
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
      } on RecipePurgedException {
        // Jiné zařízení recept mezitím natrvalo smazalo. Zachováme ho tady
        // jako nový recept s novým id, aby se neztratily neodeslané úpravy.
        await _rescueUnsent(recipe.id);
        final result = await repository.applyTombstone(recipe.id);
        await photos.deleteFiles(result.orphanPhotoPaths);
        errors.add(
          '„${recipe.title}“ bylo na jiném zařízení natrvalo smazáno. '
          'Vaše neodeslané úpravy jsou uložené jako kopie.',
        );
      } catch (error) {
        fail('„${recipe.title}“ se nepodařilo odeslat', error);
        if (offline) break;
      }
    }

    // 3) Historie verzí
    if (!offline) {
      for (final version in await repository.dirtyVersions()) {
        if (conflicted.contains(version.recipeId)) continue;
        try {
          await remote.pushVersion(version);
          await repository.markVersionClean(version.id);
        } catch (error) {
          fail('Verzi ${version.versionNumber} se nepodařilo odeslat', error);
          break;
        }
      }
    }

    // 4) Fotky do mezipaměti
    var photosCached = 0;
    if (!offline) {
      photosCached = await _cachePhotos(onError: fail);
    }

    return SyncResult(
      pulled: pulled,
      pushed: pushed,
      photosUploaded: photosUploaded,
      photosCached: photosCached,
      purged: purged,
      removedRemotely: removedRemotely,
      conflicts: await conflictCount(),
      offline: offline,
      errors: errors,
    );
  }

  /// Recept s neodeslanými úpravami, který jiné zařízení natrvalo smazalo,
  /// uloží jako kopii (nové id). Vrací `true`, když kopie vznikla.
  Future<bool> _rescueUnsent(String recipeId) async {
    final recipe = await repository.getById(recipeId);
    if (recipe == null ||
        recipe.isDeleted ||
        !await repository.isDirty(recipeId)) {
      return false;
    }
    final copy = await repository.duplicate(recipeId);
    if (copy == null) return false;
    // Soubory na serveru patřily smazanému receptu – nahrají se znovu.
    await repository.setPhotos(copy.id, [
      for (final photo in copy.photos)
        RecipePhoto(id: photo.id, localPath: photo.localPath),
    ]);
    return true;
  }

  Future<int> _cachePhotos({
    required void Function(String, Object) onError,
  }) async {
    var cached = 0;
    for (final recipe in await repository.getAll()) {
      if (recipe.isDeleted) continue;
      for (final photo in recipe.photos) {
        if (cached >= maxPhotoDownloads) return cached;
        final remotePath = photo.remotePath;
        if (remotePath == null || photos.localFile(photo) != null) continue;
        try {
          final bytes = await remote.downloadPhoto(remotePath);
          final localPath = await photos.saveDownloaded(
            recipeId: recipe.id,
            photoId: photo.id,
            bytes: bytes,
          );
          await repository.saveCachedPhoto(recipe.id, photo.id, localPath);
          cached++;
        } catch (error) {
          // Chybějící fotka na serveru nesmí zastavit synchronizaci; při
          // výpadku připojení to zkusíme příště.
          if (isOfflineError(error)) {
            onError('Stažení fotek se nepodařilo', error);
            return cached;
          }
        }
      }
    }
    return cached;
  }
}

const _offlineMessage = 'Bez připojení k internetu. Změny se odešlou později.';

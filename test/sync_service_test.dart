import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hinkredience/data/photo_store.dart';
import 'package:hinkredience/data/recipe.dart';
import 'package:hinkredience/data/recipe_repository.dart';
import 'package:hinkredience/data/remote_store.dart';
import 'package:hinkredience/data/sync_service.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

/// Server v paměti – chová se jako tabulka receptů se sloupcem synced_at.
class FakeRemote implements RemoteStore {
  @override
  String? userId = 'user-1';

  final recipes = <String, Recipe>{};
  final syncedAt = <String, DateTime>{};
  final versions = <RecipeVersion>[];
  final uploads = <String>[];
  bool failPush = false;

  /// Server bez migrace 07: nové sloupce neukládá a nevrací.
  bool legacySchema = false;

  Recipe _withoutNewColumns(Recipe recipe) => recipe.copyWith(
    yieldUnit: 'porce',
    restMinutes: 0,
    steps: [
      for (final step in recipe.steps)
        RecipeStep(
          id: step.id,
          instruction: step.instruction,
          durationMinutes: step.durationMinutes,
          temperatureC: step.temperatureC,
        ),
    ],
  );

  bool failPull = false;
  var _tick = DateTime.utc(2026, 11, 14, 13);

  DateTime _next() => _tick = _tick.add(const Duration(seconds: 1));

  /// Změna provedená „z jiného zařízení“.
  void serverEdit(Recipe recipe) {
    recipes[recipe.id] = recipe;
    syncedAt[recipe.id] = _next();
  }

  /// Natrvalo smazané recepty (náhrobky, migrace 08).
  final tombstones = <String, DateTime>{};

  /// Soubory v úložišti fotek.
  final files = <String, Uint8List>{};

  @override
  Future<void> pushRecipe(Recipe recipe) async {
    if (failPush) throw const SocketException('bez připojení');
    if (tombstones.containsKey(recipe.id)) {
      throw RecipePurgedException(recipe.id);
    }
    serverEdit(recipe);
  }

  @override
  Future<Uint8List> downloadPhoto(String remotePath) async {
    if (failPull) throw const SocketException('bez připojení');
    final bytes = files[remotePath];
    if (bytes == null) throw Exception('Objekt nenalezen');
    return bytes;
  }

  @override
  Future<List<Tombstone>> pullTombstones({DateTime? since}) async {
    if (failPull) throw const SocketException('bez připojení');
    return [
      for (final entry in tombstones.entries)
        if (since == null || entry.value.isAfter(since))
          Tombstone(entry.key, entry.value),
    ]..sort((a, b) => a.purgedAt.compareTo(b.purgedAt));
  }

  /// Jiné zařízení vysypalo koš.
  void purgeElsewhere(String id) {
    recipes.remove(id);
    syncedAt.remove(id);
    tombstones[id] = _next();
  }

  @override
  Future<void> pushVersion(RecipeVersion version) async {
    if (failPush) throw const SocketException('bez připojení');
    versions.add(version);
  }

  @override
  Future<List<RemoteChange>> pullRecipes({DateTime? since}) async {
    if (failPull) throw const SocketException('bez připojení');
    final ids = [
      for (final id in recipes.keys)
        if (since == null || syncedAt[id]!.isAfter(since)) id,
    ]..sort((a, b) => syncedAt[a]!.compareTo(syncedAt[b]!));
    return [
      for (final id in ids)
        RemoteChange(
          recipe: legacySchema
              ? _withoutNewColumns(recipes[id]!)
              : recipes[id]!,
          syncedAt: syncedAt[id]!,
          legacySchema: legacySchema,
        ),
    ];
  }

  @override
  Future<String> uploadPhoto({
    required String recipeId,
    required String photoId,
    required File file,
    bool thumbnail = false,
  }) async {
    final path = '$userId/$recipeId/$photoId${thumbnail ? '_t' : ''}.jpg';
    uploads.add(path);
    files[path] = await file.readAsBytes();
    return path;
  }

  @override
  Future<String?> signedPhotoUrl(String remotePath) async => null;

  final deletedPhotos = <String>[];
  bool failDelete = false;

  @override
  Future<void> deleteRecipe(String id, List<String> photoPaths) async {
    if (failDelete) throw const SocketException('bez připojení');
    recipes.remove(id);
    syncedAt.remove(id);
    versions.removeWhere((v) => v.recipeId == id);
    deletedPhotos.addAll(photoPaths);
    tombstones[id] = _next();
  }
}

void main() {
  late TestEnvironment env;
  late RecipeRepository repository;
  late FakeRemote remote;
  late SyncService sync;

  setUp(() async {
    env = await TestEnvironment.create();
    repository = await env.repository();
    remote = FakeRemote();
    sync = SyncService(
      repository: repository,
      remote: remote,
      photos: PhotoStore(env.directory),
    );
  });

  tearDown(() => env.dispose());

  test('bez přihlášení se nic neodešle', () async {
    remote.userId = null;
    await repository.create(sampleRecipe());
    final result = await sync.sync();
    expect(result.ok, isFalse);
    expect(remote.recipes, isEmpty);
    expect(await repository.dirtyCount(), 1);
  });

  test('místní recept se odešle včetně historie a doplní vlastníka', () async {
    await repository.create(sampleRecipe());
    final result = await sync.sync();

    expect(result.ok, isTrue);
    expect(result.pushed, 1);
    expect(remote.recipes['recipe-1']!.title, 'Žebra BBQ');
    expect(remote.recipes['recipe-1']!.ownerId, 'user-1');
    expect(remote.versions.single.versionNumber, 1);
    expect(await repository.dirtyCount(), 0);
    expect(await repository.dirtyVersions(), isEmpty);
  });

  test('recept z jiného zařízení se stáhne', () async {
    remote.serverEdit(sampleRecipe(id: 'z-iphonu', title: 'Kuře na paprice'));
    final result = await sync.sync();

    expect(result.pulled, 1);
    expect((await repository.getById('z-iphonu'))!.title, 'Kuře na paprice');
    expect(await repository.dirtyCount(), 0);

    // Podruhé už není co stahovat – kurzor se posunul.
    final again = await sync.sync();
    expect(again.pulled, 0);
    expect(again.pushed, 0);
  });

  test('prázdná kuchařka se značkou „už staženo“ stáhne všechno', () async {
    // Např. obnovená záloha telefonu: kurzor je, recepty ne.
    remote.serverEdit(sampleRecipe(id: 'stary', title: 'Svíčková'));
    await repository.setMeta(
      'sync_cursor:user-1',
      DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String(),
    );
    final result = await sync.sync();
    expect(result.pulled, 1);
    expect((await repository.getById('stary'))!.title, 'Svíčková');
  });

  test('vysypaný koš se smaže i na serveru a už se nestáhne zpět', () async {
    await repository.create(sampleRecipe());
    await repository.create(sampleRecipe(id: 'r2', title: 'Svíčková'));
    await sync.sync();
    expect(remote.recipes.keys, containsAll(['recipe-1', 'r2']));

    // Recept mimo koš se trvale smazat nedá.
    expect((await repository.purgeDeleted(ids: ['r2'])).recipes, isEmpty);
    expect(await repository.getById('r2'), isNotNull);

    await repository.softDelete('recipe-1');
    final purged = await repository.purgeDeleted();
    expect(purged.recipes.single.id, 'recipe-1');
    expect(await repository.getById('recipe-1'), isNull);
    expect(await repository.versions('recipe-1'), isEmpty);
    expect(await repository.pendingPurges(), contains('recipe-1'));

    // Bez připojení zůstane smazání ve frontě a recept se nevrátí.
    remote.failDelete = true;
    await sync.sync();
    expect(await repository.getById('recipe-1'), isNull);
    expect(await repository.pendingPurges(), contains('recipe-1'));

    remote.failDelete = false;
    final result = await sync.sync();
    expect(result.purged, 1);
    expect(remote.recipes.keys, ['r2']);
    expect(remote.versions.where((v) => v.recipeId == 'recipe-1'), isEmpty);
    expect(await repository.pendingPurges(), isEmpty);
    expect((await repository.getById('r2'))!.title, 'Svíčková');
  });

  test(
    'server bez nových sloupců: recept se uloží a místní údaje zůstanou',
    () async {
      remote.legacySchema = true;
      await repository.create(
        sampleRecipe().copyWith(
          yieldUnit: 'ks',
          restMinutes: 90,
          steps: const [
            RecipeStep(
              id: 's1',
              instruction: 'Nech kynout.',
              durationMinutes: 90,
              kind: 'passive',
            ),
            RecipeStep(
              id: 's2',
              instruction: 'Připrav náplň.',
              durationMinutes: 20,
              parallel: true,
            ),
          ],
        ),
      );
      final result = await sync.sync();
      expect(result.ok, isTrue);
      expect(remote.recipes['recipe-1'], isNotNull);

      // Úprava z jiného zařízení přes starý server nesmí nová pole vynulovat.
      remote.serverEdit(
        remote.recipes['recipe-1']!.copyWith(
          title: 'Buchty',
          updatedAt: env.now.add(const Duration(hours: 1)),
        ),
      );
      await sync.sync();
      final local = (await repository.getById('recipe-1'))!;
      expect(local.title, 'Buchty');
      expect(local.yieldUnit, 'ks');
      expect(local.restMinutes, 90);
      expect(local.steps.first.kind, 'passive');
      expect(local.steps.last.parallel, isTrue);
    },
  );

  test('smazání na jiném zařízení se projeví jako koš', () async {
    await repository.create(sampleRecipe());
    await sync.sync();
    remote.serverEdit(
      remote.recipes['recipe-1']!.copyWith(
        deletedAt: env.now.add(const Duration(hours: 2)),
        updatedAt: env.now.add(const Duration(hours: 2)),
      ),
    );
    await sync.sync();
    expect((await repository.getById('recipe-1'))!.isDeleted, isTrue);
  });

  test('úprava v telefonu nad aktuální verzí se odešle', () async {
    final created = await repository.create(sampleRecipe());
    await sync.sync();

    // Server má starší změnu, telefon novější neodeslanou.
    remote.serverEdit(
      created.copyWith(title: 'Ze serveru', updatedAt: env.now),
    );
    env.advance(const Duration(minutes: 10));
    await repository.update(created.copyWith(title: 'Z telefonu'));

    await sync.sync();
    expect((await repository.getById('recipe-1'))!.title, 'Z telefonu');
    expect(remote.recipes['recipe-1']!.title, 'Z telefonu');
  });

  test('výpadek při odesílání nic neztratí a příště se dokončí', () async {
    await repository.create(sampleRecipe());
    remote.failPush = true;
    final failed = await sync.sync();

    expect(failed.ok, isFalse);
    expect(failed.offline, isTrue);
    expect(failed.errors.first, contains('Bez připojení'));
    expect(await repository.dirtyCount(), 1);

    remote.failPush = false;
    final retried = await sync.sync();
    expect(retried.ok, isTrue);
    expect(remote.recipes, hasLength(1));
    expect(await repository.dirtyCount(), 0);
  });

  test('když selže stažení, nic se neodesílá', () async {
    await repository.create(sampleRecipe());
    remote.failPull = true;
    final result = await sync.sync();
    expect(result.ok, isFalse);
    expect(result.offline, isTrue);
    expect(remote.recipes, isEmpty);
    expect(await repository.dirtyCount(), 1);
  });

  test('fotografie se nahraje a recept dostane cestu v úložišti', () async {
    final file = File(
      p.join(env.directory.path, 'photos', 'recipe-1', 'p1.jpg'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9]);
    await repository.create(
      sampleRecipe().copyWith(
        photos: [
          RecipePhoto(
            id: 'p1',
            localPath: p.join('photos', 'recipe-1', 'p1.jpg'),
          ),
        ],
      ),
    );

    final result = await sync.sync();
    expect(result.photosUploaded, 1);
    expect(remote.uploads, ['user-1/recipe-1/p1.jpg']);
    expect(
      remote.recipes['recipe-1']!.photos.single.remotePath,
      'user-1/recipe-1/p1.jpg',
    );
    final local = (await repository.getById('recipe-1'))!.photos.single;
    expect(local.remotePath, 'user-1/recipe-1/p1.jpg');
    expect(local.localPath, isNotNull);

    // Podruhé se už nic nenahrává.
    await sync.sync();
    expect(remote.uploads, hasLength(1));
  });

  Uint8List jpeg({int width = 1200, int height = 900}) => Uint8List.fromList(
    img.encodeJpg(img.Image(width: width, height: height), quality: 80),
  );

  test('nová fotka se nahraje i s náhledem', () async {
    final source = File(p.join(env.directory.path, 'zdroj.jpg'));
    await source.writeAsBytes(jpeg());
    final photo = await PhotoStore(env.directory)
        .import(recipeId: 'recipe-1', photoId: 'p1', sourcePath: source.path);
    await repository.create(sampleRecipe().copyWith(photos: [photo]));

    await sync.sync();
    expect(remote.uploads, [
      'user-1/recipe-1/p1.jpg',
      'user-1/recipe-1/p1_t.jpg',
    ]);
    final pushed = remote.recipes['recipe-1']!.photos.single;
    expect(pushed.thumbPath, 'user-1/recipe-1/p1_t.jpg');
    final thumb = img.decodeJpg(remote.files['user-1/recipe-1/p1_t.jpg']!)!;
    expect(thumb.width, thumbnailSize);
    expect(thumb.height, 360);
  });

  test('fotka z jiného zařízení se stáhne do telefonu pro offline', () async {
    remote.files['user-2/z-iphonu/p9.jpg'] = jpeg(width: 600, height: 800);
    remote.serverEdit(
      sampleRecipe(id: 'z-iphonu', title: 'Losos').copyWith(
        photos: const [
          RecipePhoto(id: 'p9', remotePath: 'user-2/z-iphonu/p9.jpg'),
        ],
      ),
    );
    final result = await sync.sync();
    expect(result.photosCached, 1);
    final local = (await repository.getById('z-iphonu'))!;
    final store = PhotoStore(env.directory);
    expect(store.localFile(local.photos.single), isNotNull);
    expect(store.thumbnailFile(local.photos.single), isNotNull);
    expect(await repository.dirtyCount(), 0, reason: 'nic se neodesílá zpět');

    // Podruhé se nic nestahuje – fotka už je v telefonu.
    expect((await sync.sync()).photosCached, 0);
  });

  test('chybějící fotka na serveru synchronizaci nezastaví', () async {
    remote.serverEdit(
      sampleRecipe(id: 'r9').copyWith(
        photos: const [RecipePhoto(id: 'px', remotePath: 'user-2/r9/px.jpg')],
      ),
    );
    final result = await sync.sync();
    expect(result.ok, isTrue);
    expect(result.photosCached, 0);
  });

  test('vysypaný koš na jiném zařízení smaže recept i tady', () async {
    await repository.create(sampleRecipe());
    await sync.sync();
    remote.purgeElsewhere('recipe-1');
    final result = await sync.sync();
    expect(result.removedRemotely, 1);
    expect(await repository.getById('recipe-1'), isNull);
    // A znovu se už neobjeví.
    await sync.sync();
    expect(await repository.getById('recipe-1'), isNull);
    expect(remote.recipes, isEmpty);
  });

  test(
    'neodeslané úpravy receptu smazaného jinde se zachrání jako kopie',
    () async {
      final created = await repository.create(sampleRecipe());
      await sync.sync();
      env.advance(const Duration(minutes: 1));
      await repository.update(created.copyWith(title: 'Upraveno offline'));
      remote.purgeElsewhere('recipe-1');

      final result = await sync.sync();
      expect(result.removedRemotely, 1);
      expect(await repository.getById('recipe-1'), isNull);
      final all = await repository.getAll();
      expect(all.single.title, 'Upraveno offline (kopie)');
      expect(remote.recipes.values.single.title, 'Upraveno offline (kopie)');
      expect(
        remote.recipes.containsKey('recipe-1'),
        isFalse,
        reason: 'neoživeno',
      );
    },
  );

  test('server odmítne oživení natrvalo smazaného receptu', () async {
    final created = await repository.create(sampleRecipe());
    await sync.sync();
    env.advance(const Duration(minutes: 1));
    await repository.update(created.copyWith(title: 'Upraveno offline'));
    // Náhrobek telefon při stažení nevidí (např. vznikl těsně po něm).
    remote.recipes.remove('recipe-1');
    remote.tombstones['recipe-1'] = DateTime.utc(2000);
    await repository.setMeta(
      'tombstone_cursor:user-1',
      '2001-01-01T00:00:00.000Z',
    );

    final rejected = await sync.sync();
    expect(rejected.errors.single, contains('natrvalo smazáno'));
    expect(await repository.getById('recipe-1'), isNull);
    expect(
      (await repository.getAll()).single.title,
      'Upraveno offline (kopie)',
    );

    final again = await sync.sync();
    expect(again.ok, isTrue);
    expect(remote.recipes.values.single.title, 'Upraveno offline (kopie)');
  });

  test(
    'souběžná úprava (ChatGPT i telefon): nic se nepřepíše, čeká na rozhodnutí',
    () async {
      final created = await repository.create(sampleRecipe());
      await sync.sync();
      env.advance(const Duration(minutes: 5));
      await repository.update(created.copyWith(title: 'Z telefonu'));
      remote.serverEdit(
        created.copyWith(
          title: 'Z ChatGPT',
          updatedAt: env.now.add(const Duration(minutes: 1)),
        ),
      );

      final result = await sync.sync();
      expect(result.conflicts, 1);
      expect(
        remote.recipes['recipe-1']!.title,
        'Z ChatGPT',
        reason: 'server nepřepsán',
      );
      expect((await repository.getById('recipe-1'))!.title, 'Z telefonu');

      await repository.resolveConflict('recipe-1', keepLocal: true);
      final resolved = await sync.sync();
      expect(resolved.conflicts, 0);
      expect(remote.recipes['recipe-1']!.title, 'Z telefonu');
      final numbers = [
        for (final v in remote.versions.where((v) => v.recipeId == 'recipe-1'))
          v.versionNumber,
      ];
      expect(numbers.toSet().length, numbers.length);
    },
  );
}

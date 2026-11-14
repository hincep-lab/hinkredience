import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  bool failPull = false;
  var _tick = DateTime.utc(2026, 11, 14, 13);

  DateTime _next() => _tick = _tick.add(const Duration(seconds: 1));

  /// Změna provedená „z jiného zařízení“.
  void serverEdit(Recipe recipe) {
    recipes[recipe.id] = recipe;
    syncedAt[recipe.id] = _next();
  }

  @override
  Future<void> pushRecipe(Recipe recipe) async {
    if (failPush) throw const SocketException('bez připojení');
    serverEdit(recipe);
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
        RemoteChange(recipe: recipes[id]!, syncedAt: syncedAt[id]!),
    ];
  }

  @override
  Future<String> uploadPhoto({
    required String recipeId,
    required String photoId,
    required File file,
  }) async {
    final path = '$userId/$recipeId/$photoId.jpg';
    uploads.add(path);
    return path;
  }

  @override
  Future<String?> signedPhotoUrl(String remotePath) async => null;
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

  test('konflikt: vyhrává poslední úprava', () async {
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
    expect(failed.errors.first, contains('Žebra BBQ'));
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
}

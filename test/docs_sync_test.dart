import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/shopping.dart';
import 'package:hinkredience/data/docs_repository.dart';
import 'package:hinkredience/data/docs_sync.dart';
import 'package:hinkredience/data/kitchen_docs.dart';
import 'package:hinkredience/data/photo_store.dart';

import 'support.dart';

class FakeRemoteDocs implements RemoteDocs {
  @override
  String? userId = 'user-1';
  bool supported = true;
  String? household;
  final rows = <String, Map<String, RemoteDoc>>{
    DocKind.session: {},
    DocKind.plan: {},
    DocKind.shopping: {},
  };
  final pushedHousehold = <String, String?>{};
  var _tick = DateTime.utc(2026, 11, 15, 12);

  @override
  Future<String?> householdId() async {
    if (!supported) throw const DocsNotSupported();
    return household;
  }

  @override
  Future<List<RemoteDoc>> pull(String kind, {DateTime? since}) async => [
    for (final row in rows[kind]!.values)
      if (since == null || row.syncedAt.isAfter(since)) row,
  ];

  @override
  Future<void> push(String kind, DirtyDoc doc, {String? householdId}) async {
    _tick = _tick.add(const Duration(seconds: 1));
    pushedHousehold[doc.id] = householdId;
    rows[kind]![doc.id] = RemoteDoc(
      id: doc.id,
      data: doc.data,
      updatedAt: doc.updatedAt,
      syncedAt: _tick,
      deletedAt: doc.deletedAt,
    );
  }

  void serverEdit(
    String kind,
    String id,
    Map<String, dynamic> data,
    DateTime updatedAt,
  ) {
    _tick = _tick.add(const Duration(seconds: 1));
    rows[kind]![id] = RemoteDoc(
      id: id,
      data: data,
      updatedAt: updatedAt,
      syncedAt: _tick,
    );
  }

  @override
  Future<String> uploadSessionPhoto({
    required String sessionId,
    required String photoId,
    required File file,
  }) async => 'user-1/session-$sessionId/$photoId.jpg';

  @override
  Future<Uint8List> downloadPhoto(String remotePath) async =>
      throw Exception('není');
}

void main() {
  late TestEnvironment env;
  late DocsRepository docs;
  late FakeRemoteDocs remote;
  late DocsSync sync;

  setUp(() async {
    env = await TestEnvironment.create();
    docs = await env.docs();
    remote = FakeRemoteDocs();
    sync = DocsSync(
      docs: docs,
      remote: remote,
      photos: PhotoStore(env.directory),
    );
  });
  tearDown(() => env.dispose());

  test('odešle dokončené vaření, plán i nákup; rozvařený recept zůstane v telefonu', () async {
    final base = CookingSession(
      id: 's1',
      recipeTitle: 'Pizza',
      cookedAt: env.now,
      updatedAt: env.now,
    );
    await docs.saveSession(base);
    await docs.saveSession(
      CookingSession(
        id: 's2',
        recipeTitle: 'Guláš',
        status: SessionStatus.inProgress,
        cookedAt: env.now,
        updatedAt: env.now,
      ),
    );
    await docs.saveMeal(
      MealPlanEntry(
        id: 'm1',
        day: '2026-11-16',
        mealType: MealType.lunch,
        title: 'Svíčková',
        updatedAt: env.now,
      ),
    );
    await docs.addToShopping(const [
      ShoppingDraft(name: 'Mouka', quantity: 1, unit: 'kg'),
    ]);
    remote.household = 'rodina-1';

    final result = await sync.sync();
    expect(result.errors, isEmpty);
    expect(remote.rows[DocKind.session]!.keys, ['s1']);
    expect(remote.rows[DocKind.plan]!.keys, ['m1']);
    expect(remote.pushedHousehold['m1'], 'rodina-1', reason: 'plán je rodinný');
    expect(remote.rows[DocKind.shopping]!.values.single.data['name'], 'Mouka');
    expect(await docs.dirtyCount(), 0);
  });

  test(
    'položka od druhého člena rodiny se stáhne a odškrtnutí se pošle zpět',
    () async {
      remote.serverEdit(DocKind.shopping, 'x', {
        'id': 'x',
        'name': 'Mléko',
        'unit': 'l',
        'quantity': 1,
        'checked': false,
        'sources': <String>[],
        'created_at': env.now.toIso8601String(),
        'updated_at': env.now.toIso8601String(),
      }, env.now);
      await sync.sync();
      final item = (await docs.shopping()).single;
      expect(item.name, 'Mléko');
      env.advance(const Duration(minutes: 1));
      await docs.saveShoppingItem(item.copyWith(checked: true));
      await sync.sync();
      expect(remote.rows[DocKind.shopping]!['x']!.data['checked'], isTrue);
    },
  );

  test('server bez migrace 09: nic se neodešle a není to chyba', () async {
    remote.supported = false;
    await docs.saveMeal(
      MealPlanEntry(
        id: 'm1',
        day: '2026-11-16',
        mealType: MealType.lunch,
        title: 'X',
        updatedAt: env.now,
      ),
    );
    final result = await sync.sync();
    expect(result.errors, isEmpty);
    expect(await docs.dirtyCount(), 1, reason: 'odešle se po spuštění migrace');
  });
}

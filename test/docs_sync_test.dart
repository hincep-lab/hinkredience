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
    DocKind.shoppingList: {},
    DocKind.shopping: {},
    DocKind.wish: {},
    DocKind.receipt: {},
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

  final announced = <Map<String, String>>[];

  @override
  Future<void> announce(List<Map<String, String>> items) async =>
      announced.addAll(items);
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

  test(
    'seznam vytvořený v ChatGPT se objeví v telefonu a odškrtnutí se vrátí',
    () async {
      remote.serverEdit(DocKind.shoppingList, 'l1', {
        'id': 'l1',
        'name': 'Kuře na paprice',
        'owner_id': 'user-1',
        'household_id': null,
        'created_at': env.now.toIso8601String(),
        'updated_at': env.now.toIso8601String(),
      }, env.now);
      remote.serverEdit(DocKind.shopping, 'i1', {
        'id': 'i1',
        'list_id': 'l1',
        'name': 'Máslo',
        'quantity': 60,
        'unit': 'g',
        'category': 'mlecne',
        'note': '',
        'checked': false,
        'sources': <String>[],
        'created_at': env.now.toIso8601String(),
        'updated_at': env.now.toIso8601String(),
      }, env.now);
      await sync.sync();
      final lists = await docs.shoppingLists();
      expect(lists.single.name, 'Kuře na paprice');
      final butter = (await docs.shopping(listId: 'l1')).single;
      expect(butter.category, 'mlecne');

      env.advance(const Duration(minutes: 1));
      await docs.saveShoppingItem(butter.copyWith(checked: true));
      await sync.sync();
      expect(remote.rows[DocKind.shopping]!['i1']!.data['checked'], isTrue);
      expect(remote.rows[DocKind.shopping]!['i1']!.data['list_id'], 'l1');
      expect(await docs.dirtyCount(), 0);
    },
  );

  test('nový seznam z telefonu se odešle dřív než jeho položky', () async {
    final list = await docs.createShoppingList('Víkend');
    await docs.addToShopping(const [
      ShoppingDraft(name: 'Cibule', quantity: 300, unit: 'g'),
    ], listId: list.id);
    await sync.sync();
    expect(remote.rows[DocKind.shoppingList]!.keys, [list.id]);
    expect(
      remote.rows[DocKind.shopping]!.values.single.data['list_id'],
      list.id,
    );
  });

  test('smazání seznamu na serveru zmizí i v telefonu', () async {
    final list = await docs.createShoppingList('Pryč');
    await sync.sync();
    env.advance(const Duration(minutes: 1));
    final row = remote.rows[DocKind.shoppingList]![list.id]!;
    remote.rows[DocKind.shoppingList]![list.id] = RemoteDoc(
      id: row.id,
      data: row.data,
      updatedAt: env.now,
      syncedAt: DateTime.utc(2030),
      deletedAt: env.now,
    );
    await sync.sync();
    expect(await docs.shoppingLists(), isEmpty);
  });

  test(
    'novinky od rodiny: přání a nákup od druhého, ne vlastní ani první sync',
    () async {
      // První synchronizace jen stáhne historii, nic neohlásí.
      remote.serverEdit(DocKind.wish, 'w-old', {
        'id': 'w-old',
        'title': 'Staré přání',
        'owner_id': 'user-2',
        'author_name': 'Martinka',
      }, env.now);
      final first = await sync.sync();
      expect(first.news, isEmpty);

      remote.serverEdit(DocKind.wish, 'w1', {
        'id': 'w1',
        'title': 'Svíčková',
        'owner_id': 'user-2',
        'author_name': 'Martinka',
      }, env.now);
      remote.serverEdit(DocKind.wish, 'w2', {
        'id': 'w2',
        'title': 'Moje vlastní',
        'owner_id': 'user-1',
      }, env.now);
      for (final name in ['Mléko', 'Chléb', 'Máslo', 'Vejce', 'Sýr']) {
        remote.serverEdit(DocKind.shopping, 'i-$name', {
          'id': 'i-$name',
          'list_id': 'l1',
          'name': name,
        }, env.now);
      }
      final second = await sync.sync();
      expect(second.news.map((n) => n.title).toList(), [
        'Mléko',
        'Chléb',
        'Máslo',
        'Vejce',
        'Sýr',
        'Svíčková',
      ]);
      expect(
        second.news.where((n) => n.kind == DocKind.wish).single.author,
        'Martinka',
      );
      final texts = familyNotifications(second.news);
      expect(texts.first.title, 'Martinka má chuť na…');
      expect(texts.first.body, 'Svíčková');
      expect(texts.last.title, 'Na nákup přibylo 5 položek');
      expect(texts.last.body, 'Mléko, Chléb, Máslo a 2 další');

      // Podruhé už nic nového.
      final third = await sync.sync();
      expect(third.news, isEmpty);
    },
  );

  test('nové přání a položka se rodině ohlásí jednou; staré ne', () async {
    await docs.saveWish(
      MealWish(
        id: 'w-new',
        title: 'Guláš',
        createdAt: env.now,
        updatedAt: env.now,
      ),
    );
    await docs.saveWish(
      MealWish(
        id: 'w-old',
        title: 'Staré',
        createdAt: env.now.subtract(const Duration(days: 2)),
        updatedAt: env.now,
      ),
    );
    await docs.addToShopping(const [ShoppingDraft(name: 'Mléko')]);
    await sync.sync();
    expect(remote.announced, [
      {'kind': 'shopping', 'title': 'Mléko'},
      {'kind': 'wish', 'title': 'Guláš'},
    ]);
    // Úprava už ohlášeného přání se znovu neohlašuje.
    final wish = (await docs.wishes()).firstWhere((w) => w.id == 'w-new');
    await docs.saveWish(wish.copyWith(note: 'v sobotu'));
    await sync.sync();
    expect(remote.announced.length, 2);
  });

  test('vlastní položka z jiného zařízení se neohlásí', () async {
    await sync.sync();
    remote.serverEdit(DocKind.shopping, 'i-own', {
      'id': 'i-own',
      'list_id': 'l1',
      'name': 'Moje',
      'added_by': 'user-1',
    }, env.now);
    remote.serverEdit(DocKind.shopping, 'i-her', {
      'id': 'i-her',
      'list_id': 'l1',
      'name': 'Její',
      'added_by': 'user-2',
    }, env.now);
    final result = await sync.sync();
    expect(result.news.map((n) => n.title), ['Její']);
  });
}

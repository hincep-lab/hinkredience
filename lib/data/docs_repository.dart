import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/shopping.dart';
import 'app_database.dart';
import 'kitchen_docs.dart';

/// Záznam z tabulky `docs` připravený k odeslání na server.
class DirtyDoc {
  const DirtyDoc({
    required this.id,
    required this.kind,
    required this.data,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String kind;
  final Map<String, dynamic> data;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Kuchařský deník, plán vaření a nákupní seznam v místní databázi.
///
/// Každý záznam je JSON dokument v tabulce `docs`. Jako u receptů platí:
/// telefon je zdrojem pravdy, změny se označí jako neodeslané a synchronizace
/// je odešle; mazání je měkké (`deleted_at`), aby se smazání dostalo i na
/// ostatní zařízení.
class DocsRepository {
  DocsRepository(
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

  Stream<void> get changes => _changes.stream;

  String newId() => _newId();

  DateTime now() => _clock();

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();

  // ------------------------------------------------------------- obecné

  Future<List<Map<String, dynamic>>> _all(String kind) async {
    final rows = await _db.query(
      'docs',
      where: 'kind = ? AND deleted_at IS NULL',
      whereArgs: [kind],
      orderBy: 'updated_at DESC',
    );
    return [
      for (final row in rows)
        Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
    ];
  }

  Future<Map<String, dynamic>?> _one(String id) async {
    final rows = await _db.query(
      'docs',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
      jsonDecode(rows.first['data'] as String) as Map,
    );
  }

  Future<void> _put(
    DatabaseExecutor executor,
    String kind,
    String id,
    Map<String, dynamic> data,
    DateTime updatedAt, {
    bool dirty = true,
    DateTime? deletedAt,
  }) async {
    await executor.insert('docs', {
      'id': id,
      'kind': kind,
      'data': jsonEncode(data),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
      'dirty': dirty ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _softDelete(Iterable<String> ids) async {
    final now = _clock().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      for (final id in ids) {
        await txn.update(
          'docs',
          {'deleted_at': now, 'updated_at': now, 'dirty': 1},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
    _notify();
  }

  // -------------------------------------------------------------- vaření

  /// Dokončená vaření (kuchařský deník), nejnovější první.
  Future<List<CookingSession>> diary({String? recipeId}) async {
    final all = [
      for (final json in await _all(DocKind.session))
        CookingSession.fromJson(json),
    ];
    final finished = [
      for (final s in all)
        if (s.isFinished && (recipeId == null || s.recipeId == recipeId)) s,
    ]..sort((a, b) => b.cookedAt.compareTo(a.cookedAt));
    return finished;
  }

  /// Rozvařený recept (režim Vaříme spolu), pokud nějaký je.
  Future<CookingSession?> openSession() async {
    final open = [
      for (final json in await _all(DocKind.session))
        if (CookingSession.fromJson(json).isOpen) CookingSession.fromJson(json),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return open.isEmpty ? null : open.first;
  }

  Future<CookingSession?> session(String id) async {
    final json = await _one(id);
    return json == null ? null : CookingSession.fromJson(json);
  }

  Future<CookingSession> saveSession(CookingSession session) async {
    final saved = session.copyWith(updatedAt: _clock());
    await _put(_db, DocKind.session, saved.id, saved.toJson(), saved.updatedAt);
    _notify();
    return saved;
  }

  Future<void> deleteSession(String id) => _softDelete([id]);

  // ---------------------------------------------------------- plán jídel

  /// Naplánovaná jídla v rozmezí dnů (včetně), seřazená podle dne a jídla.
  Future<List<MealPlanEntry>> plan({
    required DateTime from,
    required DateTime to,
  }) async {
    final fromKey = dayKey(from);
    final toKey = dayKey(to);
    final entries =
        [
          for (final json in await _all(DocKind.plan))
            MealPlanEntry.fromJson(json),
        ].where(
          (e) => e.day.compareTo(fromKey) >= 0 && e.day.compareTo(toKey) <= 0,
        );
    return entries.toList()..sort((a, b) {
      final day = a.day.compareTo(b.day);
      if (day != 0) return day;
      return MealType.all
          .indexOf(a.mealType)
          .compareTo(MealType.all.indexOf(b.mealType));
    });
  }

  Future<MealPlanEntry> saveMeal(MealPlanEntry entry) async {
    final saved = entry.copyWith(updatedAt: _clock());
    await _put(_db, DocKind.plan, saved.id, saved.toJson(), saved.updatedAt);
    _notify();
    return saved;
  }

  Future<void> deleteMeal(String id) => _softDelete([id]);

  // ------------------------------------------------------ nákupní seznam

  /// Položky nákupního seznamu: nejdřív nenakoupené, v pořadí přidání.
  Future<List<ShoppingItem>> shopping() async {
    final items = [
      for (final json in await _all(DocKind.shopping))
        ShoppingItem.fromJson(json),
    ];
    items.sort((a, b) {
      if (a.checked != b.checked) return a.checked ? 1 : -1;
      return a.createdAt.compareTo(b.createdAt);
    });
    return items;
  }

  /// Přidá suroviny a sloučí je s tím, co už na seznamu je.
  Future<ShoppingMerge> addToShopping(Iterable<ShoppingDraft> drafts) async {
    final merge = mergeShopping(
      existing: await shopping(),
      additions: drafts,
      newId: _newId,
      now: _clock(),
    );
    await _db.transaction((txn) async {
      for (final item in merge.changed) {
        await _put(
          txn,
          DocKind.shopping,
          item.id,
          item.toJson(),
          item.updatedAt,
        );
      }
    });
    if (merge.changed.isNotEmpty) _notify();
    return merge;
  }

  Future<void> saveShoppingItem(ShoppingItem item) async {
    final saved = item.copyWith(updatedAt: _clock());
    await _put(
      _db,
      DocKind.shopping,
      saved.id,
      saved.toJson(),
      saved.updatedAt,
    );
    _notify();
  }

  Future<void> deleteShoppingItems(Iterable<String> ids) => _softDelete(ids);

  // ------------------------------------------------------- synchronizace

  Future<List<DirtyDoc>> dirty(String kind) async {
    final rows = await _db.query(
      'docs',
      where: 'kind = ? AND dirty = 1',
      whereArgs: [kind],
      orderBy: 'updated_at ASC',
    );
    return [
      for (final row in rows)
        DirtyDoc(
          id: row['id'] as String,
          kind: kind,
          data: Map<String, dynamic>.from(
            jsonDecode(row['data'] as String) as Map,
          ),
          updatedAt: DateTime.parse(row['updated_at'] as String),
          deletedAt: row['deleted_at'] == null
              ? null
              : DateTime.parse(row['deleted_at'] as String),
        ),
    ];
  }

  /// Počet záznamů čekajících na odeslání (rozvařené recepty se nepočítají,
  /// ty zůstávají jen v telefonu).
  Future<int> dirtyCount() async {
    var count = 0;
    for (final kind in [DocKind.session, DocKind.plan, DocKind.shopping]) {
      for (final doc in await dirty(kind)) {
        if (kind == DocKind.session &&
            doc.deletedAt == null &&
            !CookingSession.fromJson(doc.data).isFinished) {
          continue;
        }
        count++;
      }
    }
    return count;
  }

  /// Odesláno – jen pokud se záznam mezitím znovu nezměnil.
  Future<void> markClean(String id, DateTime updatedAt) async {
    await _db.update(
      'docs',
      {'dirty': 0},
      where: 'id = ? AND updated_at = ?',
      whereArgs: [id, updatedAt.toUtc().toIso8601String()],
    );
  }

  /// Zapíše stav ze serveru. Neodeslaná místní změna se nepřepíše, pokud je
  /// novější. Vrací `true`, když se místní záznam změnil.
  Future<bool> applyRemote({
    required String kind,
    required String id,
    required Map<String, dynamic> data,
    required DateTime updatedAt,
    DateTime? deletedAt,
  }) async {
    var applied = false;
    await _db.transaction((txn) async {
      final rows = await txn.query('docs', where: 'id = ?', whereArgs: [id]);
      if (rows.isNotEmpty && rows.first['dirty'] == 1) {
        final local = DateTime.parse(rows.first['updated_at'] as String);
        if (!updatedAt.isAfter(local)) return;
      }
      var merged = data;
      if (rows.isNotEmpty) {
        // Údaje, které server nezná (cesty k fotkám v telefonu), zachováme.
        final local = Map<String, dynamic>.from(
          jsonDecode(rows.first['data'] as String) as Map,
        );
        merged = _keepLocalPhotos(local, data);
      }
      await _put(
        txn,
        kind,
        id,
        merged,
        updatedAt,
        dirty: false,
        deletedAt: deletedAt,
      );
      applied = true;
    });
    if (applied) _notify();
    return applied;
  }

  static Map<String, dynamic> _keepLocalPhotos(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final localPhotos = {
      for (final p in (local['photos'] as List?) ?? const [])
        if (p is Map) p['id']: p['local_path'],
    };
    if (localPhotos.isEmpty || remote['photos'] is! List) return remote;
    return {
      ...remote,
      'photos': [
        for (final p in remote['photos'] as List)
          if (p is Map)
            {...p, 'local_path': p['local_path'] ?? localPhotos[p['id']]},
      ],
    };
  }

  /// Doplní fotkám vaření cesty v úložišti, aniž by změnil čas úpravy.
  Future<void> saveSessionPhotoUploads(
    String id,
    Map<String, String> remotePaths,
  ) async {
    final rows = await _db.query('docs', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final data = Map<String, dynamic>.from(
      jsonDecode(rows.first['data'] as String) as Map,
    );
    data['photos'] = [
      for (final p in (data['photos'] as List?) ?? const [])
        if (p is Map)
          {...p, 'remote_path': p['remote_path'] ?? remotePaths[p['id']]},
    ];
    await _db.update(
      'docs',
      {'data': jsonEncode(data)},
      where: 'id = ?',
      whereArgs: [id],
    );
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
}

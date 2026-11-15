import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'docs_repository.dart';
import 'kitchen_docs.dart';
import 'photo_store.dart';
import 'push_service.dart';
import 'remote_store.dart';
import 'sync_service.dart' show isOfflineError;

/// Řádek ze serveru převedený na dokument v telefonu.
class RemoteDoc {
  const RemoteDoc({
    required this.id,
    required this.data,
    required this.updatedAt,
    required this.syncedAt,
    this.deletedAt,
  });

  final String id;
  final Map<String, dynamic> data;
  final DateTime updatedAt;
  final DateTime syncedAt;
  final DateTime? deletedAt;
}

/// Server bez migrace 09 – deník, plán a nákup se zatím jen ukládají v telefonu.
class DocsNotSupported implements Exception {
  const DocsNotSupported();
}

/// Vzdálené úložiště deníku, plánu a nákupního seznamu (kvůli testům rozhraní).
abstract interface class RemoteDocs {
  String? get userId;

  /// Domácnost přihlášeného uživatele, nebo `null`.
  Future<String?> householdId();

  Future<List<RemoteDoc>> pull(String kind, {DateTime? since});

  Future<void> push(String kind, DirtyDoc doc, {String? householdId});

  Future<String> uploadSessionPhoto({
    required String sessionId,
    required String photoId,
    required File file,
  });

  Future<Uint8List> downloadPhoto(String remotePath);

  /// Dá vědět ostatním v rodině (oznámení do zavřené aplikace).
  Future<void> announce(List<Map<String, String>> items);
}

/// Synchronizace deníku vaření, plánu vaření a nákupního seznamu.
class DocsSync {
  DocsSync({required this.docs, required this.remote, required this.photos});

  final DocsRepository docs;
  final RemoteDocs remote;
  final PhotoStore photos;

  static const kinds = [
    DocKind.session,
    DocKind.plan,
    DocKind.shoppingList,
    DocKind.shopping,
    // Poslední: bez migrace 12 server tabulku nemá a synchronizace zde
    // tiše skončí (DocsNotSupported) – ostatní už jsou hotové.
    DocKind.wish,
    // Bez migrace 14 tabulka chybí – synchronizace zde tiše skončí.
    DocKind.receipt,
  ];

  /// Vrací chyby (prázdné = v pořádku). Server bez migrace 09 není chyba.
  Future<
    ({
      List<String> errors,
      bool offline,
      int pulled,
      int pushed,
      List<FamilyNews> news,
    })
  >
  sync() async {
    final uid = remote.userId;
    if (uid == null)
      return (
        errors: <String>[],
        offline: false,
        pulled: 0,
        pushed: 0,
        news: const <FamilyNews>[],
      );
    final errors = <String>[];
    var offline = false;
    var pulled = 0;
    var pushed = 0;
    final news = <FamilyNews>[];
    final announce = <Map<String, String>>[];
    String? household;
    try {
      household = await remote.householdId();
    } on DocsNotSupported {
      return (
        errors: <String>[],
        offline: false,
        pulled: 0,
        pushed: 0,
        news: const <FamilyNews>[],
      );
    } catch (error) {
      if (isOfflineError(error)) {
        return (
          errors: <String>[],
          offline: true,
          pulled: 0,
          pushed: 0,
          news: const <FamilyNews>[],
        );
      }
      household = null;
    }

    // Položky ze starší verze aplikace (bez seznamu) dostanou seznam.
    if ((await docs.shopping()).any((i) => i.listId == null)) {
      await docs.defaultShoppingList();
    }

    for (final kind in kinds) {
      try {
        // 1) Stažení změn
        final cursorKey = 'docs_cursor:$kind:$uid';
        final cursorText = await docs.getMeta(cursorKey);
        final cursor = cursorText == null
            ? null
            : DateTime.tryParse(cursorText);
        var newest = cursor;
        // Novinky hlásíme až po první úplné synchronizaci daného druhu.
        final seenKey = 'docs_seen:$kind:$uid';
        final seen = await docs.getMeta(seenKey) != null;
        for (final row in await remote.pull(kind, since: cursor)) {
          // Novinky od rodiny (ne při úplně první synchronizaci, to by
          // ohlásilo celou historii).
          final isNew =
              seen &&
              row.deletedAt == null &&
              (kind == DocKind.wish || kind == DocKind.shopping) &&
              !await docs.known(row.id);
          if (await docs.applyRemote(
            kind: kind,
            id: row.id,
            data: row.data,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          )) {
            pulled++;
            if (isNew) {
              final item = FamilyNews.from(kind, row.data, uid);
              if (item != null) news.add(item);
            }
          }
          if (newest == null || row.syncedAt.isAfter(newest)) {
            newest = row.syncedAt;
          }
        }
        if (newest != null && newest != cursor) {
          await docs.setMeta(cursorKey, newest.toUtc().toIso8601String());
        }
        if (!seen) await docs.setMeta(seenKey, '1');

        // 2) Odeslání místních změn
        for (final doc in await docs.dirty(kind)) {
          // Rozvařené recepty zůstávají jen v telefonu; do deníku patří
          // dokončená (nebo smazaná) vaření.
          if (kind == DocKind.session && doc.deletedAt == null) {
            final session = CookingSession.fromJson(doc.data);
            if (!session.isFinished) continue;
            await _uploadSessionPhotos(doc.id, session);
          }
          final fresh = kind == DocKind.session
              ? (await docs.dirty(kind))
                    .firstWhere((d) => d.id == doc.id, orElse: () => doc)
              : doc;
          await remote.push(kind, fresh, householdId: household);
          await docs.markClean(doc.id, doc.updatedAt);
          pushed++;
          if (await _announcement(kind, doc) case final item?) {
            announce.add(item);
          }
        }
      } on DocsNotSupported {
        return (
          errors: errors,
          offline: offline,
          pulled: pulled,
          pushed: pushed,
          news: news,
        );
      } catch (error) {
        if (isOfflineError(error)) {
          offline = true;
          break;
        }
        errors.add('${_label(kind)}: $error');
      }
    }

    if (!offline) await _cacheSessionPhotos();
    if (!offline && announce.isNotEmpty) {
      try {
        await remote.announce(announce);
      } catch (error) {
        // Oznámení jsou bonus – synchronizaci kvůli nim nezastavíme.
        debugPrint('Oznámení rodině se nepodařilo odeslat: $error');
      }
    }
    return (
      errors: errors,
      offline: offline,
      pulled: pulled,
      pushed: pushed,
      news: news,
    );
  }

  /// Nové přání nebo položka na nákup, o které se ještě rodině neřeklo.
  /// Staré záznamy (starší 6 hodin) se neohlašují – ani po aktualizaci.
  Future<Map<String, String>?> _announcement(String kind, DirtyDoc doc) async {
    if (doc.deletedAt != null) return null;
    if (kind != DocKind.wish && kind != DocKind.shopping) return null;
    final d = doc.data;
    final title =
        ((kind == DocKind.wish ? d['title'] : d['name']) as String? ?? '')
            .trim();
    if (title.isEmpty) return null;
    if (kind == DocKind.wish && d['planned_day'] != null) return null;
    if (kind == DocKind.shopping && d['checked'] == true) return null;
    final created = DateTime.tryParse(d['created_at'] as String? ?? '');
    if (created == null ||
        docs.now().difference(created.toUtc()) > const Duration(hours: 6)) {
      return null;
    }
    final key = 'announced:${doc.id}';
    if (await docs.getMeta(key) != null) return null;
    await docs.setMeta(key, '1');
    return {'kind': kind == DocKind.wish ? 'wish' : 'shopping', 'title': title};
  }

  Future<void> _uploadSessionPhotos(String id, CookingSession session) async {
    final uploaded = <String, String>{};
    for (final photo in session.photos) {
      if (photo.remotePath != null) continue;
      final file = photos.localFile(photo);
      if (file == null) continue;
      uploaded[photo.id] = await remote.uploadSessionPhoto(
        sessionId: id,
        photoId: photo.id,
        file: file,
      );
    }
    if (uploaded.isNotEmpty) await docs.saveSessionPhotoUploads(id, uploaded);
  }

  Future<void> _cacheSessionPhotos() async {
    if (!photos.canStore) return;
    var budget = 20;
    for (final session in await docs.diary()) {
      for (final photo in session.photos) {
        if (budget <= 0) return;
        if (photo.remotePath == null || photos.localFile(photo) != null)
          continue;
        try {
          final bytes = await remote.downloadPhoto(photo.remotePath!);
          final path = await photos.saveDownloaded(
            recipeId: 'session-${session.id}',
            photoId: photo.id,
            bytes: bytes,
          );
          await docs.saveSession(
            session.copyWith(
              photos: [
                for (final p in session.photos)
                  p.id == photo.id ? p.copyWith(localPath: path) : p,
              ],
            ),
          );
          // Uložení výše záznam označí jako neodeslaný – jde ale jen o cestu
          // v telefonu, takže ho hned zase označíme jako odeslaný.
          final saved = await docs.session(session.id);
          if (saved != null) await docs.markClean(saved.id, saved.updatedAt);
          budget--;
        } catch (error) {
          if (isOfflineError(error)) return;
        }
      }
    }
  }

  static String _label(String kind) => switch (kind) {
    DocKind.session => 'Kuchařský deník',
    DocKind.plan => 'Plán vaření',
    DocKind.shoppingList => 'Nákupní seznamy',
    DocKind.wish => 'Přání rodiny',
    DocKind.receipt => 'Ceny z účtenek',
    _ => 'Nákupní seznam',
  };
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// Implementace nad Supabase.
class SupabaseRemoteDocs implements RemoteDocs {
  SupabaseRemoteDocs(this._client);

  final SupabaseClient _client;

  @override
  String? get userId => _client.auth.currentUser?.id;

  Never _rethrow(Object error) {
    if (error is PostgrestException &&
        (isMissingColumnError(error) ||
            isMissingTableError(error) ||
            error.message.contains('my_household') ||
            error.code == 'PGRST202')) {
      throw const DocsNotSupported();
    }
    throw error;
  }

  @override
  Future<String?> householdId() async {
    try {
      final result = await _client.rpc<dynamic>('my_household');
      return result is String ? result : null;
    } catch (error) {
      _rethrow(error);
    }
  }

  static const _tables = {
    DocKind.session: 'cooking_sessions',
    DocKind.plan: 'meal_plans',
    DocKind.shoppingList: 'shopping_lists',
    DocKind.shopping: 'shopping_items',
    DocKind.wish: 'meal_wishes',
    DocKind.receipt: 'price_receipts',
  };

  @override
  Future<List<RemoteDoc>> pull(String kind, {DateTime? since}) async {
    final uid = userId!;
    try {
      var query = _client.from(_tables[kind]!).select();
      if (kind == DocKind.session) {
        query = query.eq('user_id', uid).eq('status', SessionStatus.finished);
      }
      if (since != null) {
        query = query.gt('synced_at', since.toUtc().toIso8601String());
      }
      final List<Map<String, dynamic>> rows = await query.order(
        'synced_at',
        ascending: true,
      );
      return [for (final row in rows) _fromRow(kind, row)];
    } catch (error) {
      _rethrow(error);
    }
  }

  RemoteDoc _fromRow(String kind, Map<String, dynamic> row) {
    final updatedAt = _date(row['updated_at']) ?? DateTime.now().toUtc();
    final Map<String, dynamic> data = switch (kind) {
      DocKind.session => {
        'id': row['id'],
        'recipe_id': row['recipe_id'],
        'recipe_title': row['recipe_title'] ?? '',
        'version_number': row['version_number'],
        'status': row['status'],
        'cooked_at': row['cooked_at'],
        'updated_at': row['updated_at'],
        'servings': row['servings'],
        'actual_minutes': row['actual_minutes'],
        'actual_temperatures': row['actual_temperatures'] ?? const [],
        'photos': [
          for (final p in (row['photos'] as List?) ?? const [])
            if (p is Map) {'id': p['id'], 'remote_path': p['remote_path']},
        ],
        'rating': row['rating'],
        'notes': row['notes'] ?? '',
        'went_well': row['went_well'] ?? '',
        'to_improve': row['to_improve'] ?? '',
      },
      DocKind.plan => {
        'id': row['id'],
        'day': row['plan_date'],
        'meal_type': row['meal_type'],
        'recipe_id': row['recipe_id'],
        'title': row['title'] ?? '',
        'note': row['note'] ?? '',
        'servings': row['servings'],
        'owner_id': row['owner_id'],
        'household_id': row['household_id'],
        'updated_at': row['updated_at'],
      },
      DocKind.receipt => {
        'id': row['id'],
        'store_id': row['store_id'],
        'product': row['product'] ?? '',
        'label': row['label'] ?? '',
        'price': row['price'],
        'pack_qty': row['pack_qty'],
        'pack_unit': row['pack_unit'] ?? '',
        'bought_on': row['bought_on'],
        'note': row['note'] ?? '',
        'owner_id': row['owner_id'],
        'household_id': row['household_id'],
        'updated_at': row['updated_at'],
      },
      DocKind.wish => {
        'id': row['id'],
        'title': row['title'] ?? '',
        'recipe_id': row['recipe_id'],
        'note': row['note'] ?? '',
        'author_name': row['author_name'] ?? '',
        'planned_day': row['planned_day'],
        'owner_id': row['owner_id'],
        'household_id': row['household_id'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
      DocKind.shoppingList => {
        'id': row['id'],
        'name': row['name'] ?? 'Nákupní seznam',
        'owner_id': row['owner_id'],
        'household_id': row['household_id'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
      _ => {
        'id': row['id'],
        'added_by': row['added_by'],
        'list_id': row['list_id'],
        'name': row['name'],
        'quantity': row['quantity'],
        'unit': row['unit'] ?? '',
        'category': row['category'] ?? '',
        'note': row['note'] ?? '',
        'checked': row['is_checked'] == true,
        'sources': row['sources'] ?? const [],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      },
    };
    return RemoteDoc(
      id: row['id'] as String,
      data: data,
      updatedAt: updatedAt,
      syncedAt: _date(row['synced_at']) ?? updatedAt,
      deletedAt: _date(row['deleted_at']),
    );
  }

  @override
  Future<void> push(String kind, DirtyDoc doc, {String? householdId}) async {
    final uid = userId!;
    final d = doc.data;
    final deleted = doc.deletedAt?.toUtc().toIso8601String();
    final updated = doc.updatedAt.toUtc().toIso8601String();
    final table = _tables[kind]!;
    Map<String, dynamic> row;
    switch (kind) {
      case DocKind.session:
        row = {
          'id': doc.id,
          'user_id': uid,
          'recipe_id': d['recipe_id'],
          'recipe_title': d['recipe_title'] ?? '',
          'version_number': d['version_number'],
          'status': d['status'] ?? SessionStatus.finished,
          'cooked_at': d['cooked_at'],
          'servings': d['servings'],
          'actual_minutes': d['actual_minutes'],
          'actual_temperatures': d['actual_temperatures'] ?? const [],
          'photos': [
            for (final p in (d['photos'] as List?) ?? const [])
              if (p is Map && p['remote_path'] != null)
                {'id': p['id'], 'remote_path': p['remote_path']},
          ],
          'rating': d['rating'],
          'notes': d['notes'] ?? '',
          'went_well': d['went_well'] ?? '',
          'to_improve': d['to_improve'] ?? '',
          'updated_at': updated,
          'deleted_at': deleted,
        };
      case DocKind.plan:
        row = {
          'id': doc.id,
          'owner_id': d['owner_id'] ?? uid,
          'household_id': d['household_id'] ?? householdId,
          'plan_date': d['day'],
          'meal_type': d['meal_type'],
          'recipe_id': d['recipe_id'],
          'title': d['title'] ?? '',
          'note': d['note'] ?? '',
          'servings': d['servings'],
          'updated_at': updated,
          'deleted_at': deleted,
        };
      case DocKind.receipt:
        row = {
          'id': doc.id,
          'owner_id': d['owner_id'] ?? uid,
          'household_id': d['household_id'] ?? householdId,
          'store_id': d['store_id'],
          'product': d['product'] ?? '',
          'label': d['label'] ?? '',
          'price': d['price'],
          'pack_qty': d['pack_qty'],
          'pack_unit': d['pack_unit'] ?? '',
          'bought_on': d['bought_on'],
          'note': d['note'] ?? '',
          'updated_at': updated,
          'deleted_at': deleted,
        };
      case DocKind.wish:
        row = {
          'id': doc.id,
          'owner_id': d['owner_id'] ?? uid,
          'household_id': d['household_id'] ?? householdId,
          'recipe_id': d['recipe_id'],
          'title': d['title'] ?? '',
          'note': d['note'] ?? '',
          'author_name': d['author_name'] ?? '',
          'planned_day': d['planned_day'],
          'created_at': d['created_at'],
          'updated_at': updated,
          'deleted_at': deleted,
        };
      case DocKind.shoppingList:
        row = {
          'id': doc.id,
          'owner_id': d['owner_id'] ?? uid,
          'household_id': d['household_id'],
          'name': d['name'] ?? 'Nákupní seznam',
          'created_at': d['created_at'],
          'updated_at': updated,
          'deleted_at': deleted,
        };
      default:
        if (d['list_id'] == null)
          return; // dostane seznam při příští synchronizaci
        row = {
          'id': doc.id,
          'list_id': d['list_id'],
          'name': d['name'],
          'quantity': d['quantity'],
          'unit': d['unit'] ?? '',
          'category': d['category'] ?? '',
          'note': d['note'] ?? '',
          'is_checked': d['checked'] == true,
          'sources': d['sources'] ?? const [],
          'created_at': d['created_at'],
          'updated_at': updated,
          'deleted_at': deleted,
        };
    }

    Future<void> write(Map<String, dynamic> values) async {
      final owner = values['owner_id'];
      if (owner != null && owner != uid) {
        // Záznam jiného člena rodiny smíme upravit, ne založit.
        final shared = Map<String, dynamic>.from(values)..remove('owner_id');
        await _client.from(table).update(shared).eq('id', doc.id);
      } else {
        await _client.from(table).upsert(values);
      }
    }

    try {
      await write(row);
    } on PostgrestException catch (error) {
      if (error.code == '23503' && row['recipe_id'] != null) {
        // Recept na serveru není (smazaný nebo ještě neodeslaný) – záznam
        // uložíme bez odkazu na něj; název zůstane.
        await write({...row, 'recipe_id': null});
        return;
      }
      _rethrow(error);
    }
  }

  @override
  Future<String> uploadSessionPhoto({
    required String sessionId,
    required String photoId,
    required File file,
  }) async {
    final uid = userId!;
    final path = '$uid/session-$sessionId/$photoId.jpg';
    await _client.storage
        .from(SupabaseRemoteStore.photoBucket)
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
  Future<Uint8List> downloadPhoto(String remotePath) => _client.storage
      .from(SupabaseRemoteStore.photoBucket)
      .download(remotePath);

  @override
  Future<void> announce(List<Map<String, String>> items) =>
      PushService(_client).announce(items);
}

/// Co přidal někdo jiný z rodiny (nebo jiné zařízení): přání nebo položka
/// nákupního seznamu. Z toho vznikají oznámení.
class FamilyNews {
  const FamilyNews({required this.kind, required this.title, this.author = ''});

  final String kind;
  final String title;
  final String author;

  /// Null, když nejde o novinku pro tohoto uživatele (vlastní přání,
  /// odškrtnutá položka).
  static FamilyNews? from(String kind, Map<String, dynamic> data, String uid) {
    if (kind == DocKind.wish) {
      if (data['owner_id'] == uid) return null;
      final title = (data['title'] as String? ?? '').trim();
      if (title.isEmpty || data['planned_day'] != null) return null;
      return FamilyNews(
        kind: kind,
        title: title,
        author: (data['author_name'] as String? ?? '').trim(),
      );
    }
    if (kind == DocKind.shopping) {
      if (data['checked'] == true || data['added_by'] == uid) return null;
      final name = (data['name'] as String? ?? '').trim();
      if (name.isEmpty) return null;
      return FamilyNews(kind: kind, title: name);
    }
    return null;
  }
}

/// Text oznámení: každé přání zvlášť, položky nákupu souhrnně.
List<({String title, String body})> familyNotifications(List<FamilyNews> news) {
  final out = <({String title, String body})>[];
  for (final wish in news.where((n) => n.kind == DocKind.wish)) {
    out.add((
      title: wish.author.isEmpty
          ? 'Nové přání do jídelníčku'
          : '${wish.author} má chuť na…',
      body: wish.title,
    ));
  }
  final items = [
    for (final n in news)
      if (n.kind == DocKind.shopping) n.title,
  ];
  if (items.isNotEmpty) {
    final shown = items.take(3).join(', ');
    final rest = items.length - 3;
    out.add((
      title: switch (items.length) {
        1 => 'Na nákup přibyla položka',
        < 5 => 'Na nákup přibyly ${items.length} položky',
        _ => 'Na nákup přibylo ${items.length} položek',
      },
      body: rest > 0 ? '$shown a $rest další' : shown,
    ));
  }
  return out;
}

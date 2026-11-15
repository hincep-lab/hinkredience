import 'package:sqflite/sqflite.dart';

/// Místní databáze v telefonu (SQLite). Je zdrojem pravdy pro celou aplikaci –
/// díky tomu recepty fungují i bez internetu a synchronizace je jen doplněk.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _version = 2;

  static Future<AppDatabase> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: _create,
        onUpgrade: _upgrade,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _create(Database db, int version) async {
    // Celý recept je uložen jako JSON dokument; vybrané sloupce slouží
    // k řazení a k řízení synchronizace.
    await db.execute('''
      CREATE TABLE recipes (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE recipe_versions (
        id TEXT PRIMARY KEY,
        recipe_id TEXT NOT NULL,
        version_number INTEGER NOT NULL,
        snapshot TEXT NOT NULL,
        change_summary TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 1,
        UNIQUE (recipe_id, version_number)
      )
    ''');
    await db.execute('''
      CREATE TABLE custom_categories (
        name TEXT PRIMARY KEY,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _createDocs(db);
  }

  /// Přechod ze starší verze: stávající tabulky a recepty zůstávají beze
  /// změny, jen se přidá to, co chybí.
  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) await _createDocs(db);
  }

  /// Deník vaření, plán jídel a nákupní seznam (verze 2). Každý záznam je
  /// JSON dokument; `dirty` a `deleted_at` slouží budoucí synchronizaci.
  static Future<void> _createDocs(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS docs (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        data TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS docs_kind_idx ON docs (kind, deleted_at)',
    );
  }

  Future<void> close() => db.close();
}

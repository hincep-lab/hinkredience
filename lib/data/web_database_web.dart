import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Webová verze: SQLite (WebAssembly) uložená v prohlížeči (IndexedDB).
/// Bez web workeru – spolehlivě funguje i v Safari na iPhonu.
DatabaseFactory? webDatabaseFactory() => databaseFactoryFfiWebNoWebWorker;

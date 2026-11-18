/// Databáze pro webovou verzi aplikace (jinde `null`).
library;

export 'web_database_stub.dart'
    if (dart.library.js_interop) 'web_database_web.dart';

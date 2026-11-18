/// Webová verze: zjištění nové verze a znovunačtení (web/push.js).
library;

export 'web_update_stub.dart'
    if (dart.library.js_interop) 'web_update_web.dart';

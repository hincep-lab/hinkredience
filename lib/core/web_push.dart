/// Oznámení přes prohlížeč (web push). Mimo web nic nedělá.
library;

export 'web_push_stub.dart' if (dart.library.js_interop) 'web_push_web.dart';

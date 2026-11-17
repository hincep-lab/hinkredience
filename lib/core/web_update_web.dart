import 'dart:js_interop';

// Most na window.hinkUpdate z web/push.js.

@JS('hinkUpdate')
external _HinkUpdate? get _update;

extension type _HinkUpdate._(JSObject _) implements JSObject {
  external JSPromise<JSString?> fetchText(String url);
  external void reload();
}

Future<String?> webFetchText(String url) async {
  final update = _update;
  if (update == null) return null;
  try {
    return (await update.fetchText(url).toDart)?.toDart;
  } catch (_) {
    return null;
  }
}

void webReload() => _update?.reload();

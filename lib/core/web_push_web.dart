import 'dart:convert';
import 'dart:js_interop';

// Most na window.hinkPush z web/push.js.

@JS('hinkPush')
external _HinkPush? get _push;

extension type _HinkPush._(JSObject _) implements JSObject {
  external bool supported();
  external String permission();
  external bool standalone();
  external JSPromise<JSString> subscribe(String publicKey);
  external JSPromise<JSString> unsubscribe();
  external JSPromise<JSString> current();
}

bool webPushSupported() => _push?.supported() ?? false;

String webPushPermission() => _push?.permission() ?? 'unsupported';

bool webPushStandalone() => _push?.standalone() ?? false;

Future<({String endpoint, String p256dh, String auth})> webPushSubscribe(
  String publicKey,
) async {
  final push = _push;
  if (push == null) throw UnsupportedError('Oznámení tu nejsou k dispozici.');
  final String json;
  try {
    json = (await push.subscribe(publicKey).toDart).toDart;
  } catch (error) {
    throw StateError(_message(error));
  }
  final data = jsonDecode(json) as Map<String, dynamic>;
  return (
    endpoint: data['endpoint'] as String,
    p256dh: data['p256dh'] as String,
    auth: data['auth'] as String,
  );
}

Future<String> webPushUnsubscribe() async {
  final push = _push;
  if (push == null) return '';
  try {
    return (await push.unsubscribe().toDart).toDart;
  } catch (_) {
    return '';
  }
}

Future<String> webPushCurrent() async {
  final push = _push;
  if (push == null) return '';
  try {
    return (await push.current().toDart).toDart;
  } catch (_) {
    return '';
  }
}

String _message(Object error) {
  final text = error.toString();
  // Chyba z JS přichází jako „Error: …“.
  return text.replaceFirst(
    RegExp(r'^(Error|JavaScriptError|StateError):\s*'),
    '',
  );
}

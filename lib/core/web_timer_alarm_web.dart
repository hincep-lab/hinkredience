import 'dart:js_interop';

// Most na window.hinkTimer z web/push.js.

@JS('hinkTimer')
external _HinkTimer? get _timer;

extension type _HinkTimer._(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> prepare();
  external JSPromise<JSAny?> ring(String title, String body, String tag);
  external JSPromise<JSAny?> close(String tag);
}

/// Odemkne zvuk (musí se stát po klepnutí) a požádá o oznámení.
Future<bool> webTimerPrepare() async {
  final timer = _timer;
  if (timer == null) return false;
  try {
    return (await timer.prepare().toDart).toDart;
  } catch (_) {
    return false;
  }
}

Future<void> webTimerRing(String title, String body, int id) async {
  try {
    await _timer?.ring(title, body, 'cook-$id').toDart;
  } catch (_) {
    // Zvonění nesmí shodit vaření.
  }
}

Future<void> webTimerClose(int id) async {
  try {
    await _timer?.close('cook-$id').toDart;
  } catch (_) {}
}

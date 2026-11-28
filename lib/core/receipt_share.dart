import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Účtenky v PDF z jiných aplikací (Android „Sdílet“ → HINKredience) a
/// výběr PDF ze souborů. Nativní část: MainActivity.kt.
class ReceiptShare {
  ReceiptShare._();

  static const _channel = MethodChannel('cz.hink.hinkredience/receipt');
  static final _shared = StreamController<String>.broadcast();
  static var _listening = false;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Cesty k PDF sdíleným během běhu aplikace.
  static Stream<String> get shared {
    if (!_listening && _android) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'shared' && call.arguments is String) {
          _shared.add(call.arguments as String);
        }
      });
    }
    return _shared.stream;
  }

  /// PDF sdílené při spuštění aplikace (jen jednou).
  static Future<String?> initial() async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<String>('initial');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Výběr PDF ze souborů telefonu; null = zrušeno.
  static Future<String?> pick() async {
    if (!_android) return null;
    return _channel.invokeMethod<String>('pick');
  }
}

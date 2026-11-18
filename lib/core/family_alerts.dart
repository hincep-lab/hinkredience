import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'material.dart';

/// Oznámení „někdo z rodiny něco chce“: nové přání do jídelníčku nebo
/// nová položka na nákupním seznamu.
abstract interface class FamilyAlerts {
  Future<bool> requestPermission();
  Future<void> show(List<({String title, String body})> notifications);
}

class LocalFamilyAlerts implements FamilyAlerts {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;
  var _nextId = 0;

  static const _channel = AndroidNotificationDetails(
    'family_news',
    'Rodina',
    channelDescription:
        'Když někdo z rodiny přidá přání do jídelníčku nebo něco na nákup.',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.social,
  );

  Future<void> _init() => _ready ??= _plugin
      .initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      )
      .then((_) {});

  @override
  Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    try {
      await _init();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        return await ios.requestPermissions(alert: true, sound: true) ?? false;
      }
    } catch (error) {
      debugPrint('Oznámení nejdou povolit: $error');
    }
    return false;
  }

  @override
  Future<void> show(List<({String title, String body})> notifications) async {
    if (kIsWeb || notifications.isEmpty) return;
    try {
      await _init();
      for (final n in notifications) {
        // Vlastní rozsah id, aby se nepletla s časovači vaření.
        await _plugin.show(
          id: 900000 + (_nextId++ % 1000),
          title: n.title,
          body: n.body,
          notificationDetails: const NotificationDetails(
            android: _channel,
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentSound: true,
            ),
          ),
        );
      }
    } catch (error) {
      debugPrint('Oznámení od rodiny nejde zobrazit: $error');
    }
  }
}

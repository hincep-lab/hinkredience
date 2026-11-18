// Mimo prohlížeč (Android, iOS, testy) web push neexistuje.

bool webPushSupported() => false;

/// 'granted' | 'denied' | 'default' | 'unsupported'
String webPushPermission() => 'unsupported';

/// Běží web jako aplikace z plochy?
bool webPushStandalone() => false;

Future<({String endpoint, String p256dh, String auth})> webPushSubscribe(
  String publicKey,
) => throw UnsupportedError('Web push je jen v prohlížeči.');

Future<String> webPushUnsubscribe() async => '';

Future<String> webPushCurrent() async => '';

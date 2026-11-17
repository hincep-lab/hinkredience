// Mimo prohlížeč (Android, iOS, testy) se časovač ohlašuje systémovým
// oznámením (LocalNotificationAlerts).

Future<bool> webTimerPrepare() async => false;

Future<void> webTimerRing(String title, String body, int id) async {}

Future<void> webTimerClose(int id) async {}

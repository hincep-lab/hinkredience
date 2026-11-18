/// Zvuk a oznámení doběhnutého časovače v prohlížeči (web/push.js).
/// Mimo web nic nedělá.
library;

export 'web_timer_alarm_stub.dart'
    if (dart.library.js_interop) 'web_timer_alarm_web.dart';

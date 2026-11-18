import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'cook_timer.dart';
import 'web_timer_alarm.dart';
import 'material.dart';

// Služby pro režim Vaříme spolu. Každá je za rozhraním, aby šla v testech
// nahradit a aby chyba na konkrétním telefonu nezastavila vaření.

/// Upozornění na doběhnuté časovače, i když je aplikace v pozadí.
abstract interface class CookAlerts {
  /// Požádá o povolení oznámení (Android 13+, iOS). Vrací, zda je povoleno.
  Future<bool> requestPermission();

  /// Naplánuje oznámení na konec běžícího časovače.
  Future<void> schedule(CookTimer timer);

  Future<void> cancel(CookTimer timer);

  /// Ohlásí doběhnutý časovač hned teď: zvuk + oznámení. Volá se, když je
  /// aplikace otevřená a časovač právě doběhl.
  Future<void> ring(CookTimer timer);
}

class LocalNotificationAlerts implements CookAlerts {
  LocalNotificationAlerts();

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  // Kanál se zvukem budíku: zazní i při ztlumeném vyzvánění (v kuchyni se
  // telefon často nechává potichu). Nastavení kanálu Android po vytvoření
  // nemění, proto má kanál nový název (starý „cook_timers“ zvonil
  // jako běžná zpráva).
  static final _channel = AndroidNotificationDetails(
    'cook_timer_done',
    'Doběhnutý časovač vaření',
    channelDescription: 'Zvuk a upozornění, když doběhne časovač při vaření.',
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.alarm,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    playSound: true,
    enableVibration: true,
    vibrationPattern: Int64List.fromList([0, 600, 300, 600, 300, 600]),
    visibility: NotificationVisibility.public,
    ticker: 'Časovač doběhl',
  );

  NotificationDetails get _details => NotificationDetails(
    android: _channel,
    iOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  );

  /// Nejdéle takto se čeká na systém oznámení; pak se pokračuje bez něj.
  static const _patience = Duration(seconds: 8);

  Future<void> _init() => _ready ??= () async {
    // V prohlížeči systémová oznámení nejsou – zvoní jen otevřená aplikace.
    if (kIsWeb) throw UnsupportedError('oznámení nejsou ve webové verzi');
    tzdata.initializeTimeZones();
    await _plugin
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
        .timeout(_patience);
  }();

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
        return await ios.requestPermissions(
              alert: true,
              sound: true,
              badge: false,
            ) ??
            false;
      }
    } catch (error) {
      debugPrint('Oznámení nejdou povolit: $error');
    }
    return false;
  }

  @override
  Future<void> schedule(CookTimer timer) async {
    final endsAt = timer.endsAt;
    if (endsAt == null || kIsWeb) return;
    try {
      await _init();
      var mode = AndroidScheduleMode.inexactAllowWhileIdle;
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null &&
          (await android.canScheduleExactNotifications() ?? false)) {
        mode = AndroidScheduleMode.exactAllowWhileIdle;
      }
      await _plugin
          .zonedSchedule(
            id: timer.notificationId,
            title: 'Časovač doběhl',
            body: timer.label,
            scheduledDate: tz.TZDateTime.from(endsAt.toUtc(), tz.UTC),
            notificationDetails: _details,
            androidScheduleMode: mode,
          )
          .timeout(_patience);
    } catch (error) {
      debugPrint('Oznámení časovače nejde naplánovat: $error');
    }
  }

  @override
  Future<void> cancel(CookTimer timer) async {
    if (kIsWeb) return;
    try {
      await _init();
      await _plugin.cancel(id: timer.notificationId).timeout(_patience);
    } catch (error) {
      debugPrint('Oznámení časovače nejde zrušit: $error');
    }
  }

  @override
  Future<void> ring(CookTimer timer) async {
    if (kIsWeb) return;
    try {
      await _init();
      // Naplánované oznámení (může přijít o chvilku později) nahradit
      // okamžitým se zvukem – v otevřené aplikaci zazní hned.
      await _plugin.cancel(id: timer.notificationId).timeout(_patience);
      await _plugin
          .show(
            id: timer.notificationId,
            title: 'Časovač doběhl',
            body: timer.label,
            notificationDetails: _details,
          )
          .timeout(_patience);
    } catch (error) {
      debugPrint('Časovač nejde ohlásit: $error');
    }
  }
}

/// Webová verze: pípání v prohlížeči + oznámení prohlížeče (web/push.js).
class WebCookAlerts implements CookAlerts {
  const WebCookAlerts();

  @override
  Future<bool> requestPermission() => webTimerPrepare();

  // Konec časovače hlídá otevřená aplikace (ring); prohlížeč neumí
  // oznámení naplánovat dopředu.
  @override
  Future<void> schedule(CookTimer timer) async {}

  @override
  Future<void> cancel(CookTimer timer) => webTimerClose(timer.notificationId);

  @override
  Future<void> ring(CookTimer timer) =>
      webTimerRing('Časovač doběhl', timer.label, timer.notificationId);
}

/// Předčítání kroků postupu.
abstract interface class Speaker {
  Future<void> say(String text);
  Future<void> stop();
}

class TtsSpeaker implements Speaker {
  final _tts = FlutterTts();
  bool _ready = false;

  @override
  Future<void> say(String text) async {
    try {
      if (!_ready) {
        await _tts.setLanguage('cs-CZ');
        await _tts.setSpeechRate(0.5);
        _ready = true;
      }
      await _tts.stop();
      await _tts.speak(text);
    } catch (error) {
      debugPrint('Předčítání nefunguje: $error');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// Rozpoznávání hlasu. Poslouchá jen po stisknutí tlačítka mikrofonu.
abstract interface class VoiceInput {
  /// Spustí poslech jedné věty. [onWords] dostane rozpoznaný text.
  /// Vrací `false`, když rozpoznávání v telefonu není nebo není povolené.
  Future<bool> listen(void Function(String words) onWords);

  Future<void> stop();
}

class SpeechVoiceInput implements VoiceInput {
  final _speech = SpeechToText();
  bool? _available;

  @override
  Future<bool> listen(void Function(String words) onWords) async {
    try {
      _available ??= await _speech.initialize();
      if (_available != true) return false;
      await _speech.listen(
        localeId: 'cs_CZ',
        listenFor: const Duration(seconds: 8),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: false,
          cancelOnError: true,
          listenMode: ListenMode.confirmation,
        ),
        onResult: (SpeechRecognitionResult result) {
          if (result.finalResult) onWords(result.recognizedWords);
        },
      );
      return true;
    } catch (error) {
      debugPrint('Rozpoznávání hlasu nefunguje: $error');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }
}

final cookAlertsProvider = Provider<CookAlerts>(
  (ref) => kIsWeb ? const WebCookAlerts() : LocalNotificationAlerts(),
);
final speakerProvider = Provider<Speaker>((ref) => TtsSpeaker());
final voiceInputProvider = Provider<VoiceInput>((ref) => SpeechVoiceInput());

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'cook_timer.dart';
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
}

class LocalNotificationAlerts implements CookAlerts {
  LocalNotificationAlerts();

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  static const _channel = AndroidNotificationDetails(
    'cook_timers',
    'Časovače vaření',
    channelDescription: 'Upozornění, když doběhne časovač při vaření.',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.alarm,
    playSound: true,
    enableVibration: true,
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
            notificationDetails: const NotificationDetails(
              android: _channel,
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentSound: true,
                interruptionLevel: InterruptionLevel.timeSensitive,
              ),
            ),
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
  (ref) => LocalNotificationAlerts(),
);
final speakerProvider = Provider<Speaker>((ref) => TtsSpeaker());
final voiceInputProvider = Provider<VoiceInput>((ref) => SpeechVoiceInput());

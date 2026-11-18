import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/app_config.dart';
import 'app/background_alerts.dart';
import 'app/providers.dart';
import 'core/app_colors.dart';
import 'core/material.dart';
import 'data/photo_store.dart';
import 'data/web_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final prefs = await SharedPreferences.getInstance();
  final config = AppConfig.load(prefs);

  SupabaseClient? client;
  if (config.hasSupabase) {
    try {
      await Supabase.initialize(
        url: config.supabaseUrl,
        publishableKey: config.supabaseAnonKey,
      );
      client = Supabase.instance.client;
    } catch (error) {
      // Špatně zadané připojení nesmí zabránit spuštění – recepty jsou v telefonu.
      debugPrint('Supabase se nepodařilo inicializovat: $error');
    }
  }

  // Kontrola akcí na pozadí (Android); nesmí zdržet spuštění aplikace.
  if (!kIsWeb) unawaited(scheduleBackgroundSaleAlerts());

  // Webová verze nemá složku aplikace: fotky se zobrazují ze serveru.
  final documents = kIsWeb ? null : await getApplicationDocumentsDirectory();
  final webDatabase = webDatabaseFactory();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appConfigProvider.overrideWithValue(config),
        supabaseClientProvider.overrideWithValue(client),
        photoStoreProvider.overrideWithValue(PhotoStore(documents)),
        if (webDatabase != null)
          databaseFactoryProvider.overrideWithValue(webDatabase),
      ],
      child: const HinkredienceApp(),
    ),
  );
}

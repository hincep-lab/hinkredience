import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/app_config.dart';
import 'app/providers.dart';
import 'core/app_colors.dart';
import 'core/material.dart';
import 'data/photo_store.dart';

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
        anonKey: config.supabaseAnonKey,
      );
      client = Supabase.instance.client;
    } catch (error) {
      // Špatně zadané připojení nesmí zabránit spuštění – recepty jsou v telefonu.
      debugPrint('Supabase se nepodařilo inicializovat: $error');
    }
  }

  final documents = await getApplicationDocumentsDirectory();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appConfigProvider.overrideWithValue(config),
        supabaseClientProvider.overrideWithValue(client),
        photoStoreProvider.overrideWithValue(PhotoStore(documents)),
      ],
      child: const HinkredienceApp(),
    ),
  );
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;
import 'package:workmanager/workmanager.dart';

import '../core/family_alerts.dart';
import '../data/price_service.dart';
import 'app_config.dart';
import 'sale_alerts_runner.dart';

const _task = 'sale-alerts';

/// Kontrola akcí na pozadí (Android, i při zavřené aplikaci): zhruba každé
/// 3 hodiny, jen s internetem. Bere veřejné ověřené akce bez přihlášení,
/// takže se nijak nedotkne přihlášení v aplikaci.
@pragma('vm:entry-point')
void saleAlertsDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final prefs = await SharedPreferences.getInstance();
      final config = AppConfig.load(prefs);
      if (!config.hasSupabase || !saleAlertsEnabled(prefs)) return true;
      final client = SupabaseClient(config.supabaseUrl, config.supabaseAnonKey);
      try {
        await runSaleAlerts(
          prefs: prefs,
          loadOffers: () => PriceService.publicOffers(client),
          alerts: LocalFamilyAlerts(),
          now: DateTime.now(),
          askPermission: false,
        );
      } finally {
        await client.dispose();
      }
    } catch (error) {
      debugPrint('Kontrola akcí na pozadí selhala: $error');
    }
    return true;
  });
}

/// Naplánuje kontrolu akcí na pozadí (jen Android; opakované volání nic nemění).
Future<void> scheduleBackgroundSaleAlerts() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().initialize(saleAlertsDispatcher);
    await Workmanager().registerPeriodicTask(
      _task,
      _task,
      frequency: const Duration(hours: 3),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (error) {
    debugPrint('Kontrolu akcí na pozadí se nepodařilo naplánovat: $error');
  }
}

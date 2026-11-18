import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/best_buy.dart';
import '../core/family_alerts.dart';
import '../core/sale_alerts.dart';

/// Upozornění na akce: zapnuto/vypnuto, hlídané zboží a co už bylo ohlášeno.
/// Všechno je v telefonu (SharedPreferences), aby to šlo i na pozadí.
const saleAlertsKey = 'sale_alerts';
const saleWatchKey = 'sale_watch';
const _seenKey = 'sale_alerts_seen';
const _lastKey = 'sale_alerts_last';
const _shoppingKey = 'sale_alerts_shopping';

bool saleAlertsEnabled(SharedPreferences prefs) =>
    prefs.getBool(saleAlertsKey) ?? true;

List<WatchItem> watchItems(SharedPreferences prefs) =>
    WatchItem.decode(prefs.getString(saleWatchKey));

Future<void> saveWatchItems(SharedPreferences prefs, List<WatchItem> items) =>
    prefs.setString(saleWatchKey, WatchItem.encode(items));

/// Zkontroluje nové ověřené akce na hlídané zboží a zboží ze seznamů a pošle
/// oznámení. Nejvýš jednou za 30 minut. Při prvním spuštění si jen zapamatuje,
/// co už v akci je. [shopping] = názvy z nákupních seznamů (v aplikaci);
/// na pozadí se vezmou naposledy uložené.
Future<int> runSaleAlerts({
  required SharedPreferences prefs,
  required Future<List<PriceOffer>> Function() loadOffers,
  required FamilyAlerts alerts,
  required DateTime now,
  List<String>? shopping,
  bool askPermission = true,
}) async {
  try {
    await prefs.reload();
    if (shopping != null) await prefs.setStringList(_shoppingKey, shopping);
    if (!saleAlertsEnabled(prefs)) return 0;
    final last = prefs.getInt(_lastKey) ?? 0;
    if (now.millisecondsSinceEpoch - last < 30 * 60 * 1000) return 0;
    await prefs.setInt(_lastKey, now.millisecondsSinceEpoch);
    final offers = await loadOffers();
    if (offers.isEmpty) return 0;
    final watch = watchItems(prefs);
    final names = [
      for (final w in watch) w.name,
      ...?(shopping ?? prefs.getStringList(_shoppingKey)),
    ];
    final first = !prefs.containsKey(_seenKey);
    final seen = (prefs.getStringList(_seenKey) ?? const []).toSet();
    final found = saleAlerts(
      offers: offers,
      watched: names,
      seen: seen,
      today: now,
      cards: {...?prefs.getStringList('best_buy_cards')},
      maxPrice: {
        for (final w in watch)
          if (w.maxPrice != null) w.name.toLowerCase(): w.maxPrice!,
      },
    );
    // Pamatovat jen platné akce (prošlé samy vypadnou).
    await prefs.setStringList(_seenKey, [for (final o in offers) o.id]);
    if (first || found.isEmpty) return 0;
    if (askPermission &&
        !(prefs.getBool('family_notifications_asked') ?? false)) {
      await prefs.setBool('family_notifications_asked', true);
      await alerts.requestPermission();
    }
    await alerts.show(found);
    return found.length;
  } catch (error) {
    debugPrint('Upozornění na akce se nepodařilo: $error');
    return 0;
  }
}

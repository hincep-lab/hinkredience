import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/best_buy.dart';

/// Výsledek hledání akcí na serveru.
class PriceRefresh {
  const PriceRefresh({
    this.provider,
    this.scanned = 0,
    this.cached = 0,
    this.found = 0,
    this.verified = 0,
    this.unverified = 0,
    this.errors = const [],
  });

  final String? provider;
  final int scanned;
  final int cached;
  final int found;
  final int verified;
  final int unverified;
  final List<String> errors;

  bool get noProvider => errors.contains('no_provider');

  factory PriceRefresh.fromJson(Map<String, dynamic> j) => PriceRefresh(
    provider: j['provider'] as String?,
    scanned: (j['scanned'] as num?)?.toInt() ?? 0,
    cached: (j['cached'] as num?)?.toInt() ?? 0,
    found: (j['found'] as num?)?.toInt() ?? 0,
    verified: (j['verified'] as num?)?.toInt() ?? 0,
    unverified: (j['unverified'] as num?)?.toInt() ?? 0,
    errors: [for (final e in (j['errors'] as List?) ?? const []) '$e'],
  );
}

/// Akce z letáků (čtení z tabulky price_offers) a hledání nových přes
/// serverovou funkci `prices`. Bez připojení vrací poslední známé akce.
class PriceService {
  PriceService(this._client, this._prefs);

  final SupabaseClient _client;
  final SharedPreferences _prefs;

  static const _cacheKey = 'price_offers_cache';

  /// Platné akce (dnes a později), poslední známé při výpadku.
  Future<List<PriceOffer>> offers(DateTime today) async {
    final day =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from('price_offers')
          .select()
          .gte('valid_to', day)
          .order('price')
          .limit(3000);
      await _prefs.setString(_cacheKey, jsonEncode(rows));
      return [for (final r in rows) PriceOffer.fromJson(r)];
    } catch (_) {
      return cached();
    }
  }

  List<PriceOffer> cached() {
    final text = _prefs.getString(_cacheKey);
    if (text == null) return const [];
    try {
      return [
        for (final r in jsonDecode(text) as List)
          if (r is Map<String, dynamic>) PriceOffer.fromJson(r),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Najde akce pro [products] ve všech sušických řetězcích (zdarma přes
  /// Google Gemini; stejný produkt se v jednom dni hledá jen jednou).
  Future<PriceRefresh> refresh(List<String> products) async {
    final response = await _client.functions.invoke(
      'prices',
      body: {'action': 'refresh', 'products': products},
    );
    final data = response.data;
    return data is Map<String, dynamic>
        ? PriceRefresh.fromJson(data)
        : const PriceRefresh();
  }
}

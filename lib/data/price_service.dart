import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/best_buy.dart';

/// Výsledek hledání akcí na serveru včetně diagnostiky (co se stáhlo, co
/// vrátila AI, co a proč bylo odmítnuto a co se uložilo).
class PriceRefresh {
  const PriceRefresh({
    this.provider,
    this.scanned = 0,
    this.cached = 0,
    this.found = 0,
    this.verified = 0,
    this.unverified = 0,
    this.saved = 0,
    this.duplicates = 0,
    this.rejected = 0,
    this.errors = const [],
    this.diag = const [],
    this.geminiConfigured = false,
    this.geminiOk,
    this.geminiCalls = 0,
    this.geminiModel = '',
    this.geminiError = '',
    this.version = '',
  });

  final String? provider;
  final int scanned;
  final int cached;
  final int found;
  final int verified;
  final int unverified;
  final int saved;
  final int duplicates;
  final int rejected;
  final List<String> errors;

  /// Diagnostika po řetězcích (mapy z JSON serveru).
  final List<Map<String, dynamic>> diag;

  /// Stav Google Gemini v tomto hledání: je klíč nastaven, kolikrát se
  /// volalo a zda odpovědělo (null = nebylo potřeba volat).
  final bool geminiConfigured;
  final bool? geminiOk;
  final int geminiCalls;
  final String geminiModel;
  final String geminiError;

  /// Verze serverové funkce („letaky-2“); prázdná = stará funkce.
  final String version;

  bool get noProvider => errors.contains('no_provider');

  /// Chyby jednotlivých řetězců („penny: …“).
  List<String> get chainErrors => [
    for (final e in errors)
      if (e != 'no_provider') e,
  ];

  factory PriceRefresh.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    final g = j['gemini'] is Map
        ? Map<String, dynamic>.from(j['gemini'] as Map)
        : const <String, dynamic>{};
    return PriceRefresh(
      provider: j['provider'] as String?,
      scanned: n('scanned'),
      cached: n('cached'),
      found: n('found'),
      verified: n('verified'),
      unverified: n('unverified'),
      saved: n('saved'),
      duplicates: n('duplicates'),
      rejected: n('rejected'),
      errors: [for (final e in (j['errors'] as List?) ?? const []) '$e'],
      diag: [
        for (final d in (j['diag'] as List?) ?? const [])
          if (d is Map) Map<String, dynamic>.from(d),
      ],
      geminiConfigured: g['configured'] == true,
      geminiOk: g['ok'] as bool?,
      geminiCalls: (g['calls'] as num?)?.toInt() ?? 0,
      geminiModel: '${g['model'] ?? ''}',
      geminiError: '${g['error'] ?? ''}',
      version: '${j['version'] ?? ''}',
    );
  }
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

  /// Najde akce pro [products] v aktuálních letácích sušických řetězců
  /// (zdarma; letáky čte Google Gemini, stejný leták se pro stejný produkt
  /// čte jen jednou). [force] obejde mezipaměť (pro opakovaný test).
  Future<PriceRefresh> refresh(
    List<String> products, {
    bool force = false,
  }) async {
    final response = await _client.functions.invoke(
      'prices',
      body: {
        'action': 'refresh',
        'products': products,
        if (force) 'force': true,
      },
    );
    final data = response.data;
    return data is Map<String, dynamic>
        ? PriceRefresh.fromJson(data)
        : const PriceRefresh();
  }
}

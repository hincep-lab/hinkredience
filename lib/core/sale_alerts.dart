import 'dart:convert';

import 'best_buy.dart';
import 'stores.dart';

/// Hlídané zboží: název a volitelně cena balení, pod kterou chci vědět.
class WatchItem {
  const WatchItem(this.name, {this.maxPrice});

  final String name;
  final double? maxPrice;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (maxPrice != null) 'max': maxPrice,
  };

  static List<WatchItem> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final j in list)
          if (j is Map &&
              j['name'] is String &&
              (j['name'] as String).trim().isNotEmpty)
            WatchItem(
              (j['name'] as String).trim(),
              maxPrice: (j['max'] as num?)?.toDouble(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<WatchItem> items) =>
      jsonEncode([for (final i in items) i.toJson()]);
}

/// Upozornění „zboží, které kupujete, je v akci“: nové ověřené akce, které
/// odpovídají položce z nákupních seznamů (i odškrtnuté = běžně kupované).
/// Za každou položku jedno oznámení s nejlevnější akcí, nejvýš [max]
/// oznámení – zbytek se shrne do posledního.
List<({String title, String body})> saleAlerts({
  required List<PriceOffer> offers,
  required Iterable<String> watched,
  required Set<String> seen,
  required DateTime today,
  Set<String> cards = const {},
  Map<String, double> maxPrice = const {},
  int max = 3,
}) {
  final day = DateTime(today.year, today.month, today.day);
  final fresh = [
    for (final o in offers)
      if (o.verified &&
          !o.isRegular &&
          !seen.contains(o.id) &&
          o.activeOn(day) &&
          usableOffer(o, cards))
        o,
  ];
  if (fresh.isEmpty) return const [];
  final found = <({String item, PriceOffer best, int stores})>[];
  final names = <String>{};
  for (final raw in watched) {
    final item = raw.trim();
    if (item.isEmpty || !names.add(item.toLowerCase())) continue;
    final limit = maxPrice[item.toLowerCase()];
    final hits = [
      for (final o in fresh)
        if (productMatches(item, o.product) &&
            (limit == null || o.price <= limit + 0.005))
          o,
    ];
    if (hits.isEmpty) continue;
    hits.sort((a, b) {
      final ua = a.unitPrice?.price ?? a.price;
      final ub = b.unitPrice?.price ?? b.price;
      return ua.compareTo(ub);
    });
    found.add((
      item: item,
      best: hits.first,
      stores: {for (final h in hits) h.chain}.length,
    ));
  }
  if (found.isEmpty) return const [];
  String line(PriceOffer o) {
    final chain = chainById(o.chain)?.name ?? o.chain;
    final pack = o.packQty == null
        ? ''
        : ' · ${_num(o.packQty!)} ${o.packUnit}';
    final card = o.needsLoyalty
        ? ' · s ${o.loyalty.isEmpty ? 'kartou' : o.loyalty}'
        : '';
    return '${o.product}: $chain ${_kc(o.price)}$pack$card · '
        'do ${o.validTo.day}. ${o.validTo.month}.';
  }

  final out = <({String title, String body})>[];
  for (final f in found.take(found.length > max ? max - 1 : max)) {
    final more = f.stores > 1 ? ' (v akci ve ${f.stores} obchodech)' : '';
    out.add((title: '${_cap(f.item)} je v akci', body: '${line(f.best)}$more'));
  }
  if (found.length > max) {
    final rest = found.skip(max - 1).map((f) => f.item).toList();
    out.add((title: 'Další zboží ze seznamu v akci', body: rest.join(', ')));
  }
  return out;
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _num(double v) =>
    (v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v').replaceAll('.', ',');

String _kc(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} Kč';

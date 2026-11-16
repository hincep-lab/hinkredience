import 'dart:math' as math;

import 'kitchen_math.dart';
import 'stores.dart';

// Nejvýhodnější nákup: porovnání cen nákupního seznamu v sušických
// prodejnách. Počítá se JEN s ověřenými cenami – akce z oficiálního webu
// řetězce (ověřené serverem) a ceny z vlastních účtenek. Neověřené akce se
// zobrazí s upozorněním, ale do součtů se nikdy nezapočítají.

/// Akční nabídka z letáku (tabulka `price_offers`).
class PriceOffer {
  const PriceOffer({
    required this.id,
    required this.chain,
    required this.product,
    required this.price,
    required this.validTo,
    required this.sourceUrl,
    this.storeId,
    this.label = '',
    this.packQty,
    this.packUnit = '',
    this.regularPrice,
    this.conditions = '',
    this.validFrom,
    this.sourceTitle = '',
    this.provider = '',
    this.verified = false,
    this.verifyMethod = '',
  });

  final String id;
  final String chain;

  /// Konkrétní prodejna, nebo null = všechny sušické prodejny řetězce.
  final String? storeId;
  final String product;
  final String label;
  final double price;
  final double? packQty;
  final String packUnit;
  final double? regularPrice;
  final String conditions;
  final DateTime? validFrom;
  final DateTime validTo;
  final String sourceUrl;
  final String sourceTitle;
  final String provider;
  final bool verified;
  final String verifyMethod;

  bool appliesTo(Store store) =>
      chain == store.chain && (storeId == null || storeId == store.id);

  /// Platí v daný den (včetně posledního dne).
  bool activeOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    if (validFrom != null && d.isBefore(_day(validFrom!))) return false;
    return !d.isAfter(_day(validTo));
  }

  factory PriceOffer.fromJson(Map<String, dynamic> j) => PriceOffer(
    id: j['id'] as String? ?? '',
    chain: j['chain'] as String? ?? '',
    storeId: j['store_id'] as String?,
    product: j['product'] as String? ?? '',
    label: j['label'] as String? ?? '',
    price: (j['price'] as num?)?.toDouble() ?? 0,
    packQty: (j['pack_qty'] as num?)?.toDouble(),
    packUnit: j['pack_unit'] as String? ?? '',
    regularPrice: (j['regular_price'] as num?)?.toDouble(),
    conditions: j['conditions'] as String? ?? '',
    validFrom: DateTime.tryParse(j['valid_from'] as String? ?? ''),
    validTo:
        DateTime.tryParse(j['valid_to'] as String? ?? '') ?? DateTime(2000),
    sourceUrl: j['source_url'] as String? ?? '',
    sourceTitle: j['source_title'] as String? ?? '',
    provider: j['provider'] as String? ?? '',
    verified: j['verified'] == true,
    verifyMethod: j['verify_method'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'chain': chain,
    'store_id': storeId,
    'product': product,
    'label': label,
    'price': price,
    'pack_qty': packQty,
    'pack_unit': packUnit,
    'regular_price': regularPrice,
    'conditions': conditions,
    'valid_from': validFrom == null ? null : _dayKey(validFrom!),
    'valid_to': _dayKey(validTo),
    'source_url': sourceUrl,
    'source_title': sourceTitle,
    'provider': provider,
    'verified': verified,
    'verify_method': verifyMethod,
  };
}

/// Cena z účtenky (tabulka `price_receipts`) – ověřená uživatelem.
class ReceiptPrice {
  const ReceiptPrice({
    required this.id,
    required this.storeId,
    required this.product,
    required this.price,
    required this.boughtOn,
    required this.updatedAt,
    this.label = '',
    this.packQty,
    this.packUnit = '',
    this.note = '',
    this.ownerId,
    this.householdId,
  });

  final String id;
  final String storeId;
  final String product;
  final String label;
  final double price;
  final double? packQty;
  final String packUnit;
  final DateTime boughtOn;
  final String note;
  final String? ownerId;
  final String? householdId;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'store_id': storeId,
    'product': product,
    'label': label,
    'price': price,
    'pack_qty': ?packQty,
    'pack_unit': packUnit,
    'bought_on': _dayKey(boughtOn),
    'note': note,
    'owner_id': ?ownerId,
    'household_id': ?householdId,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory ReceiptPrice.fromJson(Map<String, dynamic> j) => ReceiptPrice(
    id: j['id'] as String? ?? '',
    storeId: j['store_id'] as String? ?? '',
    product: j['product'] as String? ?? '',
    label: j['label'] as String? ?? '',
    price: (j['price'] as num?)?.toDouble() ?? 0,
    packQty: (j['pack_qty'] as num?)?.toDouble(),
    packUnit: j['pack_unit'] as String? ?? '',
    boughtOn:
        DateTime.tryParse(j['bought_on'] as String? ?? '') ?? DateTime(2000),
    note: j['note'] as String? ?? '',
    ownerId: j['owner_id'] as String?,
    householdId: j['household_id'] as String?,
    updatedAt:
        DateTime.tryParse(j['updated_at'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// Položka nákupu pro výpočet.
class BuyItem {
  const BuyItem({
    required this.id,
    required this.name,
    this.quantity,
    this.unit = '',
  });

  final String id;
  final String name;
  final double? quantity;
  final String unit;
}

/// Cena položky v jedné prodejně.
class ItemPrice {
  const ItemPrice({
    required this.item,
    required this.store,
    required this.cost,
    required this.packs,
    this.offer,
    this.receipt,
  });

  final BuyItem item;
  final Store store;

  /// Kolik položka v této prodejně stojí (cena × počet balení).
  final double cost;
  final int packs;
  final PriceOffer? offer;
  final ReceiptPrice? receipt;

  bool get isOffer => offer != null;
}

/// Celý nákup v jedné prodejně.
class StorePlan {
  const StorePlan({
    required this.store,
    required this.prices,
    required this.missing,
  });

  final Store store;
  final List<ItemPrice> prices;
  final List<BuyItem> missing;

  double get total => prices.fold(0, (sum, p) => sum + p.cost);
}

/// Výsledek porovnání.
class BestBuy {
  const BestBuy({
    required this.items,
    required this.singleStore,
    required this.storePlans,
    required this.combination,
    required this.combinationMissing,
    required this.savingsSingle,
    required this.savingsCombination,
  });

  final List<BuyItem> items;

  /// Nejvýhodnější jedna prodejna (nejvíc známých cen, pak nejnižší součet).
  final StorePlan? singleStore;

  /// Všechny prodejny se známou cenou aspoň jedné položky, od nejlepší.
  final List<StorePlan> storePlans;

  /// Nejlevnější prodejna pro každou položku zvlášť.
  final List<ItemPrice> combination;
  final List<BuyItem> combinationMissing;

  /// Úspora proti nákupu za nejvyšší známé ceny (jen položky, které mají
  /// známou cenu aspoň ve dvou prodejnách – jinak není s čím srovnávat).
  final double savingsSingle;
  final double savingsCombination;

  double get combinationTotal => combination.fold(0, (sum, p) => sum + p.cost);

  /// Položky s cenou v kombinaci podle prodejen (pořadí podle počtu).
  Map<Store, List<ItemPrice>> get combinationByStore {
    final map = <Store, List<ItemPrice>>{};
    for (final p in combination) {
      (map[p.store] ??= []).add(p);
    }
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return {for (final e in entries) e.key: e.value};
  }

  bool get hasPrices => storePlans.isNotEmpty;
}

/// Porovnání cen nákupu. [today] = den nákupu (akce musí platit).
BestBuy computeBestBuy({
  required List<BuyItem> items,
  required List<PriceOffer> offers,
  required List<ReceiptPrice> receipts,
  required DateTime today,
  List<Store> stores = susiceStores,
}) {
  final prices = <Store, Map<String, ItemPrice>>{};
  for (final store in stores) {
    for (final item in items) {
      final p = priceInStore(item, store, offers, receipts, today);
      if (p != null) (prices[store] ??= {})[item.id] = p;
    }
  }

  final plans =
      [
        for (final store in stores)
          if (prices[store] case final byItem? when byItem.isNotEmpty)
            StorePlan(
              store: store,
              prices: [
                for (final item in items)
                  if (byItem[item.id] case final p?) p,
              ],
              missing: [
                for (final item in items)
                  if (!byItem.containsKey(item.id)) item,
              ],
            ),
      ]..sort((a, b) {
        final cover = b.prices.length.compareTo(a.prices.length);
        return cover != 0 ? cover : a.total.compareTo(b.total);
      });

  final combination = <ItemPrice>[];
  final missing = <BuyItem>[];
  var savingsCombination = 0.0;
  for (final item in items) {
    final known = [
      for (final store in stores)
        if (prices[store]?[item.id] case final p?) p,
    ];
    if (known.isEmpty) {
      missing.add(item);
      continue;
    }
    known.sort((a, b) => a.cost.compareTo(b.cost));
    combination.add(known.first);
    if (known.length >= 2) {
      savingsCombination += known.last.cost - known.first.cost;
    }
  }

  var savingsSingle = 0.0;
  final best = plans.isEmpty ? null : plans.first;
  if (best != null) {
    for (final p in best.prices) {
      final known = [
        for (final store in stores)
          if (prices[store]?[p.item.id] case final q?) q.cost,
      ];
      if (known.length >= 2) savingsSingle += known.reduce(math.max) - p.cost;
    }
  }

  return BestBuy(
    items: items,
    singleStore: best,
    storePlans: plans,
    combination: combination,
    combinationMissing: missing,
    savingsSingle: _round(savingsSingle),
    savingsCombination: _round(savingsCombination),
  );
}

/// Nejnižší ověřená cena položky v prodejně: platná ověřená akce, jinak
/// nejnovější cena z účtenky (ne starší než [receiptMaxAge]).
ItemPrice? priceInStore(
  BuyItem item,
  Store store,
  List<PriceOffer> offers,
  List<ReceiptPrice> receipts,
  DateTime today, {
  Duration receiptMaxAge = const Duration(days: 120),
}) {
  ItemPrice? best;
  for (final o in offers) {
    if (!o.verified || !o.appliesTo(store) || !o.activeOn(today)) continue;
    if (!productMatches(item.name, o.product)) continue;
    final packs = packsNeeded(item, o.packQty, o.packUnit);
    final p = ItemPrice(
      item: item,
      store: store,
      cost: _round(o.price * packs),
      packs: packs,
      offer: o,
    );
    if (best == null || p.cost < best.cost) best = p;
  }
  ReceiptPrice? latest;
  for (final r in receipts) {
    if (r.storeId != store.id || !productMatches(item.name, r.product)) {
      continue;
    }
    if (today.difference(r.boughtOn) > receiptMaxAge) continue;
    if (latest == null || r.boughtOn.isAfter(latest.boughtOn)) latest = r;
  }
  if (latest != null) {
    final packs = packsNeeded(item, latest.packQty, latest.packUnit);
    final p = ItemPrice(
      item: item,
      store: store,
      cost: _round(latest.price * packs),
      packs: packs,
      receipt: latest,
    );
    if (best == null || p.cost < best.cost) best = p;
  }
  return best;
}

/// Ověřená akce, která platí dnes pro položku (pro štítek u položky):
/// nejlevnější napříč prodejnami.
({PriceOffer offer, double cost})? bestOfferFor(
  BuyItem item,
  List<PriceOffer> offers,
  DateTime today,
) {
  ({PriceOffer offer, double cost})? best;
  for (final o in offers) {
    if (!o.verified || !o.activeOn(today)) continue;
    if (!productMatches(item.name, o.product)) continue;
    final cost = o.price * packsNeeded(item, o.packQty, o.packUnit);
    if (best == null || cost < best.cost) best = (offer: o, cost: cost);
  }
  return best;
}

/// Neověřené nabídky k položce (jen pro informaci, mimo porovnání).
List<PriceOffer> unverifiedOffersFor(
  BuyItem item,
  List<PriceOffer> offers,
  DateTime today,
) => [
  for (final o in offers)
    if (!o.verified &&
        o.activeOn(today) &&
        productMatches(item.name, o.product))
      o,
];

/// Kolik balení je potřeba: 1,5 kg mouky po 1 kg = 2 balení. Když jednotky
/// nejdou převést (ks vs. g) nebo chybí množství, počítá se 1 balení.
int packsNeeded(BuyItem item, double? packQty, String packUnit) {
  final need = item.quantity;
  if (need == null || need <= 0 || packQty == null || packQty <= 0) return 1;
  final a = toBaseUnit(need, item.unit);
  final b = toBaseUnit(packQty, packUnit.isEmpty ? item.unit : packUnit);
  if (foldText(a.unit) != foldText(b.unit)) return 1;
  return math.max(1, (a.quantity / b.quantity - 1e-9).ceil());
}

/// Odpovídá produkt z letáku / účtenky položce seznamu? Porovnává české
/// kmeny slov (bez koncovek), takže „Máslo“ ~ „Máslo Tatra 250 g“ i „MASLO
/// TRAD.“ a „Kuřecí prsní řízky“ ~ „Kuřecí prsní řízek“. Všechna podstatná
/// slova položky musí být v produktu („maso“ ale není „máslo“).
bool productMatches(String itemName, String product) {
  final need = matchStems(itemName);
  if (need.isEmpty) return false;
  final have = matchStems(product);
  return need.every((s) => have.any((h) => stemsMatch(s, h)));
}

const _endings = [
  'ovych',
  'ovymi',
  'ovou',
  'ovy',
  'ova',
  'ove',
  'ych',
  'ymi',
  'ami',
  'emi',
  'ech',
  'ich',
  'ou',
  'em',
  'om',
  'y',
  'a',
  'e',
  'i',
  'o',
  'u',
];

/// Jednoduchý český kmen (stejně jako na serveru): „řízek“ i „řízky“ → „rizk“.
String czStem(String word) {
  var w = word;
  if (w.length <= 3) return w;
  for (final e in _endings) {
    if (w.endsWith(e) && w.length - e.length >= 3) {
      w = w.substring(0, w.length - e.length);
      break;
    }
  }
  if (w.length >= 4 && RegExp(r'e[kc]$').hasMatch(w)) {
    w = w.substring(0, w.length - 2) + w.substring(w.length - 1);
  }
  return w;
}

Set<String> matchStems(String text) => {
  for (final w in RegExp(r'[a-z]+').allMatches(foldText(text)))
    if (w.group(0)!.length >= 3 && !_ignore.contains(w.group(0)))
      czStem(w.group(0)!),
};

bool stemsMatch(String a, String b) {
  if (a == b) return true;
  final short = a.length <= b.length ? a : b;
  final long = identical(short, a) ? b : a;
  if (short.length >= 4 && long.startsWith(short)) return true;
  return _common(a, b) >= 4;
}

/// Klíč produktu pro mezipaměť a odstranění duplicit.
String productKey(String name) => (_stems(name).toList()..sort()).join(' ');

const _ignore = {
  'kg',
  'ml',
  'ks',
  'bal',
  'balení',
  'baleni',
  'cerstvy',
  'cerstva',
  'cerstve',
  'akce',
  'cena',
  'podle',
  'chuti',
  'trad',
  'tradicni',
};

Set<String> _stems(String text) => {
  for (final w in RegExp(r'[a-z]+').allMatches(foldText(text)))
    if (w.group(0)!.length >= 3 && !_ignore.contains(w.group(0)))
      w.group(0)!.substring(0, math.min(5, w.group(0)!.length)),
};

/// Délka společného začátku („stehn“ × „stehe“ = 4 – stehna/stehenní).
int _common(String a, String b) {
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}

double _round(double v) => (v * 100).round() / 100;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

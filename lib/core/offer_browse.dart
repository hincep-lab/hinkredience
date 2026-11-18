import 'best_buy.dart';
import 'kitchen_math.dart' show foldText;
import 'sale_dishes.dart' show groupOf, saleGroups;

// Obrazovka „Akce“: výběr, třídění a filtry akcí z letáků. Jen skutečné
// uložené nabídky – běžné ceny ani prošlé akce se nezobrazují, budoucí
// akce jsou zvlášť („Platí od“).

/// Filtry obrazovky Akce.
class OfferFilter {
  const OfferFilter({
    this.chains = const {},
    this.groups = const {},
    this.minDiscount = 0,
    this.verifiedOnly = false,
  });

  /// Vybrané obchody (prázdné = všechny).
  final Set<String> chains;

  /// Vybrané druhy potravin – id ze [saleGroups], 'other' = ostatní.
  final Set<String> groups;

  /// Minimální sleva v % (0 = bez omezení; akce bez známé původní ceny
  /// pak nevyhoví, protože slevu nelze doložit).
  final int minDiscount;
  final bool verifiedOnly;

  int get count =>
      chains.length +
      groups.length +
      (minDiscount > 0 ? 1 : 0) +
      (verifiedOnly ? 1 : 0);

  OfferFilter copyWith({
    Set<String>? chains,
    Set<String>? groups,
    int? minDiscount,
    bool? verifiedOnly,
  }) => OfferFilter(
    chains: chains ?? this.chains,
    groups: groups ?? this.groups,
    minDiscount: minDiscount ?? this.minDiscount,
    verifiedOnly: verifiedOnly ?? this.verifiedOnly,
  );

  bool matches(PriceOffer o) {
    if (chains.isNotEmpty && !chains.contains(o.chain)) return false;
    if (groups.isNotEmpty && !groups.contains(offerGroup(o))) return false;
    if (minDiscount > 0 && (o.discountPercent ?? -1) < minDiscount) {
      return false;
    }
    if (verifiedOnly && !o.verified) return false;
    return true;
  }
}

/// Druh potraviny akce: id skupiny ze [saleGroups], jinak 'other'.
String offerGroup(PriceOffer o) => groupOf(o.product) ?? 'other';

/// Název druhu potraviny pro filtr.
String groupLabel(String id) => id == 'other'
    ? 'Ostatní'
    : saleGroups
          .firstWhere((g) => g.id == id, orElse: () => saleGroups.first)
          .label;

/// Akce rozdělené na platné dnes a budoucí.
class OfferBrowse {
  const OfferBrowse({required this.current, required this.upcoming});

  final List<PriceOffer> current;
  final List<PriceOffer> upcoming;

  int get verifiedCount =>
      current.where((o) => o.verified).length +
      upcoming.where((o) => o.verified).length;
}

/// Klíč pro odstranění dvojitých záznamů: stejný obchod, prodejna, zboží,
/// balení, cena, podmínka a platnost.
String offerIdentity(PriceOffer o) => [
  o.chain,
  o.storeId ?? '',
  foldText(o.product).replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim(),
  o.packQty ?? '',
  foldText(o.packUnit),
  o.price.toStringAsFixed(2),
  o.kind,
  o.validFrom == null ? '' : _day(o.validFrom!),
  _day(o.validTo),
].join('|');

String _day(DateTime d) => '${d.year}-${d.month}-${d.day}';

/// Akce k zobrazení: bez běžných cen, bez prošlých, bez duplicit; platné
/// dnes zvlášť od budoucích. Ověřené před neověřenými, pak největší sleva,
/// pak nejnižší cena za kg / l.
OfferBrowse browseOffers(
  List<PriceOffer> offers,
  DateTime today, {
  OfferFilter filter = const OfferFilter(),
}) {
  final day = DateTime(today.year, today.month, today.day);
  final seen = <String>{};
  final current = <PriceOffer>[];
  final upcoming = <PriceOffer>[];
  for (final o in offers) {
    if (o.isRegular || o.price <= 0) continue;
    if (o.validTo.isBefore(day)) continue;
    if (!filter.matches(o)) continue;
    if (!seen.add(offerIdentity(o))) continue;
    (o.startsAfter(day) ? upcoming : current).add(o);
  }
  int order(PriceOffer a, PriceOffer b) {
    if (a.verified != b.verified) return a.verified ? -1 : 1;
    final d = (b.discountPercent ?? -1).compareTo(a.discountPercent ?? -1);
    if (d != 0) return d;
    final ua = a.unitPrice?.price ?? a.price;
    final ub = b.unitPrice?.price ?? b.price;
    return ua.compareTo(ub);
  }

  current.sort(order);
  upcoming.sort((a, b) {
    final s = a.validFrom!.compareTo(b.validFrom!);
    return s != 0 ? s : order(a, b);
  });
  return OfferBrowse(current: current, upcoming: upcoming);
}

/// Druhy potravin, které mezi akcemi jsou (pro nabídku filtru).
List<String> presentGroups(List<PriceOffer> offers) {
  final ids = {for (final o in offers) offerGroup(o)};
  return [
    for (final g in saleGroups)
      if (ids.contains(g.id)) g.id,
    if (ids.contains('other')) 'other',
  ];
}

/// Položka nákupu z akce: přesný název zboží a balení, aby se v nákupu
/// porovnávalo stejné zboží (ne jiný výrobek s podobným jménem).
({String name, double? quantity, String unit, String note}) shoppingFromOffer(
  PriceOffer o,
  String chainName,
) => (
  name: o.product,
  quantity: o.packQty,
  unit: o.packUnit,
  note: [
    'akce $chainName',
    if (o.needsLoyalty && o.loyalty.isNotEmpty) o.loyalty,
  ].join(' · '),
);

/// Prodejny v Sušici pro porovnání cen. Každá prodejna zvlášť; akce z letáku
/// řetězce platí pro všechny jeho sušické prodejny. Adresy podle katalogů
/// firmy.cz a zivefirmy.cz (ověřeno 15. 11. 2026).
class Store {
  const Store({
    required this.id,
    required this.chain,
    required this.name,
    required this.address,
  });

  final String id;
  final String chain;
  final String name;
  final String address;

  /// „Albert · Hrádecká 31“
  String get label => '$name · $address';
}

/// Řetězec: název a oficiální weby (jen z nich je akce „ověřená“).
class Chain {
  const Chain(this.id, this.name, this.domains);

  final String id;
  final String name;
  final List<String> domains;

  /// Je adresa na oficiálním webu řetězce?
  bool isOfficial(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return domains.any((d) => host == d || host.endsWith('.$d'));
  }
}

const chains = <Chain>[
  Chain('tesco', 'Tesco', ['itesco.cz', 'tesco.cz']),
  Chain('penny', 'Penny', ['penny.cz', 'files.rewe.co.at']),
  Chain('lidl', 'Lidl', ['lidl.cz']),
  Chain('albert', 'Albert', ['albert.cz']),
  Chain('jip', 'JIP', ['jip-potraviny.cz']),
  Chain('coop', 'COOP', ['zkdsusice.cz', 'coop.cz', 'skupina.coop']),
];

const susiceStores = <Store>[
  Store(
    id: 'tesco-hradecka',
    chain: 'tesco',
    name: 'Tesco',
    address: 'Hrádecká 1310',
  ),
  Store(
    id: 'penny-nadrazni',
    chain: 'penny',
    name: 'Penny',
    address: 'Nádražní 1213',
  ),
  Store(
    id: 'lidl-hradecka',
    chain: 'lidl',
    name: 'Lidl',
    address: 'Hrádecká 1261',
  ),
  Store(
    id: 'albert-hradecka',
    chain: 'albert',
    name: 'Albert',
    address: 'Hrádecká 31',
  ),
  Store(
    id: 'albert-tgm',
    chain: 'albert',
    name: 'Albert',
    address: 'T. G. Masaryka 23',
  ),
  Store(
    id: 'jip-hradecka',
    chain: 'jip',
    name: 'JIP Cash & Carry',
    address: 'Hrádecká 1260',
  ),
  Store(
    id: 'coop-namesti',
    chain: 'coop',
    name: 'COOP',
    address: 'nám. Svobody 135',
  ),
  Store(
    id: 'coop-nadrazni',
    chain: 'coop',
    name: 'COOP TUTY',
    address: 'Nádražní 634',
  ),
  Store(
    id: 'coop-lerchova',
    chain: 'coop',
    name: 'COOP TIP',
    address: 'Lerchova 926',
  ),
  Store(
    id: 'coop-smetanova',
    chain: 'coop',
    name: 'COOP',
    address: 'Smetanova 746',
  ),
];

Store? storeById(String? id) {
  for (final s in susiceStores) {
    if (s.id == id) return s;
  }
  return null;
}

Chain? chainById(String? id) {
  for (final c in chains) {
    if (c.id == id) return c;
  }
  return null;
}

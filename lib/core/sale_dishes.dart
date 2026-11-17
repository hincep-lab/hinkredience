/// „Uvař z akcí“: aplikace projde letáky v Sušici na základní suroviny
/// (maso, smetana, brambory, sýr…) a z toho, co je zrovna v akci, nabídne
/// osvědčená česká jídla – třeba zapečené maso s bramborami a smetanou.
///
/// Bez AI a zdarma: jídla jsou vestavěná, ceny jen ověřené z letáků.
library;

import '../data/recipe.dart';
import 'best_buy.dart' show PriceOffer;
import 'kitchen_math.dart' show foldText;
import 'sale_recipes.dart' show usableOffers;

/// Skupina surovin, kterou hlídáme v letácích.
class SaleGroup {
  const SaleGroup(
    this.id,
    this.label,
    this.keys, {
    this.exclude = const [],
    this.search = const [],
  });

  final String id;

  /// Jak skupinu ukázat („Vepřové maso“).
  final String label;

  /// Kusy slov (bez diakritiky), podle kterých se položka z letáku pozná.
  final List<String> keys;

  /// Když název obsahuje některé z těchto slov, do skupiny nepatří
  /// (např. kuřecí šunka není kuřecí maso).
  final List<String> exclude;

  /// Co se posílá k hledání do letáků.
  final List<String> search;
}

/// Co nikdy není surovina na vaření (krmiva, hotovky, pomazánky…).
const _never = [
  'krmiv',
  'pro psy',
  'pro kocky',
  'granul',
  'kapsick',
  'pomazank',
  'chips',
  'bujon',
  'polevk',
  'hotov',
  'instant',
  'zmrzlin',
  'jogurt',
  'dezert',
  'pudink',
  'cokolad',
  'susenk',
  'oplat',
  'spray',
];

const _meatProducts = [
  'sunk',
  'salam',
  'park',
  'pastik',
  'nugget',
  'klobas',
  'spekac',
  'uzen',
  'slanin',
  'debrec',
  'vurt',
  'kabanos',
  'jatr',
  'jater',
];

const saleGroups = <SaleGroup>[
  SaleGroup(
    'kure',
    'Kuřecí maso',
    ['kurec', 'kure '],
    exclude: _meatProducts,
    search: ['kuřecí'],
  ),
  SaleGroup(
    'veprove',
    'Vepřové maso',
    ['vepr', 'krkovic', 'kotlet', 'bucek', 'panenk'],
    exclude: [..._meatProducts, 'mlet', 'sadlo', 'skvarky', 'kolen'],
    search: ['vepřové'],
  ),
  SaleGroup(
    'hovezi',
    'Hovězí maso',
    ['hovezi'],
    exclude: [..._meatProducts, 'mlet', 'vyvar', 'konzerv'],
    search: ['hovězí'],
  ),
  SaleGroup(
    'mlete',
    'Mleté maso',
    ['mlete', 'mlety', 'mleta'],
    exclude: ['kava', 'mak', 'orech', 'pepr', 'paprika', 'kmin'],
    search: ['mleté maso'],
  ),
  SaleGroup('slanina', 'Slanina', ['slanin'], search: ['slanina']),
  SaleGroup(
    'klobasa',
    'Klobása',
    ['klobas', 'klobask', 'spekac'],
    search: ['klobása'],
  ),
  SaleGroup('sunka', 'Šunka', ['sunk'], search: ['šunka']),
  SaleGroup(
    'smetana',
    'Smetana',
    ['smetan'],
    exclude: ['zmrzlin', 'jogurt', 'kava', 'syr', 'tavene'],
    search: ['smetana'],
  ),
  SaleGroup(
    'syr',
    'Sýr',
    ['syr', 'eidam', 'gouda', 'emental', 'mozzarel', 'parmez', 'gran pad'],
    exclude: ['tvaroh', 'cottage', 'tyncin', 'krem', 'pivo'],
    search: ['sýr', 'eidam'],
  ),
  SaleGroup(
    'maslo',
    'Máslo',
    ['maslo'],
    exclude: ['arasid', 'kakao', 'bylink', 'cesnek'],
    search: ['máslo'],
  ),
  SaleGroup(
    'mleko',
    'Mléko',
    ['mleko'],
    exclude: [
      'kondenz',
      'kokos',
      'mandl',
      'ovesn',
      'sojov',
      'cokolad',
      'kakao',
    ],
    search: ['mléko'],
  ),
  SaleGroup(
    'vejce',
    'Vejce',
    ['vejce'],
    exclude: ['cokolad', 'kinder', 'nudle', 'testovin'],
    search: ['vejce'],
  ),
  SaleGroup(
    'brambory',
    'Brambory',
    ['brambor'],
    exclude: [
      'chips',
      'hranolk',
      'kase',
      'knedl',
      'krokety',
      'lupinky',
      'plack',
      'pure',
    ],
    search: ['brambory'],
  ),
  SaleGroup(
    'testoviny',
    'Těstoviny',
    [
      'testovin',
      'spaget',
      'penne',
      'vreten',
      'kolinka',
      'fusilli',
      'tagliatel',
      'farfalle',
      'mrizk',
    ],
    exclude: ['hotov', 'salat'],
    search: ['těstoviny', 'špagety'],
  ),
  SaleGroup(
    'ryze',
    'Rýže',
    ['ryze'],
    exclude: ['chleb', 'chlebic', 'nudle', 'mleko', 'ocet'],
    search: ['rýže'],
  ),
  SaleGroup(
    'zampiony',
    'Žampiony',
    ['zampion'],
    exclude: ['konzerv', 'omack'],
    search: ['žampiony'],
  ),
  SaleGroup(
    'cibule',
    'Cibule',
    ['cibul'],
    exclude: ['krouzk', 'smazen', 'susen'],
    search: ['cibule'],
  ),
  SaleGroup(
    'mrkev',
    'Mrkev',
    ['mrkev', 'mrkve'],
    exclude: ['stav', 'dzus', 'salat'],
    search: ['mrkev'],
  ),
];

SaleGroup? saleGroupById(String id) {
  for (final g in saleGroups) {
    if (g.id == id) return g;
  }
  return null;
}

/// Co poslat do hledání v letácích (server jich najednou zvládne 20).
List<String> saleSearchTerms() =>
    [for (final g in saleGroups) ...g.search].take(20).toList();

/// Do které skupiny položka z letáku patří (nebo null).
String? groupOf(String product) {
  final name = ' ${foldText(product)} ';
  if (_never.any(name.contains)) return null;
  for (final g in saleGroups) {
    if (!g.keys.any(name.contains)) continue;
    if (g.exclude.any(name.contains)) continue;
    return g.id;
  }
  return null;
}

/// Nejlevnější platné ověřené akce podle skupin (nejlevnější první).
Map<String, List<PriceOffer>> offersByGroup(
  List<PriceOffer> offers,
  DateTime today,
) {
  final out = <String, List<PriceOffer>>{};
  for (final o in usableOffers(offers, today)) {
    final group = groupOf(o.product);
    if (group == null) continue;
    (out[group] ??= []).add(o);
  }
  for (final list in out.values) {
    list.sort((a, b) => a.price.compareTo(b.price));
  }
  return out;
}

// ------------------------------------------------------------------ jídla

class DishIngredient {
  const DishIngredient(this.name, this.quantity, this.unit, [this.group]);

  final String name;
  final double? quantity;
  final String unit;

  /// Skupina surovin z letáků, nebo null u věcí, které bývají doma
  /// (sůl, mouka, koření…).
  final String? group;
}

class Dish {
  const Dish({
    required this.id,
    required this.title,
    required this.category,
    required this.minutes,
    required this.ingredients,
    required this.steps,
    this.description = '',
    this.temperature,
    this.main = const [],
  });

  final String id;
  final String title;
  final String description;
  final String category;
  final int minutes;
  final int? temperature;
  final List<DishIngredient> ingredients;
  final List<String> steps;

  /// Hlavní suroviny – jídlo se nabídne, jen když je v akci aspoň jedna
  /// z nich (aby se kvůli levné cibuli nenabízelo celé menu).
  final List<String> main;

  Set<String> get groups => {
    for (final i in ingredients)
      if (i.group != null) i.group!,
  };

  static const servings = 4;
}

/// Jídlo s tím, co z něj je teď v akci – vždy v jednom obchodě, aby se
/// nemuselo přejíždět (ostatní suroviny se koupí tamtéž za běžnou cenu).
class DishOnSale {
  const DishOnSale(this.dish, this.onSale, {this.chain});

  final Dish dish;

  /// Skupina → nejlevnější ověřená akce.
  final Map<String, PriceOffer> onSale;

  /// Obchod, ve kterém se nakoupí (null = nezjištěno).
  final String? chain;

  int get total => dish.groups.length;

  double get savings {
    var sum = 0.0;
    for (final o in onSale.values) {
      final regular = o.regularPrice;
      if (regular != null && regular > o.price) sum += regular - o.price;
    }
    return sum;
  }

  /// Do kdy platí nejdřív končící akce, na které jídlo stojí.
  DateTime? get validTo {
    DateTime? first;
    for (final o in onSale.values) {
      if (first == null || o.validTo.isBefore(first)) first = o.validTo;
    }
    return first;
  }

  /// Hlavní surovina v akci (podle ní se hlídá pestrost jídelníčku).
  String get mainGroup {
    for (final m in dish.main) {
      if (onSale.containsKey(m)) return m;
    }
    return onSale.keys.isEmpty ? '' : onSale.keys.first;
  }
}

/// Jídla, ke kterým je v některém obchodě v akci hlavní surovina. Akce se
/// berou vždy jen z jednoho obchodu; stejné jídlo může být nabídnuto
/// ve více obchodech. Nejdřív ta s nejvíc surovinami v akci, pak s větší
/// úsporou.
List<DishOnSale> dishesFromSales(
  List<PriceOffer> offers,
  DateTime today, {
  List<Dish> dishes = saleDishes,
}) {
  final byChain = <String, List<PriceOffer>>{};
  for (final o in usableOffers(offers, today)) {
    (byChain[o.chain] ??= []).add(o);
  }
  final out = <DishOnSale>[];
  for (final MapEntry(key: chain, value: chainOffers) in byChain.entries) {
    final groups = offersByGroup(chainOffers, today);
    if (groups.isEmpty) continue;
    for (final dish in dishes) {
      final onSale = <String, PriceOffer>{
        for (final g in dish.groups)
          if (groups[g] case final list? when list.isNotEmpty) g: list.first,
      };
      final mainOnSale = dish.main.isEmpty
          ? onSale.isNotEmpty
          : dish.main.any(onSale.containsKey);
      if (!mainOnSale) continue;
      out.add(DishOnSale(dish, onSale, chain: chain));
    }
  }
  out.sort(compareDishes);
  return out;
}

int compareDishes(DishOnSale a, DishOnSale b) {
  final byCount = b.onSale.length.compareTo(a.onSale.length);
  if (byCount != 0) return byCount;
  final byShare = (b.onSale.length / (b.total == 0 ? 1 : b.total)).compareTo(
    a.onSale.length / (a.total == 0 ? 1 : a.total),
  );
  if (byShare != 0) return byShare;
  final bySavings = b.savings.compareTo(a.savings);
  if (bySavings != 0) return bySavings;
  final byTitle = a.dish.title.compareTo(b.dish.title);
  if (byTitle != 0) return byTitle;
  return (a.chain ?? '').compareTo(b.chain ?? '');
}

/// Kolik balení akce se koupí na jednu surovinu.
class SaleLine {
  const SaleLine(this.ingredient, this.offer, this.packs);

  final DishIngredient ingredient;
  final PriceOffer offer;
  final int packs;

  double get price => offer.price * packs;
}

/// Co se z akcí koupí na recept pro [servings] porcí: celá balení, která se
/// zaplatí u pokladny (počítají se jen zlevněné věci z akcí).
class SaleCost {
  const SaleCost(this.lines);

  final List<SaleLine> lines;

  double get total => lines.fold(0, (sum, l) => sum + l.price);
}

/// Množství v základní jednotce (g, ml, ks), nebo null, když nejde převést.
(double, String)? _base(double? qty, String unit) {
  if (qty == null || qty <= 0) return null;
  final u = foldText(unit.trim()).replaceAll('.', '');
  return switch (u) {
    'g' => (qty, 'g'),
    'kg' => (qty * 1000, 'g'),
    'ml' => (qty, 'ml'),
    'l' => (qty * 1000, 'ml'),
    'ks' || 'kus' || 'kusy' || 'kusu' || '' => (qty, 'ks'),
    _ => null,
  };
}

/// Kolik balení je potřeba: podle množství v receptu a velikosti balení;
/// když se jednotky nedají porovnat, počítá se jedno balení.
int salePacks(double? qty, String unit, PriceOffer offer) {
  final need = _base(qty, unit);
  final pack = _base(offer.packQty, offer.packUnit);
  if (need == null || pack == null || need.$2 != pack.$2) return 1;
  final packs = (need.$1 / pack.$1 - 0.001).ceil();
  return packs < 1 ? 1 : packs;
}

/// Cena zlevněných věcí na recept pro [servings] porcí (jídla jsou na 4).
SaleCost saleCost(DishOnSale item, {double servings = 4}) {
  final factor = servings / Dish.servings;
  return SaleCost([
    for (final i in item.dish.ingredients)
      if (item.onSale[i.group] case final offer?)
        SaleLine(
          i,
          offer,
          salePacks(
            i.quantity == null ? null : i.quantity! * factor,
            i.unit,
            offer,
          ),
        ),
  ]);
}

const _weekdays = ['po', 'út', 'st', 'čt', 'pá', 'so', 'ne'];

/// „končí dnes“, „končí zítra“, nebo „akce do čt 20. 11.“.
String validityLabel(DateTime validTo, DateTime today) {
  final end = DateTime(validTo.year, validTo.month, validTo.day);
  final day = DateTime(today.year, today.month, today.day);
  final left = end.difference(day).inDays;
  if (left <= 0) return 'akce končí dnes';
  if (left == 1) return 'akce končí zítra';
  return 'akce do ${_weekdays[end.weekday - 1]} ${end.day}. ${end.month}.';
}

/// Jídlo jako recept do kuchařky (nové id pro recept, suroviny i kroky).
Recipe dishToRecipe(
  Dish dish, {
  required String Function() newId,
  required DateTime now,
  String? ownerId,
}) => Recipe(
  id: newId(),
  title: dish.title,
  description: dish.description,
  category: dish.category,
  servings: Dish.servings.toDouble(),
  totalMinutes: dish.minutes,
  temperatures: [if (dish.temperature != null) 'Trouba ${dish.temperature} °C'],
  notes: 'Navrženo z akcí v Sušici.',
  createdAt: now,
  updatedAt: now,
  ownerId: ownerId,
  ingredients: [
    for (final i in dish.ingredients)
      Ingredient(id: newId(), name: i.name, quantity: i.quantity, unit: i.unit),
  ],
  steps: [
    for (final step in dish.steps) RecipeStep(id: newId(), instruction: step),
  ],
);

/// Vestavěná osvědčená jídla pro 4 osoby.
const saleDishes = <Dish>[
  Dish(
    id: 'zapecene-veprove',
    title: 'Zapečené vepřové s bramborami a smetanou',
    description: 'Maso, brambory a cibule zapečené pod smetanou a sýrem.',
    category: 'Maso',
    minutes: 90,
    temperature: 180,
    main: ['veprove'],
    ingredients: [
      DishIngredient('Vepřová plec nebo krkovice', 700, 'g', 'veprove'),
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Smetana ke šlehání', 250, 'ml', 'smetana'),
      DishIngredient('Sýr eidam strouhaný', 150, 'g', 'syr'),
      DishIngredient('Cibule', 2, 'ks', 'cibule'),
      DishIngredient('Česnek', 3, 'stroužky'),
      DishIngredient('Sůl, pepř, kmín', null, ''),
      DishIngredient('Olej nebo sádlo', 2, 'lžíce'),
    ],
    steps: [
      'Maso nakrájejte na plátky asi 1 cm, lehce naklepejte, osolte, opepřete a posypte kmínem.',
      'Na oleji maso krátce z obou stran opečte do zlatova a vyndejte.',
      'Brambory oloupejte a nakrájejte na tenká kolečka, cibuli na půlkolečka.',
      'Do vymazaného pekáče dejte polovinu brambor, osolte, navrstvěte maso a cibuli, zakryjte zbytkem brambor a osolte.',
      'Smetanu smíchejte s prolisovaným česnekem a polijte jí brambory.',
      'Zakryté pečte 50 minut na 180 °C.',
      'Odkryjte, posypte sýrem a pečte dalších 15–20 minut, dokud brambory nezměknou a sýr nezezlátne.',
    ],
  ),
  Dish(
    id: 'kure-zampiony-smetana',
    title: 'Kuřecí na žampionech se smetanou a rýží',
    description: 'Rychlé kuřecí v krémové žampionové omáčce.',
    category: 'Drůbež',
    minutes: 35,
    main: ['kure'],
    ingredients: [
      DishIngredient('Kuřecí prsa', 600, 'g', 'kure'),
      DishIngredient('Žampiony', 300, 'g', 'zampiony'),
      DishIngredient('Smetana na vaření nebo ke šlehání', 250, 'ml', 'smetana'),
      DishIngredient('Rýže', 300, 'g', 'ryze'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Máslo', 20, 'g', 'maslo'),
      DishIngredient('Sůl, pepř', null, ''),
      DishIngredient('Petrželka', null, ''),
    ],
    steps: [
      'Rýži propláchněte a uvařte podle návodu na obalu.',
      'Kuřecí maso nakrájejte na nudličky, osolte a opepřete.',
      'Na másle orestujte nadrobno nakrájenou cibuli, přidejte maso a opékejte, až zbělá.',
      'Přidejte nakrájené žampiony a duste 8–10 minut, dokud nepustí vodu a ta se nevyvaří.',
      'Zalijte smetanou, 3 minuty povařte, dochuťte solí a pepřem a posypte petrželkou.',
      'Podávejte s rýží.',
    ],
  ),
  Dish(
    id: 'kure-paprika',
    title: 'Kuře na paprice s těstovinami',
    description: 'Klasika se sladkou paprikou a smetanou.',
    category: 'Drůbež',
    minutes: 45,
    main: ['kure'],
    ingredients: [
      DishIngredient('Kuřecí stehna nebo prsa', 800, 'g', 'kure'),
      DishIngredient('Cibule', 2, 'ks', 'cibule'),
      DishIngredient('Smetana ke šlehání', 200, 'ml', 'smetana'),
      DishIngredient('Těstoviny nebo noky', 400, 'g', 'testoviny'),
      DishIngredient('Sladká mletá paprika', 2, 'lžíce'),
      DishIngredient('Hladká mouka', 1, 'lžíce'),
      DishIngredient('Olej', 2, 'lžíce'),
      DishIngredient('Sůl', null, ''),
    ],
    steps: [
      'Na oleji zpěňte nadrobno nakrájenou cibuli do zlatova.',
      'Přidejte maso nakrájené na kousky, osolte a ze všech stran opečte.',
      'Stáhněte z plotny, vmíchejte papriku (nesmí se připálit) a podlijte asi 300 ml vody.',
      'Pod pokličkou duste do měkka – prsa 15 minut, stehna 35 minut.',
      'Smetanu rozmíchejte s moukou, vlijte do omáčky a 5 minut povařte.',
      'Mezitím uvařte těstoviny a podávejte s omáčkou.',
    ],
  ),
  Dish(
    id: 'kureci-stehna-pecena',
    title: 'Pečená kuřecí stehna s bramborami',
    description: 'Všechno na jednom plechu, skoro bez práce.',
    category: 'Drůbež',
    minutes: 70,
    temperature: 200,
    main: ['kure'],
    ingredients: [
      DishIngredient('Kuřecí stehna', 4, 'ks', 'kure'),
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Cibule', 2, 'ks', 'cibule'),
      DishIngredient('Mrkev', 2, 'ks', 'mrkev'),
      DishIngredient('Česnek', 4, 'stroužky'),
      DishIngredient('Olej', 3, 'lžíce'),
      DishIngredient('Sůl, kmín, sladká paprika', null, ''),
    ],
    steps: [
      'Stehna osolte a potřete olejem smíchaným s paprikou a prolisovaným česnekem.',
      'Brambory nakrájejte na měsíčky, cibuli na čtvrtky a mrkev na špalíčky; osolte, posypte kmínem a promíchejte s trochou oleje.',
      'Zeleninu rozložte na plech, navrch dejte stehna kůží nahoru.',
      'Pečte 50–60 minut na 200 °C, dokud kůže nezezlátne a brambory nezměknou.',
    ],
  ),
  Dish(
    id: 'kureci-rizky-salat',
    title: 'Kuřecí řízky s bramborovým salátem',
    description: 'Smažené řízky a poctivý bramborový salát.',
    category: 'Drůbež',
    minutes: 80,
    main: ['kure', 'brambory'],
    ingredients: [
      DishIngredient('Kuřecí prsa', 600, 'g', 'kure'),
      DishIngredient('Vejce', 4, 'ks', 'vejce'),
      DishIngredient('Brambory varné typu A', 1, 'kg', 'brambory'),
      DishIngredient('Mrkev', 1, 'ks', 'mrkev'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Sterilované okurky', 4, 'ks'),
      DishIngredient('Majonéza', 150, 'g'),
      DishIngredient('Hladká mouka, strouhanka', null, ''),
      DishIngredient('Olej na smažení', null, ''),
      DishIngredient('Sůl, pepř, hořčice', null, ''),
    ],
    steps: [
      'Brambory uvařte ve slupce doměkka, mrkev uvařte zvlášť. Nechte vychladnout.',
      'Dvě vejce uvařte natvrdo.',
      'Brambory oloupejte a nakrájejte na kostičky, přidejte mrkev, okurky, cibuli a vejce nakrájené nadrobno.',
      'Vmíchejte majonézu, lžičku hořčice, trochu nálevu z okurek, osolte a opepřete. Nechte uležet.',
      'Maso nakrájejte na plátky, naklepejte a osolte. Obalte v mouce, rozšlehaných vejcích a strouhance.',
      'Smažte na oleji asi 3–4 minuty z každé strany do zlatova.',
    ],
  ),
  Dish(
    id: 'krkovice-pecena',
    title: 'Pečená krkovice s bramborami a cibulí',
    description: 'Šťavnaté maso pečené na cibulovém loži.',
    category: 'Maso',
    minutes: 120,
    temperature: 170,
    main: ['veprove'],
    ingredients: [
      DishIngredient('Vepřová krkovice', 1, 'kg', 'veprove'),
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Cibule', 3, 'ks', 'cibule'),
      DishIngredient('Česnek', 4, 'stroužky'),
      DishIngredient('Hořčice', 1, 'lžíce'),
      DishIngredient('Sůl, pepř, kmín', null, ''),
    ],
    steps: [
      'Maso potřete solí, pepřem, kmínem, hořčicí a prolisovaným česnekem; nejlépe nechte přes noc v lednici.',
      'Na dno pekáče dejte cibuli nakrájenou na měsíčky, na ni maso, podlijte 200 ml vody.',
      'Zakryté pečte 70 minut na 170 °C, občas podlijte.',
      'Přidejte brambory nakrájené na měsíčky, osolte, odkryjte a pečte dalších 40 minut, maso přelévejte výpekem.',
    ],
  ),
  Dish(
    id: 'veprove-platky-zampiony',
    title: 'Vepřové plátky na žampionech',
    description: 'Plátky v žampionové omáčce s rýží nebo bramborem.',
    category: 'Maso',
    minutes: 45,
    main: ['veprove'],
    ingredients: [
      DishIngredient('Vepřová kýta nebo plec', 600, 'g', 'veprove'),
      DishIngredient('Žampiony', 300, 'g', 'zampiony'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Smetana ke šlehání', 200, 'ml', 'smetana'),
      DishIngredient('Rýže', 300, 'g', 'ryze'),
      DishIngredient('Hladká mouka', 1, 'lžíce'),
      DishIngredient('Olej', 2, 'lžíce'),
      DishIngredient('Sůl, pepř', null, ''),
    ],
    steps: [
      'Plátky naklepejte, osolte, opepřete a jednu stranu obalte v mouce.',
      'Na oleji je zprudka opečte z obou stran a vyndejte.',
      'Na výpeku orestujte cibuli, přidejte nakrájené žampiony a 5 minut duste.',
      'Vraťte maso, podlijte 200 ml vody a pod pokličkou duste 25 minut doměkka.',
      'Přilijte smetanu, povařte a dochuťte. Mezitím uvařte rýži.',
    ],
  ),
  Dish(
    id: 'hovezi-gulas',
    title: 'Hovězí guláš',
    description: 'Poctivý guláš s cibulí a paprikou, k chlebu nebo knedlíku.',
    category: 'Maso',
    minutes: 150,
    main: ['hovezi'],
    ingredients: [
      DishIngredient('Hovězí kližka nebo plec', 1, 'kg', 'hovezi'),
      DishIngredient('Cibule', 800, 'g', 'cibule'),
      DishIngredient('Sladká mletá paprika', 3, 'lžíce'),
      DishIngredient('Rajčatový protlak', 2, 'lžíce'),
      DishIngredient('Česnek', 4, 'stroužky'),
      DishIngredient('Sádlo nebo olej', 3, 'lžíce'),
      DishIngredient('Majoránka, kmín, sůl, pepř', null, ''),
    ],
    steps: [
      'Na sádle pomalu osmahněte nakrájenou cibuli dozlatova (asi 20 minut).',
      'Přidejte maso nakrájené na kostky, osolte a opékejte, až se zatáhne.',
      'Stáhněte z plotny, vmíchejte papriku a protlak, podlijte vodou tak, aby maso bylo skoro ponořené.',
      'Přidejte kmín a pod pokličkou duste 2 hodiny doměkka, průběžně podlévejte.',
      'Nakonec přidejte česnek a majoránku, dochuťte a nechte zhoustnout.',
    ],
  ),
  Dish(
    id: 'bolonske-spagety',
    title: 'Špagety po boloňsku',
    description: 'Masová omáčka s rajčaty a strouhaným sýrem.',
    category: 'Těsta',
    minutes: 60,
    main: ['mlete'],
    ingredients: [
      DishIngredient('Mleté maso', 500, 'g', 'mlete'),
      DishIngredient('Špagety', 400, 'g', 'testoviny'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Mrkev', 1, 'ks', 'mrkev'),
      DishIngredient('Rajčata z plechovky (krájená)', 400, 'g'),
      DishIngredient('Rajčatový protlak', 2, 'lžíce'),
      DishIngredient('Sýr na posypání', 80, 'g', 'syr'),
      DishIngredient('Česnek', 2, 'stroužky'),
      DishIngredient('Olej, sůl, pepř, oregano', null, ''),
    ],
    steps: [
      'Na oleji orestujte nadrobno nakrájenou cibuli a nastrouhanou mrkev.',
      'Přidejte mleté maso a opékejte, až se rozpadne a zbarví.',
      'Vmíchejte protlak, česnek, rajčata a oregano, osolte a opepřete.',
      'Duste na mírném ohni 30 minut, podle potřeby podlijte vodou.',
      'Uvařte špagety a podávejte s omáčkou a sýrem.',
    ],
  ),
  Dish(
    id: 'karbanatky-kase',
    title: 'Karbanátky s bramborovou kaší',
    description: 'Domácí karbanátky a máslová kaše.',
    category: 'Maso',
    minutes: 60,
    main: ['mlete'],
    ingredients: [
      DishIngredient('Mleté maso', 600, 'g', 'mlete'),
      DishIngredient('Vejce', 1, 'ks', 'vejce'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Rohlík', 1, 'ks'),
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Mléko', 200, 'ml', 'mleko'),
      DishIngredient('Máslo', 50, 'g', 'maslo'),
      DishIngredient('Strouhanka, olej', null, ''),
      DishIngredient('Česnek, majoránka, sůl, pepř', null, ''),
    ],
    steps: [
      'Rohlík namočte do trochy mléka a vymačkejte.',
      'Maso smíchejte s vejcem, rohlíkem, najemno nakrájenou cibulí, česnekem, majoránkou, solí a pepřem.',
      'Vytvarujte placičky, obalte ve strouhance a smažte na oleji asi 4 minuty z každé strany.',
      'Brambory uvařte v osolené vodě, sceďte a rozšťouchejte s horkým mlékem a máslem.',
    ],
  ),
  Dish(
    id: 'francouzske-brambory',
    title: 'Francouzské brambory',
    description: 'Zapečené brambory s vejci, uzeninou a smetanou.',
    category: 'Pečení',
    minutes: 70,
    temperature: 180,
    main: ['brambory', 'slanina'],
    ingredients: [
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Slanina nebo šunka', 250, 'g', 'slanina'),
      DishIngredient('Vejce', 6, 'ks', 'vejce'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Zakysaná smetana', 200, 'ml', 'smetana'),
      DishIngredient('Sýr eidam', 100, 'g', 'syr'),
      DishIngredient('Máslo na vymazání', 20, 'g', 'maslo'),
      DishIngredient('Sůl, pepř', null, ''),
    ],
    steps: [
      'Brambory uvařte ve slupce doměkka, 4 vejce natvrdo. Obojí oloupejte a nakrájejte na kolečka.',
      'Slaninu nakrájejte na kostičky a orestujte s cibulí.',
      'Do vymazaného pekáče vrstvěte brambory, slaninu s cibulí a vejce; vrstvy osolte. Nahoře budou brambory.',
      'Smetanu rozšlehejte se 2 vejci, osolte, opepřete a zalijte.',
      'Posypte sýrem a pečte 30 minut na 180 °C dozlatova.',
    ],
  ),
  Dish(
    id: 'bramborovy-gulas',
    title: 'Bramborový guláš s klobásou',
    description: 'Levné a syté jídlo z jednoho hrnce.',
    category: 'Polévky',
    minutes: 50,
    main: ['klobasa', 'brambory'],
    ingredients: [
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Klobása nebo špekáčky', 300, 'g', 'klobasa'),
      DishIngredient('Cibule', 2, 'ks', 'cibule'),
      DishIngredient('Sladká mletá paprika', 2, 'lžíce'),
      DishIngredient('Česnek', 3, 'stroužky'),
      DishIngredient('Olej', 2, 'lžíce'),
      DishIngredient('Majoránka, kmín, sůl', null, ''),
    ],
    steps: [
      'Na oleji orestujte cibuli, přidejte klobásu nakrájenou na kolečka a opečte.',
      'Vmíchejte papriku, hned přidejte brambory na kostky, kmín a sůl.',
      'Zalijte vodou tak, aby byly brambory skoro ponořené, a vařte 25 minut doměkka.',
      'Část brambor rozmačkejte, aby guláš zhoustl, přidejte česnek a majoránku.',
    ],
  ),
  Dish(
    id: 'carbonara',
    title: 'Těstoviny carbonara',
    description: 'Těstoviny se slaninou, vejci a sýrem, hotové za 20 minut.',
    category: 'Těsta',
    minutes: 20,
    main: ['slanina', 'testoviny'],
    ingredients: [
      DishIngredient('Špagety', 400, 'g', 'testoviny'),
      DishIngredient('Slanina', 200, 'g', 'slanina'),
      DishIngredient('Vejce', 4, 'ks', 'vejce'),
      DishIngredient('Tvrdý sýr (parmazán, grana)', 80, 'g', 'syr'),
      DishIngredient('Pepř, sůl', null, ''),
    ],
    steps: [
      'Uvařte špagety v osolené vodě; hrnek vody z vaření si nechte.',
      'Slaninu nakrájejte a nasucho opečte do křupava.',
      'Vejce rozšlehejte s nastrouhaným sýrem a hodně pepře.',
      'Pánev stáhněte z ohně, přidejte scezené špagety, vejce se sýrem a trochu vody z vaření; rychle míchejte, aby vznikl krém a vejce se nesrazila.',
    ],
  ),
  Dish(
    id: 'kureci-rizoto',
    title: 'Kuřecí rizoto se zeleninou',
    description: 'Jednoduché rizoto s kuřecím, žampiony a mrkví.',
    category: 'Drůbež',
    minutes: 40,
    main: ['kure'],
    ingredients: [
      DishIngredient('Kuřecí prsa', 500, 'g', 'kure'),
      DishIngredient('Rýže', 300, 'g', 'ryze'),
      DishIngredient('Žampiony', 200, 'g', 'zampiony'),
      DishIngredient('Mrkev', 2, 'ks', 'mrkev'),
      DishIngredient('Cibule', 1, 'ks', 'cibule'),
      DishIngredient('Sýr na posypání', 80, 'g', 'syr'),
      DishIngredient('Hrášek mražený', 150, 'g'),
      DishIngredient('Olej, sůl, pepř', null, ''),
    ],
    steps: [
      'Na oleji orestujte cibuli a maso nakrájené na kostky.',
      'Přidejte mrkev na kolečka a žampiony, chvíli duste.',
      'Přisypte propláchnutou rýži, krátce osmahněte a zalijte 700 ml vody, osolte.',
      'Pod pokličkou duste 18 minut, posledních 5 minut s hráškem.',
      'Podávejte posypané sýrem.',
    ],
  ),
  Dish(
    id: 'zapecene-testoviny',
    title: 'Zapečené těstoviny se šunkou a sýrem',
    description: 'Šunkofleky po domácku.',
    category: 'Pečení',
    minutes: 50,
    temperature: 190,
    main: ['sunka', 'testoviny'],
    ingredients: [
      DishIngredient('Těstoviny (fleky, kolínka)', 400, 'g', 'testoviny'),
      DishIngredient('Šunka', 250, 'g', 'sunka'),
      DishIngredient('Vejce', 3, 'ks', 'vejce'),
      DishIngredient('Mléko', 200, 'ml', 'mleko'),
      DishIngredient('Smetana', 100, 'ml', 'smetana'),
      DishIngredient('Sýr eidam', 100, 'g', 'syr'),
      DishIngredient('Máslo', 20, 'g', 'maslo'),
      DishIngredient('Sůl, pepř, muškátový oříšek', null, ''),
    ],
    steps: [
      'Těstoviny uvařte o 2 minuty kratší dobu, než uvádí obal, a sceďte.',
      'Smíchejte je s nakrájenou šunkou a dejte do vymazaného pekáče.',
      'Vejce rozšlehejte s mlékem a smetanou, osolte, opepřete a zalijte těstoviny.',
      'Posypte sýrem a pečte 30 minut na 190 °C, dokud vejce neztuhnou.',
    ],
  ),
  Dish(
    id: 'smazeny-syr',
    title: 'Smažený sýr s vařenými brambory',
    description: 'Česká klasika s tatarkou.',
    category: 'Přílohy',
    minutes: 35,
    main: ['syr'],
    ingredients: [
      DishIngredient('Sýr eidam v bloku', 600, 'g', 'syr'),
      DishIngredient('Vejce', 2, 'ks', 'vejce'),
      DishIngredient('Brambory', 1, 'kg', 'brambory'),
      DishIngredient('Máslo', 30, 'g', 'maslo'),
      DishIngredient('Hladká mouka, strouhanka', null, ''),
      DishIngredient('Olej na smažení', null, ''),
      DishIngredient('Tatarská omáčka', null, ''),
    ],
    steps: [
      'Brambory oloupejte a uvařte v osolené vodě, pak je pomastěte máslem.',
      'Sýr nakrájejte na plátky 1,5 cm silné.',
      'Obalte v mouce, rozšlehaných vejcích a strouhance; vejce a strouhanku zopakujte, aby sýr nevytekl.',
      'Smažte v rozpáleném oleji krátce, asi 1 minutu z každé strany, dozlatova.',
    ],
  ),
  Dish(
    id: 'hovezi-na-cibulce',
    title: 'Hovězí na cibulce s rýží',
    description: 'Dušené hovězí v cibulové šťávě.',
    category: 'Maso',
    minutes: 120,
    main: ['hovezi'],
    ingredients: [
      DishIngredient('Hovězí plec', 800, 'g', 'hovezi'),
      DishIngredient('Cibule', 4, 'ks', 'cibule'),
      DishIngredient('Rýže', 300, 'g', 'ryze'),
      DishIngredient('Hladká mouka', 1, 'lžíce'),
      DishIngredient('Olej', 3, 'lžíce'),
      DishIngredient('Sůl, pepř, bobkový list', null, ''),
    ],
    steps: [
      'Maso nakrájejte na plátky, naklepejte, osolte a opepřete.',
      'Zprudka je opečte na oleji a vyndejte.',
      'Na výpeku osmahněte cibuli na proužky dozlatova, vraťte maso, přidejte bobkový list a podlijte vodou.',
      'Duste pod pokličkou 90 minut doměkka, průběžně podlévejte.',
      'Šťávu zahustěte moukou rozmíchanou ve vodě a povařte. Podávejte s rýží.',
    ],
  ),
  Dish(
    id: 'omeleta',
    title: 'Omeleta se šunkou a sýrem',
    description: 'Rychlá večeře za 10 minut.',
    category: 'Přílohy',
    minutes: 10,
    main: ['vejce', 'sunka'],
    ingredients: [
      DishIngredient('Vejce', 8, 'ks', 'vejce'),
      DishIngredient('Šunka', 150, 'g', 'sunka'),
      DishIngredient('Sýr eidam', 100, 'g', 'syr'),
      DishIngredient('Mléko', 4, 'lžíce', 'mleko'),
      DishIngredient('Máslo', 20, 'g', 'maslo'),
      DishIngredient('Sůl, pepř, pažitka', null, ''),
    ],
    steps: [
      'Vejce rozšlehejte s mlékem, solí a pepřem.',
      'Na pánvi rozpusťte máslo, vlijte čtvrtinu vajec a na mírném ohni nechte ztuhnout.',
      'Na půlku dejte šunku a sýr, přeložte a nechte sýr rozpustit. Opakujte pro další porce.',
    ],
  ),
];

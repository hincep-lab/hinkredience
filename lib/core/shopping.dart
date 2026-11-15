import '../data/kitchen_docs.dart';
import 'kitchen_math.dart';

/// Surovina připravená k přidání na nákupní seznam.
class ShoppingDraft {
  const ShoppingDraft({
    required this.name,
    this.quantity,
    this.unit = '',
    this.source = '',
    this.category = '',
    this.note = '',
  });

  final String name;
  final double? quantity;
  final String unit;

  /// Název receptu, ze kterého surovina pochází.
  final String source;

  /// Kategorie; prázdná = odhadne se podle názvu ([guessCategory]).
  final String category;
  final String note;
}

/// Výsledek sloučení: položky, které je potřeba uložit (nové i změněné).
class ShoppingMerge {
  const ShoppingMerge({
    required this.changed,
    required this.added,
    required this.merged,
  });

  final List<ShoppingItem> changed;

  /// Počet nově založených položek.
  final int added;

  /// Počet surovin přičtených k položce, která už na seznamu byla.
  final int merged;
}

/// Návrh sloučení jedné suroviny s položkou, která už na seznamu je.
class MergeProposal {
  const MergeProposal({
    required this.draftIndex,
    required this.draft,
    required this.target,
    required this.resultQuantity,
    required this.resultUnit,
  });

  final int draftIndex;
  final ShoppingDraft draft;
  final ShoppingItem target;
  final double? resultQuantity;
  final String resultUnit;

  /// „Cibule: 200 g + 300 g = 500 g“.
  String describe() {
    final before = formatTotalAmount(target.quantity, target.unit);
    final added = formatTotalAmount(draft.quantity, draft.unit);
    final after = formatTotalAmount(resultQuantity, resultUnit);
    if (before.isEmpty || added.isEmpty) return target.name;
    return '${target.name}: $before + $added = $after';
  }
}

String _nameKey(String name) =>
    foldText(name.trim()).replaceAll(RegExp(r'\s+'), ' ');

String _unitKey(String unit) {
  final folded = foldText(unit.trim());
  return folded.endsWith('.') ? folded.substring(0, folded.length - 1) : folded;
}

// ------------------------------------------------------------ kategorie

const _otherFirst = [
  'olej', 'vyvar', 'bujon', 'demi', 'glace', 'mouk', 'cukr', 'ocet',
  'testovin', 'rizot', 'ryze', 'chleb', 'pecivo', 'rohlik', 'knedl', 'kecup',
  'horcic', 'vino', 'pivo', 'drozd', 'prasek', 'skrob', 'cokolad',
  'kakao', 'konzerv', 'pyre', 'protlak', 'omack', 'drobk', 'strouhank',
];
const _spices = [
  'paprika mleta', 'mleta paprika', 'mlety pepr', 'sul', 'pepr', 'koreni', 'bobkov', 'kmin', 'majorank', 'oregano',
  'tymian', 'rozmar', 'bazalk', 'skoric', 'hrebicek', 'muskat', 'chilli',
  'kari', 'curry', 'zazvor mlet', 'vanilk', 'badyan', 'jalovec', 'kurkum',
  'paprika sladka', 'sladka paprika', 'uzena paprika', 'feferonk susen',
];
const _dairy = [
  'mlek', 'mleko', 'smetan', 'maslo', 'masla', 'syr', 'jogurt', 'tvaroh',
  'vejce', 'vajec', 'vajic', 'zloutk', 'bilk', 'mascarpone', 'ricott',
  'mozzarell', 'parmazan', 'eidam', 'cottage', 'kefir', 'podmasl', 'zakys',
];
const _meat = [
  'maso', 'masa', 'kure', 'kurec', 'kurat', 'krut', 'kachn', 'husa', 'husi',
  'hovez', 'veprov', 'teleci', 'jehne', 'kralik', 'zverin', 'srnci', 'divoc',
  'slanin', 'sunk', 'klobas', 'parek', 'parky', 'salam', 'mlete', 'steh',
  'prsa', 'prsni', 'kridl', 'zebr', 'krkovic', 'panenk', 'svickov', 'rostenc',
  'ryba', 'ryby', 'losos', 'pstruh', 'kapr', 'tunak', 'treska', 'krevet',
  'jatra', 'jater', 'anglick',
];
const _vegetables = [
  'cibul', 'cesnek', 'paprik', 'mrkev', 'mrkv', 'brambor', 'rajc', 'okurk',
  'zeli', 'kapust', 'celer', 'petrzel', 'porek', 'salat', 'spenat',
  'rukol', 'cuket', 'lilek', 'dyne', 'brokolic', 'kvetak', 'hrasek',
  'fazol', 'cocka', 'kukuric', 'houb', 'zampion', 'zazvor', 'chilli paprick',
  'jablk', 'hrusk', 'citron', 'limet', 'pomeranc', 'banan', 'jahod', 'boruvk',
  'malin', 'svestk', 'merunk', 'hrozn', 'avokad', 'pazitk', 'kopr', 'redkvick',
  'repa', 'salotk', 'ovoce', 'zelenin',
];

/// Odhadne kategorii podle názvu suroviny („Kuřecí stehna“ → maso,
/// „Sladká paprika mletá“ → koření, „Kuřecí vývar“ → ostatní).
String guessCategory(String name) {
  final text = ' ${foldText(name).replaceAll(RegExp(r'[^a-z0-9% ]'), ' ')} ';
  bool any(List<String> stems) => stems.any(text.contains);
  // Pořadí je důležité: „kuřecí vývar“ není maso, „mletá paprika“ není zelenina.
  if (any(_otherFirst)) return ShoppingCategory.other;
  if (any(_spices)) return ShoppingCategory.spices;
  if (any(_dairy)) return ShoppingCategory.dairy;
  if (any(_meat)) return ShoppingCategory.meat;
  if (any(_vegetables)) return ShoppingCategory.vegetables;
  return ShoppingCategory.other;
}

/// Kategorie položky k zobrazení (uložená, jinak odhad z názvu).
String categoryOf(ShoppingItem item) => item.category.isEmpty
    ? guessCategory(item.name)
    : ShoppingCategory.normalize(item.category);

// ------------------------------------------------------------- slučování

ShoppingItem? _findTarget(List<ShoppingItem> open, ShoppingDraft draft) {
  final key = _nameKey(draft.name);
  final quantity = (draft.quantity ?? 0) > 0 ? draft.quantity : null;
  final base = quantity == null ? null : toBaseUnit(quantity, draft.unit);
  for (final item in open) {
    if (_nameKey(item.name) != key) continue;
    if (base == null || item.quantity == null) return item;
    final itemBase = toBaseUnit(item.quantity!, item.unit);
    if (_unitKey(itemBase.unit) == _unitKey(base.unit)) return item;
  }
  return null;
}

({double? quantity, String unit}) _sum(ShoppingItem target, ShoppingDraft draft) {
  final quantity = (draft.quantity ?? 0) > 0 ? draft.quantity : null;
  if (quantity == null) return (quantity: target.quantity, unit: target.unit);
  final base = toBaseUnit(quantity, draft.unit);
  if (target.quantity == null) return (quantity: base.quantity, unit: base.unit);
  final targetBase = toBaseUnit(target.quantity!, target.unit);
  return (quantity: targetBase.quantity + base.quantity, unit: targetBase.unit);
}

/// Suroviny, které by se sečetly s položkou, co už na seznamu je.
/// Uživatel pak u každé rozhodne, jestli sloučit, nebo přidat zvlášť.
List<MergeProposal> planShoppingMerge({
  required List<ShoppingItem> existing,
  required List<ShoppingDraft> additions,
}) {
  final open = [for (final i in existing) if (!i.checked) i];
  return [
    for (var index = 0; index < additions.length; index++)
      if (_findTarget(open, additions[index]) case final target?)
        () {
          final sum = _sum(target, additions[index]);
          return MergeProposal(
            draftIndex: index,
            draft: additions[index],
            target: target,
            resultQuantity: sum.quantity,
            resultUnit: sum.unit,
          );
        }(),
  ];
}

/// Přidá suroviny na seznam [listId] a sloučí stejné: „Mouka 500 g“ +
/// „Mouka 1 kg“ dá „Mouka 1,5 kg“.
///
/// Slučuje se jen s položkami, které ještě nejsou odškrtnuté – co už je
/// v košíku, se nemění. Suroviny se stejným názvem, ale nesčitatelnou
/// jednotkou (2 ks cibule + 100 g cibule) zůstávají jako dvě položky.
/// Suroviny s indexem v [keepSeparate] se přidají zvlášť i tak.
ShoppingMerge mergeShopping({
  required List<ShoppingItem> existing,
  required Iterable<ShoppingDraft> additions,
  required String Function() newId,
  required DateTime now,
  String? listId,
  Set<int> keepSeparate = const {},
}) {
  // Pracovní kopie nezaškrtnutých položek podle id.
  final items = {
    for (final item in existing)
      if (!item.checked) item.id: item,
  };
  final order = [
    for (final item in existing)
      if (!item.checked) item.id,
  ];
  final touched = <String>{};
  var added = 0;
  var merged = 0;

  List<String> withSource(List<String> sources, String source) =>
      source.isEmpty || sources.contains(source)
      ? sources
      : [...sources, source];

  var index = -1;
  for (final draft in additions) {
    index++;
    final name = draft.name.trim();
    if (name.isEmpty) continue;
    final target = keepSeparate.contains(index)
        ? null
        : _findTarget([for (final id in order) items[id]!], draft);

    if (target == null) {
      final quantity = (draft.quantity ?? 0) > 0 ? draft.quantity : null;
      final base = quantity == null ? null : toBaseUnit(quantity, draft.unit);
      final item = ShoppingItem(
        id: newId(),
        listId: listId,
        name: name,
        quantity: base?.quantity,
        unit: base?.unit ?? draft.unit.trim(),
        category: draft.category.isEmpty
            ? guessCategory(name)
            : ShoppingCategory.normalize(draft.category),
        note: draft.note,
        sources: withSource(const [], draft.source),
        createdAt: now,
        updatedAt: now,
      );
      items[item.id] = item;
      order.add(item.id);
      touched.add(item.id);
      added++;
      continue;
    }

    final sum = _sum(target, draft);
    items[target.id] = target.copyWith(
      quantity: sum.quantity,
      unit: sum.unit,
      sources: withSource(target.sources, draft.source),
      updatedAt: now,
    );
    touched.add(target.id);
    merged++;
  }

  return ShoppingMerge(
    changed: [
      for (final id in order)
        if (touched.contains(id)) items[id]!,
    ],
    added: added,
    merged: merged,
  );
}

/// Rozebere ručně napsanou položku: „2 kg brambor“, „mléko 1 l“, „3 cibule“,
/// „chleba“. Množství a jednotka se rozpoznají jen na začátku nebo na konci.
ShoppingDraft parseShoppingText(String input) {
  final text = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return const ShoppingDraft(name: '');
  const number = r'(\d+(?:[.,]\d+)?)';

  bool knownUnit(String word) {
    final kind = unitKind(word);
    return word.isNotEmpty &&
        (kind == UnitKind.mass ||
            kind == UnitKind.volume ||
            kind == UnitKind.measure ||
            (kind == UnitKind.count && _unitKey(word) == 'ks'));
  }

  double parse(String value) => double.parse(value.replaceAll(',', '.'));

  // „2 kg brambor“, „2kg brambor“, „3 cibule“
  final leading = RegExp('^$number\\s*(\\S+)?\\s*(.*)\$').firstMatch(text);
  if (leading != null) {
    final quantity = parse(leading.group(1)!);
    final word = leading.group(2) ?? '';
    final rest = leading.group(3) ?? '';
    if (knownUnit(word) && rest.isNotEmpty) {
      return ShoppingDraft(name: rest, quantity: quantity, unit: word);
    }
    final name = [word, rest].where((part) => part.isNotEmpty).join(' ');
    if (name.isNotEmpty) {
      return ShoppingDraft(name: name, quantity: quantity, unit: 'ks');
    }
  }

  // „mléko 1 l“, „mouka 500g“, „vejce 10“
  final trailing = RegExp('^(.*\\S)\\s+$number\\s*(\\S+)?\$').firstMatch(text);
  if (trailing != null) {
    final word = trailing.group(3) ?? '';
    if (word.isEmpty || knownUnit(word)) {
      return ShoppingDraft(
        name: trailing.group(1)!,
        quantity: parse(trailing.group(2)!),
        unit: word.isEmpty ? 'ks' : word,
      );
    }
  }
  return ShoppingDraft(name: text);
}

import '../data/kitchen_docs.dart';
import 'kitchen_math.dart';

/// Surovina připravená k přidání na nákupní seznam.
class ShoppingDraft {
  const ShoppingDraft({
    required this.name,
    this.quantity,
    this.unit = '',
    this.source = '',
  });

  final String name;
  final double? quantity;
  final String unit;

  /// Název receptu, ze kterého surovina pochází.
  final String source;
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

String _nameKey(String name) =>
    foldText(name.trim()).replaceAll(RegExp(r'\s+'), ' ');

String _unitKey(String unit) {
  final folded = foldText(unit.trim());
  return folded.endsWith('.') ? folded.substring(0, folded.length - 1) : folded;
}

/// Přidá suroviny na seznam a sloučí stejné: „Mouka 500 g“ + „Mouka 1 kg“
/// dá „Mouka 1,5 kg“.
///
/// Slučuje se jen s položkami, které ještě nejsou odškrtnuté – co už je
/// v košíku, se nemění. Suroviny se stejným názvem, ale nesčitatelnou
/// jednotkou (2 ks cibule + 100 g cibule) zůstávají jako dvě položky.
ShoppingMerge mergeShopping({
  required List<ShoppingItem> existing,
  required Iterable<ShoppingDraft> additions,
  required String Function() newId,
  required DateTime now,
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

  for (final draft in additions) {
    final name = draft.name.trim();
    if (name.isEmpty) continue;
    final key = _nameKey(name);
    final quantity = (draft.quantity ?? 0) > 0 ? draft.quantity : null;
    final base = quantity == null
        ? null
        : toBaseUnit(quantity, draft.unit);

    ShoppingItem? target;
    for (final id in order) {
      final item = items[id]!;
      if (_nameKey(item.name) != key) continue;
      if (base == null || item.quantity == null) {
        // Položka bez množství se přidá k první stejnojmenné.
        target = item;
        break;
      }
      final itemBase = toBaseUnit(item.quantity!, item.unit);
      if (_unitKey(itemBase.unit) == _unitKey(base.unit)) {
        target = item;
        break;
      }
    }

    if (target == null) {
      final item = ShoppingItem(
        id: newId(),
        name: name,
        quantity: base?.quantity,
        unit: base?.unit ?? '',
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

    double? total = target.quantity;
    var unit = target.unit;
    if (base != null) {
      if (target.quantity == null) {
        total = base.quantity;
        unit = base.unit;
      } else {
        final targetBase = toBaseUnit(target.quantity!, target.unit);
        total = targetBase.quantity + base.quantity;
        unit = targetBase.unit;
      }
    }
    items[target.id] = target.copyWith(
      quantity: total,
      unit: unit,
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

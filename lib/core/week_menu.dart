/// Týdenní jídelník z akcí: obědy a večeře jdou za sebou a jedno vaření
/// pokryje několik jídel (výchozí 6 porcí na 3 jídla: oběd, večeře a další
/// den oběd). Každé vaření má svůj obchod podle akce, na které stojí.
library;

import '../data/kitchen_docs.dart' show MealType;
import 'sale_dishes.dart';

/// Jedno jídlo v týdnu (den + oběd/večeře).
class MenuSlot {
  const MenuSlot(this.day, this.mealType);

  final DateTime day;
  final String mealType;

  @override
  bool operator ==(Object other) =>
      other is MenuSlot && other.day == day && other.mealType == mealType;

  @override
  int get hashCode => Object.hash(day, mealType);
}

/// Jedno vaření: jídlo, obchod a jídla, která pokryje.
class MenuCook {
  const MenuCook(this.item, this.slots);

  final DishOnSale item;
  final List<MenuSlot> slots;
}

class WeekMenu {
  const WeekMenu({
    required this.cooks,
    required this.portions,
    required this.mealsPerCook,
    this.missing = const [],
  });

  final List<MenuCook> cooks;

  /// Kolik porcí se uvaří najednou.
  final int portions;

  /// Kolik jídel jedno vaření pokryje.
  final int mealsPerCook;

  /// Jídla, na která nezbyl žádný návrh.
  final List<MenuSlot> missing;

  /// Obchody, kam se na týden jede, s počtem vaření.
  Map<String, int> get chains {
    final out = <String, int>{};
    for (final c in cooks) {
      final chain = c.item.chain ?? '';
      out[chain] = (out[chain] ?? 0) + 1;
    }
    return out;
  }

  double get savings => cooks.fold(0, (sum, c) => sum + c.item.savings);
}

/// Obědy a večeře od [start] na [days] dní (od [firstMeal] prvního dne).
List<MenuSlot> menuSlots(
  DateTime start, {
  int days = 7,
  String firstMeal = MealType.lunch,
}) {
  final first = DateTime(start.year, start.month, start.day);
  return [
    for (var d = 0; d < days; d++)
      for (final meal in const [MealType.lunch, MealType.dinner])
        if (d > 0 || meal == MealType.dinner || firstMeal == MealType.lunch)
          MenuSlot(DateTime(first.year, first.month, first.day + d), meal),
  ];
}

String _key(DishOnSale d) => d.dish.title.toLowerCase();

/// Vybere další návrh, který v jídelníčku ještě není; pokud jde, s jinou
/// hlavní surovinou než sousední vaření (aby nebylo třikrát za sebou kuře).
DishOnSale? _pick(
  List<DishOnSale> candidates,
  Set<String> used, {
  String? avoidMain,
  String? avoidMain2,
}) {
  DishOnSale? fallback;
  for (final c in candidates) {
    if (used.contains(_key(c))) continue;
    if (c.mainGroup == avoidMain || c.mainGroup == avoidMain2) {
      fallback ??= c;
      continue;
    }
    return c;
  }
  return fallback;
}

/// Sestaví jídelníček z návrhů seřazených od nejlepšího
/// (viz [dishesFromSales]).
WeekMenu buildWeekMenu(
  List<DishOnSale> candidates,
  DateTime start, {
  int days = 7,
  String firstMeal = MealType.lunch,
  int portions = 6,
  int mealsPerCook = 3,
}) {
  final per = mealsPerCook < 1 ? 1 : mealsPerCook;
  final slots = menuSlots(start, days: days, firstMeal: firstMeal);
  final used = <String>{};
  final cooks = <MenuCook>[];
  final missing = <MenuSlot>[];
  for (var i = 0; i < slots.length; i += per) {
    final block = slots.sublist(i, (i + per).clamp(0, slots.length));
    final pick = _pick(
      candidates,
      used,
      avoidMain: cooks.isEmpty ? null : cooks.last.item.mainGroup,
    );
    if (pick == null) {
      missing.addAll(block);
      continue;
    }
    used.add(_key(pick));
    cooks.add(MenuCook(pick, block));
  }
  return WeekMenu(
    cooks: cooks,
    portions: portions,
    mealsPerCook: per,
    missing: missing,
  );
}

/// Vymění jídlo v [index]-tém vaření za další návrh, který v jídelníčku
/// není (po posledním začne znovu od nejlepšího). Bez dalšího návrhu
/// vrátí jídelníček beze změny.
WeekMenu swapCook(WeekMenu menu, int index, List<DishOnSale> candidates) {
  if (index < 0 || index >= menu.cooks.length) return menu;
  final current = menu.cooks[index];
  final used = {
    for (final (i, c) in menu.cooks.indexed)
      if (i != index) _key(c.item),
  };
  // Začít hledat za současným jídlem, aby každé klepnutí ukázalo jiné.
  final at = candidates.indexWhere(
    (c) => _key(c) == _key(current.item) && c.chain == current.item.chain,
  );
  final rotated = at < 0
      ? candidates
      : [...candidates.sublist(at + 1), ...candidates.sublist(0, at + 1)];
  final pick = _pick(
    [
      for (final c in rotated)
        if (_key(c) != _key(current.item)) c,
    ],
    used,
    avoidMain: index > 0 ? menu.cooks[index - 1].item.mainGroup : null,
    avoidMain2: index + 1 < menu.cooks.length
        ? menu.cooks[index + 1].item.mainGroup
        : null,
  );
  if (pick == null) return menu;
  return WeekMenu(
    cooks: [
      for (final (i, c) in menu.cooks.indexed)
        i == index ? MenuCook(pick, c.slots) : c,
    ],
    portions: menu.portions,
    mealsPerCook: menu.mealsPerCook,
    missing: menu.missing,
  );
}

const _dayNames = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];

/// „Po“, „Út“…
String dayShort(DateTime day) => _dayNames[day.weekday - 1];

/// „Po oběd“, „Po večeře“…
String slotLabel(MenuSlot slot) =>
    '${_dayNames[slot.day.weekday - 1]} ${MealType.label(slot.mealType).toLowerCase()}';

/// „Po oběd – Út oběd“ (první a poslední jídlo vaření).
String cookLabel(MenuCook cook) => cook.slots.length == 1
    ? slotLabel(cook.slots.first)
    : '${slotLabel(cook.slots.first)} – ${slotLabel(cook.slots.last)}';

/// Recepty, které z ověřených akcí vymyslí Gemini (serverová funkce
/// `sale-ideas`). Suroviny z akcí ukazují jen na skutečně uložené akce –
/// server odkazy na neexistující akce zahazuje.
library;

import 'best_buy.dart' show PriceOffer;
import 'sale_dishes.dart';

class SaleIdeas {
  const SaleIdeas({
    this.ideas = const [],
    this.error = '',
    this.rejected = const [],
    this.model = '',
  });

  /// Návrhy jako jídla se surovinami v akci (stejně jako vestavěná jídla).
  final List<DishOnSale> ideas;
  final String error;
  final List<String> rejected;
  final String model;

  factory SaleIdeas.fromJson(Map<String, dynamic> json) {
    final ideas = <DishOnSale>[];
    final list = json['ideas'];
    if (list is List) {
      for (final (index, raw) in list.indexed) {
        if (raw is Map<String, dynamic>) {
          final idea = ideaToDish(raw, index);
          if (idea != null) ideas.add(idea);
        }
      }
    }
    return SaleIdeas(
      ideas: ideas,
      error: json['error'] as String? ?? '',
      rejected: [
        for (final r in json['rejected'] as List? ?? const [])
          if (r is String) r,
      ],
      model: json['model'] as String? ?? '',
    );
  }
}

/// Jeden návrh ze serveru → jídlo; každá surovina z akce dostane vlastní
/// „skupinu“, aby se k ní ukázala její akce.
DishOnSale? ideaToDish(Map<String, dynamic> j, int index) {
  final title = (j['title'] as String? ?? '').trim();
  final steps = [
    for (final s in j['steps'] as List? ?? const [])
      if (s is String && s.trim().isNotEmpty) s.trim(),
  ];
  if (title.isEmpty || steps.isEmpty) return null;
  final ingredients = <DishIngredient>[];
  final onSale = <String, PriceOffer>{};
  for (final (i, raw) in (j['ingredients'] as List? ?? const []).indexed) {
    if (raw is! Map<String, dynamic>) continue;
    final name = (raw['name'] as String? ?? '').trim();
    if (name.isEmpty) continue;
    String? group;
    final offer = raw['offer'];
    if (offer is Map<String, dynamic>) {
      group = 'akce-$i';
      onSale[group] = PriceOffer.fromJson({...offer, 'verified': true});
    }
    ingredients.add(
      DishIngredient(
        name,
        (raw['quantity'] as num?)?.toDouble(),
        raw['unit'] as String? ?? '',
        group,
      ),
    );
  }
  if (onSale.isEmpty) return null;
  // Nákup v jednom obchodě: platí akce obchodu, který jich má v receptu
  // nejvíc; akce z jiných obchodů se u suroviny nezobrazí.
  final counts = <String, int>{};
  for (final o in onSale.values) {
    counts[o.chain] = (counts[o.chain] ?? 0) + 1;
  }
  final chain =
      (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .first
          .key;
  for (final (i, ingredient) in ingredients.indexed) {
    final group = ingredient.group;
    if (group != null && onSale[group]!.chain != chain) {
      onSale.remove(group);
      ingredients[i] = DishIngredient(
        ingredient.name,
        ingredient.quantity,
        ingredient.unit,
      );
    }
  }
  final temp = (j['temperature_c'] as num?)?.toInt();
  final dish = Dish(
    id: 'napad-$index-${title.hashCode}',
    title: title,
    description: j['description'] as String? ?? '',
    category: j['category'] as String? ?? '',
    minutes: (j['minutes'] as num?)?.toInt() ?? 0,
    temperature: temp,
    ingredients: ingredients,
    steps: steps,
  );
  return DishOnSale(dish, onSale, chain: chain);
}

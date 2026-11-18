/// „Recepty z akcí“: které recepty z kuchařky vyjdou nejlépe z aktuálních
/// ověřených akcí v sušických obchodech.
library;

import '../data/recipe.dart';
import 'best_buy.dart' show PriceOffer, productMatches;
import 'kitchen_math.dart' show foldText;
import 'pantry.dart' show pantryStaples, pantryHas;

/// Surovina receptu, která je teď v akci.
class SaleHit {
  const SaleHit(this.ingredient, this.offer);

  final Ingredient ingredient;

  /// Nejlevnější platná ověřená akce na tuto surovinu.
  final PriceOffer offer;

  /// Úspora proti přeškrtnuté ceně (0, když ji leták neuvádí).
  double get savings {
    final regular = offer.regularPrice;
    return regular != null && regular > offer.price ? regular - offer.price : 0;
  }
}

class SaleRecipe {
  const SaleRecipe(this.recipe, this.hits, this.ingredientCount);

  final Recipe recipe;
  final List<SaleHit> hits;

  /// Kolik surovin recept má (bez základů jako sůl a pepř).
  final int ingredientCount;

  double get savings => hits.fold(0, (sum, h) => sum + h.savings);

  /// Obchody, kde jsou akce na suroviny tohoto receptu.
  Set<String> get chains => {for (final h in hits) h.offer.chain};
}

bool _isStaple(String name) => pantryStaples.any((s) => pantryHas(s, name));

/// Platné ověřené akce (neověřené se nepočítají – mohou být chybně přečtené).
List<PriceOffer> usableOffers(List<PriceOffer> offers, DateTime today) {
  final day = DateTime(today.year, today.month, today.day);
  return [
    for (final o in offers)
      if (o.verified && !o.isRegular && o.activeOn(day)) o,
  ];
}

/// Recepty, ve kterých je aspoň jedna surovina v akci; nejdřív ty s víc
/// surovinami v akci, pak s větší úsporou.
List<SaleRecipe> recipesFromSales(
  List<Recipe> recipes,
  List<PriceOffer> offers,
  DateTime today,
) {
  final usable = usableOffers(offers, today);
  if (usable.isEmpty) return const [];
  final out = <SaleRecipe>[];
  for (final recipe in recipes) {
    final hits = <SaleHit>[];
    var count = 0;
    for (final ingredient in recipe.ingredients) {
      if (ingredient.name.trim().isEmpty || _isStaple(ingredient.name)) {
        continue;
      }
      count++;
      PriceOffer? best;
      for (final o in usable) {
        if (!productMatches(ingredient.name, o.product)) continue;
        if (best == null || o.price < best.price) best = o;
      }
      if (best != null) hits.add(SaleHit(ingredient, best));
    }
    if (hits.isNotEmpty) out.add(SaleRecipe(recipe, hits, count));
  }
  out.sort((a, b) {
    final byHits = b.hits.length.compareTo(a.hits.length);
    if (byHits != 0) return byHits;
    final bySavings = b.savings.compareTo(a.savings);
    if (bySavings != 0) return bySavings;
    return a.recipe.title.compareTo(b.recipe.title);
  });
  return out;
}

/// Suroviny, na které se vyplatí hledat akce: nejčastější v receptech
/// (bez základů), nejvýš [limit] (server jich najednou prohledá 20).
List<String> ingredientsWorthSearching(List<Recipe> recipes, {int limit = 20}) {
  final counts = <String, int>{};
  final names = <String, String>{};
  for (final recipe in recipes) {
    final seen = <String>{};
    for (final ingredient in recipe.ingredients) {
      final name = ingredient.name.trim();
      if (name.isEmpty || _isStaple(name)) continue;
      final key = foldText(name);
      if (!seen.add(key)) continue;
      counts[key] = (counts[key] ?? 0) + 1;
      names.putIfAbsent(key, () => name);
    }
  }
  final keys = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return [for (final k in keys.take(limit)) names[k]!];
}

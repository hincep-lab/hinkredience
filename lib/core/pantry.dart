/// „Co mám doma“: které recepty jdou uvařit ze surovin, které jsou doma,
/// a co k nim chybí.
library;

import '../data/recipe.dart';
import 'best_buy.dart' show productMatches;

/// Základy, které má doma skoro každý (lze vypnout).
const pantryStaples = ['sůl', 'pepř', 'voda', 'olej'];

class PantryMatch {
  const PantryMatch({
    required this.recipe,
    required this.have,
    required this.missing,
  });

  final Recipe recipe;

  /// Suroviny receptu, které doma jsou.
  final List<Ingredient> have;

  /// Suroviny, které chybí.
  final List<Ingredient> missing;

  int get total => have.length + missing.length;
  double get coverage => total == 0 ? 0 : have.length / total;
}

/// Je surovina receptu mezi tím, co je doma? Stačí, když všechna slova
/// zadané suroviny jsou v názvu („mouka“ ~ „Hladká mouka“, „kuře“ ~
/// „Kuřecí prsa“), nebo naopak.
bool pantryHas(String atHome, String ingredient) {
  for (final name in _aliases(atHome)) {
    if (productMatches(name, ingredient) || productMatches(ingredient, name)) {
      return true;
    }
  }
  return false;
}

/// Zvíře → přídavné jméno v názvech surovin („kuře“ → „kuřecí stehna“).
const _animalAdjectives = {
  'kure': 'kuřecí',
  'krůta': 'krůtí',
  'kruta': 'krůtí',
  'kachna': 'kachní',
  'husa': 'husí',
  'ryba': 'rybí',
  'jehně': 'jehněčí',
  'jehne': 'jehněčí',
  'tele': 'telecí',
};

Iterable<String> _aliases(String name) sync* {
  yield name;
  final key = name.trim().toLowerCase();
  final alias =
      _animalAdjectives[key] ??
      _animalAdjectives[key.replaceAll('ř', 'r').replaceAll('ě', 'e')];
  if (alias != null) yield alias;
}

/// Recepty seřazené od nejlépe uvařitelných: nejdřív ty, kterým chybí
/// nejméně surovin, pak podle podílu toho, co doma je. Recepty bez jediné
/// shody se vynechají. Základy ([pantryStaples]) se při [withStaples]
/// počítají jako doma.
List<PantryMatch> matchPantry(
  List<Recipe> recipes,
  List<String> atHome, {
  bool withStaples = true,
}) {
  final home = [
    for (final h in atHome)
      if (h.trim().isNotEmpty) h.trim(),
  ];
  if (home.isEmpty) return const [];
  final out = <PantryMatch>[];
  for (final recipe in recipes) {
    final have = <Ingredient>[];
    final missing = <Ingredient>[];
    var fromHome = 0;
    for (final ingredient in recipe.ingredients) {
      if (ingredient.name.trim().isEmpty) continue;
      if (home.any((h) => pantryHas(h, ingredient.name))) {
        have.add(ingredient);
        fromHome++;
      } else if (withStaples &&
          pantryStaples.any((s) => pantryHas(s, ingredient.name))) {
        have.add(ingredient);
      } else {
        missing.add(ingredient);
      }
    }
    if (fromHome == 0) continue;
    out.add(PantryMatch(recipe: recipe, have: have, missing: missing));
  }
  out.sort((a, b) {
    final byMissing = a.missing.length.compareTo(b.missing.length);
    if (byMissing != 0) return byMissing;
    final byCoverage = b.coverage.compareTo(a.coverage);
    if (byCoverage != 0) return byCoverage;
    return a.recipe.title.compareTo(b.recipe.title);
  });
  return out;
}

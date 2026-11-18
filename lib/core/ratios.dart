import '../data/recipe.dart';
import 'kitchen_math.dart';

/// Na kolik porcí vychází recept, když skutečné množství jedné suroviny
/// je [actual] [actualUnit] (např. maso se zváží až v kuchyni: 730 g místo
/// 800 g). Ostatní suroviny se pak přepočítají ve stejném poměru.
/// Vrací null, když nejde převést (chybí množství, jiná jednotka).
double? servingsForActual({
  required Ingredient ingredient,
  required double recipeServings,
  required double actual,
  String? actualUnit,
}) {
  final planned = ingredient.quantity;
  if (planned == null || planned <= 0 || actual <= 0 || recipeServings <= 0) {
    return null;
  }
  final unit = (actualUnit == null || actualUnit.trim().isEmpty)
      ? ingredient.unit
      : actualUnit.trim();
  final from = toBaseUnit(planned, ingredient.unit);
  final to = toBaseUnit(actual, unit);
  if (foldText(from.unit) != foldText(to.unit)) return null;
  final servings = recipeServings * to.quantity / from.quantity;
  return (servings * 100).round() / 100;
}

/// Poměr suroviny k hlavní surovině: kolik jí patří na 100 g / 100 ml / 1 ks
/// hlavní suroviny. Null, když nejde spočítat.
({double quantity, String unit})? ratioPer(Ingredient item, Ingredient base) {
  if (item.quantity == null || base.quantity == null || base.quantity! <= 0) {
    return null;
  }
  final b = toBaseUnit(base.quantity!, base.unit);
  final perUnit = b.unit == 'g' || b.unit == 'ml' ? 100.0 : 1.0;
  return (quantity: item.quantity! * perUnit / b.quantity, unit: item.unit);
}

/// „na 100 g“, „na 100 ml“, „na 1 ks“ podle jednotky hlavní suroviny.
String ratioBaseLabel(Ingredient base) {
  final b = toBaseUnit(base.quantity ?? 1, base.unit);
  if (b.unit == 'g') return 'na 100 g';
  if (b.unit == 'ml') return 'na 100 ml';
  return 'na 1 ${base.unit.isEmpty ? 'ks' : base.unit}';
}

/// Surovina, podle které se v receptu nejspíš váží (nejtěžší v g/ml).
Ingredient? mainIngredient(Recipe recipe) {
  Ingredient? best;
  var bestQuantity = 0.0;
  for (final item in recipe.ingredients) {
    if (item.quantity == null) continue;
    final base = toBaseUnit(item.quantity!, item.unit);
    if (base.unit != 'g' && base.unit != 'ml') continue;
    if (base.quantity > bestQuantity) {
      best = item;
      bestQuantity = base.quantity;
    }
  }
  return best;
}

/// Suroviny zmíněné v textu kroku (podle kmene slova, aby to fungovalo
/// i se skloňováním: „cibuli“ ↔ „Cibule“, „smetanou“ ↔ „Smetana 31 %“).
List<Ingredient> ingredientsInStep(RecipeStep step, List<Ingredient> all) {
  final text = ' ${foldText(step.instruction)} ';
  final words = RegExp(r'[a-z]+').allMatches(text).map((m) => m.group(0)!);
  final textStems = {
    for (final w in words)
      if (w.length >= 4) _stem(w),
  };
  return [
    for (final item in all)
      if (_stems(item.name).any(textStems.contains)) item,
  ];
}

const _skip = {
  'hladka',
  'hruba',
  'polohruba',
  'cerstvy',
  'cerstva',
  'mleta',
  'mlety',
  'sladka',
  'cervena',
  'zelena',
  'bila',
  'cerny',
  'novy',
  'nove',
  'kurecich',
  'kureci',
  'hovezi',
  'veprove',
  'vepr',
  'stehna',
  'kosti',
  'podle',
  'chuti',
  'olej',
  'oleje',
};

Set<String> _stems(String name) {
  final words = RegExp(r'[a-z]+')
      .allMatches(foldText(name))
      .map((m) => m.group(0)!)
      .where((w) => w.length >= 4 && !_skip.contains(w))
      .toList();
  // Když jsou všechna slova „obecná“ (např. „Kuřecí stehna“), vezmeme je.
  final source = words.isNotEmpty
      ? words
      : RegExp(r'[a-z]+')
            .allMatches(foldText(name))
            .map((m) => m.group(0)!)
            .where((w) => w.length >= 4);
  return {for (final w in source) _stem(w)};
}

/// Kmen slova: prvních 5 písmen (u kratších 4) – stačí na české koncovky.
String _stem(String word) => word.substring(0, word.length >= 6 ? 5 : 4);

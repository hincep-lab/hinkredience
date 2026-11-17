/// Skupiny receptů na domovské obrazovce a rychlé filtry (příprava, čas,
/// příležitost). Vše se odvozuje ze skutečných údajů receptu: kategorie,
/// názvu, surovin, postupu, teplot, vybavení, časů a štítků. Co recept
/// neuvádí, filtr nepředstírá (recept bez času se do časových filtrů
/// nezapočítá, příležitost se bere jen ze štítků).
library;

import '../data/recipe.dart';
import 'kitchen_math.dart' show foldText;
import 'material.dart';

class RecipeGroup {
  const RecipeGroup(this.id, this.label, this.icon, this.asset);

  final String id;
  final String label;
  final IconData icon;

  /// Záložní fotografie, když ve skupině není recept s fotkou.
  final String asset;
}

const recipeGroups = <RecipeGroup>[
  RecipeGroup(
    'hovezi',
    'Hovězí maso',
    Icons.lunch_dining_rounded,
    'assets/images/categories/hovezi.jpg',
  ),
  RecipeGroup(
    'veprove',
    'Vepřové maso',
    Icons.kebab_dining_rounded,
    'assets/images/categories/veprove.jpg',
  ),
  RecipeGroup(
    'drubez',
    'Drůbež a králík',
    Icons.egg_alt_rounded,
    'assets/images/categories/drubez.jpg',
  ),
  RecipeGroup(
    'ryby',
    'Ryby',
    Icons.set_meal_rounded,
    'assets/images/categories/ryby.jpg',
  ),
  RecipeGroup(
    'polevky',
    'Polévky',
    Icons.soup_kitchen_rounded,
    'assets/images/categories/polevky.jpg',
  ),
  RecipeGroup(
    'omacky',
    'Omáčky',
    Icons.water_drop_rounded,
    'assets/images/categories/omacky.jpg',
  ),
  RecipeGroup(
    'testoviny',
    'Těstoviny a rýže',
    Icons.ramen_dining_rounded,
    'assets/images/categories/testoviny.jpg',
  ),
  RecipeGroup(
    'bezmasa',
    'Bezmasá jídla',
    Icons.eco_rounded,
    'assets/images/categories/bezmasa.jpg',
  ),
  RecipeGroup(
    'prilohy',
    'Přílohy',
    Icons.room_service_rounded,
    'assets/images/categories/prilohy.jpg',
  ),
  RecipeGroup(
    'sladka',
    'Sladká jídla a dezerty',
    Icons.cake_rounded,
    'assets/images/categories/sladka.jpg',
  ),
  RecipeGroup(
    'pecivo',
    'Pečivo a těsta',
    Icons.bakery_dining_rounded,
    'assets/images/categories/pecivo.jpg',
  ),
];

RecipeGroup recipeGroupById(String id) =>
    recipeGroups.firstWhere((g) => g.id == id, orElse: () => recipeGroups[7]);

bool _any(String text, List<String> words) => words.any(text.contains);

const _beef = ['hovez', 'svickov', 'telec', 'rostenc', 'roastbeef', 'steak'];
const _pork = [
  'vepr',
  'krkovic',
  'bucek',
  'panenk',
  'kotlet',
  'zebir',
  'zebr',
  'slanin',
  'vypeck',
  'vrabec',
  'kapsa',
  'sunk',
  'uzen',
  'klobas',
  'spekac',
];
const _poultry = [
  'kure',
  'kurec',
  'kurat',
  'krut',
  'kachn',
  'kachen',
  'husa',
  'husi',
  'kralik',
];
const _fish = [
  'ryb',
  'losos',
  'tresk',
  'kapr',
  'tunak',
  'pstruh',
  'makrel',
  'sled',
  'krevet',
  'filé',
  'file ',
];
const _soup = [
  'polevk',
  'vyvar',
  'kulajd',
  'bramboracka',
  'zelnack',
  'cesnecka',
  'gulasovka',
  'krem z',
];
const _pasta = [
  'testovin',
  'spaget',
  'lasagn',
  'rizot',
  'ryze',
  'penne',
  'nudle',
  'carbonar',
  'bolon',
  'gnocchi',
  'noky',
];
const _sweet = [
  'dezert',
  'sladk',
  'dort',
  'kolac',
  'buchet',
  'buchty',
  'buchtick',
  'babovk',
  'cookies',
  'susenk',
  'palacink',
  'livanc',
  'vafl',
  'tiramisu',
  'kase',
  'nakyp',
  'zmrzlin',
  'muffin',
  'strudl',
  'cukrov',
  'perník',
  'pernik',
];
const _bread = [
  'pecivo',
  'chleb',
  'rohlik',
  'hous',
  'bagety',
  'vanock',
  'pizz',
  'testo',
  'focacc',
  'loupak',
  'pletyn',
];
const _sides = ['priloh', 'salat', 'knedlik', 'kase bramb', 'hranolk'];

/// Hlavní skupina receptu. Konkrétní kategorie zadaná uživatelem má
/// přednost; obecné kategorie („Maso“, „Hlavní jídla“, „Zapékaná jídla“…)
/// se upřesní podle názvu a surovin.
RecipeGroup groupOf(Recipe recipe) {
  final category = foldText(recipe.category);
  final title = foldText(recipe.title);
  final ingredients = foldText(
    [for (final i in recipe.ingredients) i.name].join(' | '),
  );

  if (_any(category, ['polev'])) return recipeGroupById('polevky');
  if (_any(category, ['omack'])) return recipeGroupById('omacky');
  if (_any(category, ['ryb'])) return recipeGroupById('ryby');
  if (_any(category, ['dezert', 'sladk', 'mouc', 'kolac', 'cukr'])) {
    return recipeGroupById('sladka');
  }
  if (_any(category, ['pecivo', 'chleb', 'pizz'])) {
    return recipeGroupById('pecivo');
  }
  if (_any(category, ['testovin', 'ryz'])) return recipeGroupById('testoviny');
  if (_any(category, ['priloh', 'salat'])) return recipeGroupById('prilohy');
  if (_any(category, ['bezmas', 'vegetar', 'vegan'])) {
    return recipeGroupById('bezmasa');
  }
  if (_any(category, ['drubez', 'kure', 'kralik'])) {
    return recipeGroupById('drubez');
  }
  if (category == 'testa') {
    return _any(title, _pasta)
        ? recipeGroupById('testoviny')
        : recipeGroupById('pecivo');
  }
  return _byContent(title, ingredients);
}

RecipeGroup _byContent(String title, String ingredients) {
  // Název nejvíc vypovídá o tom, co je hlavní („Králík s krkovicí“).
  final firstMeat = _firstMeat(title);
  if (firstMeat != null) return recipeGroupById(firstMeat);
  if (_any(title, _soup)) return recipeGroupById('polevky');
  if (_any(title, _sweet)) return recipeGroupById('sladka');
  if (_any(title, _bread)) return recipeGroupById('pecivo');
  final meat = _firstMeat(ingredients);
  if (_any(title, _pasta)) {
    return meat == null || _any(title, ['testovin', 'spaget', 'rizot'])
        ? recipeGroupById('testoviny')
        : recipeGroupById(meat);
  }
  if (meat != null) return recipeGroupById(meat);
  if (_any(ingredients, ['mlet'])) return recipeGroupById('hovezi');
  if (_any(title, _sides)) return recipeGroupById('prilohy');
  return recipeGroupById('bezmasa');
}

/// Skupina masa, které se v textu objeví nejdřív.
String? _firstMeat(String text) {
  String? best;
  var at = 1 << 30;
  void check(String group, List<String> words) {
    for (final w in words) {
      final i = text.indexOf(w);
      if (i >= 0 && i < at) {
        at = i;
        best = group;
      }
    }
  }

  check('hovezi', _beef);
  check('veprove', _pork);
  check('drubez', _poultry);
  check('ryby', _fish);
  return best;
}

// ------------------------------------------------------------- příprava

enum PrepMethod {
  oven('Trouba', Icons.kitchen_rounded),
  pan('Pánev', Icons.egg_rounded),
  sousVide('Sous-vide', Icons.hot_tub_rounded),
  grill('Gril', Icons.outdoor_grill_rounded),
  slow('Pomalé vaření', Icons.soup_kitchen_outlined);

  const PrepMethod(this.label, this.icon);

  final String label;
  final IconData icon;
}

String _recipeText(Recipe r) => foldText(
  [
    r.title,
    r.description,
    ...r.equipment,
    ...r.temperatures,
    for (final s in r.steps) s.instruction,
  ].join(' | '),
);

final _oven = RegExp(
  r'troub|pekac|zapec|zapek|\bpec(te|eni|ena|eny|eme)?\b|\b(u|do)pec',
);
final _pan = RegExp(r'panev|panv|\bsmaz|osmaz|wok\b');

/// Způsoby přípravy, které recept skutečně uvádí (v názvu, postupu,
/// teplotách nebo vybavení). „Pomalé vaření“ = výslovně pomalá příprava
/// nebo vaření či pečení aspoň 3 hodiny.
Set<PrepMethod> prepMethodsOf(Recipe r) {
  final text = _recipeText(r);
  final head = foldText(
    [r.title, ...r.equipment, ...r.temperatures].join(' | '),
  );
  final slowByTime =
      r.cookMinutes >= 180 ||
      (r.cookMinutes == 0 && r.restMinutes == 0 && r.totalMinutes >= 180);
  return {
    if (_oven.hasMatch(text)) PrepMethod.oven,
    if (_pan.hasMatch(text)) PrepMethod.pan,
    if (_any(text, ['sous-vide', 'sous vide', 'sousvide'])) PrepMethod.sousVide,
    if (_any(text, ['gril'])) PrepMethod.grill,
    if (_any(head, ['pomal', 'slow']) || slowByTime) PrepMethod.slow,
  };
}

// ------------------------------------------------------------------ čas

enum TimeFilter {
  upTo30('Do 30 min'),
  upTo60('Do 60 min'),
  longer('Delší');

  const TimeFilter(this.label);

  final String label;
}

/// Celkový čas receptu včetně pečení a pasivního čekání (kynutí,
/// marinování…), nebo null, když ho recept neuvádí.
int? totalMinutesOf(Recipe r) {
  final total = r.effectiveTotalMinutes;
  return total > 0 ? total : null;
}

bool matchesTime(Recipe r, TimeFilter filter) {
  final total = totalMinutesOf(r);
  if (total == null) return false;
  return switch (filter) {
    TimeFilter.upTo30 => total <= 30,
    TimeFilter.upTo60 => total <= 60,
    TimeFilter.longer => total > 60,
  };
}

// ----------------------------------------------------------- příležitost

/// Příležitosti – berou se jen ze štítků, které recept opravdu má.
const occasionTags = [
  'Rychlá večeře',
  'Rodinný oběd',
  'Pro děti',
  'Slavnostní jídlo',
];

/// Štítky nabízené v úpravě receptu jedním klepnutím.
const suggestedTags = [...occasionTags, 'Na víc dní', 'Nepálivé'];

bool hasTag(Recipe r, String tag) {
  final wanted = foldText(tag);
  return r.tags.any((t) => foldText(t) == wanted);
}

/// Všechny štítky v receptech s počtem receptů (nejčastější první).
List<MapEntry<String, int>> tagCounts(List<Recipe> recipes) {
  final counts = <String, int>{};
  final names = <String, String>{};
  for (final r in recipes) {
    for (final tag in {
      for (final t in r.tags) foldText(t.trim()): t.trim(),
    }.entries) {
      if (tag.key.isEmpty) continue;
      names.putIfAbsent(tag.key, () => tag.value);
      counts[tag.key] = (counts[tag.key] ?? 0) + 1;
    }
  }
  final out = [for (final e in counts.entries) MapEntry(names[e.key]!, e.value)]
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return out;
}

// --------------------------------------------------------- kombinace

/// Zvolené filtry: v rámci jedné řady stačí shoda s kterýmkoli zvoleným
/// (příprava, příležitost), mezi řadami musí platit všechny.
@immutable
class RecipeFilters {
  const RecipeFilters({
    this.query = '',
    this.prep = const {},
    this.time,
    this.occasions = const {},
    this.group,
    this.tag,
  });

  final String query;
  final Set<PrepMethod> prep;
  final TimeFilter? time;
  final Set<String> occasions;
  final String? group;
  final String? tag;

  bool get isEmpty =>
      query.trim().isEmpty &&
      prep.isEmpty &&
      time == null &&
      occasions.isEmpty &&
      group == null &&
      tag == null;

  RecipeFilters copyWith({
    String? query,
    Set<PrepMethod>? prep,
    Object? time = _keep,
    Set<String>? occasions,
    Object? group = _keep,
    Object? tag = _keep,
  }) => RecipeFilters(
    query: query ?? this.query,
    prep: prep ?? this.prep,
    time: identical(time, _keep) ? this.time : time as TimeFilter?,
    occasions: occasions ?? this.occasions,
    group: identical(group, _keep) ? this.group : group as String?,
    tag: identical(tag, _keep) ? this.tag : tag as String?,
  );

  bool matches(Recipe r) {
    if (r.isDeleted) return false;
    if (!r.matches(query)) return false;
    if (group != null && groupOf(r).id != group) return false;
    if (tag != null && !hasTag(r, tag!)) return false;
    if (prep.isNotEmpty && prepMethodsOf(r).intersection(prep).isEmpty) {
      return false;
    }
    if (time != null && !matchesTime(r, time!)) return false;
    if (occasions.isNotEmpty && !occasions.any((o) => hasTag(r, o))) {
      return false;
    }
    return true;
  }

  List<Recipe> apply(List<Recipe> recipes) => [
    for (final r in recipes)
      if (matches(r)) r,
  ];
}

const Object _keep = Object();

/// Počet receptů v každé skupině.
Map<String, int> groupCounts(List<Recipe> recipes) {
  final out = {for (final g in recipeGroups) g.id: 0};
  for (final r in recipes) {
    if (r.isDeleted) continue;
    final id = groupOf(r).id;
    out[id] = (out[id] ?? 0) + 1;
  }
  return out;
}

/// České skloňování: 1 recept, 2–4 recepty, 5+ receptů.
String receptyCount(int n) => switch (n) {
  1 => '1 recept',
  >= 2 && <= 4 => '$n recepty',
  _ => '$n receptů',
};

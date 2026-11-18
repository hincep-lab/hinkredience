/// Skupiny receptů na domovské obrazovce a rychlé filtry (příprava, čas,
/// příležitost). Vše se odvozuje ze skutečných údajů receptu: kategorie,
/// názvu, surovin, postupu, teplot, vybavení, časů a štítků. Co recept
/// neuvádí, filtr nepředstírá (recept bez času se do časových filtrů
/// nezapočítá, příležitost se bere jen ze štítků).
library;

import '../data/recipe.dart';
import 'kitchen_math.dart' show foldText;
import 'material.dart';
import 'recipe_time.dart' show formatDuration;

class RecipeGroup {
  const RecipeGroup(this.id, this.label, this.icon, this.asset);

  final String id;
  final String label;
  final IconData icon;

  /// Záložní fotografie, když ve skupině není recept s fotkou.
  final String asset;

  /// Obrysová ikona podle předlohy (bílá, průhledné pozadí).
  String get iconAsset => 'assets/images/icons/$id.png';
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
  oven('Trouba', Icons.kitchen_rounded, 'trouba'),
  pan('Pánev', Icons.egg_rounded, 'panev'),
  sousVide('Sous-vide', Icons.hot_tub_rounded, 'sousvide'),
  grill('Gril', Icons.outdoor_grill_rounded, 'gril'),
  slow('Pomalé vaření', Icons.soup_kitchen_outlined, 'pomale');

  const PrepMethod(this.label, this.icon, this._asset);

  final String label;
  final IconData icon;
  final String _asset;

  /// Obrysová ikona podle předlohy.
  String get iconAsset => 'assets/images/icons/$_asset.png';

  /// Štítek, pod kterým se způsob přípravy ukládá u receptu.
  String get tag => label;

  static PrepMethod? fromTag(String tag) {
    final folded = _canonTag(tag);
    for (final m in PrepMethod.values) {
      if (_canonTag(m.label) == folded) return m;
    }
    return null;
  }
}

String _recipeText(Recipe r) => foldText(
  [
    r.title,
    r.description,
    ...r.equipment,
    ...r.temperatures,
    for (final s in r.steps) s.instruction,
    for (final i in r.ingredients) i.name,
  ].join(' | '),
);

final _oven = RegExp(
  r'troub|\bpekac|\bplech(u|y)?\b|zapec|zapek|\bpredehrej|'
  r'\bpec(te|e|eni|ena|eny|eme)?\b|\b(u|do)pec',
);
final _pan = RegExp(
  r'panev|panv|\bsmaz|\bosmaz|\bwok\b|\bzprudka|z obou stran',
);
final _sousVide = RegExp(r'sous-vide|sous vide|sousvide|vodni lazn');

/// Způsoby přípravy uložené u receptu jako štítky.
Set<PrepMethod> savedPrepMethods(Recipe r) => {
  for (final t in r.tags)
    if (PrepMethod.fromTag(t) case final m?) m,
};

/// Odhad způsobů přípravy z postupu, vybavení, surovin, teplot a časů.
/// Používá se jen pro recepty, které ještě žádný způsob přípravy uložený
/// nemají (a jako návrh v editoru).
Set<PrepMethod> inferPrepMethods(Recipe r) {
  final text = _recipeText(r);
  final title = foldText(r.title);
  // Vafle ve vaflovači nejsou pečení v troubě.
  final waffleOnly = text.contains('vaflovac') && !text.contains('troub');
  return {
    if (_oven.hasMatch(text) && !waffleOnly) PrepMethod.oven,
    if (_pan.hasMatch(text)) PrepMethod.pan,
    if (_sousVide.hasMatch(text)) PrepMethod.sousVide,
    if (RegExp(r'\bgril').hasMatch(text)) PrepMethod.grill,
    if (title.contains('pomal') || r.cookMinutes >= 180) PrepMethod.slow,
  };
}

/// Způsoby přípravy receptu: uložené štítky, jinak odhad.
Set<PrepMethod> prepMethodsOf(Recipe r) {
  final saved = savedPrepMethods(r);
  return saved.isNotEmpty ? saved : inferPrepMethods(r);
}

// ------------------------------------------------------------------ čas

/// Podle čeho se filtruje čas.
enum TimeMode {
  total('Celkový čas'),
  active('Aktivní práce');

  const TimeMode(this.label);

  final String label;
}

enum TimeFilter {
  upTo15('Do 15 min'),
  upTo30('Do 30 min'),
  upTo60('Do 60 min'),
  h1to3('1–3 hodiny'),
  over3('Nad 3 hodiny');

  const TimeFilter(this.label);

  final String label;

  bool accepts(int minutes) => switch (this) {
    TimeFilter.upTo15 => minutes <= 15,
    TimeFilter.upTo30 => minutes <= 30,
    TimeFilter.upTo60 => minutes <= 60,
    TimeFilter.h1to3 => minutes > 60 && minutes <= 180,
    TimeFilter.over3 => minutes > 180,
  };
}

/// Celkový čas receptu včetně vaření, pečení a pasivního čekání (kynutí,
/// marinování…), nebo null, když ho recept neuvádí. Počítá se ze
/// skutečných údajů u receptu a jeho kroků (viz [Recipe.timeBreakdown]).
int? totalMinutesOf(Recipe r) {
  final total = r.effectiveTotalMinutes;
  return total > 0 ? total : null;
}

/// Aktivní práce (příprava u linky), nebo null, když ji recept neuvádí.
int? activeMinutesOf(Recipe r) {
  final active = r.timeBreakdown.active;
  return active > 0 ? active : null;
}

int? minutesOf(Recipe r, TimeMode mode) => switch (mode) {
  TimeMode.total => totalMinutesOf(r),
  TimeMode.active => activeMinutesOf(r),
};

bool matchesTime(
  Recipe r,
  TimeFilter filter, {
  TimeMode mode = TimeMode.total,
}) {
  final minutes = minutesOf(r, mode);
  return minutes != null && filter.accepts(minutes);
}

/// Čas pro kartu receptu: „1 h 20 min“, nebo „Čas neuveden“.
String timeLabelOf(Recipe r, {TimeMode mode = TimeMode.total}) {
  final minutes = minutesOf(r, mode);
  if (minutes == null) return 'Čas neuveden';
  final text = formatDuration(minutes);
  return mode == TimeMode.active ? 'aktivně $text' : text;
}

// ----------------------------------------------------------- příležitost

/// Příležitosti – berou se jen ze štítků, které recept opravdu má.
const occasionTags = [
  'Rychlá večeře',
  'Rodinný oběd',
  'Pro děti',
  'Nedělní oběd',
  'Slavnostní jídlo',
  'Na více dní',
  'Sladká snídaně',
];

/// Štítky nabízené v úpravě receptu jedním klepnutím (kromě způsobů
/// přípravy, které mají vlastní řadu).
const suggestedTags = [...occasionTags, 'Nepálivé'];

/// Názvy způsobů přípravy, které jsou zároveň štítky.
final prepTags = [for (final m in PrepMethod.values) m.tag];

/// Starší podoby štítků, které znamenají totéž.
const _tagAliases = {'na vic dni': 'na vice dni'};

String _canonTag(String tag) {
  final folded = foldText(tag.trim()).replaceAll(RegExp(r'\s+'), ' ');
  return _tagAliases[folded] ?? folded;
}

/// Jde o stejný štítek? (Bez ohledu na diakritiku, velikost písmen a
/// starší podoby názvu.)
bool sameTag(String a, String b) => _canonTag(a) == _canonTag(b);

bool hasTag(Recipe r, String tag) {
  final wanted = _canonTag(tag);
  return r.tags.any((t) => _canonTag(t) == wanted);
}

/// Vrátí štítky se zapnutým/vypnutým [tag] (bez ohledu na diakritiku).
List<String> toggleTag(List<String> tags, String tag, bool on) {
  final wanted = _canonTag(tag);
  final rest = [
    for (final t in tags)
      if (_canonTag(t) != wanted) t,
  ];
  return on ? [...rest, tag] : rest;
}

/// Všechny štítky v receptech s počtem receptů (nejčastější první).
List<MapEntry<String, int>> tagCounts(List<Recipe> recipes) {
  final counts = <String, int>{};
  final names = <String, String>{};
  for (final r in recipes) {
    if (r.isDeleted) continue;
    for (final tag in {
      for (final t in r.tags) _canonTag(t): t.trim(),
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

/// Zvolené filtry. V rámci jedné skupiny (příprava, čas, příležitost,
/// kategorie) stačí shoda s kterýmkoli zvoleným, mezi skupinami musí platit
/// všechny.
@immutable
class RecipeFilters {
  const RecipeFilters({
    this.query = '',
    this.prep = const {},
    this.times = const {},
    this.timeMode = TimeMode.total,
    this.occasions = const {},
    this.groups = const {},
    this.tag,
  });

  final String query;
  final Set<PrepMethod> prep;
  final Set<TimeFilter> times;
  final TimeMode timeMode;
  final Set<String> occasions;
  final Set<String> groups;
  final String? tag;

  bool get isEmpty =>
      query.trim().isEmpty &&
      prep.isEmpty &&
      times.isEmpty &&
      occasions.isEmpty &&
      groups.isEmpty &&
      tag == null;

  /// Počet zvolených filtrů (bez hledaného textu).
  int get count =>
      prep.length +
      times.length +
      occasions.length +
      groups.length +
      (tag == null ? 0 : 1);

  RecipeFilters copyWith({
    String? query,
    Set<PrepMethod>? prep,
    Set<TimeFilter>? times,
    TimeMode? timeMode,
    Set<String>? occasions,
    Set<String>? groups,
    Object? tag = _keep,
  }) => RecipeFilters(
    query: query ?? this.query,
    prep: prep ?? this.prep,
    times: times ?? this.times,
    timeMode: timeMode ?? this.timeMode,
    occasions: occasions ?? this.occasions,
    groups: groups ?? this.groups,
    tag: identical(tag, _keep) ? this.tag : tag as String?,
  );

  /// Ponechá hledaný text a režim času, ostatní filtry zruší.
  RecipeFilters cleared() => RecipeFilters(query: query, timeMode: timeMode);

  bool matches(Recipe r) => !r.isDeleted && reasonsAgainst(r).isEmpty;

  /// Proč recept nevyhovuje – jedna věta za každou nesplněnou skupinu.
  List<String> reasonsAgainst(Recipe r) {
    final out = <String>[];
    if (query.trim().isNotEmpty && !r.matches(query)) {
      out.add('neodpovídá hledání „${query.trim()}“');
    }
    if (groups.isNotEmpty) {
      final g = groupOf(r);
      if (!groups.contains(g.id)) out.add('patří do kategorie ${g.label}');
    }
    if (tag != null && !hasTag(r, tag!)) out.add('nemá štítek $tag');
    if (prep.isNotEmpty) {
      final has = prepMethodsOf(r);
      if (has.intersection(prep).isEmpty) {
        out.add(
          has.isEmpty
              ? 'nemá uvedený způsob přípravy'
              : 'způsob přípravy: ${has.map((m) => m.label).join(', ')}',
        );
      }
    }
    if (times.isNotEmpty) {
      final minutes = minutesOf(r, timeMode);
      if (minutes == null) {
        out.add(
          timeMode == TimeMode.active ? 'aktivní čas neuveden' : 'čas neuveden',
        );
      } else if (!times.any((t) => t.accepts(minutes))) {
        out.add(
          '${timeMode == TimeMode.active ? 'aktivní práce' : 'celkový čas'} '
          '${formatDuration(minutes)}',
        );
      }
    }
    if (occasions.isNotEmpty && !occasions.any((o) => hasTag(r, o))) {
      out.add(
        occasions.length == 1
            ? 'nemá štítek ${occasions.first}'
            : 'nemá žádný ze štítků ${occasions.join(', ')}',
      );
    }
    return out;
  }

  List<Recipe> apply(List<Recipe> recipes) => [
    for (final r in recipes)
      if (matches(r)) r,
  ];

  /// Recepty, kterým k zobrazení chybí splnit jen jedna podmínka – s
  /// vysvětlením proč. Pro prázdný výsledek („proč nic nenašlo?“).
  List<(Recipe, String)> nearMisses(List<Recipe> recipes, {int limit = 5}) {
    final out = <(Recipe, String)>[];
    for (final r in recipes) {
      if (r.isDeleted) continue;
      final reasons = reasonsAgainst(r);
      if (reasons.length == 1) out.add((r, reasons.first));
      if (out.length >= limit) break;
    }
    return out;
  }
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

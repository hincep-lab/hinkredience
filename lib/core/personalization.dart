import 'dart:math' as math;

import '../data/kitchen_docs.dart';
import '../data/recipe.dart';
import 'formatters.dart';
import 'kitchen_math.dart';

/// Osobní chutě a vybavení, ze kterých se počítají doporučení.
///
/// Vzniká z položek „Kuchyně a chutě“ (Více → Kuchyně a chutě). Funguje
/// i bez nich – pak se doporučuje jen podle oblíbených, hodnocení a deníku.
class TasteProfile {
  const TasteProfile({
    this.slowCooking = false,
    this.sousVide = false,
    this.strongFlavour = false,
    this.meat = false,
    this.family = false,
    this.noChilli = false,
    this.experimenting = false,
    this.equipment = const [],
  });

  /// Profil z popisků preferencí a názvů spotřebičů (jen zapnuté položky).
  factory TasteProfile.fromLabels(
    Iterable<String> preferences, {
    Iterable<String> equipment = const [],
  }) {
    final text = [for (final p in preferences) foldText(p)].join(' | ');
    bool has(List<String> stems) => stems.any(text.contains);
    return TasteProfile(
      slowCooking: has(['pomal', 'dusen', 'slow']),
      sousVide: has(['sous']),
      strongFlavour: has(['vyrazn', 'pikant', 'ochucen']),
      meat: has(['maso', 'masa']),
      family: has(['rodin', 'deti', 'detsk']),
      noChilli: has(['bez chilli', 'bez chili', 'nepalive', 'bez paliv']),
      experimenting: has(['experiment']),
      equipment: [
        for (final e in equipment)
          if (e.trim().isNotEmpty) e.trim(),
      ],
    );
  }

  static const empty = TasteProfile();

  final bool slowCooking;
  final bool sousVide;
  final bool strongFlavour;
  final bool meat;
  final bool family;
  final bool noChilli;
  final bool experimenting;
  final List<String> equipment;
}

// ------------------------------------------------------------- chilli

const _chilliStems = [
  'chilli',
  'chili',
  'feferon',
  'jalapen',
  'habaner',
  'kajensk',
  'cayenn',
  'tabasco',
  'sriracha',
  'harissa',
  'sambal',
  'chipotle',
  'piri piri',
  'gochujang',
  'paliv',
  'pikantn',
];

/// Surovina, která dělá jídlo pálivým (chilli, feferonky, pálivá paprika…).
bool isChilliIngredient(String name) {
  final text = foldText(name);
  // „Sladká paprika“ ani „paprika bez chilli“ pálivé nejsou.
  if (text.contains('bez chil') || text.contains('nepaliv')) return false;
  return _chilliStems.any(text.contains);
}

/// Obsahuje recept pálivé suroviny?
bool recipeHasChilli(Recipe recipe) =>
    recipe.ingredients.any((i) => isChilliIngredient(i.name));

/// Pálivé suroviny receptu (pro upozornění).
List<Ingredient> chilliIngredients(Recipe recipe) => [
  for (final i in recipe.ingredients)
    if (isChilliIngredient(i.name)) i,
];

/// Varianta receptu bez chilli: pálivé suroviny vypadnou, pálivá mletá
/// paprika se nahradí sladkou (stejné množství). Ostatní zůstane.
Recipe withoutChilli(Recipe recipe) {
  final ingredients = <Ingredient>[];
  for (final i in recipe.ingredients) {
    if (!isChilliIngredient(i.name)) {
      ingredients.add(i);
      continue;
    }
    final text = foldText(i.name);
    final groundPaprika =
        text.contains('paprik') &&
        (text.contains('paliv') || text.contains('pikant'));
    if (groundPaprika) {
      ingredients.add(
        i.copyWith(
          name: 'Sladká paprika mletá',
          note: [if (i.note.isNotEmpty) i.note, 'místo pálivé'].join(', '),
        ),
      );
    }
  }
  return recipe.copyWith(ingredients: ingredients);
}

// ------------------------------------------------------------- doporučení

/// Doporučený recept a krátké důvody, proč právě on.
class Recommendation {
  const Recommendation({
    required this.recipe,
    required this.score,
    required this.reasons,
  });

  final Recipe recipe;
  final double score;

  /// Nejdůležitější důvod je první („Dlouho jste nevařili“, „Sous-vide“…).
  final List<String> reasons;
}

const _slowStems = ['pomal', 'dusen', 'dus ', 'pecen', 'konfit', 'brais'];
const _meatStems = [
  'maso',
  'masa',
  'kure',
  'kurec',
  'hovez',
  'veprov',
  'krkovic',
  'zebr',
  'kachn',
  'krut',
  'jehne',
  'kralik',
  'svickov',
  'gulas',
];

/// Doporučení „Co dnes uvaříme?“ – bez AI, jen z dat v telefonu:
/// oblíbené a hodnocení, deník vaření (co se dlouho nevařilo, co se
/// naposledy povedlo, co bylo před pár dny), osobní chutě, vybavení a den
/// v týdnu (o víkendu delší vaření, ve všední den rychlejší).
List<Recommendation> recommend({
  required List<Recipe> recipes,
  List<CookingSession> diary = const [],
  TasteProfile profile = TasteProfile.empty,
  DateTime? now,
  int limit = 6,
}) {
  final today = (now ?? DateTime.now()).toLocal();
  final weekend =
      today.weekday == DateTime.saturday || today.weekday == DateTime.sunday;
  final byRecipe = <String, List<CookingSession>>{};
  for (final session in diary) {
    if (!session.isFinished || session.recipeId == null) continue;
    byRecipe.putIfAbsent(session.recipeId!, () => []).add(session);
  }
  for (final list in byRecipe.values) {
    list.sort((a, b) => b.cookedAt.compareTo(a.cookedAt));
  }

  final result = <Recommendation>[];
  for (final recipe in recipes) {
    if (recipe.isDeleted) continue;
    var score = 0.0;
    final reasons = <({double weight, String text})>[];
    void add(double weight, String text) {
      score += weight;
      if (text.isNotEmpty && weight > 0) {
        reasons.add((weight: weight, text: text));
      }
    }

    if (recipe.isFavorite) add(4, 'Oblíbený');
    if (recipe.rating != null) {
      add(
        recipe.rating! * 0.6,
        recipe.rating! >= 4.5
            ? 'Hodnocení ${formatQuantity(recipe.rating!)}★'
            : '',
      );
    }

    final sessions = byRecipe[recipe.id] ?? const <CookingSession>[];
    final lastCooked = sessions.isNotEmpty
        ? sessions.first.cookedAt
        : recipe.lastCookedAt;
    if (lastCooked != null) {
      final days = today.difference(lastCooked.toLocal()).inDays;
      if (days < 3) {
        add(-5, '');
      } else if (days < 7) {
        add(-1.5, '');
      } else if (days >= 21) {
        add(
          math.min(2.5, 1 + days / 60),
          'Dlouho jste nevařili (${_ago(days)})',
        );
      }
      add(math.min(1.5, sessions.length * 0.4), '');
      final lastRating = sessions.isEmpty ? null : sessions.first.rating;
      if (lastRating != null && lastRating >= 4.5) {
        add(1, 'Minule se povedlo');
      }
    } else if (profile.experimenting) {
      add(1, 'Ještě jste nevařili – něco nového');
    } else {
      add(0.3, '');
    }

    final text = foldText(
      [
        recipe.title,
        recipe.category,
        recipe.description,
        for (final s in recipe.steps) s.instruction,
      ].join(' '),
    );
    final minutes = recipe.effectiveTotalMinutes;
    if (profile.sousVide && text.contains('sous')) add(1.5, 'Sous-vide');
    if (profile.slowCooking &&
        (minutes >= 150 || _slowStems.any(text.contains))) {
      add(1, 'Pomalé vaření');
    }
    final meaty =
        foldText(recipe.category).contains('mas') ||
        recipe.ingredients.any(
          (i) => _meatStems.any(foldText(i.name).contains),
        );
    if (profile.meat && meaty) add(0.6, '');
    if (profile.strongFlavour && meaty) add(0.3, '');

    if (recipeHasChilli(recipe)) {
      if (profile.family || profile.noChilli) {
        add(-0.5, '');
        reasons.add((weight: 0.1, text: 'Jde i bez chilli'));
      }
    } else if (profile.family) {
      add(0.4, '');
    }

    final appliance = _matchingEquipment(recipe, profile.equipment);
    if (appliance != null) add(0.5, 'Na ${_shortName(appliance)}');

    if (minutes > 0) {
      if (weekend && minutes >= 120) {
        add(0.8, 'Víkend – čas na delší vaření');
      } else if (!weekend && minutes <= 45) {
        add(0.8, 'Rychlé na všední den');
      } else if (!weekend && minutes >= 180) {
        add(-0.8, '');
      }
    }

    reasons.sort((a, b) => b.weight.compareTo(a.weight));
    result.add(
      Recommendation(
        recipe: recipe,
        score: score,
        reasons: [for (final r in reasons) r.text],
      ),
    );
  }

  result.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return b.recipe.updatedAt.compareTo(a.recipe.updatedAt);
  });
  return result.take(limit).toList();
}

String _ago(int days) {
  String plural(int n, String one, String few, String many) =>
      '$n ${n == 1 ? one : (n >= 2 && n <= 4 ? few : many)}';
  if (days >= 60) return plural(days ~/ 30, 'měsíc', 'měsíce', 'měsíců');
  if (days >= 14) return plural(days ~/ 7, 'týden', 'týdny', 'týdnů');
  return plural(days, 'den', 'dny', 'dní');
}

/// Spotřebič z vybavení, který recept zmiňuje (název nebo první slovo).
String? _matchingEquipment(Recipe recipe, List<String> equipment) {
  if (equipment.isEmpty) return null;
  final haystack = foldText(
    [
      ...recipe.equipment,
      for (final s in recipe.steps) s.instruction,
      recipe.notes,
    ].join(' '),
  );
  for (final item in equipment) {
    final brand = foldText(item.split(' ').first);
    if (brand.length < 3) continue;
    if (haystack.contains(foldText(item)) || haystack.contains(brand)) {
      return item;
    }
  }
  return null;
}

String _shortName(String appliance) {
  final words = appliance.split(' ');
  return words.length <= 2 ? appliance : words.take(2).join(' ');
}

// ------------------------------------------------------- deník → příště

/// Co si uživatel u receptu naposledy poznamenal (z deníku vaření).
class DiaryReminder {
  const DiaryReminder({
    required this.cookedAt,
    this.toImprove = '',
    this.wentWell = '',
    this.notes = '',
    this.actualMinutes,
    this.rating,
    this.times = 1,
  });

  final DateTime cookedAt;
  final String toImprove;
  final String wentWell;
  final String notes;
  final int? actualMinutes;
  final double? rating;

  /// Kolikrát se recept vařil celkem.
  final int times;

  bool get hasAdvice => toImprove.isNotEmpty || notes.isNotEmpty;
}

/// Poslední zápis v deníku k receptu, který má co připomenout
/// („příště víc soli“), nebo null. Novější zápisy bez poznámek nevadí –
/// použije se nejnovější s radou.
DiaryReminder? diaryReminder(String recipeId, List<CookingSession> diary) {
  final sessions = [
    for (final s in diary)
      if (s.recipeId == recipeId && s.isFinished) s,
  ]..sort((a, b) => b.cookedAt.compareTo(a.cookedAt));
  for (final s in sessions) {
    final improve = s.toImprove.trim();
    final notes = s.notes.trim();
    if (improve.isEmpty && notes.isEmpty) continue;
    return DiaryReminder(
      cookedAt: s.cookedAt,
      toImprove: improve,
      wentWell: s.wentWell.trim(),
      notes: notes,
      actualMinutes: s.actualMinutes,
      rating: s.rating,
      times: sessions.length,
    );
  }
  return null;
}

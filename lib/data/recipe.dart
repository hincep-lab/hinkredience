import 'package:flutter/foundation.dart';

import '../core/formatters.dart';
import '../core/kitchen_math.dart';
import '../core/recipe_time.dart';

/// Viditelnost receptu.
abstract final class RecipeVisibility {
  static const private = 'private';
  static const household = 'household';
}

@immutable
class Ingredient {
  const Ingredient({
    required this.id,
    required this.name,
    this.quantity,
    this.unit = '',
    this.note = '',
  });

  final String id;
  final String name;
  final double? quantity;
  final String unit;
  final String note;

  Ingredient copyWith({String? id, String? name, String? unit, String? note}) =>
      Ingredient(
        id: id ?? this.id,
        name: name ?? this.name,
        quantity: quantity,
        unit: unit ?? this.unit,
        note: note ?? this.note,
      );

  /// Množství s jednotkou přepočtené na jiný počet porcí, např. „1,2 kg“,
  /// „1 ½ lžíce“ nebo „3 ks“. Zaokrouhluje se tak, aby šlo množství odměřit;
  /// vejce vycházejí na celé kusy.
  String amountLabel({double fromServings = 1, double toServings = 1}) =>
      formatAmount(
        quantity,
        unit,
        factor: scaleFactor(fromServings, toServings),
        name: name,
      );

  /// Poznámka s přepočtenými rozsahy, např. „nebo 2–3 lžíce“ → „nebo 4–6 lžíce“.
  String noteLabel({double fromServings = 1, double toServings = 1}) =>
      scaleRangesInText(
        note,
        scaleFactor(fromServings, toServings),
        fallbackUnit: unit,
        name: name,
      );

  /// Název suroviny; u suroviny bez množství se přepočítá i rozsah v názvu
  /// („2–3 stroužky česneku“).
  String nameLabel({double fromServings = 1, double toServings = 1}) =>
      quantity != null
      ? name
      : scaleRangesInText(
          name,
          scaleFactor(fromServings, toServings),
          fallbackUnit: unit,
          name: name,
        );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'quantity': quantity,
    'unit': unit,
    'note': note,
  };

  factory Ingredient.fromJson(Map<String, dynamic> json) => Ingredient(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    quantity: (json['quantity'] as num?)?.toDouble(),
    unit: (json['unit'] as String?) ?? '',
    note: (json['note'] as String?) ?? '',
  );
}

@immutable
class RecipeStep {
  const RecipeStep({
    required this.id,
    required this.instruction,
    this.durationMinutes,
    this.temperatureC,
    this.kind = StepKind.auto,
    this.parallel = false,
  });

  final String id;
  final String instruction;
  final int? durationMinutes;
  final double? temperatureC;

  /// Druh kroku z hlediska času ([StepKind]): aktivní příprava, vaření,
  /// čekání, nebo prázdné = rozpoznat z textu.
  final String kind;

  /// Krok probíhá současně s předchozím a celkový čas neprodlužuje.
  final bool parallel;

  RecipeStep copyWith({String? id}) => RecipeStep(
    id: id ?? this.id,
    instruction: instruction,
    durationMinutes: durationMinutes,
    temperatureC: temperatureC,
    kind: kind,
    parallel: parallel,
  );

  /// Druh kroku, jak se s ním počítá – ručně zvolený, jinak rozpoznaný z textu.
  /// Pečení/dušení označené jako pasivní se počítá jako vaření (viz
  /// [effectiveStepKind]).
  String get effectiveKind => effectiveStepKind(
    TimedStep(instruction: instruction, kind: kind, temperatureC: temperatureC),
  );

  /// Běží krok souběžně s předchozím (ručně označeno, nebo „mezitím…“)?
  bool get runsInParallel => parallel || inferParallel(instruction);

  Map<String, dynamic> toJson() => {
    'id': id,
    'instruction': instruction,
    'duration_minutes': durationMinutes,
    'temperature_c': temperatureC,
    'kind': kind,
    'parallel': parallel,
  };

  factory RecipeStep.fromJson(Map<String, dynamic> json) => RecipeStep(
    id: json['id'] as String,
    instruction: (json['instruction'] as String?) ?? '',
    durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
    temperatureC: (json['temperature_c'] as num?)?.toDouble(),
    kind: StepKind.normalize(json['kind'] as String?),
    parallel: json['parallel'] == true,
  );
}

/// Fotografie receptu. [localPath] je soubor v telefonu, [remotePath] cesta
/// v úložišti Supabase (vyplní se po nahrání).
@immutable
class RecipePhoto {
  const RecipePhoto({
    required this.id,
    this.localPath,
    this.remotePath,
    this.thumbPath,
  });

  final String id;

  /// Relativní cesta souboru v telefonu (složka aplikace).
  final String? localPath;

  /// Cesta v úložišti Supabase (bucket recipe-photos).
  final String? remotePath;

  /// Cesta zmenšeného náhledu v úložišti (pro přehledy a ChatGPT).
  final String? thumbPath;

  RecipePhoto copyWith({
    String? id,
    String? localPath,
    String? remotePath,
    String? thumbPath,
  }) => RecipePhoto(
    id: id ?? this.id,
    localPath: localPath ?? this.localPath,
    remotePath: remotePath ?? this.remotePath,
    thumbPath: thumbPath ?? this.thumbPath,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'local_path': localPath,
    'remote_path': remotePath,
    'thumb_path': ?thumbPath,
  };

  /// Podoba ukládaná na server – cesta v telefonu tam nepatří.
  Map<String, dynamic> toRemoteJson() => {
    'id': id,
    'remote_path': remotePath,
    'thumb_path': ?thumbPath,
  };

  factory RecipePhoto.fromJson(Map<String, dynamic> json) => RecipePhoto(
    id: json['id'] as String,
    localPath: json['local_path'] as String?,
    remotePath: json['remote_path'] as String?,
    thumbPath: json['thumb_path'] as String?,
  );
}

@immutable
class Recipe {
  const Recipe({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.ownerId,
    this.householdId,
    this.visibility = RecipeVisibility.private,
    this.description = '',
    this.category = '',
    this.servings = 4,
    this.yieldUnit = YieldUnit.servings,
    this.altYield,
    this.altYieldUnit,
    this.prepMinutes = 0,
    this.cookMinutes = 0,
    this.restMinutes = 0,
    this.totalMinutes = 0,
    this.temperatures = const [],
    this.equipment = const [],
    this.tags = const [],
    this.notes = '',
    this.rating,
    this.isFavorite = false,
    this.photos = const [],
    this.sourceUrl,
    this.currentVersion = 1,
    this.lastCookedAt,
    this.deletedAt,
    this.ingredients = const [],
    this.steps = const [],
  });

  final String id;
  final String? ownerId;
  final String? householdId;
  final String visibility;
  final String title;
  final String description;
  final String category;

  /// Výtěžnost receptu – počet porcí nebo kusů podle [yieldUnit].
  final double servings;

  /// [YieldUnit.servings] nebo [YieldUnit.pieces].
  final String yieldUnit;

  /// Druhá varianta výnosu pro stejné množství surovin („55 ks“, „1 l“,
  /// „600 g“). V detailu se mezi variantami přepíná; nepovinná.
  final double? altYield;
  final String? altYieldUnit;

  /// Má recept platnou druhou variantu výnosu (jinou jednotku než hlavní)?
  bool get hasAltYield {
    final unit = YieldUnit.normalizeVariant(altYieldUnit);
    return altYield != null &&
        altYield! > 0 &&
        unit != null &&
        unit != YieldUnit.normalize(yieldUnit);
  }

  /// Aktivní příprava v minutách.
  final int prepMinutes;

  /// Vaření, pečení, smažení v minutách.
  final int cookMinutes;

  /// Pasivní čekání v minutách: kynutí, marinování, chlazení, odpočinek.
  final int restMinutes;

  /// Ručně zadaný celkový čas; 0 = spočítat.
  final int totalMinutes;
  final List<String> temperatures;
  final List<String> equipment;

  /// Štítky („Pro děti“, „Rychlá večeře“…) – zadává uživatel.
  final List<String> tags;
  final String notes;
  final double? rating;
  final bool isFavorite;
  final List<RecipePhoto> photos;
  final String? sourceUrl;
  final int currentVersion;
  final DateTime? lastCookedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final List<Ingredient> ingredients;
  final List<RecipeStep> steps;

  bool get isDeleted => deletedAt != null;

  /// Rozpad času: aktivní příprava, vaření, čekání a skutečný celek.
  /// Počítá i s časy u kroků a s čekáním popsaným jen v textu postupu;
  /// souběžné kroky se nezapočítávají dvakrát.
  TimeBreakdown get timeBreakdown => computeRecipeTime(
    prepMinutes: prepMinutes,
    cookMinutes: cookMinutes,
    restMinutes: restMinutes,
    totalOverride: totalMinutes,
    steps: [
      for (final step in steps)
        TimedStep(
          instruction: step.instruction,
          durationMinutes: step.durationMinutes,
          kind: step.kind,
          parallel: step.parallel,
          temperatureC: step.temperatureC,
        ),
    ],
  );

  /// Skutečný celkový čas receptu včetně kynutí, marinování a odpočinku.
  int get effectiveTotalMinutes => timeBreakdown.total;

  /// Výtěžnost slovy: „4 porce“, „12 ks“.
  String get yieldText => yieldLabel(servings, yieldUnit);

  Recipe copyWith({
    String? id,
    Object? ownerId = _keep,
    Object? householdId = _keep,
    String? visibility,
    String? title,
    String? description,
    String? category,
    double? servings,
    String? yieldUnit,
    Object? altYield = _keep,
    Object? altYieldUnit = _keep,
    int? prepMinutes,
    int? cookMinutes,
    int? restMinutes,
    int? totalMinutes,
    List<String>? temperatures,
    List<String>? equipment,
    List<String>? tags,
    String? notes,
    Object? rating = _keep,
    bool? isFavorite,
    List<RecipePhoto>? photos,
    Object? sourceUrl = _keep,
    int? currentVersion,
    Object? lastCookedAt = _keep,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? deletedAt = _keep,
    List<Ingredient>? ingredients,
    List<RecipeStep>? steps,
  }) => Recipe(
    id: id ?? this.id,
    ownerId: identical(ownerId, _keep) ? this.ownerId : ownerId as String?,
    householdId: identical(householdId, _keep)
        ? this.householdId
        : householdId as String?,
    visibility: visibility ?? this.visibility,
    title: title ?? this.title,
    description: description ?? this.description,
    category: category ?? this.category,
    servings: servings ?? this.servings,
    yieldUnit: yieldUnit ?? this.yieldUnit,
    altYield: identical(altYield, _keep) ? this.altYield : altYield as double?,
    altYieldUnit: identical(altYieldUnit, _keep)
        ? this.altYieldUnit
        : altYieldUnit as String?,
    prepMinutes: prepMinutes ?? this.prepMinutes,
    cookMinutes: cookMinutes ?? this.cookMinutes,
    restMinutes: restMinutes ?? this.restMinutes,
    totalMinutes: totalMinutes ?? this.totalMinutes,
    temperatures: temperatures ?? this.temperatures,
    equipment: equipment ?? this.equipment,
    tags: tags ?? this.tags,
    notes: notes ?? this.notes,
    rating: identical(rating, _keep) ? this.rating : rating as double?,
    isFavorite: isFavorite ?? this.isFavorite,
    photos: photos ?? this.photos,
    sourceUrl: identical(sourceUrl, _keep)
        ? this.sourceUrl
        : sourceUrl as String?,
    currentVersion: currentVersion ?? this.currentVersion,
    lastCookedAt: identical(lastCookedAt, _keep)
        ? this.lastCookedAt
        : lastCookedAt as DateTime?,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: identical(deletedAt, _keep)
        ? this.deletedAt
        : deletedAt as DateTime?,
    ingredients: ingredients ?? this.ingredients,
    steps: steps ?? this.steps,
  );

  /// Úplná podoba receptu – pro místní databázi, historii verzí a export.
  Map<String, dynamic> toJson() => {
    'id': id,
    'owner_id': ownerId,
    'household_id': householdId,
    'visibility': visibility,
    'title': title,
    'description': description,
    'category': category,
    'servings': servings,
    'yield_unit': yieldUnit,
    'alt_yield': altYield,
    'alt_yield_unit': altYieldUnit,
    'prep_minutes': prepMinutes,
    'cook_minutes': cookMinutes,
    'rest_minutes': restMinutes,
    'total_minutes': totalMinutes,
    'temperatures': temperatures,
    'equipment': equipment,
    'tags': tags,
    'notes': notes,
    'rating': rating,
    'is_favorite': isFavorite,
    'photos': [for (final photo in photos) photo.toJson()],
    'source_url': sourceUrl,
    'current_version': currentVersion,
    'last_cooked_at': lastCookedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'ingredients': [for (final item in ingredients) item.toJson()],
    'steps': [for (final step in steps) step.toJson()],
  };

  factory Recipe.fromJson(Map<String, dynamic> json) => Recipe(
    id: json['id'] as String,
    ownerId: json['owner_id'] as String?,
    householdId: json['household_id'] as String?,
    visibility: (json['visibility'] as String?) ?? RecipeVisibility.private,
    title: (json['title'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    category: (json['category'] as String?) ?? '',
    servings: (json['servings'] as num?)?.toDouble() ?? 4,
    yieldUnit: YieldUnit.normalize(json['yield_unit'] as String?),
    altYield: (json['alt_yield'] as num?)?.toDouble(),
    altYieldUnit: YieldUnit.normalizeVariant(json['alt_yield_unit'] as String?),
    prepMinutes: (json['prep_minutes'] as num?)?.toInt() ?? 0,
    cookMinutes: (json['cook_minutes'] as num?)?.toInt() ?? 0,
    restMinutes: (json['rest_minutes'] as num?)?.toInt() ?? 0,
    totalMinutes: (json['total_minutes'] as num?)?.toInt() ?? 0,
    temperatures: _stringList(json['temperatures']),
    equipment: _stringList(json['equipment']),
    tags: _stringList(json['tags']),
    notes: (json['notes'] as String?) ?? '',
    rating: (json['rating'] as num?)?.toDouble(),
    isFavorite: json['is_favorite'] == true,
    photos: [
      for (final photo in (json['photos'] as List?) ?? const [])
        RecipePhoto.fromJson(Map<String, dynamic>.from(photo as Map)),
    ],
    sourceUrl: json['source_url'] as String?,
    currentVersion: (json['current_version'] as num?)?.toInt() ?? 1,
    lastCookedAt: _date(json['last_cooked_at']),
    createdAt: _date(json['created_at']) ?? DateTime.now().toUtc(),
    updatedAt: _date(json['updated_at']) ?? DateTime.now().toUtc(),
    deletedAt: _date(json['deleted_at']),
    ingredients: [
      for (final item in (json['ingredients'] as List?) ?? const [])
        Ingredient.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
    steps: [
      for (final step in (json['steps'] as List?) ?? const [])
        RecipeStep.fromJson(Map<String, dynamic>.from(step as Map)),
    ],
  );

  /// Čitelný text receptu pro sdílení.
  String toShareText() {
    final buffer = StringBuffer()..writeln(title);
    if (description.isNotEmpty) buffer.writeln(description);
    buffer.writeln();
    buffer.writeln('Výtěžnost: $yieldText');
    final time = timeBreakdown;
    if (time.total > 0) {
      final parts = [
        if (time.active > 0) 'aktivně ${formatMinutes(time.active)}',
        if (time.cook > 0) 'vaření/pečení ${formatMinutes(time.cook)}',
        if (time.passive > 0) 'čekání ${formatMinutes(time.passive)}',
      ];
      buffer.writeln(
        parts.length > 1
            ? 'Celkový čas: ${formatMinutes(time.total)} (${parts.join(', ')})'
            : 'Celkový čas: ${formatMinutes(time.total)}',
      );
    }
    if (temperatures.isNotEmpty) {
      buffer.writeln('Teploty: ${temperatures.join(', ')}');
    }
    if (ingredients.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('SUROVINY');
      for (final item in ingredients) {
        final amount = item.amountLabel();
        buffer.writeln(
          amount.isEmpty ? '• ${item.name}' : '• $amount ${item.name}',
        );
      }
    }
    if (steps.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('POSTUP');
      for (var i = 0; i < steps.length; i++) {
        buffer.writeln('${i + 1}. ${steps[i].instruction}');
      }
    }
    if (notes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('POZNÁMKY')
        ..writeln(notes);
    }
    buffer
      ..writeln()
      ..write('— HINKredience°');
    return buffer.toString();
  }

  /// Vyhledávání bez ohledu na diakritiku a velikost písmen – v názvu,
  /// popisu, kategorii i surovinách.
  bool matches(String query) {
    final needle = foldForSearch(query.trim());
    if (needle.isEmpty) return true;
    final haystack = foldForSearch(
      [
        title,
        description,
        category,
        ...tags,
        for (final i in ingredients) i.name,
      ].join('\n'),
    );
    return needle.split(RegExp(r'\s+')).every(haystack.contains);
  }
}

const Object _keep = Object();

List<String> _stringList(Object? value) => [
  for (final item in (value as List?) ?? const []) item.toString(),
];

DateTime? _date(Object? value) => value is String && value.isNotEmpty
    ? DateTime.tryParse(value)?.toUtc()
    : null;

/// Uložený stav receptu v historii úprav.
@immutable
class RecipeVersion {
  const RecipeVersion({
    required this.id,
    required this.recipeId,
    required this.versionNumber,
    required this.snapshot,
    required this.createdAt,
    this.changeSummary = '',
  });

  final String id;
  final String recipeId;
  final int versionNumber;
  final Map<String, dynamic> snapshot;
  final String changeSummary;
  final DateTime createdAt;
}

/// Výchozí kategorie podle grafického návrhu. Uživatel si může přidat vlastní.
const defaultCategories = <String>[
  'Hovězí maso',
  'Vepřové maso',
  'Drůbež a králík',
  'Ryby',
  'Polévky',
  'Omáčky',
  'Těstoviny a rýže',
  'Bezmasá jídla',
  'Přílohy',
  'Sladká jídla a dezerty',
  'Pečivo a těsta',
];

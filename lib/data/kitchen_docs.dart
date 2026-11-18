import 'dart:math' as math;

import '../core/cook_timer.dart';
import 'recipe.dart';

export '../core/cook_timer.dart' show CookTimer, CookTimers;

/// Druhy záznamů v tabulce `docs`.
abstract final class DocKind {
  static const session = 'cooking_session';
  static const plan = 'meal_plan';
  static const shopping = 'shopping_item';
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? _iso(DateTime? value) => value?.toUtc().toIso8601String();

List<String> _strings(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is String && item.trim().isNotEmpty) item,
];

// ------------------------------------------------------------------ vaření

/// Stav vaření (shodný se sloupcem `cooking_sessions.status` na serveru).
abstract final class SessionStatus {
  static const inProgress = 'in_progress';
  static const paused = 'paused';
  static const finished = 'finished';
  static const cancelled = 'cancelled';
}

/// Jedno vaření: rozpracované (režim Vaříme spolu) i dokončené (zápis
/// v kuchařském deníku).
class CookingSession {
  const CookingSession({
    required this.id,
    required this.recipeTitle,
    required this.cookedAt,
    required this.updatedAt,
    this.recipeId,
    this.versionNumber,
    this.status = SessionStatus.finished,
    this.servings,
    this.stepIndex = 0,
    this.activeSeconds = 0,
    this.resumedAt,
    this.timers = const [],
    this.actualMinutes,
    this.actualTemperatures = const [],
    this.photos = const [],
    this.rating,
    this.notes = '',
    this.wentWell = '',
    this.toImprove = '',
  });

  final String id;
  final String? recipeId;

  /// Název receptu v době vaření – zůstane, i kdyby byl recept smazán.
  final String recipeTitle;

  /// Verze receptu, podle které se vařilo.
  final int? versionNumber;
  final String status;

  /// Datum vaření.
  final DateTime cookedAt;
  final DateTime updatedAt;

  /// Počet porcí / kusů, na který se vařilo.
  final double? servings;

  // --- průběh režimu Vaříme spolu
  final int stepIndex;

  /// Čistý čas vaření nasbíraný před posledním pozastavením.
  final int activeSeconds;

  /// Od kdy vaření právě běží; `null`, když je pozastavené nebo skončilo.
  final DateTime? resumedAt;
  final List<CookTimer> timers;

  // --- výsledek
  final int? actualMinutes;
  final List<String> actualTemperatures;

  /// Fotky hotového jídla.
  final List<RecipePhoto> photos;
  final double? rating;
  final String notes;
  final String wentWell;
  final String toImprove;

  bool get isOpen =>
      status == SessionStatus.inProgress || status == SessionStatus.paused;
  bool get isFinished => status == SessionStatus.finished;

  /// Čistý čas vaření bez přestávek.
  int elapsedSeconds(DateTime now) =>
      activeSeconds +
      (resumedAt == null
          ? 0
          : math.max(0, now.difference(resumedAt!).inSeconds));

  static const _keep = Object();

  CookingSession copyWith({
    Object? recipeId = _keep,
    String? recipeTitle,
    Object? versionNumber = _keep,
    String? status,
    DateTime? cookedAt,
    DateTime? updatedAt,
    Object? servings = _keep,
    int? stepIndex,
    int? activeSeconds,
    Object? resumedAt = _keep,
    List<CookTimer>? timers,
    Object? actualMinutes = _keep,
    List<String>? actualTemperatures,
    List<RecipePhoto>? photos,
    Object? rating = _keep,
    String? notes,
    String? wentWell,
    String? toImprove,
  }) => CookingSession(
    id: id,
    recipeId: identical(recipeId, _keep) ? this.recipeId : recipeId as String?,
    recipeTitle: recipeTitle ?? this.recipeTitle,
    versionNumber: identical(versionNumber, _keep)
        ? this.versionNumber
        : versionNumber as int?,
    status: status ?? this.status,
    cookedAt: cookedAt ?? this.cookedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    servings: identical(servings, _keep) ? this.servings : servings as double?,
    stepIndex: stepIndex ?? this.stepIndex,
    activeSeconds: activeSeconds ?? this.activeSeconds,
    resumedAt: identical(resumedAt, _keep)
        ? this.resumedAt
        : resumedAt as DateTime?,
    timers: timers ?? this.timers,
    actualMinutes: identical(actualMinutes, _keep)
        ? this.actualMinutes
        : actualMinutes as int?,
    actualTemperatures: actualTemperatures ?? this.actualTemperatures,
    photos: photos ?? this.photos,
    rating: identical(rating, _keep) ? this.rating : rating as double?,
    notes: notes ?? this.notes,
    wentWell: wentWell ?? this.wentWell,
    toImprove: toImprove ?? this.toImprove,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'recipe_id': ?recipeId,
    'recipe_title': recipeTitle,
    'version_number': ?versionNumber,
    'status': status,
    'cooked_at': _iso(cookedAt),
    'updated_at': _iso(updatedAt),
    'servings': ?servings,
    'step_index': stepIndex,
    'active_seconds': activeSeconds,
    'resumed_at': ?_iso(resumedAt),
    'timers': [for (final timer in timers) timer.toJson()],
    'actual_minutes': ?actualMinutes,
    'actual_temperatures': actualTemperatures,
    'photos': [for (final photo in photos) photo.toJson()],
    'rating': ?rating,
    'notes': notes,
    'went_well': wentWell,
    'to_improve': toImprove,
  };

  factory CookingSession.fromJson(Map<String, dynamic> json) {
    final fallback = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return CookingSession(
      id: json['id'] as String? ?? '',
      recipeId: json['recipe_id'] as String?,
      recipeTitle: json['recipe_title'] as String? ?? '',
      versionNumber: (json['version_number'] as num?)?.toInt(),
      status: json['status'] as String? ?? SessionStatus.finished,
      cookedAt: _date(json['cooked_at']) ?? fallback,
      updatedAt: _date(json['updated_at']) ?? fallback,
      servings: (json['servings'] as num?)?.toDouble(),
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      activeSeconds: (json['active_seconds'] as num?)?.toInt() ?? 0,
      resumedAt: _date(json['resumed_at']),
      timers: [
        if (json['timers'] is List)
          for (final item in json['timers'] as List)
            if (item is Map)
              CookTimer.fromJson(Map<String, dynamic>.from(item)),
      ],
      actualMinutes: (json['actual_minutes'] as num?)?.toInt(),
      actualTemperatures: _strings(json['actual_temperatures']),
      photos: [
        if (json['photos'] is List)
          for (final item in json['photos'] as List)
            if (item is Map && item['id'] is String)
              RecipePhoto.fromJson(Map<String, dynamic>.from(item)),
      ],
      rating: (json['rating'] as num?)?.toDouble(),
      notes: json['notes'] as String? ?? '',
      wentWell: json['went_well'] as String? ?? '',
      toImprove: json['to_improve'] as String? ?? '',
    );
  }
}

// -------------------------------------------------------------- plán jídel

/// Druh jídla v plánu (shodné se sloupcem `meal_plans.meal_type`).
abstract final class MealType {
  static const breakfast = 'breakfast';
  static const lunch = 'lunch';
  static const dinner = 'dinner';

  static const all = [breakfast, lunch, dinner];

  static String label(String type) => switch (type) {
    breakfast => 'Snídaně',
    lunch => 'Oběd',
    _ => 'Večeře',
  };
}

/// Den ve tvaru `2026-11-15` – bez času a časového pásma.
String dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Pondělí týdne, do kterého [date] patří.
DateTime weekStart(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

/// Jedno naplánované jídlo.
class MealPlanEntry {
  const MealPlanEntry({
    required this.id,
    required this.day,
    required this.mealType,
    required this.updatedAt,
    this.recipeId,
    this.title = '',
    this.note = '',
    this.servings,
    this.ownerId,
    this.householdId,
  });

  final String id;

  /// Den ve tvaru [dayKey].
  final String day;
  final String mealType;
  final String? recipeId;

  /// Název jídla (u receptu jeho název v době plánování).
  final String title;
  final String note;

  /// Na kolik porcí / kusů se má vařit (`null` = podle receptu).
  final double? servings;

  /// Kdo jídlo naplánoval a s jakou domácností je plán sdílený (ze serveru).
  final String? ownerId;
  final String? householdId;
  final DateTime updatedAt;

  MealPlanEntry copyWith({
    String? day,
    String? mealType,
    String? recipeId,
    String? title,
    String? note,
    double? servings,
    DateTime? updatedAt,
  }) => MealPlanEntry(
    id: id,
    day: day ?? this.day,
    mealType: mealType ?? this.mealType,
    recipeId: recipeId ?? this.recipeId,
    title: title ?? this.title,
    note: note ?? this.note,
    servings: servings ?? this.servings,
    ownerId: ownerId,
    householdId: householdId,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'day': day,
    'meal_type': mealType,
    'recipe_id': ?recipeId,
    'title': title,
    'note': note,
    'servings': ?servings,
    'owner_id': ?ownerId,
    'household_id': ?householdId,
    'updated_at': _iso(updatedAt),
  };

  factory MealPlanEntry.fromJson(Map<String, dynamic> json) => MealPlanEntry(
    id: json['id'] as String? ?? '',
    day: json['day'] as String? ?? '',
    mealType: json['meal_type'] as String? ?? MealType.dinner,
    recipeId: json['recipe_id'] as String?,
    title: json['title'] as String? ?? '',
    note: json['note'] as String? ?? '',
    servings: (json['servings'] as num?)?.toDouble(),
    ownerId: json['owner_id'] as String?,
    householdId: json['household_id'] as String?,
    updatedAt:
        _date(json['updated_at']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

// ---------------------------------------------------------- nákupní seznam

/// Položka nákupního seznamu.
class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.quantity,
    this.unit = '',
    this.checked = false,
    this.sources = const [],
  });

  final String id;
  final String name;
  final double? quantity;
  final String unit;

  /// Už je v košíku.
  final bool checked;

  /// Názvy receptů, ze kterých položka pochází (prázdné = přidáno ručně).
  final List<String> sources;
  final DateTime createdAt;
  final DateTime updatedAt;

  static const _keep = Object();

  ShoppingItem copyWith({
    String? name,
    Object? quantity = _keep,
    String? unit,
    bool? checked,
    List<String>? sources,
    DateTime? updatedAt,
  }) => ShoppingItem(
    id: id,
    name: name ?? this.name,
    quantity: identical(quantity, _keep) ? this.quantity : quantity as double?,
    unit: unit ?? this.unit,
    checked: checked ?? this.checked,
    sources: sources ?? this.sources,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'quantity': ?quantity,
    'unit': unit,
    'checked': checked,
    'sources': sources,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
  };

  factory ShoppingItem.fromJson(Map<String, dynamic> json) {
    final fallback = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return ShoppingItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      quantity: (json['quantity'] as num?)?.toDouble(),
      unit: json['unit'] as String? ?? '',
      checked: json['checked'] == true,
      sources: _strings(json['sources']),
      createdAt: _date(json['created_at']) ?? fallback,
      updatedAt: _date(json['updated_at']) ?? fallback,
    );
  }
}

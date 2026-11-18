import 'package:flutter/foundation.dart';

import 'recipe.dart';

/// Chyba při volání AI – [message] je česká zpráva pro uživatele.
class AiException implements Exception {
  const AiException(this.message, {this.code = 'unknown', this.status});

  final String message;
  final String code;
  final int? status;

  /// Server AI ještě nemá nastavený klíč OpenAI.
  bool get notConfigured => code == 'ai_not_configured';

  /// Funkce „ai“ na serveru vůbec není nasazená.
  bool get notDeployed => code == 'not_deployed';

  bool get limitReached => code == 'daily_limit' || code == 'search_limit';

  @override
  String toString() => message;
}

List<String> _strings(Object? value) => [
  for (final item in (value as List?) ?? const [])
    if (item != null && item.toString().trim().isNotEmpty)
      item.toString().trim(),
];

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

/// Odkaz na webovou stránku, ze které AI čerpala.
@immutable
class AiSource {
  const AiSource({required this.url, this.title = ''});

  final String url;
  final String title;

  /// Název webu bez „www.“, např. „recepty.cz“.
  String get host {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  String get label => title.isEmpty ? host : title;

  Map<String, dynamic> toJson() => {'url': url, 'title': title};

  static AiSource? tryParse(Object? value) {
    final json = _map(value);
    final url = (json?['url'] as String?)?.trim() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      return null;
    }
    if (uri.host.isEmpty) return null;
    return AiSource(url: url, title: (json?['title'] as String?) ?? '');
  }

  static List<AiSource> listFrom(Object? value) => [
    for (final item in (value as List?) ?? const [])
      if (tryParse(item) case final source?) source,
  ];
}

/// Jedna navržená změna receptu a její důvod.
@immutable
class AiChange {
  const AiChange({required this.what, this.why = ''});

  final String what;
  final String why;

  static List<AiChange> listFrom(Object? value) => [
    for (final item in (value as List?) ?? const [])
      if (_map(item) case final json?)
        if (((json['what'] as String?) ?? '').trim().isNotEmpty)
          AiChange(
            what: (json['what'] as String).trim(),
            why: ((json['why'] as String?) ?? '').trim(),
          ),
  ];
}

@immutable
class DraftIngredient {
  const DraftIngredient({
    required this.name,
    this.quantity,
    this.unit = '',
    this.note = '',
  });

  final String name;
  final double? quantity;
  final String unit;
  final String note;
}

@immutable
class DraftStep {
  const DraftStep({
    required this.instruction,
    this.durationMinutes,
    this.temperatureC,
  });

  final String instruction;
  final int? durationMinutes;
  final double? temperatureC;
}

/// Návrh receptu od AI. Do kuchařky se dostane až po potvrzení uživatelem.
@immutable
class RecipeDraft {
  const RecipeDraft({
    required this.title,
    this.description = '',
    this.category = '',
    this.servings = 4,
    this.prepMinutes = 0,
    this.cookMinutes = 0,
    this.temperatures = const [],
    this.equipment = const [],
    this.notes = '',
    this.ingredients = const [],
    this.steps = const [],
  });

  final String title;
  final String description;
  final String category;
  final double servings;
  final int prepMinutes;
  final int cookMinutes;
  final List<String> temperatures;
  final List<String> equipment;
  final String notes;
  final List<DraftIngredient> ingredients;
  final List<DraftStep> steps;

  /// Přečte návrh ze serveru. Vrací `null`, když chybí název.
  static RecipeDraft? tryParse(Object? value) {
    final json = _map(value);
    if (json == null) return null;
    final title = ((json['title'] as String?) ?? '').trim();
    if (title.isEmpty) return null;
    final servings = (json['servings'] as num?)?.toDouble() ?? 4;
    return RecipeDraft(
      title: title,
      description: ((json['description'] as String?) ?? '').trim(),
      category: ((json['category'] as String?) ?? '').trim(),
      servings: servings > 0 ? servings : 4,
      prepMinutes: _nonNegative(json['prep_minutes']),
      cookMinutes: _nonNegative(json['cook_minutes']),
      temperatures: _strings(json['temperatures']),
      equipment: _strings(json['equipment']),
      notes: ((json['notes'] as String?) ?? '').trim(),
      ingredients: [
        for (final item in (json['ingredients'] as List?) ?? const [])
          if (_map(item) case final row?)
            if (((row['name'] as String?) ?? '').trim().isNotEmpty)
              DraftIngredient(
                name: (row['name'] as String).trim(),
                quantity: _positive(row['quantity']),
                unit: ((row['unit'] as String?) ?? '').trim(),
                note: ((row['note'] as String?) ?? '').trim(),
              ),
      ],
      steps: [
        for (final item in (json['steps'] as List?) ?? const [])
          if (_map(item) case final row?)
            if (((row['instruction'] as String?) ?? '').trim().isNotEmpty)
              DraftStep(
                instruction: (row['instruction'] as String).trim(),
                durationMinutes: _positive(row['duration_minutes'])?.round(),
                temperatureC: (row['temperature_c'] as num?)?.toDouble(),
              ),
      ],
    );
  }

  static int _nonNegative(Object? value) {
    final number = (value as num?)?.round() ?? 0;
    return number < 0 ? 0 : number;
  }

  static double? _positive(Object? value) {
    final number = (value as num?)?.toDouble();
    return number == null || number <= 0 ? null : number;
  }

  /// Nový recept z návrhu. [newId] dodává identifikátory řádků.
  Recipe toRecipe({
    required String Function() newId,
    required DateTime now,
    String? ownerId,
    String? sourceUrl,
    String extraNotes = '',
  }) => Recipe(
    id: newId(),
    ownerId: ownerId,
    title: title,
    description: description,
    category: category,
    servings: servings,
    prepMinutes: prepMinutes,
    cookMinutes: cookMinutes,
    temperatures: temperatures,
    equipment: equipment,
    notes: _joinNotes(notes, extraNotes),
    sourceUrl: sourceUrl,
    createdAt: now,
    updatedAt: now,
    ingredients: _ingredients(newId),
    steps: _steps(newId),
  );

  /// Přepíše obsah existujícího receptu návrhem. Fotografie, hodnocení,
  /// oblíbené a vlastnictví zůstávají; uložením vznikne nová verze.
  Recipe applyTo(
    Recipe recipe, {
    required String Function() newId,
    String extraNotes = '',
  }) => recipe.copyWith(
    title: title,
    description: description,
    category: category.isEmpty ? recipe.category : category,
    servings: servings,
    prepMinutes: prepMinutes,
    cookMinutes: cookMinutes,
    totalMinutes: 0,
    temperatures: temperatures,
    equipment: equipment,
    notes: _joinNotes(notes, extraNotes),
    ingredients: _ingredients(newId),
    steps: _steps(newId),
  );

  List<Ingredient> _ingredients(String Function() newId) => [
    for (final item in ingredients)
      Ingredient(
        id: newId(),
        name: item.name,
        quantity: item.quantity,
        unit: item.unit,
        note: item.note,
      ),
  ];

  List<RecipeStep> _steps(String Function() newId) => [
    for (final step in steps)
      RecipeStep(
        id: newId(),
        instruction: step.instruction,
        durationMinutes: step.durationMinutes,
        temperatureC: step.temperatureC,
      ),
  ];

  static String _joinNotes(String notes, String extra) {
    if (extra.trim().isEmpty) return notes;
    if (notes.trim().isEmpty) return extra.trim();
    return '${notes.trim()}\n\n${extra.trim()}';
  }
}

/// Podoba uloženého receptu, která se posílá AI (bez fotek a interních polí).
Map<String, dynamic> recipeForAi(Recipe recipe) => {
  'title': recipe.title,
  'description': recipe.description,
  'category': recipe.category,
  'servings': recipe.servings,
  'prep_minutes': recipe.prepMinutes,
  'cook_minutes': recipe.cookMinutes,
  'temperatures': recipe.temperatures,
  'equipment': recipe.equipment,
  'notes': recipe.notes,
  'rating': recipe.rating,
  'ingredients': [
    for (final item in recipe.ingredients)
      {
        'name': item.name,
        'quantity': item.quantity,
        'unit': item.unit,
        'note': item.note,
      },
  ],
  'steps': [
    for (final step in recipe.steps)
      {
        'instruction': step.instruction,
        'duration_minutes': step.durationMinutes,
        'temperature_c': step.temperatureC,
      },
  ],
};

/// Poznámka o zdrojích, která se připojí k receptu vzniklému z internetu.
String sourcesNote(List<AiSource> sources) {
  if (sources.isEmpty) return '';
  final lines = [
    for (final source in sources) '• ${source.label}: ${source.url}',
  ];
  return 'Zdroje:\n${lines.join('\n')}';
}

/// Odpověď AI kuchaře v chatu.
@immutable
class ChatReply {
  const ChatReply({
    required this.conversationId,
    required this.reply,
    this.recipe,
    this.changeSummary = '',
    this.sources = const [],
  });

  final String conversationId;
  final String reply;
  final RecipeDraft? recipe;
  final String changeSummary;
  final List<AiSource> sources;

  factory ChatReply.fromJson(Map<String, dynamic> json) => ChatReply(
    conversationId: (json['conversation_id'] as String?) ?? '',
    reply: (json['reply'] as String?) ?? '',
    recipe: RecipeDraft.tryParse(json['recipe']),
    changeSummary: (json['change_summary'] as String?) ?? '',
    sources: AiSource.listFrom(json['sources']),
  );
}

/// Recept nalezený na internetu.
@immutable
class WebRecipe {
  const WebRecipe({
    required this.title,
    required this.url,
    this.site = '',
    this.summary = '',
    this.ingredients = const [],
    this.method = '',
    this.temperatures = const [],
    this.totalMinutes,
    this.rating,
    this.ratingCount,
    this.verified = true,
  });

  final String title;
  final String url;
  final String site;
  final String summary;
  final List<String> ingredients;
  final String method;
  final List<String> temperatures;
  final int? totalMinutes;
  final double? rating;
  final int? ratingCount;

  /// `true`, když vyhledávání vrátilo přesně tuto stránku; `false`, když
  /// jen stejný web (odkaz je pak potřeba brát s rezervou).
  final bool verified;

  static WebRecipe? tryParse(Object? value) {
    final json = _map(value);
    final source = AiSource.tryParse(value);
    final title = ((json?['title'] as String?) ?? '').trim();
    if (json == null || source == null || title.isEmpty) return null;
    return WebRecipe(
      title: title,
      url: source.url,
      site: ((json['site'] as String?) ?? '').trim().isEmpty
          ? source.host
          : (json['site'] as String).trim(),
      summary: ((json['summary'] as String?) ?? '').trim(),
      ingredients: _strings(json['ingredients']),
      method: ((json['method'] as String?) ?? '').trim(),
      temperatures: _strings(json['temperatures']),
      totalMinutes: (json['total_minutes'] as num?)?.round(),
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: (json['rating_count'] as num?)?.round(),
      verified: json['verified'] != false,
    );
  }

  /// Podoba pro akci „Vytvořit naši verzi“.
  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'ingredients': ingredients,
    'method': method,
    'temperatures': temperatures,
    'total_minutes': totalMinutes,
  };
}

/// Výsledek hledání receptů na internetu včetně porovnání.
@immutable
class SearchOutcome {
  const SearchOutcome({
    required this.results,
    this.compareIngredients = '',
    this.compareMethod = '',
    this.compareTemperatures = '',
    this.compareRatings = '',
    this.droppedUnverified = 0,
  });

  final List<WebRecipe> results;
  final String compareIngredients;
  final String compareMethod;
  final String compareTemperatures;
  final String compareRatings;

  /// Kolik výsledků server zahodil, protože je nešlo ověřit odkazem.
  final int droppedUnverified;

  bool get hasComparison =>
      compareIngredients.isNotEmpty ||
      compareMethod.isNotEmpty ||
      compareTemperatures.isNotEmpty ||
      compareRatings.isNotEmpty;

  factory SearchOutcome.fromJson(Map<String, dynamic> json) {
    final comparison = _map(json['comparison']) ?? const <String, dynamic>{};
    return SearchOutcome(
      results: [
        for (final item in (json['results'] as List?) ?? const [])
          if (WebRecipe.tryParse(item) case final recipe?) recipe,
      ],
      compareIngredients: (comparison['ingredients'] as String?) ?? '',
      compareMethod: (comparison['method'] as String?) ?? '',
      compareTemperatures: (comparison['temperatures_times'] as String?) ?? '',
      compareRatings: (comparison['ratings'] as String?) ?? '',
      droppedUnverified: (json['dropped_unverified'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Návrh receptu s vysvětlením – vylepšení, „naše verze“ nebo import.
@immutable
class DraftProposal {
  const DraftProposal({
    required this.recipe,
    this.summary = '',
    this.changes = const [],
    this.sources = const [],
    this.sourceUrl,
  });

  final RecipeDraft recipe;
  final String summary;
  final List<AiChange> changes;
  final List<AiSource> sources;

  /// Adresa stránky, ze které byl recept importován.
  final String? sourceUrl;

  DraftProposal withSources(List<AiSource> sources) => DraftProposal(
    recipe: recipe,
    summary: summary,
    changes: changes,
    sources: sources,
    sourceUrl: sourceUrl,
  );

  /// Shrnutí změn pro historii verzí.
  String get changeSummary {
    if (changes.isEmpty) return summary;
    return changes.map((c) => c.what).join('; ');
  }

  /// Přečte odpověď akcí `improve`, `our_version` a `import`.
  factory DraftProposal.fromJson(Map<String, dynamic> json) {
    final recipe = RecipeDraft.tryParse(json['recipe']);
    if (recipe == null) {
      throw const AiException(
        'AI nevrátila použitelný recept.',
        code: 'ai_invalid',
      );
    }
    return DraftProposal(
      recipe: recipe,
      summary:
          ((json['summary'] as String?) ?? (json['message'] as String?) ?? '')
              .trim(),
      changes: AiChange.listFrom(json['changes']),
      sources: AiSource.listFrom(json['sources']),
      sourceUrl: json['source_url'] as String?,
    );
  }
}

/// Zpráva v uložené konverzaci s AI.
@immutable
class AiMessage {
  const AiMessage({
    required this.fromUser,
    required this.text,
    this.proposal,
    this.changeSummary = '',
    this.sources = const [],
    this.hadPhoto = false,
    this.attachedRecipeTitle,
  });

  final bool fromUser;
  final String text;
  final RecipeDraft? proposal;
  final String changeSummary;
  final List<AiSource> sources;
  final bool hadPhoto;
  final String? attachedRecipeTitle;

  /// Řádek tabulky `ai_messages`.
  factory AiMessage.fromRow(Map<String, dynamic> row) {
    RecipeDraft? proposal;
    var changeSummary = '';
    var sources = const <AiSource>[];
    var hadPhoto = false;
    String? attachedTitle;
    for (final item in (row['attachments'] as List?) ?? const []) {
      final attachment = _map(item);
      switch (attachment?['type']) {
        case 'recipe_proposal':
          proposal = RecipeDraft.tryParse(attachment!['recipe']);
          changeSummary = (attachment['change_summary'] as String?) ?? '';
        case 'sources':
          sources = AiSource.listFrom(attachment!['sources']);
        case 'photo':
          hadPhoto = true;
        case 'recipe':
          attachedTitle = attachment!['title'] as String?;
      }
    }
    return AiMessage(
      fromUser: row['role'] == 'user',
      text: (row['content'] as String?) ?? '',
      proposal: proposal,
      changeSummary: changeSummary,
      sources: sources,
      hadPhoto: hadPhoto,
      attachedRecipeTitle: attachedTitle,
    );
  }
}

@immutable
class AiConversation {
  const AiConversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.recipeId,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String? recipeId;

  factory AiConversation.fromRow(Map<String, dynamic> row) => AiConversation(
    id: row['id'] as String,
    title: ((row['title'] as String?) ?? '').trim().isEmpty
        ? 'Rozhovor'
        : (row['title'] as String).trim(),
    updatedAt:
        DateTime.tryParse((row['updated_at'] as String?) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    recipeId: row['recipe_id'] as String?,
  );
}

/// Položka kuchyňského vybavení nebo chuťová preference (dlouhodobá paměť).
@immutable
class MemoryItem {
  const MemoryItem({
    required this.id,
    required this.label,
    this.detail = '',
    this.kind = '',
    this.enabled = true,
  });

  final String id;
  final String label;
  final String detail;

  /// Druh vybavení („trouba“, „hrnec“…); u preferencí prázdný.
  final String kind;
  final bool enabled;

  factory MemoryItem.equipment(Map<String, dynamic> row) => MemoryItem(
    id: row['id'] as String,
    label: (row['name'] as String?) ?? '',
    kind: (row['kind'] as String?) ?? '',
    detail: [
      ..._strings(row['capabilities']),
      if (((row['notes'] as String?) ?? '').trim().isNotEmpty)
        (row['notes'] as String).trim(),
    ].join(' · '),
  );

  factory MemoryItem.preference(Map<String, dynamic> row) => MemoryItem(
    id: row['id'] as String,
    label: (row['label'] as String?) ?? '',
    enabled: row['enabled'] != false,
  );
}

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'ai_models.dart';
import 'recipe.dart';

/// Spojení se serverovou funkcí „ai“. Oddělené rozhraní kvůli testům.
abstract class AiBackend {
  /// Zavolá funkci a vrátí tělo odpovědi. Při chybě vyhodí [AiException].
  Future<Map<String, dynamic>> call(Map<String, dynamic> body);
}

/// Převede chybovou odpověď funkce na [AiException].
AiException aiErrorFromResponse(int status, Object? details) {
  if (details is Map) {
    final error = details['error'];
    if (error is Map && error['message'] is String) {
      return AiException(
        error['message'] as String,
        code: (error['code'] as String?) ?? 'unknown',
        status: status,
      );
    }
  }
  if (status == 404) {
    return const AiException(
      'Serverová funkce „ai“ ještě není v Supabase nasazená.',
      code: 'not_deployed',
      status: 404,
    );
  }
  if (status == 401 || status == 403) {
    return AiException(
      'Přihlášení vypršelo. Přihlaste se znovu.',
      code: 'unauthorized',
      status: status,
    );
  }
  return AiException(
    'Server AI vrátil chybu $status. Zkuste to za chvíli znovu.',
    code: 'server_error',
    status: status,
  );
}

class SupabaseAiBackend implements AiBackend {
  SupabaseAiBackend(this._client);

  final SupabaseClient _client;

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> body) async {
    try {
      final response = await _client.functions.invoke('ai', body: body);
      final data = response.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const AiException(
        'Server AI vrátil odpověď v neznámém tvaru.',
        code: 'bad_response',
      );
    } on FunctionException catch (error) {
      throw aiErrorFromResponse(error.status, error.details);
    } on SocketException {
      throw const AiException(
        'AI kuchař potřebuje připojení k internetu.',
        code: 'offline',
      );
    } on TimeoutException {
      throw const AiException(
        'Server AI neodpověděl včas. Zkuste to znovu.',
        code: 'timeout',
      );
    } on AiException {
      rethrow;
    } catch (error) {
      throw AiException('Spojení s AI se nepodařilo: $error', code: 'network');
    }
  }
}

/// AI kuchař: chat, hledání na internetu, vylepšování a import receptů.
class AiService {
  AiService(this._backend);

  final AiBackend _backend;

  Future<ChatReply> chat({
    required String message,
    String? conversationId,
    Recipe? recipe,
    String? imageBase64,
  }) async {
    final json = await _backend.call({
      'action': 'chat',
      'message': message,
      'conversation_id': ?conversationId,
      if (recipe != null) ...{
        'recipe': recipeForAi(recipe),
        'recipe_id': recipe.id,
      },
      'image_base64': ?imageBase64,
    });
    return ChatReply.fromJson(json);
  }

  Future<SearchOutcome> search({
    String query = '',
    List<String> ingredients = const [],
    String cuisine = '',
    int? maxMinutes,
    bool useEquipment = false,
    Recipe? similarTo,
    String? imageBase64,
  }) async {
    final json = await _backend.call({
      'action': 'search',
      if (query.trim().isNotEmpty) 'query': query.trim(),
      if (ingredients.isNotEmpty) 'ingredients': ingredients,
      if (cuisine.trim().isNotEmpty) 'cuisine': cuisine.trim(),
      'max_minutes': ?maxMinutes,
      if (useEquipment) 'use_equipment': true,
      if (similarTo != null) 'similar_to': recipeForAi(similarTo),
      'image_base64': ?imageBase64,
    });
    final outcome = SearchOutcome.fromJson(json);
    if (outcome.results.isEmpty) {
      throw const AiException(
        'Vyhledávání nevrátilo žádný použitelný recept.',
        code: 'no_results',
      );
    }
    return outcome;
  }

  /// „Vytvořit naši verzi“ z vybraných nalezených receptů.
  Future<DraftProposal> ourVersion(
    List<WebRecipe> sources, {
    String wish = '',
  }) async {
    final json = await _backend.call({
      'action': 'our_version',
      'sources': [for (final source in sources) source.toJson()],
      if (wish.trim().isNotEmpty) 'wish': wish.trim(),
    });
    return DraftProposal.fromJson(json);
  }

  /// Návrh vylepšení uloženého receptu; [withWeb] ho porovná s internetem.
  Future<DraftProposal> improve(
    Recipe recipe, {
    String instruction = '',
    bool withWeb = false,
  }) async {
    final json = await _backend.call({
      'action': 'improve',
      'recipe': recipeForAi(recipe),
      if (instruction.trim().isNotEmpty) 'instruction': instruction.trim(),
      if (withWeb) 'with_web': true,
    });
    return DraftProposal.fromJson(json);
  }

  /// Převede text, webovou stránku nebo fotografii na návrh receptu.
  Future<DraftProposal> importRecipe({
    String? text,
    String? url,
    String? imageBase64,
  }) async {
    final json = await _backend.call({
      'action': 'import',
      if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
      if (url != null && url.trim().isNotEmpty) 'url': url.trim(),
      'image_base64': ?imageBase64,
    });
    return DraftProposal.fromJson(json);
  }
}

/// Doplní adrese chybějící „https://“ a ověří, že jde o webový odkaz.
/// Vrací `null`, když text adresou není.
String? normalizeWebUrl(String input) {
  var text = input.trim();
  if (text.isEmpty || text.contains(' ')) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
    return null;
  }
  if (!uri.host.contains('.')) return null;
  return uri.toString();
}

/// Rozdělí „kuře, smetana; paprika“ na jednotlivé suroviny.
List<String> splitIngredients(String input) => [
  for (final part in input.split(RegExp(r'[,;\n]')))
    if (part.trim().isNotEmpty) part.trim(),
];

/// Uložené konverzace s AI (tabulky `ai_conversations` a `ai_messages`).
class AiHistoryStore {
  AiHistoryStore(this._client);

  final SupabaseClient _client;

  Future<List<AiConversation>> conversations() async {
    final rows = await _client
        .from('ai_conversations')
        .select('id,title,updated_at,recipe_id')
        .order('updated_at', ascending: false)
        .limit(100);
    return [for (final row in rows) AiConversation.fromRow(row)];
  }

  Future<List<AiMessage>> messages(String conversationId) async {
    final rows = await _client
        .from('ai_messages')
        .select('role,content,attachments,created_at')
        .eq('conversation_id', conversationId)
        .order('created_at')
        .limit(200);
    return [
      for (final row in rows)
        if (row['role'] == 'user' || row['role'] == 'assistant')
          AiMessage.fromRow(row),
    ];
  }

  Future<void> delete(String conversationId) async {
    await _client.from('ai_conversations').delete().eq('id', conversationId);
  }
}

/// Kuchyňské vybavení a chuťové preference – dlouhodobá paměť AI.
class KitchenStore {
  KitchenStore(this._client);

  final SupabaseClient _client;

  Future<List<MemoryItem>> equipment() async {
    final rows = await _client
        .from('kitchen_equipment')
        .select('id,name,kind,capabilities,notes')
        .order('position')
        .order('created_at');
    return [for (final row in rows) MemoryItem.equipment(row)];
  }

  Future<List<MemoryItem>> preferences() async {
    final rows = await _client
        .from('user_preferences')
        .select('id,label,enabled')
        .order('position')
        .order('created_at');
    return [for (final row in rows) MemoryItem.preference(row)];
  }

  Future<void> addEquipment(String name, {String notes = ''}) async {
    await _client.from('kitchen_equipment').insert({
      'name': name.trim(),
      'notes': notes.trim(),
      'position': 1000,
    });
  }

  Future<void> deleteEquipment(String id) async {
    await _client.from('kitchen_equipment').delete().eq('id', id);
  }

  Future<void> addPreference(String label) async {
    await _client.from('user_preferences').insert({
      'label': label.trim(),
      'position': 1000,
    });
  }

  Future<void> setPreferenceEnabled(String id, bool enabled) async {
    await _client
        .from('user_preferences')
        .update({'enabled': enabled})
        .eq('id', id);
  }

  Future<void> deletePreference(String id) async {
    await _client.from('user_preferences').delete().eq('id', id);
  }

  /// Doplní výchozí vybavení a preference Pavla Hinka (jen když chybí).
  Future<void> seedDefaults() async {
    await _client.rpc('seed_hink_defaults');
  }
}

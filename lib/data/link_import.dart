import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'ai_models.dart';

/// Recept z webové stránky nebo popisu videa bez AI. Stránku stáhne
/// a přečte server HINKredience (stejný nástroj jako pro ChatGPT), takže to
/// funguje i ve webové verzi a nic se neplatí.
class LinkImporter {
  LinkImporter(this._client);

  final SupabaseClient _client;

  Future<DraftProposal> fromUrl(String url) async {
    final response = await _client.functions.invoke(
      'mcp',
      headers: const {'Accept': 'application/json, text/event-stream'},
      body: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'import_recipe_from_url',
          'arguments': {'url': url},
        },
      },
    );
    final data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    final result = data is Map ? data['result'] : null;
    if (result is! Map) {
      throw Exception('Server odpověděl neočekávaně. Zkuste to znovu.');
    }
    if (result['isError'] == true) {
      final content = result['content'];
      final message = content is List && content.isNotEmpty
          ? (content.first as Map)['text'] as String? ?? ''
          : '';
      throw Exception(
        message.isEmpty ? 'Recept se nepodařilo načíst.' : message,
      );
    }
    final structured = result['structuredContent'];
    final recipe = RecipeDraft.tryParse(
      structured is Map ? structured['recipe'] : null,
    );
    if (recipe == null) {
      throw Exception('Na stránce jsem recept nenašel.');
    }
    final method = structured is Map ? structured['method'] : null;
    return DraftProposal(
      recipe: recipe,
      summary: method == 'structured'
          ? 'Načteno ze stránky bez AI.'
          : 'Načteno z popisu bez AI – zkontrolujte suroviny a postup.',
      sourceUrl: url,
    );
  }
}

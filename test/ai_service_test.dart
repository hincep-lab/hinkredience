import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/data/ai_models.dart';
import 'package:hinkredience/data/ai_service.dart';
import 'package:hinkredience/data/draft_saver.dart';

import 'ai_models_test.dart' show draftJson;
import 'support.dart';

/// Maketa serverové funkce: zaznamená požadavky a vrací připravené odpovědi.
class FakeAiBackend implements AiBackend {
  FakeAiBackend(this.respond);

  final Map<String, dynamic> Function(Map<String, dynamic> body) respond;
  final requests = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> body) async {
    requests.add(body);
    return respond(body);
  }
}

void main() {
  group('AiService', () {
    test('chat posílá přiložený recept a čte návrh', () async {
      final backend = FakeAiBackend(
        (body) => {
          'conversation_id': 'k1',
          'reply': 'Hotovo, žluťoučký kůň.',
          'recipe': draftJson(),
          'change_summary': 'Dvojnásobek porcí',
          'sources': [
            {'url': 'https://a.cz/x', 'title': 'A'},
          ],
        },
      );
      final reply = await AiService(backend)
          .chat(message: 'Zdvojnásob to.', recipe: sampleRecipe());
      expect(reply.conversationId, 'k1');
      expect(reply.reply, 'Hotovo, žluťoučký kůň.');
      expect(reply.recipe!.title, 'Svíčková na smetaně');
      expect(reply.changeSummary, 'Dvojnásobek porcí');
      expect(reply.sources.single.url, 'https://a.cz/x');

      final request = backend.requests.single;
      expect(request['action'], 'chat');
      expect(request['recipe_id'], 'recipe-1');
      expect((request['recipe'] as Map)['title'], 'Žebra BBQ');
      expect(request.containsKey('conversation_id'), isFalse);
      expect(request.containsKey('image_base64'), isFalse);
    });

    test('chat navazuje na konverzaci a posílá fotografii', () async {
      final backend = FakeAiBackend(
        (body) => {'conversation_id': 'k1', 'reply': 'Vidím guláš.'},
      );
      final reply = await AiService(backend)
          .chat(message: '', conversationId: 'k1', imageBase64: 'QUJD');
      expect(reply.recipe, isNull);
      expect(backend.requests.single['conversation_id'], 'k1');
      expect(backend.requests.single['image_base64'], 'QUJD');
      expect(backend.requests.single.containsKey('recipe'), isFalse);
    });

    test('hledání posílá jen vyplněná upřesnění', () async {
      final backend = FakeAiBackend(
        (body) => {
          'results': [
            {
              'title': 'Svíčková',
              'url': 'https://recepty.cz/s',
              'verified': true,
            },
          ],
          'comparison': <String, dynamic>{},
        },
      );
      await AiService(backend).search(
        query: ' svíčková ',
        ingredients: ['hovězí', 'smetana'],
        maxMinutes: 120,
        useEquipment: true,
      );
      expect(backend.requests.single, {
        'action': 'search',
        'query': 'svíčková',
        'ingredients': ['hovězí', 'smetana'],
        'max_minutes': 120,
        'use_equipment': true,
      });
    });

    test(
      'hledání bez použitelných výsledků je chyba, ne prázdný seznam',
      () async {
        final backend = FakeAiBackend(
          (body) => {'results': <Object>[], 'comparison': <String, dynamic>{}},
        );
        await expectLater(
          AiService(backend).search(query: 'svíčková'),
          throwsA(
            isA<AiException>().having((e) => e.code, 'code', 'no_results'),
          ),
        );
      },
    );

    test('naše verze posílá vybrané recepty i s odkazy', () async {
      final backend = FakeAiBackend(
        (body) => {
          'summary': 'Spojeno.',
          'changes': <Object>[],
          'recipe': draftJson(),
          'sources': [
            {'url': 'https://recepty.cz/s', 'title': 'Svíčková'},
          ],
        },
      );
      final proposal = await AiService(backend).ourVersion(const [
        WebRecipe(
          title: 'Svíčková',
          url: 'https://recepty.cz/s',
          method: 'Péct.',
        ),
      ]);
      expect(proposal.sources.single.url, 'https://recepty.cz/s');
      final sources = backend.requests.single['sources'] as List;
      expect((sources.single as Map)['url'], 'https://recepty.cz/s');
      expect((sources.single as Map)['method'], 'Péct.');
    });

    test('vylepšení a import předávají správné akce', () async {
      final backend = FakeAiBackend(
        (body) => {'summary': '', 'changes': <Object>[], 'recipe': draftJson()},
      );
      final service = AiService(backend);
      await service.improve(
        sampleRecipe(),
        instruction: ' víc chuti ',
        withWeb: true,
      );
      await service.importRecipe(url: ' https://recepty.cz/gulas ');
      await service.importRecipe(text: 'Guláš: 800 g hovězího…');
      expect(backend.requests[0], containsPair('action', 'improve'));
      expect(backend.requests[0], containsPair('instruction', 'víc chuti'));
      expect(backend.requests[0], containsPair('with_web', true));
      expect(backend.requests[1], {
        'action': 'import',
        'url': 'https://recepty.cz/gulas',
      });
      expect(backend.requests[2], {
        'action': 'import',
        'text': 'Guláš: 800 g hovězího…',
      });
    });
  });

  group('chyby serveru', () {
    test('zpráva a kód z těla odpovědi', () {
      final error = aiErrorFromResponse(503, {
        'error': {'code': 'ai_not_configured', 'message': 'Chybí klíč.'},
      });
      expect(error.message, 'Chybí klíč.');
      expect(error.notConfigured, isTrue);
      expect(error.status, 503);

      final limit = aiErrorFromResponse(429, {
        'error': {'code': 'daily_limit', 'message': 'Limit vyčerpán.'},
      });
      expect(limit.limitReached, isTrue);
    });

    test('nenasazená funkce, vypršelé přihlášení a neznámá chyba', () {
      expect(aiErrorFromResponse(404, 'Not Found').notDeployed, isTrue);
      expect(aiErrorFromResponse(401, null).code, 'unauthorized');
      final unknown = aiErrorFromResponse(500, '<html>');
      expect(unknown.code, 'server_error');
      expect(unknown.message, contains('500'));
    });
  });

  group('uložení návrhu', () {
    late TestEnvironment env;

    setUp(() async => env = await TestEnvironment.create());
    tearDown(() => env.dispose());

    DraftProposal proposal({List<AiSource> sources = const []}) =>
        DraftProposal.fromJson({
          'summary': 'Nižší teplota.',
          'changes': [
            {'what': 'Trouba 150 °C', 'why': 'Šťavnatější'},
          ],
          'recipe': draftJson(),
        }).withSources(sources);

    test('nový recept vznikne jako verze 1 a čeká na synchronizaci', () async {
      final repository = await env.repository();
      final saved = await saveDraftAsNew(
        repository,
        proposal(
          sources: const [
            AiSource(url: 'https://recepty.cz/s', title: 'Svíčková'),
          ],
        ),
        ownerId: 'pavel',
      );
      expect(saved.currentVersion, 1);
      expect(saved.ownerId, 'pavel');
      expect(saved.sourceUrl, 'https://recepty.cz/s');
      expect(
        saved.notes,
        contains('Zdroje:\n• Svíčková: https://recepty.cz/s'),
      );

      final stored = await repository.getById(saved.id);
      expect(stored!.title, 'Svíčková na smetaně');
      expect(stored.ingredients, hasLength(3));
      expect(await repository.dirtyCount(), 1);
      expect(await repository.versions(saved.id), hasLength(1));
    });

    test('úprava vytvoří novou verzi a původní zůstane v historii', () async {
      final repository = await env.repository();
      final original = await repository.create(sampleRecipe(ownerId: 'pavel'));
      env.advance(const Duration(minutes: 5));

      final updated = await saveDraftAsVersion(
        repository,
        original,
        proposal(),
      );
      expect(updated.id, original.id);
      expect(updated.currentVersion, 2);
      expect(updated.title, 'Svíčková na smetaně');

      final versions = await repository.versions(original.id);
      expect(versions, hasLength(2));
      expect(versions.first.versionNumber, 2);
      expect(versions.first.changeSummary, 'AI: Trouba 150 °C');
      expect(versions.last.snapshot['title'], 'Žebra BBQ');
      expect(
        (versions.last.snapshot['ingredients'] as List).length,
        4,
        reason: 'původní suroviny jsou v historii celé',
      );
    });
  });
}

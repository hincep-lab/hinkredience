import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/data/ai_models.dart';
import 'package:hinkredience/data/ai_service.dart';

import 'support.dart';

Map<String, dynamic> draftJson({String title = 'Svíčková na smetaně'}) => {
  'title': title,
  'description': 'Klasika s brusinkami.',
  'category': 'Omáčky',
  'servings': 6,
  'prep_minutes': 30,
  'cook_minutes': 180,
  'temperatures': ['Trouba 160 °C', '  '],
  'equipment': ['Litinový hrnec'],
  'notes': 'Maso den předem naložit.',
  'ingredients': [
    {'name': 'Hovězí zadní', 'quantity': 800, 'unit': 'g', 'note': ''},
    {
      'name': 'Smetana ke šlehání',
      'quantity': 0.25,
      'unit': 'l',
      'note': '33 %',
    },
    {'name': 'Sůl', 'quantity': null, 'unit': '', 'note': ''},
    {'name': '   ', 'quantity': 1, 'unit': 'ks', 'note': ''},
  ],
  'steps': [
    {
      'instruction': 'Maso osol a opeč.',
      'duration_minutes': 10,
      'temperature_c': null,
    },
    {
      'instruction': 'Peč pod pokličkou.',
      'duration_minutes': 150,
      'temperature_c': 160,
    },
    {'instruction': '', 'duration_minutes': 5, 'temperature_c': null},
  ],
};

void main() {
  group('RecipeDraft', () {
    test('přečte návrh ze serveru a vynechá prázdné řádky', () {
      final draft = RecipeDraft.tryParse(draftJson())!;
      expect(draft.title, 'Svíčková na smetaně');
      expect(draft.servings, 6);
      expect(draft.temperatures, ['Trouba 160 °C']);
      expect(draft.ingredients, hasLength(3));
      expect(draft.ingredients[1].quantity, 0.25);
      expect(draft.ingredients[1].note, '33 %');
      expect(draft.ingredients[2].quantity, isNull);
      expect(draft.steps, hasLength(2));
      expect(draft.steps[1].temperatureC, 160);
      expect(draft.steps[1].durationMinutes, 150);
    });

    test('bez názvu nebo ve špatném tvaru vrací null', () {
      expect(RecipeDraft.tryParse(null), isNull);
      expect(RecipeDraft.tryParse('text'), isNull);
      expect(RecipeDraft.tryParse({'title': '  '}), isNull);
    });

    test('neplatná čísla nahradí rozumnými hodnotami', () {
      final draft = RecipeDraft.tryParse({
        'title': 'Kachna',
        'servings': -2,
        'prep_minutes': -5,
        'ingredients': [
          {'name': 'Kachna', 'quantity': -1},
        ],
        'steps': [
          {'instruction': 'Peč.', 'duration_minutes': 0},
        ],
      })!;
      expect(draft.servings, 4);
      expect(draft.prepMinutes, 0);
      expect(draft.ingredients.single.quantity, isNull);
      expect(draft.steps.single.durationMinutes, isNull);
    });

    test('toRecipe vytvoří nový recept s vlastními identifikátory', () {
      var counter = 0;
      final recipe = RecipeDraft.tryParse(draftJson())!.toRecipe(
        newId: () => 'id-${++counter}',
        now: DateTime.utc(2026, 11, 14),
        ownerId: 'pavel',
        sourceUrl: 'https://recepty.cz/svickova',
        extraNotes: 'Zdroje:\n• recepty.cz',
      );
      expect(recipe.id, 'id-1');
      expect(recipe.ownerId, 'pavel');
      expect(recipe.title, 'Svíčková na smetaně');
      expect(recipe.category, 'Omáčky');
      expect(recipe.sourceUrl, 'https://recepty.cz/svickova');
      expect(recipe.notes, 'Maso den předem naložit.\n\nZdroje:\n• recepty.cz');
      expect(recipe.ingredients.map((i) => i.id).toSet(), hasLength(3));
      expect(recipe.steps.first.id, isNot(recipe.ingredients.first.id));
      expect(recipe.effectiveTotalMinutes, 210);
    });

    test('applyTo zachová fotky, hodnocení a vlastníka', () {
      final existing = sampleRecipe(ownerId: 'pavel').copyWith(
        rating: 4.5,
        isFavorite: true,
        totalMinutes: 999,
        photos: const [],
      );
      var counter = 0;
      final updated = RecipeDraft.tryParse(draftJson(title: 'Žebra 2.0'))!
          .applyTo(existing, newId: () => 'n-${++counter}');
      expect(updated.id, existing.id);
      expect(updated.ownerId, 'pavel');
      expect(updated.rating, 4.5);
      expect(updated.isFavorite, isTrue);
      expect(updated.title, 'Žebra 2.0');
      expect(updated.totalMinutes, 0, reason: 'celkový čas se přepočítá');
      expect(updated.ingredients.first.name, 'Hovězí zadní');
      expect(updated.currentVersion, existing.currentVersion);
    });

    test('recipeForAi neposílá fotky ani interní pole', () {
      final json = recipeForAi(sampleRecipe(ownerId: 'pavel'));
      expect(json.containsKey('photos'), isFalse);
      expect(json.containsKey('owner_id'), isFalse);
      expect(json.containsKey('id'), isFalse);
      expect((json['ingredients'] as List).first, {
        'name': 'Vepřová žebra',
        'quantity': 2.0,
        'unit': 'kg',
        'note': '',
      });
      expect(RecipeDraft.tryParse(json)!.steps, hasLength(2));
    });
  });

  group('zdroje a hledání', () {
    test('AiSource přijme jen webové odkazy', () {
      expect(AiSource.tryParse({'url': 'javascript:alert(1)'}), isNull);
      expect(AiSource.tryParse({'url': 'recepty.cz'}), isNull);
      expect(AiSource.tryParse({'title': 'bez adresy'}), isNull);
      final source = AiSource.tryParse({
        'url': 'https://www.recepty.cz/recept/svickova',
        'title': 'Svíčková',
      })!;
      expect(source.host, 'recepty.cz');
      expect(source.label, 'Svíčková');
      expect(const AiSource(url: 'https://a.cz/x').label, 'a.cz');
    });

    test('sourcesNote vypíše odkazy pod sebe', () {
      expect(sourcesNote(const []), '');
      expect(
        sourcesNote(const [
          AiSource(url: 'https://a.cz/x', title: 'Áčko'),
          AiSource(url: 'https://www.b.cz/y'),
        ]),
        'Zdroje:\n• Áčko: https://a.cz/x\n• b.cz: https://www.b.cz/y',
      );
    });

    test('SearchOutcome přečte výsledky, hodnocení a porovnání', () {
      final outcome = SearchOutcome.fromJson({
        'results': [
          {
            'title': 'Svíčková podle babičky',
            'url': 'https://www.recepty.cz/svickova',
            'site': '',
            'summary': 'Poctivá.',
            'ingredients': ['hovězí 800 g'],
            'method': 'Péct.',
            'temperatures': ['160 °C'],
            'total_minutes': 240,
            'rating': 4.7,
            'rating_count': 312,
            'verified': true,
          },
          {
            'title': 'Bez hodnocení',
            'url': 'https://kucharka.cz/a',
            'rating': null,
            'verified': false,
          },
          {'title': 'Bez odkazu'},
          {'title': '', 'url': 'https://x.cz/a'},
        ],
        'comparison': {'ingredients': 'Liší se zeleninou.', 'method': ''},
        'dropped_unverified': 2,
      });
      expect(outcome.results, hasLength(2));
      expect(outcome.results.first.site, 'recepty.cz');
      expect(outcome.results.first.rating, 4.7);
      expect(outcome.results.first.ratingCount, 312);
      expect(outcome.results.last.rating, isNull);
      expect(outcome.results.last.verified, isFalse);
      expect(outcome.hasComparison, isTrue);
      expect(outcome.compareIngredients, 'Liší se zeleninou.');
      expect(outcome.droppedUnverified, 2);
      expect(
        outcome.results.first.toJson()['url'],
        'https://www.recepty.cz/svickova',
      );
    });

    test('DraftProposal: shrnutí změn pro historii verzí', () {
      final proposal = DraftProposal.fromJson({
        'summary': 'Nižší teplota.',
        'changes': [
          {'what': 'Trouba 150 °C', 'why': 'Šťavnatější'},
          {'what': 'Delší odpočinek', 'why': ''},
          {'what': '  ', 'why': 'prázdné'},
        ],
        'recipe': draftJson(),
        'sources': [
          {'url': 'https://a.cz/x', 'title': 'A'},
        ],
      });
      expect(proposal.changes, hasLength(2));
      expect(proposal.changeSummary, 'Trouba 150 °C; Delší odpočinek');
      expect(proposal.sources.single.host, 'a.cz');
      expect(
        () => DraftProposal.fromJson({'recipe': null}),
        throwsA(isA<AiException>()),
      );
    });

    test('import: zpráva a adresa zdroje', () {
      final proposal = DraftProposal.fromJson({
        'recipe': draftJson(),
        'message': 'Zkontroluj množství soli.',
        'source_url': 'https://recepty.cz/gulas',
      });
      expect(proposal.summary, 'Zkontroluj množství soli.');
      expect(proposal.sourceUrl, 'https://recepty.cz/gulas');
      expect(proposal.changeSummary, 'Zkontroluj množství soli.');
    });
  });

  group('konverzace', () {
    test('zpráva z databáze včetně návrhu receptu a zdrojů', () {
      final message = AiMessage.fromRow({
        'role': 'assistant',
        'content': 'Tady je svíčková.',
        'attachments': [
          {
            'type': 'recipe_proposal',
            'recipe': draftJson(),
            'change_summary': 'Méně smetany',
          },
          {
            'type': 'sources',
            'sources': [
              {'url': 'https://a.cz/x', 'title': 'A'},
            ],
          },
          {'type': 'neznámé'},
        ],
      });
      expect(message.fromUser, isFalse);
      expect(message.proposal!.title, 'Svíčková na smetaně');
      expect(message.changeSummary, 'Méně smetany');
      expect(message.sources, hasLength(1));

      final mine = AiMessage.fromRow({
        'role': 'user',
        'content': 'Uprav to.',
        'attachments': [
          {'type': 'recipe', 'title': 'Žebra BBQ'},
          {'type': 'photo'},
        ],
      });
      expect(mine.fromUser, isTrue);
      expect(mine.attachedRecipeTitle, 'Žebra BBQ');
      expect(mine.hadPhoto, isTrue);
    });

    test('konverzace bez názvu dostane výchozí', () {
      final conversation = AiConversation.fromRow({
        'id': 'k1',
        'title': '',
        'updated_at': '2026-11-14T19:00:00Z',
      });
      expect(conversation.title, 'Rozhovor');
      expect(conversation.updatedAt, DateTime.utc(2026, 11, 14, 19));
    });

    test('vybavení a preference pro paměť AI', () {
      final oven = MemoryItem.equipment({
        'id': 'e1',
        'name': 'Gorenje BPSAX6747A08BGWI',
        'capabilities': ['Teplotní sonda', 'SteamAssist'],
        'notes': 'max 300 °C',
      });
      expect(oven.detail, 'Teplotní sonda · SteamAssist · max 300 °C');
      final taste = MemoryItem.preference({
        'id': 'p1',
        'label': 'Výraznější chuť',
        'enabled': false,
      });
      expect(taste.enabled, isFalse);
    });
  });

  group('pomocné funkce', () {
    test('normalizeWebUrl doplní https a odmítne nesmysly', () {
      expect(normalizeWebUrl('recepty.cz/gulas'), 'https://recepty.cz/gulas');
      expect(
        normalizeWebUrl(' https://www.recepty.cz/a?b=1 '),
        'https://www.recepty.cz/a?b=1',
      );
      expect(normalizeWebUrl(''), isNull);
      expect(normalizeWebUrl('to není odkaz'), isNull);
      expect(normalizeWebUrl('ftp://recepty.cz/a'), isNull);
      expect(normalizeWebUrl('localhost'), isNull);
    });

    test('splitIngredients dělí čárkou, středníkem i řádkem', () {
      expect(splitIngredients('kuře, smetana;paprika\n cibule ,, '), [
        'kuře',
        'smetana',
        'paprika',
        'cibule',
      ]);
      expect(splitIngredients('   '), isEmpty);
    });
  });
}

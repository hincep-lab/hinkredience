import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/personalization.dart';
import '../data/docs_repository.dart';
import '../data/kitchen_docs.dart';
import 'providers.dart';

/// Proud, který se obnoví při každé změně deníku, plánu nebo nákupu.
Stream<T> _watch<T>(Ref ref, Future<T> Function(DocsRepository docs) read) {
  final controller = StreamController<T>();
  StreamSubscription<void>? subscription;
  ref.onDispose(() {
    subscription?.cancel();
    controller.close();
  });
  final future = ref.watch(docsRepositoryProvider.future);
  () async {
    try {
      final docs = await future;
      Future<void> emit() async {
        final value = await read(docs);
        if (!controller.isClosed) controller.add(value);
      }

      subscription = docs.changes.listen((_) => emit());
      await emit();
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
    }
  }();
  return controller.stream;
}

/// Kuchařský deník – dokončená vaření, nejnovější první.
final diaryProvider = StreamProvider<List<CookingSession>>(
  (ref) => _watch(ref, (docs) => docs.diary()),
);

/// Deník jednoho receptu.
final recipeDiaryProvider =
    Provider.family<AsyncValue<List<CookingSession>>, String>(
      (ref, recipeId) => ref
          .watch(diaryProvider)
          .whenData(
            (all) => [
              for (final s in all)
                if (s.recipeId == recipeId) s,
            ],
          ),
    );

/// Osobní chutě a vybavení pro doporučení (prázdné, dokud se nenačtou
/// nebo když uživatel není přihlášený).
final tasteProfileProvider = Provider.autoDispose<TasteProfile>((ref) {
  final kitchen = ref.watch(kitchenProvider).value;
  if (kitchen == null) return TasteProfile.empty;
  return TasteProfile.fromLabels(
    [
      for (final p in kitchen.preferences)
        if (p.enabled) p.label,
    ],
    equipment: [for (final e in kitchen.equipment) e.label],
  );
});

/// Připomínka z deníku k receptu („příště víc soli“), nebo null.
final diaryReminderProvider = Provider.family<DiaryReminder?, String>(
  (ref, recipeId) =>
      diaryReminder(recipeId, ref.watch(diaryProvider).value ?? const []),
);

/// Rozvařený recept (pokračování po zavření aplikace).
final openSessionProvider = StreamProvider<CookingSession?>(
  (ref) => _watch(ref, (docs) => docs.openSession()),
);

/// Všechny položky všech nákupních seznamů.
final shoppingProvider = StreamProvider<List<ShoppingItem>>(
  (ref) => _watch(ref, (docs) => docs.shopping()),
);

/// Nákupní seznam s počtem zbývajících položek.
class ShoppingListSummary {
  const ShoppingListSummary({
    required this.list,
    required this.remaining,
    required this.total,
  });

  final ShoppingList list;
  final int remaining;
  final int total;
}

/// Nákupní seznamy (nejnovější první) s počty položek.
final shoppingListsProvider = StreamProvider<List<ShoppingListSummary>>(
  (ref) => _watch(ref, (docs) async {
    final lists = await docs.shoppingLists();
    final items = await docs.shopping();
    return [
      for (final list in lists)
        ShoppingListSummary(
          list: list,
          remaining: items
              .where((i) => i.listId == list.id && !i.checked)
              .length,
          total: items.where((i) => i.listId == list.id).length,
        ),
    ];
  }),
);

/// Jeden nákupní seznam (null = smazaný nebo neexistuje).
final shoppingListProvider = StreamProvider.family<ShoppingList?, String>(
  (ref, id) => _watch(ref, (docs) => docs.shoppingList(id)),
);

/// Položky jednoho nákupního seznamu.
final shoppingItemsProvider = StreamProvider.family<List<ShoppingItem>, String>(
  (ref, listId) => _watch(ref, (docs) => docs.shopping(listId: listId)),
);

/// Plán vaření na týden začínající daným pondělím.
final weekPlanProvider = StreamProvider.family<List<MealPlanEntry>, DateTime>(
  (ref, monday) => _watch(
    ref,
    (docs) => docs.plan(from: monday, to: monday.add(const Duration(days: 6))),
  ),
);

// ------------------------------------------------------------------- rodina

class HouseholdMember {
  const HouseholdMember({
    required this.userId,
    required this.name,
    required this.isOwner,
    required this.isMe,
  });

  final String userId;
  final String name;
  final bool isOwner;
  final bool isMe;
}

class Household {
  const Household({
    required this.id,
    required this.name,
    required this.amOwner,
    required this.members,
  });

  final String id;
  final String name;
  final bool amOwner;
  final List<HouseholdMember> members;
}

/// Rodina (domácnost) na serveru. Členové sdílejí rodinné recepty, plán
/// vaření a nákupní seznam; chutě, deník a soukromé recepty zůstávají každému.
class HouseholdStore {
  HouseholdStore(this._client);

  final SupabaseClient _client;

  String get _uid => _client.auth.currentUser!.id;

  Future<Household?> current() async {
    final List<Map<String, dynamic>> mine = await _client
        .from('household_members')
        .select('household_id, role, joined_at')
        .eq('user_id', _uid)
        .order('joined_at')
        .limit(1);
    if (mine.isEmpty) return null;
    final id = mine.first['household_id'] as String;
    final Map<String, dynamic> house = await _client
        .from('households')
        .select('id, name')
        .eq('id', id)
        .single();
    final List<Map<String, dynamic>> members = await _client
        .from('household_members')
        .select('user_id, role')
        .eq('household_id', id)
        .order('joined_at');
    final ids = [for (final m in members) m['user_id'] as String];
    final List<Map<String, dynamic>> profiles = ids.isEmpty
        ? const []
        : await _client
              .from('profiles')
              .select('id, display_name, greeting_name')
              .inFilter('id', ids);
    String nameOf(String id) {
      final profile = profiles.where((p) => p['id'] == id).firstOrNull;
      final name =
          (profile?['display_name'] as String?)?.trim() ??
          (profile?['greeting_name'] as String?)?.trim() ??
          '';
      return name.isEmpty ? 'Člen rodiny' : name;
    }

    return Household(
      id: id,
      name: house['name'] as String? ?? 'Rodina',
      amOwner: mine.first['role'] == 'owner',
      members: [
        for (final m in members)
          HouseholdMember(
            userId: m['user_id'] as String,
            name: nameOf(m['user_id'] as String),
            isOwner: m['role'] == 'owner',
            isMe: m['user_id'] == _uid,
          ),
      ],
    );
  }

  Future<void> create(String name) async {
    await _client.from('households').insert({'name': name.trim()});
  }

  /// Přidá člena podle e-mailu (jen zakladatel). Vrací jméno člena.
  Future<String> addMember(String householdId, String email) async {
    try {
      final result = await _client.rpc<dynamic>(
        'household_add_member',
        params: {'p_household': householdId, 'p_email': email.trim()},
      );
      final name = (result is Map ? result['display_name'] : null) as String?;
      return name == null || name.isEmpty ? email.trim() : name;
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202') {
        throw Exception(
          'Na serveru ještě chybí migrace 09 (rodina). Spusťte ji v Supabase.',
        );
      }
      throw Exception(error.message);
    }
  }

  Future<void> leave(String householdId) async {
    await _client
        .from('household_members')
        .delete()
        .eq('household_id', householdId)
        .eq('user_id', _uid);
  }

  Future<void> removeMember(String householdId, String userId) async {
    await _client
        .from('household_members')
        .delete()
        .eq('household_id', householdId)
        .eq('user_id', userId);
  }
}

final householdStoreProvider = Provider<HouseholdStore?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null || !ref.watch(sessionProvider).isSignedIn) return null;
  return HouseholdStore(client);
});

/// Rodina přihlášeného uživatele (`null` = žádná nebo bez účtu).
final householdProvider = FutureProvider<Household?>((ref) async {
  final store = ref.watch(householdStoreProvider);
  if (store == null) return null;
  return store.current();
});

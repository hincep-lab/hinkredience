import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/best_buy.dart';
import '../core/equipment_fit.dart';
import '../core/personalization.dart';
import '../data/docs_repository.dart';
import '../data/kitchen_docs.dart';
import '../data/price_service.dart';
import 'providers.dart';
import 'sale_alerts_runner.dart';

/// Proud, který se obnoví při každé změně deníku, plánu nebo nákupu.
Stream<T> _watch<T>(Ref ref, Future<T> Function(DocsRepository docs) read) =>
    watchRepositoryData(
      ref,
      ref.watch(docsRepositoryProvider.future),
      (repository) => repository.changes,
      read,
    );

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
    appliances: [
      for (final e in kitchen.equipment)
        Appliance(name: e.label, kind: e.kind, detail: e.detail),
    ],
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

/// Ceny z vlastních účtenek (synchronizované s rodinou).
final receiptPricesProvider = StreamProvider<List<ReceiptPrice>>(
  (ref) => _watch(ref, (docs) => docs.receipts()),
);

/// Služba cen (bez Supabase null).
final priceServiceProvider = Provider<PriceService?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return null;
  return PriceService(client, ref.watch(sharedPreferencesProvider));
});

/// Platné akce z letáků; [PriceOffersNotifier.reload] po hledání.
final priceOffersProvider =
    AsyncNotifierProvider<PriceOffersNotifier, List<PriceOffer>>(
      PriceOffersNotifier.new,
    );

/// Kdy se letáky jednotlivých řetězců naposledy stáhly (a zda poslední
/// pokus selhal).
final priceUpdatesProvider =
    AsyncNotifierProvider<PriceUpdatesNotifier, Map<String, ChainUpdate>>(
      PriceUpdatesNotifier.new,
    );

class PriceUpdatesNotifier extends AsyncNotifier<Map<String, ChainUpdate>> {
  @override
  Future<Map<String, ChainUpdate>> build() async {
    final service = ref.watch(priceServiceProvider);
    if (service == null) return const {};
    return service.updates();
  }

  Future<void> reload() async {
    final service = ref.read(priceServiceProvider);
    if (service == null) return;
    state = AsyncData(await service.updates());
  }
}

class PriceOffersNotifier extends AsyncNotifier<List<PriceOffer>> {
  @override
  Future<List<PriceOffer>> build() async {
    final service = ref.watch(priceServiceProvider);
    if (service == null) return const [];
    return service.offers(DateTime.now());
  }

  Future<void> reload() async {
    final service = ref.read(priceServiceProvider);
    if (service == null) return;
    state = AsyncData(await service.offers(DateTime.now()));
  }
}

/// Nastavení panelu „Nejvýhodnější nákup“ (zapnuto, sbaleno, varianta,
/// seskupení podle prodejen) – pamatuje si ho telefon.
class BestBuyPrefs {
  const BestBuyPrefs({
    this.enabled = true,
    this.collapsed = false,
    this.multiStore = false,
    this.groupByStore = false,
    this.cards = const {},
  });

  final bool enabled;
  final bool collapsed;
  final bool multiStore;
  final bool groupByStore;

  /// Řetězce, jejichž věrnostní kartu / aplikaci uživatel má. Jen u nich
  /// se počítá s cenou „s kartou“ (Clubcard, Můj Albert, PENNY karta…).
  final Set<String> cards;

  BestBuyPrefs copyWith({
    bool? enabled,
    bool? collapsed,
    bool? multiStore,
    bool? groupByStore,
    Set<String>? cards,
  }) => BestBuyPrefs(
    enabled: enabled ?? this.enabled,
    collapsed: collapsed ?? this.collapsed,
    multiStore: multiStore ?? this.multiStore,
    groupByStore: groupByStore ?? this.groupByStore,
    cards: cards ?? this.cards,
  );
}

final bestBuyPrefsProvider =
    NotifierProvider<BestBuyPrefsNotifier, BestBuyPrefs>(
      BestBuyPrefsNotifier.new,
    );

class BestBuyPrefsNotifier extends Notifier<BestBuyPrefs> {
  static const _prefix = 'best_buy_';

  @override
  BestBuyPrefs build() {
    final p = ref.watch(sharedPreferencesProvider);
    return BestBuyPrefs(
      enabled: p.getBool('${_prefix}enabled') ?? true,
      collapsed: p.getBool('${_prefix}collapsed') ?? false,
      multiStore: p.getBool('${_prefix}multi') ?? false,
      groupByStore: p.getBool('${_prefix}group') ?? false,
      cards: {...?p.getStringList('${_prefix}cards')},
    );
  }

  Future<void> update(BestBuyPrefs next) async {
    state = next;
    final p = ref.read(sharedPreferencesProvider);
    await p.setBool('${_prefix}enabled', next.enabled);
    await p.setBool('${_prefix}collapsed', next.collapsed);
    await p.setBool('${_prefix}multi', next.multiStore);
    await p.setBool('${_prefix}group', next.groupByStore);
    await p.setStringList('${_prefix}cards', next.cards.toList()..sort());
  }
}

/// Přání rodiny „mám chuť na…“ (čekající a ještě nesnědená naplánovaná).
final wishesProvider = StreamProvider<List<MealWish>>(
  (ref) => _watch(ref, (docs) => docs.wishes()),
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

  /// Sdílí se automaticky každý můj recept s rodinou?
  Future<bool> shareAllRecipes() async {
    try {
      final Map<String, dynamic>? row = await _client
          .from('profiles')
          .select('share_recipes_with_family')
          .eq('id', _uid)
          .maybeSingle();
      return row?['share_recipes_with_family'] == true;
    } on PostgrestException {
      // Server ještě nemá migraci 11 – volba je vypnutá.
      return false;
    }
  }

  /// Zapne / vypne automatické sdílení. Při zapnutí rovnou nasdílí všechny
  /// mé recepty. Vrací počet nově sdílených receptů.
  Future<int> setShareAllRecipes(bool enabled) =>
      _shareRpc('set_share_recipes_with_family', {'p_enabled': enabled});

  /// Jednorázově nasdílí rodině všechny mé recepty. Vrací jejich počet.
  Future<int> shareAllRecipesNow() => _shareRpc('share_all_my_recipes', {});

  Future<int> _shareRpc(String name, Map<String, dynamic> params) async {
    try {
      final result = await _client.rpc<dynamic>(name, params: params);
      return result is num ? result.toInt() : 0;
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202' || error.code == '42703') {
        throw Exception(
          'Na serveru ještě chybí migrace 11 (sdílení receptů). '
          'Spusťte ji v Supabase.',
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

/// Automatické sdílení všech mých receptů s rodinou (nastavení na serveru,
/// platí na všech zařízeních i pro recepty z ChatGPT).
final shareAllRecipesProvider = FutureProvider<bool>((ref) async {
  final store = ref.watch(householdStoreProvider);
  if (store == null) return false;
  return store.shareAllRecipes();
});

/// Rodina přihlášeného uživatele (`null` = žádná nebo bez účtu).
final householdProvider = FutureProvider<Household?>((ref) async {
  final store = ref.watch(householdStoreProvider);
  if (store == null) return null;
  return store.current();
});

/// Po synchronizaci: nové akce na hlídané zboží a zboží ze seznamů → oznámení.
Future<void> checkSaleAlerts(WidgetRef ref, {DateTime? now}) async {
  final service = ref.read(priceServiceProvider);
  final docs = ref.read(docsRepositoryProvider).value;
  if (service == null || docs == null) return;
  final items = await docs.shopping();
  final time = now ?? DateTime.now();
  await runSaleAlerts(
    prefs: ref.read(sharedPreferencesProvider),
    loadOffers: () => service.offers(time),
    alerts: ref.read(familyAlertsProvider),
    now: time,
    shopping: [for (final i in items) i.name],
  );
}

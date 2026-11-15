import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/ai_models.dart';
import '../data/ai_service.dart';
import '../data/app_database.dart';
import '../data/docs_repository.dart';
import '../data/docs_sync.dart';
import '../data/photo_store.dart';
import '../data/recipe.dart';
import '../data/recipe_repository.dart';
import '../data/remote_store.dart';
import '../data/sync_service.dart';
import 'app_config.dart';

// --------------------------------------------------------------- základ
// Tyto providery se naplní při startu v main().

final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Nastavuje se v main().'),
);

final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('Nastavuje se v main().'),
);

/// Klient Supabase, nebo `null`, když připojení není nastavené.
final supabaseClientProvider = Provider<SupabaseClient?>((ref) => null);

final photoStoreProvider = Provider<PhotoStore>(
  (ref) => throw UnimplementedError('Nastavuje se v main().'),
);

final databaseFactoryProvider = Provider<DatabaseFactory>(
  (ref) => databaseFactory,
);

// ------------------------------------------------------------ nastavení

@immutable
class AppSettings {
  const AppSettings({
    required this.greetingName,
    required this.skipAuth,
    this.aiEnabled = false,
    this.keepScreenOn = true,
  });

  /// Oslovení na hlavní obrazovce („Ahoj Pájo“).
  final String greetingName;

  /// Uživatel zvolil používání bez účtu.
  final bool skipAuth;

  /// AI funkce v aplikaci (AI kuchař, hledání na internetu, import). Jsou
  /// placené přes OpenAI API, proto jsou ve výchozím stavu vypnuté a aplikace
  /// bez výslovného zapnutí žádný požadavek na AI neodešle.
  final bool aiEnabled;

  /// Při otevřeném receptu nenechat zhasnout displej (výchozí zapnuto).
  final bool keepScreenOn;

  AppSettings copyWith({
    String? greetingName,
    bool? skipAuth,
    bool? aiEnabled,
    bool? keepScreenOn,
  }) => AppSettings(
    greetingName: greetingName ?? this.greetingName,
    skipAuth: skipAuth ?? this.skipAuth,
    aiEnabled: aiEnabled ?? this.aiEnabled,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.greetingName == greetingName &&
      other.skipAuth == skipAuth &&
      other.aiEnabled == aiEnabled &&
      other.keepScreenOn == keepScreenOn;

  @override
  int get hashCode =>
      Object.hash(greetingName, skipAuth, aiEnabled, keepScreenOn);
}

class SettingsController extends Notifier<AppSettings> {
  static const _greetingKey = 'greeting_name';
  static const _skipAuthKey = 'skip_auth';
  static const _aiEnabledKey = 'ai_enabled';
  static const _keepScreenOnKey = 'keep_screen_on';

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return AppSettings(
      greetingName: prefs.getString(_greetingKey) ?? 'Pájo',
      skipAuth: prefs.getBool(_skipAuthKey) ?? false,
      aiEnabled: prefs.getBool(_aiEnabledKey) ?? false,
      keepScreenOn: prefs.getBool(_keepScreenOnKey) ?? true,
    );
  }

  Future<void> setGreetingName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await ref.read(sharedPreferencesProvider).setString(_greetingKey, trimmed);
    state = state.copyWith(greetingName: trimmed);
  }

  Future<void> setSkipAuth(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(_skipAuthKey, value);
    state = state.copyWith(skipAuth: value);
  }

  Future<void> setAiEnabled(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(_aiEnabledKey, value);
    state = state.copyWith(aiEnabled: value);
  }

  Future<void> setKeepScreenOn(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(_keepScreenOnKey, value);
    state = state.copyWith(keepScreenOn: value);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

// ----------------------------------------------------------- přihlášení

@immutable
class Session {
  const Session({this.userId, this.email});

  final String? userId;
  final String? email;

  bool get isSignedIn => userId != null;

  @override
  bool operator ==(Object other) =>
      other is Session && other.userId == userId && other.email == email;

  @override
  int get hashCode => Object.hash(userId, email);
}

class SessionController extends Notifier<Session> {
  @override
  Session build() {
    final client = ref.watch(supabaseClientProvider);
    if (client == null) return const Session();
    final subscription = client.auth.onAuthStateChange.listen((data) {
      final user = data.session?.user;
      state = Session(userId: user?.id, email: user?.email);
    });
    ref.onDispose(subscription.cancel);
    final user = client.auth.currentUser;
    return Session(userId: user?.id, email: user?.email);
  }

  SupabaseClient get _client {
    final client = ref.read(supabaseClientProvider);
    if (client == null) {
      throw AuthException('Připojení k Supabase není nastavené.');
    }
    return client;
  }

  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// Zaregistruje účet. Vrací `true`, když je uživatel rovnou přihlášen,
  /// a `false`, když musí nejdřív potvrdit e-mail.
  Future<bool> signUp({
    required String email,
    required String password,
    String? greetingName,
  }) async {
    final response = await _client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {
        if (greetingName != null && greetingName.isNotEmpty)
          'greeting_name': greetingName,
      },
    );
    return response.session != null;
  }

  Future<void> resetPassword(String email) =>
      _client.auth.resetPasswordForEmail(email.trim());

  Future<void> signOut() => _client.auth.signOut();
}

final sessionProvider = NotifierProvider<SessionController, Session>(
  SessionController.new,
);

// ------------------------------------------------------------ databáze

String _databaseName(String? userId) =>
    userId == null ? 'hinkredience_local.db' : 'hinkredience_$userId.db';

/// Každý účet má vlastní databázi, aby se data uživatelů v jednom telefonu
/// nikdy nesmíchala. Bez účtu se používá místní databáze.
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final userId = ref.watch(sessionProvider.select((s) => s.userId));
  final factory = ref.watch(databaseFactoryProvider);
  final directory = await factory.getDatabasesPath();
  final database = await AppDatabase.open(
    factory: factory,
    path: p.join(directory, _databaseName(userId)),
  );
  ref.onDispose(database.close);
  return database;
});

final recipeRepositoryProvider = FutureProvider<RecipeRepository>((ref) async {
  final database = await ref.watch(databaseProvider.future);
  final userId = ref.watch(sessionProvider.select((s) => s.userId));
  final repository = RecipeRepository(database);
  ref.onDispose(repository.dispose);

  // Po prvním přihlášení převezmeme recepty vytvořené bez účtu.
  if (userId != null) {
    final factory = ref.read(databaseFactoryProvider);
    final localPath = p.join(
      await factory.getDatabasesPath(),
      _databaseName(null),
    );
    if (!kIsWeb && await File(localPath).exists()) {
      try {
        final local = await AppDatabase.open(factory: factory, path: localPath);
        final localRepository = RecipeRepository(local);
        await repository.importFrom(localRepository, ownerId: userId);
        await localRepository.dispose();
        await local.close();
        await factory.deleteDatabase(localPath);
      } catch (error) {
        debugPrint('Převzetí místních receptů selhalo: $error');
      }
    }
  }
  return repository;
});

/// Kuchařský deník, plán vaření a nákupní seznam (stejná místní databáze).
final docsRepositoryProvider = FutureProvider<DocsRepository>((ref) async {
  final database = await ref.watch(databaseProvider.future);
  final repository = DocsRepository(database);
  ref.onDispose(repository.dispose);
  return repository;
});

/// Všechny recepty včetně koše; obnovuje se při každé změně v databázi.
final allRecipesProvider = StreamProvider<List<Recipe>>((ref) {
  final controller = StreamController<List<Recipe>>();
  StreamSubscription<void>? subscription;
  ref.onDispose(() {
    subscription?.cancel();
    controller.close();
  });
  final repositoryFuture = ref.watch(recipeRepositoryProvider.future);
  () async {
    try {
      final repository = await repositoryFuture;
      Future<void> emit() async {
        final recipes = await repository.getAll();
        if (!controller.isClosed) controller.add(recipes);
      }

      subscription = repository.changes.listen((_) => emit());
      await emit();
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
    }
  }();
  return controller.stream;
});

/// Recepty mimo koš.
final recipesProvider = Provider<AsyncValue<List<Recipe>>>(
  (ref) => ref
      .watch(allRecipesProvider)
      .whenData(
        (all) => [
          for (final r in all)
            if (!r.isDeleted) r,
        ],
      ),
);

/// Koš.
final trashProvider = Provider<AsyncValue<List<Recipe>>>(
  (ref) => ref
      .watch(allRecipesProvider)
      .whenData(
        (all) => [
          for (final r in all)
            if (r.isDeleted) r,
        ],
      ),
);

final recipeProvider = Provider.family<AsyncValue<Recipe?>, String>(
  (ref, id) => ref
      .watch(allRecipesProvider)
      .whenData((all) => all.firstWhereOrNull((r) => r.id == id)),
);

/// Výchozí kategorie + vlastní + ty, které už jsou v receptech použité.
final categoriesProvider = FutureProvider<List<String>>((ref) async {
  final repository = await ref.watch(recipeRepositoryProvider.future);
  final recipes = ref.watch(recipesProvider).value ?? const <Recipe>[];
  final custom = await repository.customCategories();
  final result = <String>[...defaultCategories];
  for (final name in [...custom, for (final r in recipes) r.category]) {
    if (name.isNotEmpty && !result.contains(name)) result.add(name);
  }
  return result;
});

final recipeVersionsProvider =
    FutureProvider.family<List<RecipeVersion>, String>((ref, recipeId) async {
      final repository = await ref.watch(recipeRepositoryProvider.future);
      ref.watch(recipeProvider(recipeId));
      return repository.versions(recipeId);
    });

/// Dočasná adresa fotografie uložené na serveru.
final signedPhotoUrlProvider = FutureProvider.family<String?, String>((
  ref,
  remotePath,
) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null || !ref.watch(sessionProvider).isSignedIn) return null;
  return SupabaseRemoteStore(client).signedPhotoUrl(remotePath);
});

// -------------------------------------------------------- synchronizace

/// Co ukazuje nenápadný ukazatel synchronizace.
enum SyncPhase {
  /// Bez účtu nebo bez připojení k Supabase – recepty jsou jen v telefonu.
  localOnly,
  syncing,
  synced,

  /// Některé změny ještě nejsou na serveru.
  pending,
  offline,
  error,

  /// Recept byl změněn na dvou místech a čeká na rozhodnutí.
  conflict,
}

@immutable
class SyncState {
  const SyncState({
    this.running = false,
    this.lastSuccess,
    this.errors = const [],
    this.offline = false,
    this.pending = 0,
    this.conflicts = 0,
    this.nextRetry,
  });

  final bool running;
  final DateTime? lastSuccess;

  /// Chyby posledního pokusu (prázdné = proběhl bez chyby).
  final List<String> errors;

  /// Poslední pokus selhal kvůli chybějícímu připojení.
  final bool offline;

  /// Počet receptů čekajících na odeslání.
  final int pending;

  /// Počet receptů se souběžnou úpravou k rozhodnutí.
  final int conflicts;

  /// Kdy se synchronizace po chybě sama zopakuje.
  final DateTime? nextRetry;

  String? get lastError => errors.isEmpty ? null : errors.first;

  SyncPhase phaseFor({required bool enabled}) {
    if (!enabled) return SyncPhase.localOnly;
    if (running) return SyncPhase.syncing;
    if (conflicts > 0) return SyncPhase.conflict;
    if (offline) return SyncPhase.offline;
    if (errors.isNotEmpty) return SyncPhase.error;
    if (pending > 0) return SyncPhase.pending;
    return SyncPhase.synced;
  }

  SyncState copyWith({
    bool? running,
    DateTime? lastSuccess,
    List<String>? errors,
    bool? offline,
    int? pending,
    int? conflicts,
    Object? nextRetry = _keep,
  }) => SyncState(
    running: running ?? this.running,
    lastSuccess: lastSuccess ?? this.lastSuccess,
    errors: errors ?? this.errors,
    offline: offline ?? this.offline,
    pending: pending ?? this.pending,
    conflicts: conflicts ?? this.conflicts,
    nextRetry: identical(nextRetry, _keep)
        ? this.nextRetry
        : nextRetry as DateTime?,
  );
}

const Object _keep = Object();

/// Prodlevy mezi opakovanými pokusy po chybě: 5 s, 15 s, 30 s, 1, 2, 5 min.
const syncRetryDelays = [
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
];

/// Připojení k internetu: `true` = nějaká síť je k dispozici. Přepsatelné
/// v testech (tam systémové rozhraní neexistuje).
final connectivityChangesProvider = Provider<Stream<bool>>(
  (ref) => Connectivity().onConnectivityChanged.map(
    (results) => !results.contains(ConnectivityResult.none),
  ),
);

/// Je synchronizace vůbec možná (účet a připojení k Supabase)?
final syncEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(supabaseClientProvider) != null &&
      ref.watch(sessionProvider).isSignedIn,
);

/// Automatická synchronizace. Spouští se sama:
/// - po otevření aplikace a po přihlášení,
/// - po každé místní změně (recept, fotka, oblíbené, koš) – za 2 s,
/// - po návratu aplikace z pozadí,
/// - po obnovení připojení k internetu,
/// - když Supabase Realtime ohlásí změnu z jiného zařízení nebo z ChatGPT,
/// - po chybě opakovaně s rostoucí prodlevou (5 s až 5 min).
class SyncController extends Notifier<SyncState> {
  Timer? _debounce;
  Timer? _retry;
  int _failures = 0;
  bool _running = false;
  bool _again = false;

  @override
  SyncState build() {
    final userId = ref.watch(sessionProvider.select((s) => s.userId));
    final repository = ref.watch(recipeRepositoryProvider).value;
    final client = ref.watch(supabaseClientProvider);
    ref.onDispose(() {
      _debounce?.cancel();
      _retry?.cancel();
    });
    _failures = 0;

    if (repository != null) {
      // Místní změna, která čeká na odeslání → odeslat za 2 s.
      final subscription = repository.changes.listen((_) async {
        final pending = await _refreshCounts();
        if (pending > 0) schedule(const Duration(seconds: 2));
      });
      ref.onDispose(subscription.cancel);
      Future.microtask(_refreshCounts);
    }
    final docs = ref.watch(docsRepositoryProvider).value;
    if (docs != null) {
      final subscription = docs.changes.listen((_) async {
        final pending = await _refreshCounts();
        if (pending > 0) schedule(const Duration(seconds: 2));
      });
      ref.onDispose(subscription.cancel);
    }

    if (repository != null && client != null && userId != null) {
      _listenForTriggers(client);
      Future.microtask(syncNow);
    }
    return const SyncState();
  }

  void _listenForTriggers(SupabaseClient client) {
    // Návrat z pozadí.
    final lifecycle = AppLifecycleListener(
      onResume: () => schedule(const Duration(milliseconds: 300)),
    );
    ref.onDispose(lifecycle.dispose);

    // Obnovení připojení.
    var online = true;
    final connectivity = ref
        .read(connectivityChangesProvider)
        .listen(
          (isOnline) {
            if (isOnline && !online) schedule(const Duration(seconds: 1));
            online = isOnline;
          },
          onError: (Object error) {
            debugPrint('Sledování připojení nefunguje: $error');
          },
        );
    ref.onDispose(connectivity.cancel);

    // Změny z jiného zařízení nebo z ChatGPT (Supabase Realtime). Událost
    // je jen upozornění – data se pak načtou běžnou synchronizací změn.
    try {
      final channel = client
          .channel('hinkredience-sync')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'recipes',
            callback: (_) => schedule(const Duration(seconds: 1)),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'recipe_tombstones',
            callback: (_) => schedule(const Duration(seconds: 1)),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'meal_plans',
            callback: (_) => schedule(const Duration(seconds: 1)),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'shopping_items',
            callback: (_) => schedule(const Duration(seconds: 1)),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'shopping_lists',
            callback: (_) => schedule(const Duration(seconds: 1)),
          )
          .subscribe();
      ref.onDispose(() => client.removeChannel(channel));
    } catch (error) {
      debugPrint('Realtime se nepodařilo zapnout: $error');
    }
  }

  /// Naplánuje synchronizaci (opakovaná volání se sloučí).
  void schedule(Duration delay) {
    if (!ref.mounted) return;
    _debounce?.cancel();
    _debounce = Timer(delay, syncNow);
  }

  Future<int> _refreshCounts() async {
    final repository = ref.read(recipeRepositoryProvider).value;
    if (repository == null) return 0;
    final docs = ref.read(docsRepositoryProvider).value;
    final pending =
        await repository.dirtyCount() + (await docs?.dirtyCount() ?? 0);
    final conflicts = (await repository.conflicts()).length;
    if (ref.mounted) {
      state = state.copyWith(pending: pending, conflicts: conflicts);
    }
    return pending;
  }

  /// Spustí synchronizaci. Bez přihlášení nebo připojení k Supabase nedělá nic.
  Future<SyncResult?> syncNow() async {
    if (!ref.mounted) return null;
    final client = ref.read(supabaseClientProvider);
    final repository = ref.read(recipeRepositoryProvider).value;
    if (client == null ||
        repository == null ||
        !ref.read(sessionProvider).isSignedIn) {
      return null;
    }
    if (_running) {
      _again = true;
      return null;
    }
    _running = true;
    _retry?.cancel();
    state = state.copyWith(running: true, nextRetry: null);
    SyncResult result;
    try {
      result = await SyncService(
        repository: repository,
        remote: SupabaseRemoteStore(client),
        photos: ref.read(photoStoreProvider),
      ).sync();
    } catch (error) {
      result = SyncResult(offline: isOfflineError(error), errors: ['$error']);
    }
    // Deník, plán a nákupní seznam.
    final docs = ref.read(docsRepositoryProvider).value;
    if (docs != null && !result.offline && ref.mounted) {
      try {
        final extra = await DocsSync(
          docs: docs,
          remote: SupabaseRemoteDocs(client),
          photos: ref.read(photoStoreProvider),
        ).sync();
        if (extra.errors.isNotEmpty || extra.offline) {
          result = SyncResult(
            pulled: result.pulled + extra.pulled,
            pushed: result.pushed + extra.pushed,
            conflicts: result.conflicts,
            offline: extra.offline,
            errors: [
              ...result.errors,
              ...extra.errors,
              if (extra.offline)
                'Bez připojení k internetu. Změny se odešlou později.',
            ],
          );
        }
      } catch (error) {
        result = SyncResult(
          pulled: result.pulled,
          pushed: result.pushed,
          conflicts: result.conflicts,
          offline: isOfflineError(error),
          errors: [...result.errors, '$error'],
        );
      }
    }
    _running = false;
    if (!ref.mounted) return result;
    final pending =
        await repository.dirtyCount() + (await docs?.dirtyCount() ?? 0);
    if (!ref.mounted) return result;

    DateTime? nextRetry;
    if (result.ok) {
      _failures = 0;
    } else {
      final delay =
          syncRetryDelays[_failures.clamp(0, syncRetryDelays.length - 1)];
      _failures++;
      nextRetry = DateTime.now().add(delay);
      _retry = Timer(delay, syncNow);
    }
    state = SyncState(
      running: false,
      lastSuccess: result.ok ? DateTime.now() : state.lastSuccess,
      errors: result.errors,
      offline: result.offline,
      pending: pending,
      conflicts: result.conflicts,
      nextRetry: nextRetry,
    );
    if (_again) {
      _again = false;
      schedule(const Duration(seconds: 1));
    }
    return result;
  }
}

final syncProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

/// Souběžná úprava čekající na rozhodnutí u daného receptu.
final recipeConflictProvider = FutureProvider.family<RecipeConflict?, String>((
  ref,
  recipeId,
) async {
  final repository = await ref.watch(recipeRepositoryProvider.future);
  // Přepočítá se při každé změně receptů (konflikt vždy změnu ohlásí).
  ref.watch(allRecipesProvider);
  return (await repository.conflicts())[recipeId];
});

// -------------------------------------------------------------------- AI

bool _aiReady(Ref ref) =>
    ref.watch(supabaseClientProvider) != null &&
    ref.watch(sessionProvider).isSignedIn;

/// Jsou AI funkce v nastavení zapnuté?
final aiEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider.select((s) => s.aiEnabled)),
);

/// AI kuchař, nebo `null`, když je AI vypnutá nebo chybí připojení či
/// přihlášení. Vypnutá AI tak nemůže odeslat žádný placený požadavek.
final aiServiceProvider = Provider<AiService?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (!ref.watch(aiEnabledProvider)) return null;
  if (client == null || !_aiReady(ref)) return null;
  return AiService(SupabaseAiBackend(client));
});

final aiHistoryStoreProvider = Provider<AiHistoryStore?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (!ref.watch(aiEnabledProvider)) return null;
  if (client == null || !_aiReady(ref)) return null;
  return AiHistoryStore(client);
});

final kitchenStoreProvider = Provider<KitchenStore?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null || !_aiReady(ref)) return null;
  return KitchenStore(client);
});

/// Uložené konverzace s AI, od nejnovější.
final aiConversationsProvider =
    FutureProvider.autoDispose<List<AiConversation>>((ref) async {
      final store = ref.watch(aiHistoryStoreProvider);
      if (store == null) return const [];
      return store.conversations();
    });

/// Kuchyňské vybavení a chuťové preference uložené na serveru.
final kitchenProvider =
    FutureProvider.autoDispose<
      ({List<MemoryItem> equipment, List<MemoryItem> preferences})
    >((ref) async {
      final store = ref.watch(kitchenStoreProvider);
      if (store == null) {
        return (
          equipment: const <MemoryItem>[],
          preferences: const <MemoryItem>[],
        );
      }
      final equipment = await store.equipment();
      final preferences = await store.preferences();
      return (equipment: equipment, preferences: preferences);
    });

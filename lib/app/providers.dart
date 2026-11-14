import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/ai_models.dart';
import '../data/ai_service.dart';
import '../data/app_database.dart';
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
  const AppSettings({required this.greetingName, required this.skipAuth});

  /// Oslovení na hlavní obrazovce („Ahoj Pájo“).
  final String greetingName;

  /// Uživatel zvolil používání bez účtu.
  final bool skipAuth;

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.greetingName == greetingName &&
      other.skipAuth == skipAuth;

  @override
  int get hashCode => Object.hash(greetingName, skipAuth);
}

class SettingsController extends Notifier<AppSettings> {
  static const _greetingKey = 'greeting_name';
  static const _skipAuthKey = 'skip_auth';

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return AppSettings(
      greetingName: prefs.getString(_greetingKey) ?? 'Pájo',
      skipAuth: prefs.getBool(_skipAuthKey) ?? false,
    );
  }

  Future<void> setGreetingName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await ref.read(sharedPreferencesProvider).setString(_greetingKey, trimmed);
    state = AppSettings(greetingName: trimmed, skipAuth: state.skipAuth);
  }

  Future<void> setSkipAuth(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(_skipAuthKey, value);
    state = AppSettings(greetingName: state.greetingName, skipAuth: value);
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
    if (await File(localPath).exists()) {
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

@immutable
class SyncState {
  const SyncState({
    this.running = false,
    this.lastSuccess,
    this.lastError,
    this.pending = 0,
  });

  final bool running;
  final DateTime? lastSuccess;
  final String? lastError;

  /// Počet receptů čekajících na odeslání.
  final int pending;

  SyncState copyWith({
    bool? running,
    DateTime? lastSuccess,
    Object? lastError = _keep,
    int? pending,
  }) => SyncState(
    running: running ?? this.running,
    lastSuccess: lastSuccess ?? this.lastSuccess,
    lastError: identical(lastError, _keep)
        ? this.lastError
        : lastError as String?,
    pending: pending ?? this.pending,
  );
}

const Object _keep = Object();

class SyncController extends Notifier<SyncState> {
  Timer? _debounce;
  bool _running = false;
  bool _again = false;

  @override
  SyncState build() {
    final userId = ref.watch(sessionProvider.select((s) => s.userId));
    final repository = ref.watch(recipeRepositoryProvider).value;
    final client = ref.watch(supabaseClientProvider);

    if (repository != null) {
      // Po každé místní změně naplánujeme odeslání.
      final subscription = repository.changes.listen((_) {
        _refreshPending();
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), syncNow);
      });
      ref.onDispose(subscription.cancel);
      Future.microtask(_refreshPending);
    }
    ref.onDispose(() => _debounce?.cancel());

    if (repository != null && client != null && userId != null) {
      Future.microtask(syncNow);
    }
    return const SyncState();
  }

  Future<void> _refreshPending() async {
    final repository = ref.read(recipeRepositoryProvider).value;
    if (repository == null) return;
    final pending = await repository.dirtyCount();
    if (ref.mounted) state = state.copyWith(pending: pending);
  }

  /// Spustí synchronizaci. Bez přihlášení nebo připojení nedělá nic.
  Future<SyncResult?> syncNow() async {
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
    state = state.copyWith(running: true);
    SyncResult result;
    try {
      result = await SyncService(
        repository: repository,
        remote: SupabaseRemoteStore(client),
        photos: ref.read(photoStoreProvider),
      ).sync();
    } catch (error) {
      result = SyncResult(errors: ['$error']);
    }
    _running = false;
    if (!ref.mounted) return result;
    final pending = await repository.dirtyCount();
    if (!ref.mounted) return result;
    state = SyncState(
      running: false,
      lastSuccess: result.ok ? DateTime.now() : state.lastSuccess,
      lastError: result.ok ? null : result.errors.first,
      pending: pending,
    );
    if (_again) {
      _again = false;
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), syncNow);
    }
    return result;
  }
}

final syncProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

// -------------------------------------------------------------------- AI

bool _aiReady(Ref ref) =>
    ref.watch(supabaseClientProvider) != null &&
    ref.watch(sessionProvider).isSignedIn;

/// AI kuchař, nebo `null`, když chybí připojení či přihlášení.
final aiServiceProvider = Provider<AiService?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null || !_aiReady(ref)) return null;
  return AiService(SupabaseAiBackend(client));
});

final aiHistoryStoreProvider = Provider<AiHistoryStore?>((ref) {
  final client = ref.watch(supabaseClientProvider);
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

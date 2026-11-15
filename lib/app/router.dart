import 'package:go_router/go_router.dart';

import '../core/material.dart';
import '../features/ai/ai_chat_screen.dart';
import '../features/ai/ai_history_screen.dart';
import '../features/ai/draft_review_screen.dart';
import '../features/ai/import_screen.dart';
import '../features/ai/web_search_screen.dart';
import '../features/auth/auth_screen.dart';
import '../features/home/home_screen.dart';
import '../features/more/temperatures_screen.dart';
import '../features/more/chatgpt_screen.dart';
import '../features/more/connection_screen.dart';
import '../features/more/kitchen_screen.dart';
import '../features/more/more_screen.dart';
import '../features/more/trash_screen.dart';
import '../features/recipes/recipe_detail_screen.dart';
import '../features/recipes/recipe_edit_screen.dart';
import '../core/screen_wake.dart';
import '../features/cooking/cooking_screen.dart';
import '../features/kitchen/diary_entry_screen.dart';
import '../features/kitchen/diary_screen.dart';
import '../features/kitchen/plan_screen.dart';
import '../features/kitchen/shopping_lists_screen.dart';
import '../features/kitchen/shopping_screen.dart';
import '../features/more/family_screen.dart';
import '../features/photos/recipe_photos_screen.dart';
import '../features/recipes/recipes_screen.dart';
import '../features/shell/main_shell.dart';
import '../features/splash/splash_screen.dart';

/// Cesty v aplikaci.
abstract final class Routes {
  static const splash = '/';
  static const auth = '/auth';
  static const home = '/home';
  static const recipes = '/recipes';
  static const favorites = '/favorites';
  static const more = '/more';
  static const trash = '/more/trash';
  static const connection = '/more/connection';
  static const kitchen = '/more/kitchen';
  static const temperatures = '/more/temperatures';
  static const chatGpt = '/more/chatgpt';
  static const newRecipe = '/recipe/new';
  static const ai = '/ai';
  static const aiHistory = '/ai/history';
  static const webSearch = '/ai/search';
  static const importRecipe = '/ai/import';
  static const draft = '/ai/draft';
  static const shopping = '/shopping';
  static const plan = '/plan';
  static const diary = '/diary';
  static const family = '/more/family';

  static String diaryFor(String recipeId) =>
      Uri(path: diary, queryParameters: {'recipe': recipeId}).toString();
  static String diaryEntry(String id) => '/diary/$id';

  /// Režim Vaříme spolu, volitelně na jiný počet porcí / kusů.
  static String cook(String recipeId, {double? servings}) => Uri(
    path: '/cook/$recipeId',
    queryParameters: servings == null ? null : {'s': '$servings'},
  ).toString();

  /// Chat s AI: pokračování konverzace nebo rozhovor nad receptem.
  static String aiChat({
    String? conversationId,
    String? recipeId,
    String? draft,
  }) {
    final parameters = {
      'c': ?conversationId,
      'recipe': ?recipeId,
      'draft': ?draft,
    };
    return Uri(
      path: ai,
      queryParameters: parameters.isEmpty ? null : parameters,
    ).toString();
  }

  /// Hledání na internetu s předvyplněným dotazem nebo podle receptu.
  static String webSearchWith({String? query, String? similarRecipeId}) {
    final parameters = {
      if (query != null && query.isNotEmpty) 'q': query,
      'similar': ?similarRecipeId,
    };
    return Uri(
      path: webSearch,
      queryParameters: parameters.isEmpty ? null : parameters,
    ).toString();
  }

  static String recipe(String id) => '/recipe/$id';
  static String shoppingList(String id) => '/shopping/$id';
  static String editRecipe(String id) => '/recipe/$id/edit';
  static String recipePhotos(String id) => '/recipe/$id/photos';

  static String recipesWith({String? query, String? category}) {
    final parameters = {
      if (query != null && query.isNotEmpty) 'q': query,
      if (category != null && category.isNotEmpty) 'category': category,
    };
    return Uri(
      path: recipes,
      queryParameters: parameters.isEmpty ? null : parameters,
    ).toString();
  }

  static String newRecipeIn(String? category) => Uri(
    path: newRecipe,
    queryParameters: category == null || category.isEmpty
        ? null
        : {'category': category},
  ).toString();
}

GoRouter createRouter({String initialLocation = Routes.splash}) {
  final rootKey = GlobalKey<NavigatorState>();

  Page<void> page(GoRouterState state, Widget child) =>
      MaterialPage<void>(key: state.pageKey, child: child);

  Page<void> tab(GoRouterState state, Widget child) =>
      NoTransitionPage<void>(key: state.pageKey, child: child);

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: initialLocation,
    observers: [appRouteObserver],
    routes: [
      GoRoute(
        path: Routes.splash,
        pageBuilder: (context, state) => page(state, const SplashScreen()),
      ),
      GoRoute(
        path: Routes.auth,
        pageBuilder: (context, state) => page(state, const AuthScreen()),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => MainShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                pageBuilder: (context, state) => tab(state, const HomeScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.recipes,
                pageBuilder: (context, state) => tab(
                  state,
                  RecipesScreen(
                    initialQuery: state.uri.queryParameters['q'] ?? '',
                    initialCategory: state.uri.queryParameters['category'],
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.shopping,
                pageBuilder: (context, state) =>
                    tab(state, const ShoppingListsScreen()),
                routes: [
                  GoRoute(
                    path: ':id',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) => page(
                      state,
                      ShoppingScreen(listId: state.pathParameters['id']!),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.favorites,
                pageBuilder: (context, state) =>
                    tab(state, const RecipesScreen(favoritesOnly: true)),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.more,
                pageBuilder: (context, state) => tab(state, const MoreScreen()),
                routes: [
                  GoRoute(
                    path: 'trash',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) =>
                        page(state, const TrashScreen()),
                  ),
                  GoRoute(
                    path: 'connection',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) =>
                        page(state, const ConnectionScreen()),
                  ),
                  GoRoute(
                    path: 'chatgpt',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) =>
                        page(state, const ChatGptScreen()),
                  ),
                  GoRoute(
                    path: 'family',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) =>
                        page(state, const FamilyScreen()),
                  ),
                  GoRoute(
                    path: 'kitchen',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) =>
                        page(state, const KitchenScreen()),
                  ),
                  GoRoute(
                    path: 'temperatures',
                    parentNavigatorKey: rootKey,
                    pageBuilder: (context, state) =>
                        page(state, const TemperaturesScreen()),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.ai,
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => page(
          state,
          AiChatScreen(
            conversationId: state.uri.queryParameters['c'],
            recipeId: state.uri.queryParameters['recipe'],
            draft: state.uri.queryParameters['draft'],
          ),
        ),
        routes: [
          GoRoute(
            path: 'history',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) =>
                page(state, const AiHistoryScreen()),
          ),
          GoRoute(
            path: 'search',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) => page(
              state,
              WebSearchScreen(
                initialQuery: state.uri.queryParameters['q'] ?? '',
                similarRecipeId: state.uri.queryParameters['similar'],
              ),
            ),
          ),
          GoRoute(
            path: 'import',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) => page(state, const ImportScreen()),
          ),
          GoRoute(
            path: 'draft',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) {
              final extra = state.extra;
              return page(
                state,
                DraftReviewScreen(
                  args: extra is DraftReviewArgs ? extra : null,
                ),
              );
            },
          ),
        ],
      ),
      GoRoute(
        path: Routes.plan,
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => page(state, const PlanScreen()),
      ),
      GoRoute(
        path: Routes.diary,
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => page(
          state,
          DiaryScreen(recipeId: state.uri.queryParameters['recipe']),
        ),
        routes: [
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) => page(
              state,
              DiaryEntryScreen(sessionId: state.pathParameters['id']!),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/cook/:id',
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => page(
          state,
          CookingScreen(
            recipeId: state.pathParameters['id']!,
            servings: double.tryParse(state.uri.queryParameters['s'] ?? ''),
          ),
        ),
      ),
      GoRoute(
        path: Routes.newRecipe,
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => page(
          state,
          RecipeEditScreen(
            initialCategory: state.uri.queryParameters['category'],
          ),
        ),
      ),
      GoRoute(
        path: '/recipe/:id',
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => page(
          state,
          RecipeDetailScreen(recipeId: state.pathParameters['id']!),
        ),
        routes: [
          GoRoute(
            path: 'edit',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) => page(
              state,
              RecipeEditScreen(recipeId: state.pathParameters['id']),
            ),
          ),
          GoRoute(
            path: 'photos',
            parentNavigatorKey: rootKey,
            pageBuilder: (context, state) => page(
              state,
              RecipePhotosScreen(recipeId: state.pathParameters['id']!),
            ),
          ),
        ],
      ),
    ],
  );
}

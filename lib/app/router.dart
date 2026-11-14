import 'package:go_router/go_router.dart';

import '../core/material.dart';
import '../features/auth/auth_screen.dart';
import '../features/home/home_screen.dart';
import '../features/more/connection_screen.dart';
import '../features/more/more_screen.dart';
import '../features/more/trash_screen.dart';
import '../features/recipes/recipe_detail_screen.dart';
import '../features/recipes/recipe_edit_screen.dart';
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
  static const newRecipe = '/recipe/new';

  static String recipe(String id) => '/recipe/$id';
  static String editRecipe(String id) => '/recipe/$id/edit';

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
                ],
              ),
            ],
          ),
        ],
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
        ],
      ),
    ],
  );
}

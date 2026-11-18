import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/recipe_groups.dart';
import '../../core/widgets.dart';
import '../home/home_widgets.dart' show GroupGrid;
import '../sync/sync_status.dart';
import '../../data/recipe.dart';

enum RecipeFilter { categories, all, favorites, newest }

/// Ikona kategorie pro dlaždice bez fotografie.
IconData categoryIcon(String category) {
  for (final g in recipeGroups) {
    if (g.label == category) return g.icon;
  }
  return _legacyCategoryIcon(category);
}

IconData _legacyCategoryIcon(String category) => switch (category) {
  'Maso' => Icons.kebab_dining_rounded,
  'Drůbež' => Icons.egg_alt_rounded,
  'Ryby' => Icons.set_meal_rounded,
  'Polévky' => Icons.soup_kitchen_rounded,
  'Omáčky' => Icons.water_drop_rounded,
  'Přílohy' => Icons.rice_bowl_rounded,
  'Pečení' => Icons.bakery_dining_rounded,
  'Dezerty' => Icons.cake_rounded,
  'Těsta' => Icons.breakfast_dining_rounded,
  'Pizza' => Icons.local_pizza_rounded,
  'Gril' => Icons.outdoor_grill_rounded,
  'Zavařování' => Icons.kitchen_rounded,
  _ => Icons.restaurant_rounded,
};

/// Vyfiltruje a seřadí recepty podle zvoleného pohledu.
List<Recipe> filterRecipes(
  List<Recipe> recipes, {
  required RecipeFilter filter,
  String query = '',
  String? category,
  String? group,
  String? tag,
}) {
  final result = [
    for (final recipe in recipes)
      if ((filter != RecipeFilter.favorites || recipe.isFavorite) &&
          (category == null || recipe.category == category) &&
          (group == null || groupOf(recipe).id == group) &&
          (tag == null || hasTag(recipe, tag)) &&
          recipe.matches(query))
        recipe,
  ];
  if (filter == RecipeFilter.newest) {
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  } else {
    result.sort(
      (a, b) => foldForSearch(a.title).compareTo(foldForSearch(b.title)),
    );
  }
  return result;
}

class RecipesScreen extends ConsumerStatefulWidget {
  const RecipesScreen({
    super.key,
    this.initialQuery = '',
    this.initialCategory,
    this.initialGroup,
    this.initialTag,
    this.favoritesOnly = false,
  });

  final String initialQuery;
  final String? initialCategory;

  /// Skupina z domovské obrazovky (Hovězí maso, Polévky…).
  final String? initialGroup;

  /// Štítek ze záložky Štítky.
  final String? initialTag;

  /// Záložka „Oblíbené“ – stejný seznam, jen bez přepínání pohledů.
  final bool favoritesOnly;

  @override
  ConsumerState<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends ConsumerState<RecipesScreen> {
  late final _search = TextEditingController(text: widget.initialQuery);
  late RecipeFilter _filter = widget.favoritesOnly
      ? RecipeFilter.favorites
      : RecipeFilter.categories;
  late String? _category = widget.initialCategory;
  late String? _group = widget.initialGroup;
  late String? _tag = widget.initialTag;

  @override
  void didUpdateWidget(RecipesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Hledání spuštěné z hlavní obrazovky.
    if (widget.initialQuery != oldWidget.initialQuery &&
        widget.initialQuery.isNotEmpty) {
      _search.text = widget.initialQuery;
    }
    if (widget.initialCategory != oldWidget.initialCategory &&
        widget.initialCategory != null) {
      _category = widget.initialCategory;
    }
    if (widget.initialGroup != oldWidget.initialGroup &&
        widget.initialGroup != null) {
      _group = widget.initialGroup;
      _filter = RecipeFilter.categories;
    }
    if (widget.initialTag != oldWidget.initialTag &&
        widget.initialTag != null) {
      _tag = widget.initialTag;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim();

  bool get _showCategoryGrid =>
      !widget.favoritesOnly &&
      _filter == RecipeFilter.categories &&
      _category == null &&
      _group == null &&
      _tag == null &&
      _query.isEmpty;

  @override
  Widget build(BuildContext context) {
    final recipes = ref.watch(recipesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.favoritesOnly ? 'Oblíbené' : 'Recepty'),
        actions: const [SyncStatusButton(), SizedBox(width: 4)],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nový recept',
        onPressed: () => context.push(Routes.newRecipeIn(_category)),
        child: const Icon(Icons.add_rounded, size: 30),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Hledat recept nebo surovinu',
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.textSecondary,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Vymazat hledání',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
            ),
          ),
          if (!widget.favoritesOnly)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final (filter, label) in const [
                    (RecipeFilter.categories, 'Kategorie'),
                    (RecipeFilter.all, 'Vše'),
                    (RecipeFilter.favorites, 'Oblíbené'),
                    (RecipeFilter.newest, 'Nové'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: _filter == filter,
                        showCheckmark: false,
                        onSelected: (_) => setState(() {
                          _filter = filter;
                          if (filter == RecipeFilter.categories) {
                            _category = null;
                            _group = null;
                          }
                        }),
                      ),
                    ),
                ],
              ),
            ),
          if (_group != null || _tag != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (_group != null)
                      InputChip(
                        avatar: Icon(
                          recipeGroupById(_group!).icon,
                          size: 18,
                          color: AppColors.copperGold,
                        ),
                        label: Text(recipeGroupById(_group!).label),
                        onDeleted: () => setState(() => _group = null),
                        deleteButtonTooltipMessage: 'Zrušit skupinu',
                      ),
                    if (_tag != null)
                      InputChip(
                        avatar: const Icon(
                          Icons.sell_outlined,
                          size: 18,
                          color: AppColors.copperGold,
                        ),
                        label: Text(_tag!),
                        onDeleted: () => setState(() => _tag = null),
                        deleteButtonTooltipMessage: 'Zrušit štítek',
                      ),
                  ],
                ),
              ),
            ),
          if (_category != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: Icon(
                    categoryIcon(_category!),
                    size: 18,
                    color: AppColors.copperGold,
                  ),
                  label: Text(_category!),
                  onDeleted: () => setState(() => _category = null),
                  deleteButtonTooltipMessage: 'Zrušit kategorii',
                ),
              ),
            ),
          Expanded(
            child: recipes.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => ErrorState(
                error: error,
                onRetry: () => ref.invalidate(recipeRepositoryProvider),
              ),
              data: (all) {
                if (_showCategoryGrid) {
                  return ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    children: [
                      GroupGrid(
                        recipes: all,
                        onSelected: (group) =>
                            setState(() => _group = group.id),
                      ),
                    ],
                  );
                }
                final visible = filterRecipes(
                  all,
                  filter: _filter,
                  query: _query,
                  category: _category,
                  group: _group,
                  tag: _tag,
                );
                if (visible.isEmpty) return _empty(all.isEmpty);
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: visible.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      RecipeListTile(recipe: visible[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(bool cookbookEmpty) {
    if (_query.isNotEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Nic jsme nenašli',
        message: 'Pro „$_query“ není v kuchařce žádný recept.',
      );
    }
    if (_filter == RecipeFilter.favorites && !cookbookEmpty) {
      return const EmptyState(
        icon: Icons.favorite_outline_rounded,
        title: 'Zatím žádné oblíbené',
        message: 'Recept přidáte mezi oblíbené srdíčkem v jeho detailu.',
      );
    }
    return EmptyState(
      icon: Icons.menu_book_rounded,
      title: _category == null ? 'Kuchařka je prázdná' : 'Tady zatím nic není',
      message: _category == null
          ? 'Přidejte svůj první recept.'
          : 'V kategorii $_category zatím není žádný recept.',
      actionLabel: 'Nový recept',
      onAction: () => context.push(Routes.newRecipeIn(_category)),
    );
  }
}

/// Řádek receptu v seznamu.
class RecipeListTile extends ConsumerWidget {
  const RecipeListTile({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HkCard(
      padding: EdgeInsets.zero,
      onTap: () => context.push(Routes.recipe(recipe.id)),
      child: SizedBox(
        height: 92,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(17),
              ),
              child: SizedBox(
                width: 92,
                height: 92,
                child: RecipeCover(recipe: recipe),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      recipe.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (recipe.description.isNotEmpty)
                      Text(
                        recipe.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    const SizedBox(height: 4),
                    RecipeMetaLine(recipe: recipe),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: recipe.isFavorite
                  ? 'Odebrat z oblíbených'
                  : 'Přidat mezi oblíbené',
              icon: Icon(
                recipe.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_outline_rounded,
                color: recipe.isFavorite
                    ? AppColors.copperGold
                    : AppColors.textSecondary,
              ),
              onPressed: () async {
                final repository = await ref.read(
                  recipeRepositoryProvider.future,
                );
                await repository.setFavorite(recipe.id, !recipe.isFavorite);
              },
            ),
          ],
        ),
      ),
    );
  }
}

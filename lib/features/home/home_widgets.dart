import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/recipe_groups.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';

/// Sdílené prvky nového vzhledu (domovská obrazovka, Recepty, Štítky).

const _cardRadius = 16.0;
const _cardBorder = Color(0xFF2E2E30);

/// Nadpis sekce s ikonou a odkazem „Zobrazit všechny →“.
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 6, 8),
      child: Row(
        children: [
          Icon(icon, color: AppColors.copper, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                ),
              ),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.copper,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 44),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Zaoblené filtrační tlačítko s ikonou (Trouba, Do 30 min…).
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.iconAsset,
  });

  final String label;
  final IconData? icon;

  /// Obrysová ikona z předlohy (má přednost před [icon]).
  final String? iconAsset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? const Color(0xFF1A1006) : const Color(0xFFE6E6E8);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? AppColors.copper : const Color(0xFF1E1E20),
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? AppColors.copper : const Color(0xFF3A3A3C),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: icon == null && iconAsset == null ? 14 : 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (iconAsset != null) ...[
                    ImageIcon(
                      AssetImage(iconAsset!),
                      size: 22,
                      color: selected ? fg : Colors.white,
                    ),
                    const SizedBox(width: 7),
                  ] else if (icon != null) ...[
                    Icon(icon, size: 19, color: selected ? fg : Colors.white),
                    const SizedBox(width: 7),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Recept s fotkou pro kartu skupiny: nejnověji upravený s fotkou.
Recipe? _photoRecipe(List<Recipe> recipes) {
  Recipe? best;
  for (final r in recipes) {
    if (r.photos.isEmpty) continue;
    if (best == null || r.updatedAt.isAfter(best.updatedAt)) best = r;
  }
  return best;
}

/// Fotografická karta skupiny receptů (Hovězí maso, Polévky…).
class GroupCard extends StatelessWidget {
  const GroupCard({
    super.key,
    required this.group,
    required this.recipes,
    required this.onTap,
  });

  final RecipeGroup group;

  /// Recepty v této skupině.
  final List<Recipe> recipes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final photo = _photoRecipe(recipes);
    return Semantics(
      button: true,
      label: '${group.label}, ${receptyCount(recipes.length)}',
      excludeSemantics: true,
      child: Material(
        color: AppColors.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_cardRadius),
          side: const BorderSide(color: _cardBorder),
        ),
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photo != null)
                RecipeCover(recipe: photo)
              else
                Image.asset(group.asset, fit: BoxFit.cover),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.35, 1],
                    colors: [Color(0x00000000), Color(0xE6000000)],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 10,
                bottom: 10,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ImageIcon(
                      AssetImage(group.iconAsset),
                      color: Colors.white,
                      size: 30,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            group.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              height: 1.15,
                              shadows: [
                                Shadow(blurRadius: 6, color: Colors.black),
                              ],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            receptyCount(recipes.length),
                            style: const TextStyle(
                              color: Color(0xFFDADADC),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mřížka 11 skupin – na telefonu dvě karty vedle sebe.
class GroupGrid extends StatelessWidget {
  const GroupGrid({super.key, required this.recipes, required this.onSelected});

  final List<Recipe> recipes;
  final ValueChanged<RecipeGroup> onSelected;

  @override
  Widget build(BuildContext context) {
    final byGroup = {for (final g in recipeGroups) g.id: <Recipe>[]};
    for (final r in recipes) {
      if (r.isDeleted) continue;
      byGroup[groupOf(r).id]!.add(r);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 600
            ? 3
            : 2;
        const gap = 12.0;
        final width = constraints.maxWidth - 32;
        final cardWidth = (width - gap * (columns - 1)) / columns;
        final height = cardWidth / 1.32;
        final rows = <List<RecipeGroup>>[
          for (var i = 0; i < recipeGroups.length; i += columns)
            recipeGroups.sublist(
              i,
              (i + columns).clamp(0, recipeGroups.length),
            ),
        ];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              for (final (index, row) in rows.indexed)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: index == rows.length - 1 ? 0 : gap,
                  ),
                  child: SizedBox(
                    height: height,
                    // Neúplná poslední řada se roztáhne na celou šířku.
                    child: Row(
                      children: [
                        for (final (i, group) in row.indexed) ...[
                          if (i > 0) const SizedBox(width: gap),
                          Expanded(
                            child: GroupCard(
                              group: group,
                              recipes: byGroup[group.id]!,
                              onTap: () => onSelected(group),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Fotografická karta receptu se srdíčkem (oblíbené, výsledky hledání).
class RecipePhotoCard extends ConsumerWidget {
  const RecipePhotoCard({
    super.key,
    required this.recipe,
    this.showMeta = true,
    this.timeMode = TimeMode.total,
  });

  final Recipe recipe;
  final bool showMeta;

  /// Který čas ukázat pod názvem (celkový / aktivní práce).
  final TimeMode timeMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: AppColors.card,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_cardRadius),
        side: const BorderSide(color: _cardBorder),
      ),
      child: InkWell(
        onTap: () => context.push(Routes.recipe(recipe.id)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  recipe.photos.isEmpty
                      ? Image.asset(groupOf(recipe).asset, fit: BoxFit.cover)
                      : RecipeCover(recipe: recipe),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _HeartButton(recipe: recipe),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recipe.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      height: 1.2,
                    ),
                  ),
                  if (showMeta)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        [
                          groupOf(recipe).label,
                          timeLabelOf(recipe, mode: timeMode),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeartButton extends ConsumerWidget {
  const _HeartButton({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = recipe.isFavorite;
    return Semantics(
      button: true,
      label: on ? 'Odebrat z oblíbených' : 'Přidat mezi oblíbené',
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          final repository = await ref.read(recipeRepositoryProvider.future);
          await repository.setFavorite(recipe.id, !on);
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? const Color(0xFFE53935) : const Color(0x99000000),
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Icon(
              on ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

/// Vodorovný pás oblíbených receptů.
class FavoritesStrip extends StatelessWidget {
  const FavoritesStrip({super.key, required this.recipes});

  final List<Recipe> recipes;

  @override
  Widget build(BuildContext context) {
    if (recipes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Zatím nemáte oblíbené recepty. Přidáte je srdíčkem u receptu.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return SizedBox(
      height: 196,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: recipes.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) => SizedBox(
          width: 150,
          child: RecipePhotoCard(recipe: recipes[index], showMeta: false),
        ),
      ),
    );
  }
}

/// Mřížka receptů (výsledky hledání a filtrů).
class RecipeResultsGrid extends StatelessWidget {
  const RecipeResultsGrid({
    super.key,
    required this.recipes,
    this.timeMode = TimeMode.total,
  });

  final List<Recipe> recipes;
  final TimeMode timeMode;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 600
            ? 3
            : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.78,
          ),
          itemCount: recipes.length,
          itemBuilder: (context, index) =>
              RecipePhotoCard(recipe: recipes[index], timeMode: timeMode),
        );
      },
    );
  }
}

/// Samostatná stránka s recepty podle filtru (štítek, způsob přípravy).
class FilteredRecipesPage extends ConsumerWidget {
  const FilteredRecipesPage({
    super.key,
    required this.title,
    required this.filters,
  });

  final String title;
  final RecipeFilters filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(recipesProvider).value ?? const <Recipe>[];
    final list = filters.apply(
      all,
    )..sort((a, b) => foldForSearch(a.title).compareTo(foldForSearch(b.title)));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: list.isEmpty
          ? const EmptyState(
              icon: Icons.sell_outlined,
              title: 'Žádné recepty',
              message: 'Sem zatím žádný recept nepatří.',
            )
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text(
                    receptyCount(list.length),
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                RecipeResultsGrid(recipes: list),
              ],
            ),
    );
  }
}

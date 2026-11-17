import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/recipe_groups.dart';
import '../../data/recipe.dart';
import '../home/home_widgets.dart';

/// Záložka „Štítky“: vlastní štítky receptů (příležitosti i další)
/// a způsoby přípravy, které recepty skutečně uvádějí.
class TagsScreen extends ConsumerWidget {
  const TagsScreen({super.key});

  void _open(BuildContext context, String title, RecipeFilters filters) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FilteredRecipesPage(title: title, filters: filters),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipes = [
      for (final r in ref.watch(recipesProvider).value ?? const <Recipe>[])
        if (!r.isDeleted) r,
    ];
    final tags = tagCounts(recipes);
    final occasionCounts = {
      for (final o in occasionTags)
        o: recipes.where((r) => hasTag(r, o)).length,
    };
    final custom = [
      for (final t in tags)
        if (!occasionTags.any((o) => o.toLowerCase() == t.key.toLowerCase())) t,
    ];
    final prepCounts = {
      for (final p in PrepMethod.values)
        p: recipes.where((r) => prepMethodsOf(r).contains(p)).length,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Štítky')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HomeSectionHeader(
              icon: Icons.star_outline_rounded,
              title: 'Podle příležitosti',
            ),
            _Wrap(
              children: [
                for (final o in occasionTags)
                  FilterPill(
                    label: '$o · ${occasionCounts[o]}',
                    selected: false,
                    onTap: () =>
                        _open(context, o, RecipeFilters(occasions: {o})),
                  ),
              ],
            ),
            if (occasionCounts.values.every((n) => n == 0))
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  'Příležitosti přidáte v úpravě receptu v části Štítky. '
                  'Aplikace je sama nedomýšlí.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            const HomeSectionHeader(
              icon: Icons.local_fire_department_outlined,
              title: 'Podle přípravy',
            ),
            _Wrap(
              children: [
                for (final p in PrepMethod.values)
                  FilterPill(
                    icon: p.icon,
                    label: '${p.label} · ${prepCounts[p]}',
                    selected: false,
                    onTap: () =>
                        _open(context, p.label, RecipeFilters(prep: {p})),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                'Způsob přípravy se pozná z postupu, teplot a vybavení receptu.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ),
            const HomeSectionHeader(
              icon: Icons.sell_outlined,
              title: 'Vlastní štítky',
            ),
            if (custom.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: EmptyHint(
                  'Zatím žádné vlastní štítky. Přidáte je v úpravě receptu.',
                ),
              )
            else
              _Wrap(
                children: [
                  for (final t in custom)
                    FilterPill(
                      icon: Icons.sell_outlined,
                      label: '${t.key} · ${t.value}',
                      selected: false,
                      onTap: () =>
                          _open(context, t.key, RecipeFilters(tag: t.key)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Wrap extends StatelessWidget {
  const _Wrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}

/// Šedý vysvětlující text.
class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: AppColors.textSecondary));
}

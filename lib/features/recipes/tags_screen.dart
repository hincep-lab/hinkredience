import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/recipe_groups.dart';
import '../../data/recipe.dart';
import '../home/home_widgets.dart';

/// Záložka „Štítky“: způsoby přípravy, příležitosti, světové kuchyně
/// a vlastní štítky. Klepnutím se štítky vybírají a kombinují – recept musí
/// mít všechny vybrané štítky (u kuchyní stačí kterákoli z vybraných).
class TagsScreen extends ConsumerStatefulWidget {
  const TagsScreen({super.key});

  @override
  ConsumerState<TagsScreen> createState() => _TagsScreenState();
}

class _TagsScreenState extends ConsumerState<TagsScreen> {
  var _filters = const RecipeFilters();

  void _open(String title, RecipeFilters filters) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FilteredRecipesPage(title: title, filters: filters),
      ),
    );
  }

  Set<T> _toggled<T>(Set<T> set, T value) {
    final next = {...set};
    if (!next.remove(value)) next.add(value);
    return next;
  }

  String _title() {
    final f = _filters;
    return [
      for (final p in PrepMethod.values)
        if (f.prep.contains(p)) p.label,
      ...f.occasions,
      ...f.cuisines,
      ...f.tags,
      if (f.withoutPhoto) 'Bez fotky',
    ].join(' + ');
  }

  @override
  Widget build(BuildContext context) {
    final recipes = [
      for (final r in ref.watch(recipesProvider).value ?? const <Recipe>[])
        if (!r.isDeleted) r,
    ];
    final f = _filters;
    int count(RecipeFilters filters) => filters.apply(recipes).length;
    final custom = [
      for (final t in tagCounts(recipes))
        if (tagKindOf(t.key) == TagKind.other) t,
    ];
    final cuisines = cuisinesIn(recipes);
    final withoutPhoto = recipes.where((r) => r.photos.isEmpty).length;
    final results = f.isEmpty ? null : f.apply(recipes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Štítky'),
        actions: [
          if (!f.isEmpty)
            TextButton(
              key: const Key('tags-clear'),
              onPressed: () => setState(() => _filters = const RecipeFilters()),
              child: const Text('Zrušit výběr'),
            ),
        ],
      ),
      bottomNavigationBar: results == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  key: const Key('tags-show'),
                  onPressed: results.isEmpty
                      ? null
                      : () => _open(_title(), _filters),
                  icon: const Icon(Icons.manage_search_rounded),
                  label: Text(
                    results.isEmpty
                        ? 'Žádný recept nemá všechny vybrané štítky'
                        : 'Zobrazit ${receptyCount(results.length)}',
                  ),
                ),
              ),
            ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Vyberte jeden nebo víc štítků. Recept musí mít všechny '
                'vybrané štítky; u kuchyní stačí kterákoli z vybraných.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ),
            HomeSectionHeader(
              icon: Icons.local_fire_department_outlined,
              title: TagKind.prep.label,
            ),
            _Wrap(
              children: [
                for (final p in PrepMethod.values)
                  FilterPill(
                    key: Key('tags-prep-${p.name}'),
                    iconAsset: p.iconAsset,
                    icon: p.icon,
                    label:
                        '${p.label} · '
                        '${count(RecipeFilters(prep: {p}))}',
                    selected: f.prep.contains(p),
                    onTap: () => setState(
                      () => _filters = f.copyWith(prep: _toggled(f.prep, p)),
                    ),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Recept může mít víc způsobů přípravy. Bez uloženého štítku '
                'se způsob pozná z postupu, teplot a vybavení.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ),
            HomeSectionHeader(
              icon: Icons.star_outline_rounded,
              title: TagKind.occasion.label,
            ),
            _Wrap(
              children: [
                for (final o in occasionTags)
                  FilterPill(
                    label: '$o · ${count(RecipeFilters(occasions: {o}))}',
                    selected: f.occasions.contains(o),
                    onTap: () => setState(
                      () => _filters = f.copyWith(
                        occasions: _toggled(f.occasions, o),
                      ),
                    ),
                  ),
              ],
            ),
            HomeSectionHeader(
              icon: Icons.public_rounded,
              title: TagKind.cuisine.label,
            ),
            if (cuisines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: EmptyHint(
                  'Zatím žádný recept nemá štítek kuchyně. Přidáte ho v úpravě '
                  'receptu.',
                ),
              )
            else
              _Wrap(
                children: [
                  for (final c in cuisines)
                    FilterPill(
                      label: '$c · ${count(RecipeFilters(cuisines: {c}))}',
                      selected: f.cuisines.contains(c),
                      onTap: () => setState(
                        () => _filters = f.copyWith(
                          cuisines: _toggled(f.cuisines, c),
                        ),
                      ),
                    ),
                ],
              ),
            HomeSectionHeader(
              icon: Icons.sell_outlined,
              title: TagKind.other.label,
            ),
            if (custom.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: EmptyHint(
                  'Zatím žádné další štítky. Přidáte je v úpravě receptu.',
                ),
              )
            else
              _Wrap(
                children: [
                  for (final t in custom)
                    FilterPill(
                      icon: Icons.sell_outlined,
                      label: '${t.key} · ${t.value}',
                      selected: f.tags.contains(t.key),
                      onTap: () => setState(
                        () => _filters = f.copyWith(
                          tags: _toggled(f.tags, t.key),
                        ),
                      ),
                    ),
                ],
              ),
            const HomeSectionHeader(
              icon: Icons.fact_check_outlined,
              title: 'Kontrola receptů',
            ),
            _Wrap(
              children: [
                FilterPill(
                  key: const Key('tags-no-photo'),
                  icon: Icons.no_photography_outlined,
                  label: 'Bez fotky · $withoutPhoto',
                  selected: f.withoutPhoto,
                  onTap: () => setState(
                    () => _filters = f.copyWith(withoutPhoto: !f.withoutPhoto),
                  ),
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

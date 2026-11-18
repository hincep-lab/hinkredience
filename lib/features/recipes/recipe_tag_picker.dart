import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/recipe_groups.dart';
import '../../data/recipe.dart';

/// Výběr štítků receptu: způsob přípravy (lze víc najednou), příležitosti
/// a světová kuchyně.
/// Ostatní (vlastní) štítky v seznamu zůstanou beze změny.
class RecipeTagPicker extends StatelessWidget {
  const RecipeTagPicker({
    super.key,
    required this.tags,
    required this.onChanged,
    this.suggest,
  });

  final List<String> tags;
  final ValueChanged<List<String>> onChanged;

  /// Odhad způsobů přípravy z postupu, vybavení a surovin (tlačítko
  /// „Navrhnout podle postupu“). Bez něj se tlačítko neukáže.
  final Set<PrepMethod> Function()? suggest;

  bool _has(String tag) => tags.any((t) => sameTag(t, tag));

  Widget _chip(String label, {IconData? icon, String? iconAsset}) {
    final selected = _has(label);
    return FilterChip(
      key: Key('tag-chip-$label'),
      avatar: iconAsset != null
          ? ImageIcon(AssetImage(iconAsset), size: 18)
          : icon == null
          ? null
          : Icon(icon, size: 18),
      showCheckmark: iconAsset == null && icon == null,
      label: Text(label),
      selected: selected,
      selectedColor: AppColors.copper.withValues(alpha: 0.35),
      onSelected: (on) => onChanged(toggleTag(tags, label, on)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final noPrep = !PrepMethod.values.any((m) => _has(m.tag));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('Způsob přípravy'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in PrepMethod.values)
              _chip(m.label, iconAsset: m.iconAsset, icon: m.icon),
          ],
        ),
        if (suggest != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('suggest-prep'),
              onPressed: () {
                var next = tags;
                for (final m in suggest!()) {
                  next = toggleTag(next, m.tag, true);
                }
                onChanged(next);
              },
              icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
              label: const Text('Navrhnout podle postupu a vybavení'),
            ),
          ),
        if (noPrep)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Bez zvoleného způsobu přípravy se ve filtrech použije odhad '
              'z postupu receptu.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ),
        const SizedBox(height: 8),
        const _Label('Příležitost'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final t in suggestedTags) _chip(t)],
        ),
        const SizedBox(height: 8),
        const _Label('Světová kuchyně'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in {
              ...cuisineTags,
              // Vlastní kuchyně, které recept už má (např. „Gruzínská“).
              for (final t in tags)
                if (isCuisineTag(t) && !cuisineTags.any((c) => sameTag(c, t)))
                  t,
            })
              _chip(t),
          ],
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    ),
  );
}

/// Spodní panel pro rychlou úpravu štítků z detailu receptu. Uloží se bez
/// nové verze receptu a synchronizuje se jako ostatní změny.
Future<void> showRecipeTagsSheet(
  BuildContext context,
  WidgetRef ref,
  Recipe recipe,
) async {
  var tags = [...recipe.tags];
  if (savedPrepMethods(recipe).isEmpty) {
    // Recept zatím nemá uložený způsob přípravy – předvyplní se odhad.
    for (final m in inferPrepMethods(recipe)) {
      tags = toggleTag(tags, m.tag, true);
    }
  }
  final result = await showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Štítky receptu',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              RecipeTagPicker(
                tags: tags,
                onChanged: (next) => setSheet(() => tags = next),
                suggest: () => inferPrepMethods(recipe),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('save-tags'),
                onPressed: () => Navigator.of(context).pop(tags),
                child: const Text('Uložit štítky'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (result == null) return;
  final repository = await ref.read(recipeRepositoryProvider.future);
  await repository.setTags(recipe.id, result);
}

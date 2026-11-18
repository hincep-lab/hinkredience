import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';

/// Výběr receptu z kuchařky (s hledáním). Vrací recept, nebo `null`.
Future<Recipe?> pickRecipe(
  BuildContext context, {
  String title = 'Vyberte recept',
}) => showModalBottomSheet<Recipe>(
  context: context,
  isScrollControlled: true,
  builder: (context) => FractionallySizedBox(
    heightFactor: 0.85,
    child: _RecipePicker(title: title),
  ),
);

class _RecipePicker extends ConsumerStatefulWidget {
  const _RecipePicker({required this.title});

  final String title;

  @override
  ConsumerState<_RecipePicker> createState() => _RecipePickerState();
}

class _RecipePickerState extends ConsumerState<_RecipePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final recipes = ref.watch(recipesProvider).value ?? const <Recipe>[];
    final query = foldForSearch(_query);
    final shown = [
      for (final r in recipes)
        if (query.isEmpty || foldForSearch(r.title).contains(query)) r,
    ]..sort((a, b) => a.title.compareTo(b.title));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: false,
                decoration: const InputDecoration(
                  hintText: 'Hledat recept',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('Žádný recept neodpovídá.'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final recipe = shown[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: RecipeCover(recipe: recipe),
                            ),
                          ),
                          title: Text(recipe.title),
                          subtitle: Text(recipe.category),
                          onTap: () => Navigator.of(context).pop(recipe),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

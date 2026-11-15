import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/shopping.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';

const _newList = '__new__';

/// „Přidat do nákupního seznamu“ z receptu: výběr seznamu, počet porcí
/// s přepočtem, odškrtnutí surovin, které jsou doma, a nabídka sloučení
/// se stejnými položkami na seznamu.
Future<void> showAddRecipeToShopping(
  BuildContext context, {
  required Recipe recipe,
  double? servings,
}) async {
  final result =
      await showModalBottomSheet<({ShoppingList list, ShoppingMerge merge})>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => _AddRecipeSheet(
          recipe: recipe,
          initialServings: servings ?? recipe.servings,
        ),
      );
  if (result == null || !context.mounted) return;
  final merge = result.merge;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          '„${result.list.name}“: ${merge.added} nových'
          '${merge.merged > 0 ? ', ${merge.merged} sečteno' : ''}.',
        ),
        action: SnackBarAction(
          label: 'Otevřít',
          onPressed: () => context.push(Routes.shoppingList(result.list.id)),
        ),
      ),
    );
}

class _AddRecipeSheet extends ConsumerStatefulWidget {
  const _AddRecipeSheet({required this.recipe, required this.initialServings});

  final Recipe recipe;
  final double initialServings;

  @override
  ConsumerState<_AddRecipeSheet> createState() => _AddRecipeSheetState();
}

class _AddRecipeSheetState extends ConsumerState<_AddRecipeSheet> {
  late double _servings = widget.initialServings > 0
      ? widget.initialServings
      : (widget.recipe.servings > 0 ? widget.recipe.servings : 4);
  String? _listId;
  late final _newName = TextEditingController(text: widget.recipe.title);

  /// Indexy surovin, které uživatel má doma (nepřidávat).
  final _atHome = <int>{};

  /// Indexy návrhů (v [_drafts]), které se NEMAJÍ sloučit.
  final _keepSeparate = <int>{};
  bool _saving = false;

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  double get _factor {
    final base = widget.recipe.servings;
    return base <= 0 ? 1 : _servings / base;
  }

  double get _step => widget.recipe.servings >= 1 ? 1 : 0.5;

  List<Ingredient> get _ingredients => widget.recipe.ingredients;

  /// Suroviny k přidání (bez těch, které jsou doma), přepočtené.
  List<ShoppingDraft> get _drafts => [
    for (var i = 0; i < _ingredients.length; i++)
      if (!_atHome.contains(i))
        ShoppingDraft(
          name: _ingredients[i].name,
          quantity: _ingredients[i].quantity == null
              ? null
              : _ingredients[i].quantity! * _factor,
          unit: _ingredients[i].unit,
          note: _ingredients[i].note,
          source: widget.recipe.title,
          category: guessCategory(_ingredients[i].name),
        ),
  ];

  Future<void> _save(List<ShoppingDraft> drafts) async {
    if (drafts.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final docs = await ref.read(docsRepositoryProvider.future);
      final list = _listId == null || _listId == _newList
          ? await docs.createShoppingList(
              _newName.text.trim().isEmpty
                  ? widget.recipe.title
                  : _newName.text.trim(),
            )
          : (await docs.shoppingList(_listId!))!;
      final merge = await docs.addToShopping(
        drafts,
        listId: list.id,
        keepSeparate: _keepSeparate,
      );
      if (mounted) Navigator.of(context).pop((list: list, merge: merge));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(shoppingListsProvider).value ?? const [];
    final selected =
        _listId ?? (lists.isEmpty ? _newList : lists.first.list.id);
    final isNew = selected == _newList;
    final existing = isNew
        ? const <ShoppingItem>[]
        : ref.watch(shoppingItemsProvider(selected)).value ?? const [];
    final drafts = _drafts;
    final proposals = planShoppingMerge(existing: existing, additions: drafts);
    final recipe = widget.recipe;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              children: [
                Text(
                  'Přidat do nákupního seznamu',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  recipe.title,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('$selected/${lists.length}'),
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Seznam'),
                  items: [
                    for (final s in lists)
                      DropdownMenuItem(
                        value: s.list.id,
                        child: Text(
                          '${s.list.name} (${s.remaining})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const DropdownMenuItem(
                      value: _newList,
                      child: Text('＋ Nový seznam'),
                    ),
                  ],
                  onChanged: (value) => setState(() {
                    _listId = value;
                    _keepSeparate.clear();
                  }),
                ),
                if (isNew) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _newName,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Název nového seznamu',
                      counterText: '',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Počet porcí',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Méně',
                      iconSize: 28,
                      onPressed: _servings - _step <= 0
                          ? null
                          : () => setState(() => _servings -= _step),
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    SizedBox(
                      width: 96,
                      child: Text(
                        yieldLabel(_servings, recipe.yieldUnit),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.copperGold,
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Více',
                      iconSize: 28,
                      onPressed: () => setState(() => _servings += _step),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Suroviny – odškrtněte, co máte doma',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                for (var i = 0; i < _ingredients.length; i++)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: !_atHome.contains(i),
                    onChanged: (value) => setState(() {
                      value == true ? _atHome.remove(i) : _atHome.add(i);
                      _keepSeparate.clear();
                    }),
                    title: Text(_ingredients[i].name),
                    secondary: Text(
                      formatTotalAmount(
                        _ingredients[i].quantity == null
                            ? null
                            : _ingredients[i].quantity! * _factor,
                        _ingredients[i].unit,
                      ),
                      style: const TextStyle(color: AppColors.copperGold),
                    ),
                    subtitle: _atHome.contains(i)
                        ? const Text('Mám doma')
                        : null,
                  ),
                if (proposals.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Už je na seznamu – sečíst?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  for (final p in proposals)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: !_keepSeparate.contains(p.draftIndex),
                      onChanged: (merge) => setState(
                        () => merge
                            ? _keepSeparate.remove(p.draftIndex)
                            : _keepSeparate.add(p.draftIndex),
                      ),
                      title: Text(p.describe()),
                      subtitle: Text(
                        _keepSeparate.contains(p.draftIndex)
                            ? 'Přidá se jako samostatná položka'
                            : 'Sečte se do jedné položky',
                      ),
                    ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                ),
                onPressed: drafts.isEmpty || _saving
                    ? null
                    : () {
                        _listId = selected;
                        _save(drafts);
                      },
                icon: const Icon(Icons.add_shopping_cart_rounded),
                label: Text(
                  drafts.isEmpty
                      ? 'Vše máte doma'
                      : 'Přidat ${drafts.length} surovin',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Výběr seznamu pro více receptů najednou (plán na týden).
/// Vrací id seznamu, nebo null po zrušení.
Future<String?> pickShoppingList(
  BuildContext context,
  WidgetRef ref, {
  required String suggestedName,
}) async {
  final lists = ref.read(shoppingListsProvider).value ?? const [];
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Do kterého seznamu?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: Text('Nový seznam „$suggestedName“'),
            onTap: () => Navigator.of(context).pop(_newList),
          ),
          for (final s in lists)
            ListTile(
              leading: const Icon(Icons.shopping_cart_outlined),
              title: Text(s.list.name),
              subtitle: Text('Zbývá ${s.remaining}'),
              onTap: () => Navigator.of(context).pop(s.list.id),
            ),
        ],
      ),
    ),
  );
  if (choice == null) return null;
  if (choice != _newList) return choice;
  final docs = await ref.read(docsRepositoryProvider.future);
  return (await docs.createShoppingList(suggestedName)).id;
}

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';
import 'recipe_picker.dart';
import 'add_to_shopping_sheet.dart';
import 'shopping_screen.dart';
import 'wishes.dart';

const _dayNames = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];

/// Týdenní plán vaření: snídaně, obědy a večeře. V rodině společný.
class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key});

  @override
  ConsumerState<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends ConsumerState<PlanScreen> {
  late DateTime _monday = weekStart(DateTime.now());

  void _moveWeek(int weeks) => setState(
    () => _monday = DateTime(
      _monday.year,
      _monday.month,
      _monday.day + 7 * weeks,
    ),
  );

  Future<void> _addMeal(DateTime day, String mealType) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: const Text('Recept z kuchařky'),
              onTap: () => Navigator.of(context).pop('recipe'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: const Text('Vlastní jídlo (jen název)'),
              onTap: () => Navigator.of(context).pop('text'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    if (choice == 'recipe') {
      if (!mounted) return;
      final recipe = await pickRecipe(context, title: MealType.label(mealType));
      if (recipe == null) return;
      await docs.saveMeal(
        MealPlanEntry(
          id: docs.newId(),
          day: dayKey(day),
          mealType: mealType,
          recipeId: recipe.id,
          title: recipe.title,
          servings: recipe.servings,
          updatedAt: docs.now(),
        ),
      );
    } else {
      if (!mounted) return;
      final title = await _askText('Co bude k jídlu?');
      if (title == null || title.isEmpty) return;
      await docs.saveMeal(
        MealPlanEntry(
          id: docs.newId(),
          day: dayKey(day),
          mealType: mealType,
          title: title,
          updatedAt: docs.now(),
        ),
      );
    }
  }

  Future<String?> _askText(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
  }

  Future<void> _mealOptions(MealPlanEntry entry, Recipe? recipe) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (recipe != null)
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Otevřít recept'),
                onTap: () => Navigator.of(context).pop('open'),
              ),
            if (recipe != null)
              ListTile(
                leading: const Icon(Icons.restaurant_rounded),
                title: const Text('Vařit'),
                onTap: () => Navigator.of(context).pop('cook'),
              ),
            if (recipe != null)
              ListTile(
                leading: const Icon(Icons.people_outline_rounded),
                title: Text(
                  'Počet: ${yieldLabel(entry.servings ?? recipe.servings, recipe.yieldUnit)}',
                ),
                onTap: () => Navigator.of(context).pop('servings'),
              ),
            ListTile(
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: Text(
                entry.note.isEmpty
                    ? 'Přidat poznámku'
                    : 'Poznámka: ${entry.note}',
              ),
              onTap: () => Navigator.of(context).pop('note'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.danger,
              ),
              title: const Text('Odebrat z plánu'),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    switch (action) {
      case 'open':
        if (mounted) context.push(Routes.recipe(recipe!.id));
      case 'cook':
        if (mounted) {
          context.push(Routes.cook(recipe!.id, servings: entry.servings));
        }
      case 'servings':
        final text = await _askText(
          'Kolik ${recipe!.yieldUnit == 'ks' ? 'kusů' : 'porcí'}?',
          initial: formatNumber(entry.servings ?? recipe.servings),
        );
        final value = double.tryParse((text ?? '').replaceAll(',', '.'));
        if (value != null && value > 0) {
          await docs.saveMeal(entry.copyWith(servings: value));
        }
      case 'note':
        final note = await _askText('Poznámka', initial: entry.note);
        if (note != null) await docs.saveMeal(entry.copyWith(note: note));
      case 'remove':
        await docs.deleteMeal(entry.id);
    }
  }

  Future<void> _shopForWeek(List<MealPlanEntry> entries) async {
    final recipes = ref.read(recipesProvider).value ?? const <Recipe>[];
    final drafts = [
      for (final entry in entries)
        if (recipes.firstWhereOrNull((r) => r.id == entry.recipeId)
            case final recipe?)
          ...recipeShoppingDrafts(
            title: recipe.title,
            recipeServings: recipe.servings,
            servings: entry.servings ?? recipe.servings,
            ingredients: [
              for (final i in recipe.ingredients)
                (name: i.name, quantity: i.quantity, unit: i.unit),
            ],
          ),
    ];
    if (drafts.isEmpty) {
      showMessage(context, 'V tomto týdnu nejsou naplánované žádné recepty.');
      return;
    }
    final listId = await pickShoppingList(
      context,
      ref,
      suggestedName: 'Týden od ${_monday.day}. ${_monday.month}.',
    );
    if (listId == null || !mounted) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    final result = await docs.addToShopping(drafts, listId: listId);
    if (!mounted) return;
    showMessage(
      context,
      'Na seznam přidáno: ${result.added}, sečteno se stávajícími: ${result.merged}.',
    );
    context.push(Routes.shoppingList(listId));
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(weekPlanProvider(_monday)).value ?? const [];
    final recipes = ref.watch(recipesProvider).value ?? const <Recipe>[];
    final sunday = _monday.add(const Duration(days: 6));
    final today = dayKey(DateTime.now());
    final shared = ref.watch(householdProvider).value != null;
    final aiEnabled = ref.watch(aiEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plán vaření'),
        actions: [
          if (aiEnabled)
            IconButton(
              tooltip: 'Navrhnout jídelníček s AI',
              icon: const Icon(Icons.auto_awesome_rounded),
              onPressed: () => context.push(Routes.ai),
            ),
          IconButton(
            tooltip: 'Nakoupit na tento týden',
            icon: const Icon(Icons.add_shopping_cart_rounded),
            onPressed: () => _shopForWeek(entries),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Předchozí týden',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () => _moveWeek(-1),
              ),
              Expanded(
                child: Text(
                  '${_monday.day}. ${_monday.month}. – ${sunday.day}. ${sunday.month}. ${sunday.year}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Další týden',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: () => _moveWeek(1),
              ),
            ],
          ),
          if (shared)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'Plán je společný pro celou rodinu.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ),
          const WishesSection(),
          for (var i = 0; i < 7; i++)
            () {
              final day = DateTime(
                _monday.year,
                _monday.month,
                _monday.day + i,
              );
              final key = dayKey(day);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: HkCard(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_dayNames[i]} ${day.day}. ${day.month}.${key == today ? ' · dnes' : ''}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: key == today ? AppColors.copperGold : null,
                        ),
                      ),
                      for (final meal in MealType.all)
                        _mealRow(day, meal, [
                          for (final e in entries)
                            if (e.day == key && e.mealType == meal) e,
                        ], recipes),
                    ],
                  ),
                ),
              );
            }(),
        ],
      ),
    );
  }

  Widget _mealRow(
    DateTime day,
    String meal,
    List<MealPlanEntry> planned,
    List<Recipe> recipes,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              MealType.label(meal),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in planned)
                ActionChip(
                  label: Text(
                    entry.recipeId == null
                        ? entry.title
                        : (recipes
                                  .firstWhereOrNull(
                                    (r) => r.id == entry.recipeId,
                                  )
                                  ?.title ??
                              entry.title),
                  ),
                  avatar: Icon(
                    entry.recipeId == null
                        ? Icons.edit_note_rounded
                        : Icons.menu_book_rounded,
                    size: 18,
                  ),
                  onPressed: () => _mealOptions(
                    entry,
                    recipes.firstWhereOrNull((r) => r.id == entry.recipeId),
                  ),
                ),
              IconButton(
                tooltip:
                    'Přidat: ${MealType.label(meal)} ${day.day}. ${day.month}.',
                icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
                onPressed: () => _addMeal(day, meal),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

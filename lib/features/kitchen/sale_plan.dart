import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/kitchen_math.dart' show foldText;
import '../../core/material.dart';
import '../../core/sale_dishes.dart';
import '../../core/stores.dart';
import '../../core/week_menu.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';
import 'shopping_screen.dart' show recipeShoppingDrafts;

/// Kolik porcí se uvaří najednou a na kolik jídel vystačí (uloženo
/// v telefonu; výchozí 6 porcí na 3 jídla: oběd, večeře, oběd).
class MenuPortions {
  const MenuPortions(this.portions, this.meals);

  final int portions;
  final int meals;

  static const _portionsKey = 'menu_portions';
  static const _mealsKey = 'menu_meals';

  static MenuPortions read(SharedPreferences prefs) => MenuPortions(
    prefs.getInt(_portionsKey) ?? 6,
    prefs.getInt(_mealsKey) ?? 3,
  );

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setInt(_portionsKey, portions);
    await prefs.setInt(_mealsKey, meals);
  }
}

String chainName(String? chain) =>
    chain == null ? '' : chainById(chain)?.name ?? chain;

/// Recept z kuchařky se stejným názvem, jinak se jídlo uloží jako nový recept.
Future<Recipe> ensureRecipe(WidgetRef ref, Dish dish) async {
  final repository = await ref.read(recipeRepositoryProvider.future);
  final recipes = ref.read(allRecipesProvider).value ?? const <Recipe>[];
  final title = foldText(dish.title.trim());
  for (final r in recipes) {
    if (r.deletedAt == null && foldText(r.title.trim()) == title) return r;
  }
  return repository.create(
    dishToRecipe(
      dish,
      newId: repository.newId,
      now: repository.now().toUtc(),
      ownerId: ref.read(sessionProvider).userId,
    ),
  );
}

/// Zapíše jedno vaření do plánu vaření: první jídlo s receptem a počtem
/// porcí (podle něj se nakupuje), další jídla jako „zbytek“ bez receptu,
/// aby se suroviny na nákupní seznam nepočítaly dvakrát.
Future<void> planCook(
  WidgetRef ref,
  DishOnSale item,
  List<MenuSlot> slots,
  int portions,
) async {
  if (slots.isEmpty) return;
  final recipe = await ensureRecipe(ref, item.dish);
  final docs = await ref.read(docsRepositoryProvider.future);
  final first = slots.first;
  final store = chainName(item.chain);
  for (final (i, slot) in slots.indexed) {
    await docs.saveMeal(
      MealPlanEntry(
        id: docs.newId(),
        day: dayKey(slot.day),
        mealType: slot.mealType,
        recipeId: i == 0 ? recipe.id : null,
        title: i == 0 ? recipe.title : '${recipe.title} (zbytek)',
        servings: i == 0 ? portions.toDouble() : null,
        note: i == 0
            ? 'Uvařit $portions porcí na ${slots.length} '
                  '${slots.length == 1 ? 'jídlo' : 'jídla'}'
                  '${store.isEmpty ? '' : ' · nákup: $store'}'
            : 'Zbytek z vaření: ${slotLabel(first)}',
        updatedAt: docs.now(),
      ),
    );
  }
}

/// Nákupní seznamy po obchodech: pro každý obchod jeden seznam se surovinami
/// všech jídel, která se v něm nakupují. Vrátí počet seznamů.
Future<int> shopForMenu(WidgetRef ref, WeekMenu menu, DateTime start) async {
  final docs = await ref.read(docsRepositoryProvider.future);
  final byChain = <String, List<MenuCook>>{};
  for (final cook in menu.cooks) {
    (byChain[cook.item.chain ?? ''] ??= []).add(cook);
  }
  for (final MapEntry(key: chain, value: cooks) in byChain.entries) {
    final name = chain.isEmpty ? 'Jídelníček' : chainName(chain);
    final list = await docs.createShoppingList(
      '$name – jídelníček od ${start.day}. ${start.month}.',
    );
    await docs.addToShopping([
      for (final cook in cooks)
        ...recipeShoppingDrafts(
          title: cook.item.dish.title,
          recipeServings: Dish.servings.toDouble(),
          servings: menu.portions.toDouble(),
          ingredients: [
            for (final i in cook.item.dish.ingredients)
              (name: i.name, quantity: i.quantity, unit: i.unit),
          ],
        ),
    ], listId: list.id);
  }
  return byChain.length;
}

/// „Přidat do jídelníčku“ u jednoho jídla: den, oběd/večeře a na kolik jídel.
Future<void> showAddDishToMenu(
  BuildContext context,
  WidgetRef ref,
  DishOnSale item,
) async {
  final prefs = ref.read(sharedPreferencesProvider);
  final defaults = MenuPortions.read(prefs);
  final today = DateTime.now();
  var day = DateTime(today.year, today.month, today.day);
  var meal = today.hour < 13 ? MealType.lunch : MealType.dinner;
  var meals = defaults.meals.clamp(1, 3);
  final perMeal = (defaults.portions / defaults.meals).clamp(1, 10);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) {
        final slots = menuSlots(
          day,
          days: 3,
          firstMeal: meal,
        ).take(meals).toList();
        final portions = (perMeal * meals).round();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Do jídelníčku: ${item.dish.title}',
                  style: Theme.of(sheet).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                const Text('Kdy se vaří'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var d = 0; d < 7; d++)
                      if (DateTime(today.year, today.month, today.day + d)
                          case final date)
                        ChoiceChip(
                          label: Text(
                            d == 0
                                ? 'Dnes'
                                : d == 1
                                ? 'Zítra'
                                : '${dayShort(date)} ${date.day}.',
                          ),
                          selected: day == date,
                          onSelected: (_) => setState(() => day = date),
                        ),
                  ],
                ),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: MealType.lunch, label: Text('Oběd')),
                    ButtonSegment(
                      value: MealType.dinner,
                      label: Text('Večeře'),
                    ),
                  ],
                  selected: {meal},
                  onSelectionChanged: (v) => setState(() => meal = v.first),
                ),
                const SizedBox(height: 12),
                const Text('Na kolik jídel vystačí'),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                  ],
                  selected: {meals},
                  onSelectionChanged: (v) => setState(() => meals = v.first),
                ),
                const SizedBox(height: 8),
                Text(
                  'Uvaří se $portions porcí: ${slots.map(slotLabel).join(', ')}'
                  '${item.chain == null ? '' : ' · nákup v ${chainName(item.chain)}'}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    await planCook(ref, item, slots, portions);
                    if (sheet.mounted) Navigator.of(sheet).pop(true);
                  },
                  icon: const Icon(Icons.event_available_rounded),
                  label: const Text('Přidat do jídelníčku'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Přidáno do plánu vaření.')));
  }
}

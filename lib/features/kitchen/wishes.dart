import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';
import 'recipe_picker.dart';

const _days = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];

/// „Pá 20. 11.“ z klíče dne `2026-11-20`.
String wishDayLabel(String key) {
  final date = DateTime.tryParse(key);
  if (date == null) return key;
  return '${_days[date.weekday - 1]} ${date.day}. ${date.month}.';
}

/// Přidá přání „mám chuť na…“. S [recipe] rovnou, jinak se zeptá, jestli
/// recept z kuchařky, nebo jen název (třeba „něco s houbami“).
Future<void> addWish(
  BuildContext context,
  WidgetRef ref, {
  Recipe? recipe,
}) async {
  var chosen = recipe;
  String? title = recipe?.title;
  if (chosen == null) {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Mám chuť na…',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: const Text('Recept z kuchařky'),
              onTap: () => Navigator.of(context).pop('recipe'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: const Text('Napsat vlastními slovy'),
              subtitle: const Text('Třeba „něco s houbami“ nebo „palačinky“'),
              onTap: () => Navigator.of(context).pop('text'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'recipe') {
      chosen = await pickRecipe(context, title: 'Mám chuť na…');
      title = chosen?.title;
    } else {
      title = await _askText(context, 'Na co máte chuť?');
    }
  }
  if (title == null || title.trim().isEmpty || !context.mounted) return;
  final note = await _askText(
    context,
    'Poznámka (nepovinné)',
    hint: 'Třeba „ideálně v sobotu“',
    allowEmpty: true,
  );
  if (note == null || !context.mounted) return;
  final docs = await ref.read(docsRepositoryProvider.future);
  final author = ref.read(settingsProvider).greetingName;
  await docs.saveWish(
    MealWish(
      id: docs.newId(),
      title: title.trim(),
      recipeId: chosen?.id,
      note: note,
      authorName: author,
      createdAt: docs.now(),
      updatedAt: docs.now(),
    ),
  );
  ref.read(syncProvider.notifier).schedule(const Duration(seconds: 1));
  if (context.mounted) {
    final shared = ref.read(householdProvider).value != null;
    showMessage(
      context,
      shared
          ? 'Přání „${title.trim()}“ uvidí celá rodina v plánu vaření.'
          : 'Přání „${title.trim()}“ je v plánu vaření.',
    );
  }
}

Future<String?> _askText(
  BuildContext context,
  String title, {
  String hint = '',
  bool allowEmpty = false,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: hint.isEmpty ? null : hint),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(allowEmpty ? 'Hotovo' : 'Uložit'),
        ),
      ],
    ),
  );
}

/// Naplánuje přání: vybere den (dnes + 13 dní) a jídlo, zapíše do plánu
/// vaření a přání označí jako naplánované.
Future<void> planWish(
  BuildContext context,
  WidgetRef ref,
  MealWish wish,
) async {
  final today = DateTime.now();
  final days = [
    for (var i = 0; i < 14; i++)
      DateTime(today.year, today.month, today.day + i),
  ];
  var day = days.first;
  var meal = MealType.lunch;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Naplánovat: ${wish.title}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final d in days)
                    ChoiceChip(
                      label: Text(
                        d == days.first
                            ? 'Dnes'
                            : d == days[1]
                            ? 'Zítra'
                            : wishDayLabel(dayKey(d)),
                      ),
                      selected: d == day,
                      onSelected: (_) => setState(() => day = d),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  for (final m in MealType.all)
                    ButtonSegment(value: m, label: Text(MealType.label(m))),
                ],
                selected: {meal},
                onSelectionChanged: (value) =>
                    setState(() => meal = value.first),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.event_available_rounded),
                label: const Text('Přidat do plánu'),
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final docs = await ref.read(docsRepositoryProvider.future);
  final recipes = ref.read(recipesProvider).value ?? const <Recipe>[];
  final recipe = recipes.firstWhereOrNull((r) => r.id == wish.recipeId);
  final key = dayKey(day);
  await docs.saveMeal(
    MealPlanEntry(
      id: docs.newId(),
      day: key,
      mealType: meal,
      recipeId: recipe?.id,
      title: wish.title,
      note: [
        if (wish.authorName.isNotEmpty) 'Přání: ${wish.authorName}',
        if (wish.note.isNotEmpty) wish.note,
      ].join(' · '),
      servings: recipe?.servings,
      updatedAt: docs.now(),
    ),
  );
  await docs.saveWish(wish.copyWith(plannedDay: key));
  ref.read(syncProvider.notifier).schedule(const Duration(seconds: 1));
  if (context.mounted) {
    showMessage(
      context,
      '${wish.title}: ${wishDayLabel(key)}, ${MealType.label(meal).toLowerCase()}.',
    );
  }
}

Future<void> _wishOptions(
  BuildContext context,
  WidgetRef ref,
  MealWish wish,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              wish.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: wish.note.isEmpty ? null : Text(wish.note),
          ),
          if (!wish.isPlanned)
            ListTile(
              leading: const Icon(Icons.event_available_rounded),
              title: const Text('Naplánovat'),
              onTap: () => Navigator.of(context).pop('plan'),
            ),
          if (wish.recipeId != null)
            ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: const Text('Otevřít recept'),
              onTap: () => Navigator.of(context).pop('open'),
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(wish.isPlanned ? 'Skrýt' : 'Smazat přání'),
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'plan':
      await planWish(context, ref, wish);
    case 'open':
      context.push(Routes.recipe(wish.recipeId!));
    case 'delete':
      final docs = await ref.read(docsRepositoryProvider.future);
      await docs.deleteWish(wish.id);
      ref.read(syncProvider.notifier).schedule(const Duration(seconds: 1));
  }
}

/// Sekce v plánu vaření: na co má rodina chuť + tlačítko „Mám chuť na…“.
class WishesSection extends ConsumerWidget {
  const WishesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wishes = ref.watch(wishesProvider).value ?? const <MealWish>[];
    final shared = ref.watch(householdProvider).value != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.restaurant_menu_rounded,
                  color: AppColors.copperGold,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    shared ? 'Na co má rodina chuť' : 'Na co mám chuť',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Mám chuť na…'),
                  onPressed: () => addWish(context, ref),
                ),
              ],
            ),
            if (wishes.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, right: 6),
                child: Text(
                  shared
                      ? 'Zatím nic. Kdokoli z rodiny sem může napsat, na co '
                            'má chuť, a ostatní to naplánují.'
                      : 'Zatím nic. Zapište si, na co máte chuť, a pak to '
                            'jedním klepnutím naplánujte.',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            for (final wish in wishes)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(right: 4),
                leading: Icon(
                  wish.isPlanned
                      ? Icons.event_available_rounded
                      : Icons.favorite_border_rounded,
                  color: wish.isPlanned
                      ? AppColors.textSecondary
                      : AppColors.copperGold,
                ),
                title: Text(
                  wish.title,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: wish.isPlanned ? AppColors.textSecondary : null,
                  ),
                ),
                subtitle: Text(
                  [
                    if (wish.authorName.isNotEmpty) wish.authorName,
                    if (wish.isPlanned)
                      'naplánováno: ${wishDayLabel(wish.plannedDay!)}',
                    if (wish.note.isNotEmpty) wish.note,
                  ].join(' · '),
                ),
                trailing: wish.isPlanned
                    ? null
                    : IconButton(
                        tooltip: 'Naplánovat',
                        icon: const Icon(Icons.event_rounded),
                        onPressed: () => planWish(context, ref, wish),
                      ),
                onTap: () => _wishOptions(context, ref, wish),
              ),
          ],
        ),
      ),
    );
  }
}

/// Samostatná obrazovka „Mám chuť“: na co má rodina chuť, přidání přání
/// a jeho naplánování jedním klepnutím.
class WishesScreen extends ConsumerWidget {
  const WishesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mám chuť')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-wish'),
        onPressed: () => addWish(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Mám chuť na…'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: const [WishesSection()],
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/shopping.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../core/best_buy.dart';
import 'best_buy_panel.dart';
import 'shopping_lists_screen.dart';

/// Množství položky k zobrazení („1,5 kg“, „3 ks“).
String shoppingAmount(ShoppingItem item) =>
    formatTotalAmount(item.quantity, item.unit);

/// Jeden nákupní seznam: položky po kategoriích, velká zaškrtávátka,
/// koupené zešednou (jdou vrátit), přidávání tlačítkem dole.
class ShoppingScreen extends ConsumerWidget {
  const ShoppingScreen({super.key, required this.listId});

  final String listId;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    while (context.mounted) {
      final result = await showShoppingItemSheet(context);
      if (result == null) return;
      final docs = await ref.read(docsRepositoryProvider.future);
      await docs.addToShopping([result.draft], listId: listId);
      if (!result.again) return;
    }
  }

  Future<void> _toggle(WidgetRef ref, ShoppingItem item) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveShoppingItem(item.copyWith(checked: !item.checked));
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    ShoppingItem item,
  ) async {
    final result = await showShoppingItemSheet(context, item: item);
    if (result == null) return;
    final d = result.draft;
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveShoppingItem(
      item.copyWith(
        name: d.name,
        quantity: d.quantity,
        unit: d.unit,
        category: d.category,
        note: d.note,
      ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ShoppingItem item,
  ) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.deleteShoppingItems([item.id]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('„${item.name}“ odstraněno'),
          action: SnackBarAction(
            label: 'Vrátit',
            onPressed: () => docs.saveShoppingItem(item),
          ),
        ),
      );
  }

  Future<void> _clearChecked(BuildContext context, WidgetRef ref) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    final count = await docs.clearChecked(listId);
    if (context.mounted && count > 0) {
      showMessage(context, 'Odstraněno nakoupených položek: $count');
    }
  }

  Future<void> _share(ShoppingList list, List<ShoppingItem> items) async {
    final open = [
      for (final i in items)
        if (!i.checked) i,
    ];
    if (open.isEmpty) return;
    final text = [
      list.name,
      for (final category in ShoppingCategory.all)
        if (open.where((i) => categoryOf(i) == category).toList()
            case final group when group.isNotEmpty) ...[
          '',
          '${ShoppingCategory.label(category)}:',
          for (final item in group) '• ${itemLine(item)}',
        ],
    ].join('\n');
    await SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(shoppingListProvider(listId));
    final itemsAsync = ref.watch(shoppingItemsProvider(listId));
    final list = listAsync.value;
    final items = itemsAsync.value ?? const <ShoppingItem>[];

    if (list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nákupní seznam')),
        body: listAsync.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                icon: Icons.remove_shopping_cart_outlined,
                title: 'Seznam neexistuje',
                message: 'Byl smazán, nebo ještě nedorazil z jiného zařízení.',
              ),
      );
    }

    final remaining = items.where((i) => !i.checked).length;
    final checked = items.length - remaining;
    final prefs = ref.watch(bestBuyPrefsProvider);
    final offers = ref.watch(priceOffersProvider).value ?? const <PriceOffer>[];
    final best = prefs.enabled ? ref.watch(bestBuyProvider(listId)) : null;
    final today = DateTime.now();
    final byStore =
        prefs.enabled &&
        prefs.multiStore &&
        prefs.groupByStore &&
        best != null &&
        best.combination.isNotEmpty;

    Widget tile(ShoppingItem item) {
      final tag = !prefs.enabled || item.checked
          ? null
          : bestOfferFor(buyItemOf(item), offers, today);
      return _ItemTile(
        item: item,
        onToggle: () => _toggle(ref, item),
        onEdit: () => _edit(context, ref, item),
        onRemove: () => _remove(context, ref, item),
        tag: tag == null
            ? null
            : OfferTag(
                offer: tag.offer,
                onTap: () => showOfferDetail(
                  context,
                  tag.offer,
                  unverified: unverifiedOffersFor(
                    buyItemOf(item),
                    offers,
                    today,
                  ),
                ),
              ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(list.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: prefs.enabled
                ? 'Skrýt nejvýhodnější nákup'
                : 'Zobrazit nejvýhodnější nákup',
            icon: Icon(
              prefs.enabled ? Icons.savings_rounded : Icons.savings_outlined,
              color: prefs.enabled ? AppColors.copperGold : null,
            ),
            onPressed: () => ref
                .read(bestBuyPrefsProvider.notifier)
                .update(prefs.copyWith(enabled: !prefs.enabled)),
          ),
          IconButton(
            tooltip: 'Sdílet seznam jako text',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: remaining == 0 ? null : () => _share(list, items),
          ),
          ShoppingListMenu(
            list: list,
            onDeleted: () {
              if (context.mounted && context.canPop()) context.pop();
            },
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-shopping-item',
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.add_rounded, size: 28),
        label: const Text('Přidat položku', style: TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          _Progress(
            remaining: remaining,
            total: items.length,
            shared: list.shared,
          ),
          if (items.isNotEmpty) BestBuyPanel(listId: listId),
          Expanded(
            child: items.isEmpty
                ? const EmptyState(
                    icon: Icons.shopping_basket_outlined,
                    title: 'Seznam je prázdný',
                    message:
                        'Přidejte položku tlačítkem dole, nebo v receptu '
                        'zvolte ⋯ → Přidat do nákupního seznamu. Stejné '
                        'suroviny se samy sečtou.',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 120),
                    children: [
                      if (byStore) ...[
                        // Varianta „více obchodů“: položky podle prodejen.
                        for (final entry
                            in best!.combinationByStore.entries) ...[
                          _StoreHeader(
                            title: entry.key.label,
                            subtotal: entry.value.fold(
                              0.0,
                              (sum, p) => sum + p.cost,
                            ),
                          ),
                          for (final p in entry.value)
                            if (items
                                    .where((i) => i.id == p.item.id)
                                    .firstOrNull
                                case final item?)
                              tile(item),
                        ],
                        if (best!.combinationMissing.isNotEmpty) ...[
                          const _StoreHeader(title: 'Bez známé ceny'),
                          for (final m in best!.combinationMissing)
                            if (items.where((i) => i.id == m.id).firstOrNull
                                case final item?)
                              tile(item),
                        ],
                        if (checked > 0) ...[
                          const _StoreHeader(title: 'Nakoupeno'),
                          for (final item in items)
                            if (item.checked) tile(item),
                        ],
                      ] else
                        for (final category in ShoppingCategory.all)
                          if (items
                                  .where((i) => categoryOf(i) == category)
                                  .toList()
                              case final group when group.isNotEmpty) ...[
                            _CategoryHeader(
                              category: category,
                              remaining: group.where((i) => !i.checked).length,
                            ),
                            for (final item in [
                              ...group.where((i) => !i.checked),
                              ...group.where((i) => i.checked),
                            ])
                              tile(item),
                          ],
                      if (checked > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 20, 8, 0),
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                            ),
                            onPressed: () => _clearChecked(context, ref),
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: Text('Odstranit nakoupené ($checked)'),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// „Kuřecí stehna s kostí – 1,5 kg (poznámka)“.
String itemLine(ShoppingItem item) {
  final amount = shoppingAmount(item);
  return [
    item.name,
    if (amount.isNotEmpty) ' – $amount',
    if (item.note.isNotEmpty) ' (${item.note})',
  ].join();
}

class _Progress extends StatelessWidget {
  const _Progress({
    required this.remaining,
    required this.total,
    required this.shared,
  });

  final int remaining;
  final int total;
  final bool shared;

  @override
  Widget build(BuildContext context) {
    if (total == 0 && !shared) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  remainingLabel(remaining, total),
                  style: const TextStyle(
                    color: AppColors.copperGold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (shared) ...[
                const Icon(
                  Icons.group_outlined,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Rodinný',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (total - remaining) / total,
                minHeight: 6,
                backgroundColor: AppColors.outline,
                color: AppColors.copper,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.category, required this.remaining});

  final String category;
  final int remaining;

  static IconData icon(String category) => switch (category) {
    ShoppingCategory.meat => Icons.set_meal_outlined,
    ShoppingCategory.vegetables => Icons.eco_outlined,
    ShoppingCategory.dairy => Icons.egg_outlined,
    ShoppingCategory.spices => Icons.grass_outlined,
    _ => Icons.shopping_basket_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 4),
      child: Row(
        children: [
          Icon(icon(category), size: 20, color: AppColors.copperGold),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ShoppingCategory.label(category),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (remaining > 0)
            Text(
              '$remaining',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// Nadpis skupiny podle prodejny (varianta více obchodů).
class _StoreHeader extends StatelessWidget {
  const _StoreHeader({required this.title, this.subtotal});

  final String title;
  final double? subtotal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 4),
      child: Row(
        children: [
          const Icon(
            Icons.store_outlined,
            size: 20,
            color: AppColors.copperGold,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (subtotal != null)
            Text(
              kc(subtotal!),
              style: const TextStyle(color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.onToggle,
    required this.onEdit,
    required this.onRemove,
    this.tag,
  });

  final ShoppingItem item;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  /// Štítek ověřené akce (obchod, cena, platnost).
  final Widget? tag;

  @override
  Widget build(BuildContext context) {
    final amount = shoppingAmount(item);
    final done = item.checked;
    final subtitle = [
      if (item.note.isNotEmpty) item.note,
      if (item.sources.isNotEmpty) item.sources.join(', '),
    ].join(' · ');
    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline_rounded),
      ),
      onDismissed: (_) => onRemove(),
      child: Opacity(
        opacity: done ? 0.55 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggle,
          onLongPress: onEdit,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Row(
              children: [
                Semantics(
                  label: done ? 'Koupeno' : 'Koupit',
                  child: Transform.scale(
                    scale: 1.4,
                    child: Checkbox(
                      value: done,
                      onChanged: (_) => onToggle(),
                      activeColor: AppColors.success,
                      side: const BorderSide(
                        color: AppColors.copperGold,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: TextStyle(
                            fontSize: 16.5,
                            decoration: done
                                ? TextDecoration.lineThrough
                                : null,
                            color: done ? AppColors.textSecondary : null,
                          ),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ?tag,
                      ],
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: onEdit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    child: Text(
                      amount.isEmpty ? '✎' : amount,
                      style: TextStyle(
                        fontSize: 15.5,
                        color: done
                            ? AppColors.textSecondary
                            : AppColors.copperGold,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Výsledek formuláře položky; [again] = přidat další.
typedef ShoppingItemResult = ({ShoppingDraft draft, bool again});

/// Formulář pro přidání nebo úpravu položky (spodní panel).
Future<ShoppingItemResult?> showShoppingItemSheet(
  BuildContext context, {
  ShoppingItem? item,
}) => showModalBottomSheet<ShoppingItemResult>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _ItemSheet(item: item),
);

class _ItemSheet extends StatefulWidget {
  const _ItemSheet({this.item});

  final ShoppingItem? item;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _amount = TextEditingController(
    text: widget.item?.quantity == null
        ? ''
        : formatNumber(widget.item!.quantity!),
  );
  late final _unit = TextEditingController(text: widget.item?.unit ?? '');
  late final _note = TextEditingController(text: widget.item?.note ?? '');
  late String? _category = widget.item == null
      ? null
      : categoryOf(widget.item!);

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _unit.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Kategorie: zvolená ručně, jinak odhad podle názvu.
  String get _effectiveCategory =>
      _category ?? guessCategory(_name.text.trim());

  void _submit({required bool again}) {
    var name = _name.text.trim();
    if (name.isEmpty) return;
    var quantity = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    var unit = _unit.text.trim();
    // „2 kg brambor“ napsané do názvu se rozdělí samo.
    if (widget.item == null && _amount.text.trim().isEmpty && unit.isEmpty) {
      final parsed = parseShoppingText(name);
      if (parsed.name.isNotEmpty) {
        name = parsed.name;
        quantity = parsed.quantity;
        unit = parsed.unit;
      }
    }
    Navigator.of(context).pop((
      draft: ShoppingDraft(
        name: name,
        quantity: quantity != null && quantity > 0 ? quantity : null,
        unit: unit,
        category: _category ?? guessCategory(name),
        note: _note.text.trim(),
      ),
      again: again,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.item != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              editing ? 'Upravit položku' : 'Přidat položku',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: !editing,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(again: !editing),
              decoration: const InputDecoration(
                labelText: 'Co koupit',
                hintText: 'Např. Mléko, nebo rovnou „2 kg brambor“',
                counterText: '',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amount,
                    decoration: const InputDecoration(labelText: 'Množství'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Jednotka',
                      hintText: 'g, kg, l, ks…',
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final category in ShoppingCategory.all)
                  ChoiceChip(
                    label: Text(ShoppingCategory.label(category)),
                    selected: _effectiveCategory == category,
                    onSelected: (_) => setState(() => _category = category),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Poznámka',
                hintText: 'Např. podle chuti, 31 %, bio',
                counterText: '',
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                if (!editing)
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () => _submit(again: true),
                      child: const Text('Přidat a další'),
                    ),
                  ),
                if (!editing) const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: () => _submit(again: false),
                    child: Text(editing ? 'Uložit' : 'Přidat'),
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

/// Suroviny receptu přepočtené na [servings] připravené pro nákupní seznam.
List<ShoppingDraft> recipeShoppingDrafts({
  required String title,
  required double recipeServings,
  required double servings,
  required Iterable<({String name, double? quantity, String unit})> ingredients,
}) {
  final factor = recipeServings <= 0 ? 1.0 : servings / recipeServings;
  return [
    for (final i in ingredients)
      ShoppingDraft(
        name: i.name,
        quantity: i.quantity == null ? null : i.quantity! * factor,
        unit: i.unit,
        source: title,
        category: guessCategory(i.name),
      ),
  ];
}

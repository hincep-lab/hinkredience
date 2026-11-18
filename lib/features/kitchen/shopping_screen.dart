import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/shopping.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';

/// Množství položky k zobrazení („1,5 kg“, „3 ks“).
String shoppingAmount(ShoppingItem item) =>
    formatTotalAmount(item.quantity, item.unit);

/// Nákupní seznam: ruční přidávání, suroviny z receptů a plánu (sloučené),
/// odškrtávání nakoupeného, v rodině společný.
class ShoppingScreen extends ConsumerStatefulWidget {
  const ShoppingScreen({super.key});

  @override
  ConsumerState<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends ConsumerState<ShoppingScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final draft = parseShoppingText(_input.text);
    if (draft.name.isEmpty) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.addToShopping([draft]);
    _input.clear();
    _focus.requestFocus();
  }

  Future<void> _toggle(ShoppingItem item) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveShoppingItem(item.copyWith(checked: !item.checked));
  }

  Future<void> _delete(Iterable<ShoppingItem> items) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.deleteShoppingItems(items.map((i) => i.id));
  }

  Future<void> _edit(ShoppingItem item) async {
    final name = TextEditingController(text: item.name);
    final amount = TextEditingController(
      text: item.quantity == null ? '' : formatNumber(item.quantity!),
    );
    final unit = TextEditingController(text: item.unit);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upravit položku'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Název'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: amount,
                    decoration: const InputDecoration(labelText: 'Množství'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: unit,
                    decoration: const InputDecoration(labelText: 'Jednotka'),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;
    final quantity = double.tryParse(amount.text.trim().replaceAll(',', '.'));
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveShoppingItem(
      item.copyWith(
        name: name.text.trim(),
        quantity: quantity != null && quantity > 0 ? quantity : null,
        unit: unit.text.trim(),
      ),
    );
  }

  Future<void> _share(List<ShoppingItem> items) async {
    final open = [
      for (final i in items)
        if (!i.checked) i,
    ];
    if (open.isEmpty) return;
    final text = [
      'Nákupní seznam',
      for (final item in open)
        '• ${item.name}${shoppingAmount(item).isEmpty ? '' : ' – ${shoppingAmount(item)}'}',
    ].join('\n');
    await SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(shoppingProvider);
    final items = async.value ?? const <ShoppingItem>[];
    final open = [
      for (final i in items)
        if (!i.checked) i,
    ];
    final done = [
      for (final i in items)
        if (i.checked) i,
    ];
    final shared = ref.watch(householdProvider).value != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nákupní seznam'),
        actions: [
          IconButton(
            tooltip: 'Sdílet seznam',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: open.isEmpty ? null : () => _share(items),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _input,
              focusNode: _focus,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _add(),
              decoration: InputDecoration(
                hintText: 'Přidat, např. „2 kg brambor“ nebo „mléko 1 l“',
                prefixIcon: const Icon(Icons.add_shopping_cart_rounded),
                suffixIcon: IconButton(
                  tooltip: 'Přidat',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _add,
                ),
              ),
            ),
          ),
          if (shared)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.group_outlined,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Společný seznam celé rodiny',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: async.isLoading && items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                ? const EmptyState(
                    icon: Icons.shopping_cart_outlined,
                    title: 'Seznam je prázdný',
                    message:
                        'Přidejte položku výše, nebo v receptu zvolte ⋯ → '
                        'Na nákupní seznam. Stejné suroviny se samy sečtou.',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                    children: [
                      for (final item in open) _tile(item),
                      if (done.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'V košíku (${done.length})',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => _delete(done),
                                icon: const Icon(Icons.delete_sweep_outlined),
                                label: const Text('Smazat nakoupené'),
                              ),
                            ],
                          ),
                        ),
                        for (final item in done) _tile(item),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ShoppingItem item) {
    final amount = shoppingAmount(item);
    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppColors.danger.withValues(alpha: 0.25),
        child: const Icon(Icons.delete_outline_rounded),
      ),
      onDismissed: (_) => _delete([item]),
      child: CheckboxListTile(
        value: item.checked,
        onChanged: (_) => _toggle(item),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          item.name,
          style: TextStyle(
            decoration: item.checked ? TextDecoration.lineThrough : null,
            color: item.checked ? AppColors.textSecondary : null,
          ),
        ),
        subtitle: item.sources.isEmpty
            ? null
            : Text(
                item.sources.join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
        secondary: GestureDetector(
          onTap: () => _edit(item),
          child: Text(
            amount.isEmpty ? '✎' : amount,
            style: const TextStyle(
              color: AppColors.copperGold,
              fontWeight: FontWeight.w600,
            ),
          ),
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
      ),
  ];
}

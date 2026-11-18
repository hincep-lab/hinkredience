import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';

/// Záložka Nákupy: přehled pojmenovaných nákupních seznamů.
class ShoppingListsScreen extends ConsumerWidget {
  const ShoppingListsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await askShoppingListName(context);
    if (name == null) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    final list = await docs.createShoppingList(name);
    if (context.mounted) context.push(Routes.shoppingList(list.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(shoppingListsProvider);
    final lists = async.value ?? const <ShoppingListSummary>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Nákupy')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-shopping-list',
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nový seznam'),
      ),
      body: async.isLoading && lists.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : lists.isEmpty
          ? const EmptyState(
              icon: Icons.shopping_cart_outlined,
              title: 'Zatím žádný nákupní seznam',
              message:
                  'Založte seznam tlačítkem dole, nebo v receptu zvolte '
                  '⋯ → Přidat do nákupního seznamu. Seznam může vytvořit '
                  'i ChatGPT.',
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              itemCount: lists.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _ListCard(summary: lists[index]),
            ),
    );
  }
}

class _ListCard extends ConsumerWidget {
  const _ListCard({required this.summary});

  final ShoppingListSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = summary.list;
    final done = summary.total > 0 && summary.remaining == 0;
    return HkCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      onTap: () => context.push(Routes.shoppingList(list.id)),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (done ? AppColors.success : AppColors.copper).withValues(
                alpha: 0.18,
              ),
            ),
            child: done
                ? const Icon(Icons.check_rounded, color: AppColors.success)
                : Text(
                    '${summary.remaining}',
                    style: const TextStyle(
                      color: AppColors.copperGold,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  list.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (list.shared) ...[
                      const Icon(
                        Icons.group_outlined,
                        size: 15,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        remainingLabel(summary.remaining, summary.total),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ShoppingListMenu(list: list),
        ],
      ),
    );
  }
}

/// „Zbývá 5 z 16“, „Vše nakoupeno“, „Prázdný seznam“.
String remainingLabel(int remaining, int total) {
  if (total == 0) return 'Prázdný seznam';
  if (remaining == 0) return 'Vše nakoupeno · $total položek';
  return 'Zbývá koupit $remaining z $total';
}

/// Dialog pro název seznamu. Vrací null po zrušení.
Future<String?> askShoppingListName(
  BuildContext context, {
  String initial = '',
  String title = 'Nový nákupní seznam',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 120,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Např. Kuře na paprice, Víkend, Drogerie',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Uložit'),
        ),
      ],
    ),
  );
  final name = result?.trim() ?? '';
  return name.isEmpty ? null : name;
}

/// Nabídka seznamu: přejmenovat, sdílet s rodinou, smazat.
class ShoppingListMenu extends ConsumerWidget {
  const ShoppingListMenu({super.key, required this.list, this.onDeleted});

  final ShoppingList list;
  final VoidCallback? onDeleted;

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    if (!context.mounted) return;
    switch (action) {
      case 'rename':
        final name = await askShoppingListName(
          context,
          initial: list.name,
          title: 'Přejmenovat seznam',
        );
        if (name != null)
          await docs.saveShoppingList(list.copyWith(name: name));
      case 'share':
        final household = await ref.read(householdProvider.future);
        if (household == null) {
          if (context.mounted) {
            showMessage(
              context,
              'Nejste v rodině. Rodinu založíte v záložce Více → Rodina.',
            );
          }
          return;
        }
        await docs.saveShoppingList(list.copyWith(householdId: household.id));
        if (context.mounted) {
          showMessage(context, 'Seznam teď vidí celá rodina.');
        }
      case 'unshare':
        await docs.saveShoppingList(list.copyWith(householdId: null));
        if (context.mounted) showMessage(context, 'Seznam je jen váš.');
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Smazat seznam?',
          message: 'Seznam „${list.name}“ se smaže i se všemi položkami.',
          confirmLabel: 'Smazat',
          destructive: true,
        );
        if (!ok) return;
        await docs.deleteShoppingList(list.id);
        onDeleted?.call();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine =
        list.ownerId == null ||
        list.ownerId == ref.watch(sessionProvider.select((s) => s.userId));
    return PopupMenuButton<String>(
      tooltip: 'Možnosti seznamu',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (action) => _select(context, ref, action),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('Přejmenovat'),
          ),
        ),
        if (mine)
          list.shared
              ? const PopupMenuItem(
                  value: 'unshare',
                  child: ListTile(
                    leading: Icon(Icons.person_outline_rounded),
                    title: Text('Přestat sdílet s rodinou'),
                  ),
                )
              : const PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                    leading: Icon(Icons.group_add_outlined),
                    title: Text('Sdílet s rodinou'),
                  ),
                ),
        if (mine)
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: AppColors.danger,
              ),
              title: Text('Smazat seznam'),
            ),
          ),
      ],
    );
  }
}

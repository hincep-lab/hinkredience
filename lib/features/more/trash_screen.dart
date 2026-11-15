import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';

/// Koš – smazané recepty, které lze obnovit nebo natrvalo odstranit.
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  /// Natrvalo smaže recepty z koše; bez [id] celý koš. Vždy se nejdřív zeptá.
  Future<void> _purge(
    BuildContext context,
    WidgetRef ref, {
    String? id,
    String? title,
    required int count,
  }) async {
    final confirmed = await confirm(
      context,
      title: id == null ? 'Vysypat koš?' : 'Smazat natrvalo?',
      message: id == null
          ? 'Natrvalo se smaže $count ${_recipesWord(count)} včetně historie '
                'verzí a fotografií. Tento krok nejde vrátit.'
          : 'Recept „$title“ se smaže natrvalo včetně historie verzí '
                'a fotografií. Tento krok nejde vrátit.',
      confirmLabel: id == null ? 'Vysypat koš' : 'Smazat natrvalo',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      final repository = await ref.read(recipeRepositoryProvider.future);
      final result = await repository.purgeDeleted(
        ids: id == null ? null : [id],
      );
      await ref.read(photoStoreProvider).deleteFiles(result.orphanPhotoPaths);
      if (!context.mounted) return;
      final removed = result.recipes.length;
      showMessage(
        context,
        removed == 0
            ? 'V koši nebylo co smazat.'
            : ref.read(sessionProvider).isSignedIn
            ? 'Smazáno natrvalo: $removed. Na serveru se smaže při synchronizaci.'
            : 'Smazáno natrvalo: $removed.',
      );
    } catch (error) {
      if (context.mounted) {
        showMessage(context, 'Smazání se nepodařilo: $error');
      }
    }
  }

  static String _recipesWord(int count) => count == 1
      ? 'recept'
      : count >= 2 && count <= 4
      ? 'recepty'
      : 'receptů';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trash = ref.watch(trashProvider);
    final count = trash.value?.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Koš'),
        actions: [
          if (count > 0)
            TextButton.icon(
              onPressed: () => _purge(context, ref, count: count),
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('Vysypat'),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: trash.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorState(error: error),
        data: (recipes) => recipes.isEmpty
            ? const EmptyState(
                icon: Icons.delete_outline_rounded,
                title: 'Koš je prázdný',
                message:
                    'Smazané recepty se objeví tady. Půjdou obnovit, nebo '
                    'natrvalo odstranit.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: recipes.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final recipe = recipes[index];
                  return HkCard(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    onTap: () => context.push(Routes.recipe(recipe.id)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                recipe.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                'Smazáno ${formatDate(recipe.deletedAt!)}',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final repository = await ref.read(
                              recipeRepositoryProvider.future,
                            );
                            await repository.restore(recipe.id);
                            if (context.mounted) {
                              showMessage(
                                context,
                                '„${recipe.title}“ je zpět v kuchařce.',
                              );
                            }
                          },
                          icon: const Icon(Icons.restore_rounded),
                          label: const Text('Obnovit'),
                        ),
                        IconButton(
                          tooltip: 'Smazat natrvalo',
                          icon: const Icon(
                            Icons.delete_forever_rounded,
                            color: AppColors.danger,
                          ),
                          onPressed: () => _purge(
                            context,
                            ref,
                            id: recipe.id,
                            title: recipe.title,
                            count: 1,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

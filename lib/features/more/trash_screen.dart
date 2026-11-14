import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';

/// Koš – smazané recepty, které lze obnovit.
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trash = ref.watch(trashProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Koš')),
      body: trash.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorState(error: error),
        data: (recipes) => recipes.isEmpty
            ? const EmptyState(
                icon: Icons.delete_outline_rounded,
                title: 'Koš je prázdný',
                message: 'Smazané recepty se objeví tady a půjdou obnovit.',
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
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

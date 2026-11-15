import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';
import 'recipe_picker.dart';

String diaryDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day}. ${local.month}. ${local.year}';
}

/// Kuchařský deník: každé vaření se skutečným časem, teplotami, fotkami,
/// hodnocením a tím, co se povedlo a co zlepšit.
class DiaryScreen extends ConsumerWidget {
  const DiaryScreen({super.key, this.recipeId});

  /// Jen historie jednoho jídla.
  final String? recipeId;

  Future<void> _addManual(BuildContext context, WidgetRef ref) async {
    Recipe? recipe;
    if (recipeId != null) {
      recipe = ref.read(recipeProvider(recipeId!)).value;
    } else {
      recipe = await pickRecipe(context, title: 'Co jste vařili?');
    }
    if (recipe == null) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    final session = await docs.saveSession(
      CookingSession(
        id: docs.newId(),
        recipeId: recipe.id,
        recipeTitle: recipe.title,
        versionNumber: recipe.currentVersion,
        status: SessionStatus.inProgress,
        servings: recipe.servings,
        cookedAt: docs.now(),
        updatedAt: docs.now(),
      ),
    );
    if (context.mounted) context.push(Routes.diaryEntry(session.id));
  }

  String _experimentPrompt(Recipe recipe, List<CookingSession> history) {
    final lines = [
      'Navrhni mi další experiment s receptem „${recipe.title}“ podle mé historie vaření:',
      for (final s in history.take(6))
        '- ${diaryDate(s.cookedAt)}'
            '${s.rating == null ? '' : ', hodnocení ${formatQuantity(s.rating!)}/5'}'
            '${s.actualMinutes == null ? '' : ', čas ${formatMinutes(s.actualMinutes!)}'}'
            '${s.wentWell.isEmpty ? '' : '; povedlo se: ${s.wentWell}'}'
            '${s.toImprove.isEmpty ? '' : '; zlepšit: ${s.toImprove}'}'
            '${s.notes.isEmpty ? '' : '; poznámka: ${s.notes}'}',
      'Navrhni jednu konkrétní změnu, proč ji zkusit a co sledovat.',
    ];
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = recipeId == null
        ? ref.watch(diaryProvider)
        : ref.watch(recipeDiaryProvider(recipeId!));
    final recipe = recipeId == null
        ? null
        : ref.watch(recipeProvider(recipeId!)).value;
    final entries = async.value ?? const <CookingSession>[];
    final aiEnabled = ref.watch(aiEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          recipe == null ? 'Kuchařský deník' : 'Historie: ${recipe.title}',
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addManual(context, ref),
        icon: const Icon(Icons.edit_note_rounded),
        label: const Text('Zapsat vaření'),
      ),
      body: async.isLoading && entries.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const EmptyState(
              icon: Icons.menu_book_outlined,
              title: 'Deník je zatím prázdný',
              message:
                  'Po vaření v režimu Vaříme spolu se sem uloží skutečný čas, '
                  'teploty, fotky a hodnocení. Vaření můžete zapsat i ručně.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                if (recipe != null && aiEnabled && entries.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: OutlinedButton.icon(
                      onPressed: () => context.push(
                        Routes.aiChat(
                          recipeId: recipe.id,
                          draft: _experimentPrompt(recipe, entries),
                        ),
                      ),
                      icon: const Icon(Icons.auto_awesome_rounded),
                      label: const Text('Navrhnout další experiment s AI'),
                    ),
                  ),
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _DiaryTile(entry: entry, showTitle: recipe == null),
                  ),
              ],
            ),
    );
  }
}

class _DiaryTile extends StatelessWidget {
  const _DiaryTile({required this.entry, required this.showTitle});

  final CookingSession entry;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (entry.actualMinutes != null) formatMinutes(entry.actualMinutes!),
      if (entry.actualTemperatures.isNotEmpty)
        entry.actualTemperatures.join(', '),
      if (entry.versionNumber != null) 'verze ${entry.versionNumber}',
    ].join(' · ');
    final text = [
      if (entry.wentWell.isNotEmpty) '✓ ${entry.wentWell}',
      if (entry.toImprove.isNotEmpty) '→ ${entry.toImprove}',
      if (entry.notes.isNotEmpty) entry.notes,
    ].join('\n');
    return HkCard(
      onTap: () => context.push(Routes.diaryEntry(entry.id)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry.photos.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 64,
                height: 64,
                child: RecipePhotoView(
                  photo: entry.photos.first,
                  thumbnail: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  showTitle ? entry.recipeTitle : diaryDate(entry.cookedAt),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                  ),
                ),
                if (showTitle)
                  Text(
                    diaryDate(entry.cookedAt),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                if (entry.rating != null) ...[
                  const SizedBox(height: 4),
                  StarRating(value: entry.rating, size: 16),
                ],
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    details,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                if (text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

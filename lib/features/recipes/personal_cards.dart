import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/kitchen_providers.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/personalization.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';
import '../kitchen/diary_screen.dart' show diaryDate;

/// „Příště nezapomeňte“ – co si uživatel u receptu naposledy zapsal do
/// deníku (co zlepšit, poznámky). Na detailu receptu i na začátku vaření.
class DiaryReminderCard extends ConsumerWidget {
  const DiaryReminderCard({
    super.key,
    required this.recipeId,
    this.large = false,
  });

  final String recipeId;

  /// Větší písmo pro režim Vaříme spolu.
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminder = ref.watch(diaryReminderProvider(recipeId));
    if (reminder == null || !reminder.hasAdvice) return const SizedBox.shrink();
    final size = large ? 17.0 : 14.5;
    final meta = [
      'Vařeno ${diaryDate(reminder.cookedAt)}',
      if (reminder.rating != null) '${formatQuantity(reminder.rating!)}★',
      if (reminder.actualMinutes != null)
        'trvalo ${formatMinutes(reminder.actualMinutes!)}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.lightbulb_outline_rounded,
              color: AppColors.copperGold,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Příště nezapomeňte',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: size,
                    ),
                  ),
                  if (reminder.toImprove.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      reminder.toImprove,
                      style: TextStyle(
                        fontSize: size,
                        color: AppColors.copperGold,
                      ),
                    ),
                  ],
                  if (reminder.notes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(reminder.notes, style: TextStyle(fontSize: size - 1)),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Upozornění na pálivé suroviny s přepínačem „bez chilli“ a uložením
/// samostatné varianty receptu.
class ChilliCard extends StatelessWidget {
  const ChilliCard({
    super.key,
    required this.recipe,
    required this.mild,
    required this.onMild,
    required this.onSaveCopy,
  });

  final Recipe recipe;
  final bool mild;
  final ValueChanged<bool> onMild;
  final VoidCallback onSaveCopy;

  @override
  Widget build(BuildContext context) {
    final hot = chilliIngredients(recipe);
    if (hot.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(
                Icons.local_fire_department_outlined,
                color: AppColors.danger,
              ),
              title: const Text(
                'Bez chilli',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                mild
                    ? 'Zobrazeno bez: ${hot.map((i) => i.name).join(', ')}'
                    : 'Pálivé: ${hot.map((i) => i.name).join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              value: mild,
              onChanged: onMild,
            ),
            if (mild)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onSaveCopy,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Uložit jako recept bez chilli'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

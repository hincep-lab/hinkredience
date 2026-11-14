import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';
import '../../data/draft_saver.dart';
import 'ai_common.dart';

/// Co se má zkontrolovat a kam se to uloží.
class DraftReviewArgs {
  const DraftReviewArgs({
    required this.proposal,
    this.targetRecipeId,
    this.heading = 'Návrh receptu',
  });

  final DraftProposal proposal;

  /// Recept, který návrh upravuje. `null` = vznikne nový recept.
  final String? targetRecipeId;
  final String heading;
}

/// Kontrola návrhu od AI před uložením. Bez potvrzení se nic neuloží
/// a uložený recept se nikdy nepřepíše – úprava vytvoří novou verzi.
class DraftReviewScreen extends ConsumerStatefulWidget {
  const DraftReviewScreen({super.key, required this.args});

  final DraftReviewArgs? args;

  @override
  ConsumerState<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends ConsumerState<DraftReviewScreen> {
  bool _saving = false;

  Future<void> _save({required bool asVersion}) async {
    final args = widget.args;
    if (args == null || _saving) return;
    setState(() => _saving = true);
    try {
      final repository = await ref.read(recipeRepositoryProvider.future);
      final targetId = args.targetRecipeId;
      final existing = asVersion && targetId != null
          ? await repository.getById(targetId)
          : null;
      final saved = existing != null
          ? await saveDraftAsVersion(repository, existing, args.proposal)
          : await saveDraftAsNew(
              repository,
              args.proposal,
              ownerId: ref.read(sessionProvider).userId,
            );
      if (!mounted) return;
      showMessage(
        context,
        existing != null
            ? 'Uloženo jako verze ${saved.currentVersion}. Původní zůstává v historii.'
            : 'Recept „${saved.title}“ je v kuchařce.',
      );
      if (existing != null) {
        context.pop();
      } else {
        context.pushReplacement(Routes.recipe(saved.id));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showMessage(context, 'Uložení se nepodařilo: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    if (args == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Návrh receptu')),
        body: const EmptyState(
          icon: Icons.hourglass_empty_rounded,
          title: 'Návrh už není k dispozici',
          message: 'Vraťte se zpět a nechte si recept navrhnout znovu.',
        ),
      );
    }
    final theme = Theme.of(context);
    final proposal = args.proposal;
    final draft = proposal.recipe;
    final total = draft.prepMinutes + draft.cookMinutes;
    final updating = args.targetRecipeId != null;

    return Scaffold(
      appBar: AppBar(title: Text(args.heading)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          HkCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.fact_check_outlined,
                  color: AppColors.copperGold,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    updating
                        ? 'Zkontrolujte návrh. Uložením vznikne nová verze, '
                              'původní recept zůstane v historii.'
                        : 'Zkontrolujte návrh. Do kuchařky se uloží až po '
                              'vašem potvrzení a pak ho můžete dál upravovat.',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(draft.title, style: theme.textTheme.headlineSmall),
          if (draft.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              draft.description,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (draft.category.isNotEmpty) _Pill(draft.category),
              _Pill('${formatQuantity(draft.servings)} porce'),
              if (draft.prepMinutes > 0)
                _Pill('Příprava ${formatMinutes(draft.prepMinutes)}'),
              if (draft.cookMinutes > 0)
                _Pill('Vaření ${formatMinutes(draft.cookMinutes)}'),
              if (total > 0) _Pill('Celkem ${formatMinutes(total)}'),
            ],
          ),
          if (proposal.summary.isNotEmpty) ...[
            const SectionTitle('Shrnutí'),
            Text(proposal.summary, style: const TextStyle(height: 1.45)),
          ],
          if (proposal.changes.isNotEmpty) ...[
            const SectionTitle('Co a proč se mění'),
            for (final change in proposal.changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.change_circle_outlined,
                        size: 18,
                        color: AppColors.copperGold,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            change.what,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (change.why.isNotEmpty)
                            Text(
                              change.why,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                height: 1.35,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          SectionTitle('Suroviny (${draft.ingredients.length})'),
          if (draft.ingredients.isEmpty)
            const Text(
              'Návrh neobsahuje žádné suroviny.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          for (final item in draft.ingredients)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.note.isEmpty
                          ? item.name
                          : '${item.name} (${item.note})',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _amount(item),
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          SectionTitle('Postup (${draft.steps.length})'),
          if (draft.steps.isEmpty)
            const Text(
              'Návrh neobsahuje žádné kroky.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          for (final (index, step) in draft.steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${index + 1}.',
                      style: const TextStyle(
                        color: AppColors.copperGold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.instruction,
                          style: const TextStyle(height: 1.4),
                        ),
                        if (step.durationMinutes != null ||
                            step.temperatureC != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              [
                                if (step.temperatureC != null)
                                  '${formatQuantity(step.temperatureC!)} °C',
                                if (step.durationMinutes != null)
                                  formatMinutes(step.durationMinutes!),
                              ].join(' · '),
                              style: const TextStyle(
                                color: AppColors.copperGold,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (draft.temperatures.isNotEmpty) ...[
            const SectionTitle('Teploty'),
            Text(draft.temperatures.join(' · ')),
          ],
          if (draft.equipment.isNotEmpty) ...[
            const SectionTitle('Vybavení'),
            Text(draft.equipment.join(' · ')),
          ],
          if (draft.notes.isNotEmpty) ...[
            const SectionTitle('Poznámky'),
            Text(draft.notes, style: const TextStyle(height: 1.4)),
          ],
          if (proposal.sources.isNotEmpty) ...[
            const SizedBox(height: 16),
            SourceLinks(sources: proposal.sources),
          ],
          if (proposal.sourceUrl != null) ...[
            const SizedBox(height: 16),
            SourceLinks(
              title: 'Importováno z',
              sources: [AiSource(url: proposal.sourceUrl!)],
            ),
          ],
          const SizedBox(height: 24),
          if (updating) ...[
            CopperButton(
              label: 'Uložit jako novou verzi',
              icon: Icons.history_rounded,
              busy: _saving,
              onPressed: () => _save(asVersion: true),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: _saving ? null : () => _save(asVersion: false),
                child: const Text('Uložit jako samostatný nový recept'),
              ),
            ),
          ] else
            CopperButton(
              label: 'Uložit do kuchařky',
              icon: Icons.check_rounded,
              busy: _saving,
              onPressed: () => _save(asVersion: false),
            ),
          Center(
            child: TextButton(
              onPressed: _saving ? null : () => context.pop(),
              child: const Text('Zahodit návrh'),
            ),
          ),
        ],
      ),
    );
  }

  String _amount(DraftIngredient item) {
    final quantity = item.quantity;
    if (quantity == null) return item.unit;
    return item.unit.isEmpty
        ? formatQuantity(quantity)
        : '${formatQuantity(quantity)} ${item.unit}';
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outline),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
      ),
    );
  }
}

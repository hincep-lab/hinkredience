import 'ai_models.dart';
import 'recipe.dart';
import 'recipe_repository.dart';

/// Uloží návrh od AI jako nový recept (verze 1).
Future<Recipe> saveDraftAsNew(
  RecipeRepository repository,
  DraftProposal proposal, {
  String? ownerId,
}) {
  final firstSource = proposal.sources.isEmpty
      ? null
      : proposal.sources.first.url;
  return repository.create(
    proposal.recipe.toRecipe(
      newId: repository.newId,
      now: repository.now(),
      ownerId: ownerId,
      sourceUrl: proposal.sourceUrl ?? firstSource,
      extraNotes: sourcesNote(proposal.sources),
    ),
  );
}

/// Uloží návrh od AI jako novou verzi existujícího receptu. Předchozí
/// podoba zůstává v historii verzí.
Future<Recipe> saveDraftAsVersion(
  RecipeRepository repository,
  Recipe existing,
  DraftProposal proposal,
) {
  final summary = proposal.changeSummary.trim();
  return repository.update(
    proposal.recipe.applyTo(
      existing,
      newId: repository.newId,
      extraNotes: sourcesNote(proposal.sources),
    ),
    changeSummary: summary.isEmpty
        ? 'Úprava navržená AI kuchařem'
        : 'AI: ${summary.length > 300 ? '${summary.substring(0, 300)}…' : summary}',
  );
}

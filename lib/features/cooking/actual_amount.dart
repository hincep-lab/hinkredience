import '../../core/app_colors.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/ratios.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';

/// „Kolik toho máte?“ – zadané skutečné množství jedné suroviny přepočítá
/// celý recept ve stejném poměru. Vrací nový počet porcí, nebo null.
Future<double?> askActualAmount(
  BuildContext context, {
  required Ingredient ingredient,
  required double recipeServings,
  required double currentServings,
}) async {
  final planned = ingredient.amountLabel(
    fromServings: recipeServings,
    toServings: currentServings,
  );
  final amount = TextEditingController();
  final unit = TextEditingController(text: ingredient.unit);
  final result = await showDialog<double>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final value = double.tryParse(amount.text.trim().replaceAll(',', '.'));
        final servings = value == null
            ? null
            : servingsForActual(
                ingredient: ingredient,
                recipeServings: recipeServings,
                actual: value,
                actualUnit: unit.text,
              );
        return AlertDialog(
          title: Text(ingredient.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'V receptu: $planned. Kolik ho skutečně máte? Ostatní '
                'suroviny se přepočítají ve stejném poměru.',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: amount,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: const TextStyle(fontSize: 22),
                      decoration: const InputDecoration(labelText: 'Množství'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: unit,
                      style: const TextStyle(fontSize: 22),
                      decoration: const InputDecoration(labelText: 'Jednotka'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (value != null)
                Text(
                  servings == null
                      ? 'Tuhle jednotku nejde převést na ${ingredient.unit}.'
                      : 'Recept vyjde na ${formatNumber(servings, decimals: 1)} '
                            '${servings == 1 ? 'porci' : 'porcí'} '
                            '(${formatNumber(servings / recipeServings * 100, decimals: 0)} % receptu).',
                  style: TextStyle(
                    color: servings == null
                        ? AppColors.danger
                        : AppColors.copperGold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: servings == null
                  ? null
                  : () => Navigator.of(context).pop(servings),
              child: const Text('Přepočítat'),
            ),
          ],
        );
      },
    ),
  );
  return result;
}

/// Poměry surovin vůči hlavní surovině (např. na 100 g masa).
class RatioList extends StatelessWidget {
  const RatioList({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final base = mainIngredient(recipe);
    if (base == null) {
      return const Text(
        'Poměry jdou spočítat, když má recept suroviny v gramech nebo '
        'mililitrech.',
        style: TextStyle(color: AppColors.textSecondary),
      );
    }
    return HkCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Poměry ${ratioBaseLabel(base)} „${base.name}“',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final item in recipe.ingredients)
            if (item != base)
              if (ratioPer(item, base) case final ratio?)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(item.name)),
                      Text(
                        formatAmount(
                          ratio.quantity,
                          ratio.unit,
                          name: item.name,
                        ),
                        style: const TextStyle(
                          color: AppColors.copperGold,
                          fontWeight: FontWeight.w600,
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/sale_dishes.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';
import 'add_to_shopping_sheet.dart';
import 'best_buy_panel.dart' show kc;
import 'sale_plan.dart';
import 'sale_recipes_screen.dart' show offerLine;

/// Jídlo navržené z akcí: suroviny (co je v akci a za kolik), postup,
/// uložení do kuchařky a přidání surovin do nákupu.
class SaleDishScreen extends ConsumerStatefulWidget {
  const SaleDishScreen({super.key, required this.item});

  final DishOnSale item;

  @override
  ConsumerState<SaleDishScreen> createState() => _SaleDishScreenState();
}

class _SaleDishScreenState extends ConsumerState<SaleDishScreen> {
  Recipe? _saved;
  bool _saving = false;

  Dish get _dish => widget.item.dish;

  Recipe _draft() => dishToRecipe(
    _dish,
    newId: () => DateTime.now().microsecondsSinceEpoch.toString(),
    now: DateTime.now().toUtc(),
  );

  Future<void> _save() async {
    final saved = _saved;
    if (saved != null) {
      context.push(Routes.recipe(saved.id));
      return;
    }
    setState(() => _saving = true);
    try {
      final repository = await ref.read(recipeRepositoryProvider.future);
      final recipe = await repository.create(
        dishToRecipe(
          _dish,
          newId: repository.newId,
          now: repository.now().toUtc(),
          ownerId: ref.read(sessionProvider).userId,
        ),
      );
      if (!mounted) return;
      setState(() => _saved = recipe);
      showMessage(context, 'Uloženo do kuchařky: ${recipe.title}');
    } catch (error) {
      if (mounted) showMessage(context, 'Uložení se nepovedlo: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dish = _dish;
    final onSale = widget.item.onSale;
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);
    return Scaffold(
      appBar: AppBar(title: const Text('Uvař z akcí')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(dish.title, style: Theme.of(context).textTheme.titleLarge),
          if (dish.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(dish.description, style: muted),
          ],
          const SizedBox(height: 6),
          Text(
            '${dish.minutes > 0 ? '${dish.minutes} min · ' : ''}${Dish.servings} porce'
            '${dish.temperature == null ? '' : ' · trouba ${dish.temperature} °C'}'
            ' · v akci ${onSale.length} z ${widget.item.total} surovin',
            style: const TextStyle(color: AppColors.copperGold),
          ),
          if (widget.item.chain != null || widget.item.validTo != null)
            Text(
              [
                if (widget.item.chain != null)
                  'Vše koupíte v obchodě ${chainName(widget.item.chain)}',
                if (widget.item.validTo case final validTo?)
                  validityLabel(validTo, DateTime.now()),
              ].join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          Text(
            'Zlevněné zboží na recept (4 porce): '
            '${kc(saleCost(widget.item).total)}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          if (widget.item.savings > 0)
            Text(
              'Ušetříte asi ${kc(widget.item.savings)} proti běžné ceně',
              style: const TextStyle(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: Icon(
                    _saved == null
                        ? Icons.bookmark_add_outlined
                        : Icons.menu_book_outlined,
                  ),
                  label: Text(
                    _saved == null ? 'Uložit do kuchařky' : 'Otevřít recept',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showAddRecipeToShopping(
                    context,
                    recipe: _saved ?? _draft(),
                  ),
                  icon: const Icon(Icons.add_shopping_cart_rounded),
                  label: const Text('Do nákupu'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => showAddDishToMenu(context, ref, widget.item),
            icon: const Icon(Icons.event_available_rounded),
            label: const Text('Přidat do jídelníčku'),
          ),
          const SizedBox(height: 8),
          const SectionTitle('Suroviny'),
          HkCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final i in dish.ingredients)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [
                            if (i.quantity != null)
                              '${_amount(i.quantity!)} ${i.unit}'.trim(),
                            i.name,
                          ].join(' '),
                          style: TextStyle(
                            fontWeight: onSale.containsKey(i.group)
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        if (onSale[i.group] case final offer?)
                          Text(
                            'V akci: ${packsNeeded(i.quantity, i.unit, offer)}× '
                            '${offer.product} – ${offerLine(offer)}',
                            style: const TextStyle(
                              color: AppColors.success,
                              fontSize: 12.5,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const SectionTitle('Postup'),
          for (final (index, step) in dish.steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
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
                  Expanded(child: Text(step)),
                ],
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            'Ceny jsou z ověřených akčních letáků pro Sušici. Před nákupem '
            'je dobré zkontrolovat platnost akce v obchodě.',
            style: muted,
          ),
        ],
      ),
    );
  }
}

String _amount(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString().replaceAll('.', ',');

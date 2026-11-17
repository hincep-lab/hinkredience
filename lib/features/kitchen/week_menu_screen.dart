import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/sale_dishes.dart';
import '../../core/week_menu.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import 'best_buy_panel.dart' show kc;
import 'sale_dish_screen.dart';
import 'sale_plan.dart';
import 'sale_recipes_screen.dart' show offerLine;

/// Týdenní jídelníček z akcí: obědy a večeře za sebou, jedno vaření na
/// několik jídel, každé vaření ze svého obchodu. Jídlo jde vyměnit, celý
/// týden uložit do plánu vaření a nakoupit po obchodech.
class WeekMenuScreen extends ConsumerStatefulWidget {
  const WeekMenuScreen({super.key, required this.candidates});

  /// Návrhy seřazené od nejlepšího (vestavěná jídla i nápady od Gemini).
  final List<DishOnSale> candidates;

  @override
  ConsumerState<WeekMenuScreen> createState() => _WeekMenuScreenState();
}

class _WeekMenuScreenState extends ConsumerState<WeekMenuScreen> {
  late DateTime _today;
  late DateTime _start;
  late String _firstMeal;
  late MenuPortions _portions;
  late WeekMenu _menu;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    // Odpoledne už se dnes neuvaří oběd – začít večeří.
    _start = _today;
    _firstMeal = now.hour < 11 ? MealType.lunch : MealType.dinner;
    _portions = MenuPortions.read(ref.read(sharedPreferencesProvider));
    _rebuild();
  }

  void _rebuild() {
    _menu = buildWeekMenu(
      widget.candidates,
      _start,
      firstMeal: _firstMeal,
      portions: _portions.portions,
      mealsPerCook: _portions.meals,
    );
  }

  void _change(void Function() update) {
    setState(() {
      update();
      _rebuild();
    });
  }

  Future<void> _setPortions(MenuPortions value) async {
    _change(() => _portions = value);
    await value.save(ref.read(sharedPreferencesProvider));
  }

  void _swap(int index) {
    final next = swapCook(_menu, index, widget.candidates);
    if (identical(next, _menu)) {
      showMessage(context, 'Jiné jídlo z akcí teď není k dispozici.');
      return;
    }
    setState(() => _menu = next);
  }

  Future<void> _save() async {
    if (_menu.cooks.isEmpty) return;
    setState(() => _saving = true);
    try {
      for (final cook in _menu.cooks) {
        await planCook(ref, cook.item, cook.slots, _menu.portions);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Uloženo do plánu vaření: ${_menu.cooks.length}× vaření.',
            ),
            action: SnackBarAction(
              label: 'Otevřít',
              onPressed: () => context.push(Routes.plan),
            ),
          ),
        );
    } catch (error) {
      if (mounted) showMessage(context, 'Uložení se nepovedlo: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _shop() async {
    if (_menu.cooks.isEmpty) return;
    setState(() => _saving = true);
    try {
      final lists = await shopForMenu(ref, _menu, _start);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              lists == 1
                  ? 'Vytvořen nákupní seznam.'
                  : 'Vytvořeno $lists nákupních seznamů – pro každý obchod jeden.',
            ),
            action: SnackBarAction(
              label: 'Nákupy',
              onPressed: () => context.go(Routes.shopping),
            ),
          ),
        );
    } catch (error) {
      if (mounted) showMessage(context, 'Nákupní seznamy se nepovedly: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);
    final menu = _menu;
    final chains = menu.chains.entries
        .map((e) => '${chainName(e.key)} ${e.value}×')
        .join(', ');
    return Scaffold(
      appBar: AppBar(title: const Text('Jídelníček z akcí')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          HkCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Od kdy'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var d = 0; d < 4; d++)
                      if (DateTime(_today.year, _today.month, _today.day + d)
                          case final date)
                        ChoiceChip(
                          label: Text(
                            d == 0
                                ? 'Dnes'
                                : d == 1
                                ? 'Zítra'
                                : '${dayShort(date)} ${date.day}.',
                          ),
                          selected: _start == date,
                          onSelected: (_) => _change(() => _start = date),
                        ),
                  ],
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: MealType.lunch,
                      label: Text('Začít obědem'),
                    ),
                    ButtonSegment(
                      value: MealType.dinner,
                      label: Text('Začít večeří'),
                    ),
                  ],
                  selected: {_firstMeal},
                  onSelectionChanged: (v) =>
                      _change(() => _firstMeal = v.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Text('Porcí z jednoho vaření')),
                    IconButton(
                      onPressed: _portions.portions <= 2
                          ? null
                          : () => _setPortions(
                              MenuPortions(
                                _portions.portions - 1,
                                _portions.meals,
                              ),
                            ),
                      icon: const Icon(Icons.remove_circle_outline_rounded),
                    ),
                    Text(
                      '${_portions.portions}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    IconButton(
                      onPressed: _portions.portions >= 16
                          ? null
                          : () => _setPortions(
                              MenuPortions(
                                _portions.portions + 1,
                                _portions.meals,
                              ),
                            ),
                      icon: const Icon(Icons.add_circle_outline_rounded),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: Text('Vystačí na jídel')),
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 1, label: Text('1')),
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                        ButtonSegment(value: 4, label: Text('4')),
                      ],
                      selected: {_portions.meals},
                      onSelectionChanged: (v) => _setPortions(
                        MenuPortions(_portions.portions, v.first),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Oběd a večeře 7 dní. Jedno vaření = ${_portions.portions} '
                  'porcí na ${_portions.meals} '
                  '${_portions.meals == 1 ? 'jídlo' : 'jídla'} po sobě '
                  '(např. oběd, večeře a další den oběd).',
                  style: muted,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (menu.cooks.isEmpty)
            const EmptyState(
              icon: Icons.event_busy_rounded,
              title: 'Z akcí teď nejde sestavit jídelníček',
              message:
                  'Nejdřív klepněte na Najít akce. Nové letáky vycházejí '
                  'obvykle ve středu a ve čtvrtek.',
            )
          else ...[
            Text(
              'Vaří se ${menu.cooks.length}× · nákup: $chains',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (menu.savings > 0)
              Text(
                'Na akcích ušetříte asi ${kc(menu.savings * menu.portions / Dish.servings)}',
                style: const TextStyle(
                  color: AppColors.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 8),
            for (final (index, cook) in menu.cooks.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _CookCard(
                  cook: cook,
                  today: _today,
                  onSwap: () => _swap(index),
                ),
              ),
            if (menu.missing.isNotEmpty)
              Text(
                'Bez návrhu (málo akcí): '
                '${menu.missing.map(slotLabel).join(', ')}. Klepněte na '
                '„Vymyslet recepty“ pro další nápady.',
                style: muted,
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.event_available_rounded),
              label: const Text('Uložit do plánu vaření'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _saving ? null : _shop,
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: const Text('Nákupní seznamy po obchodech'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ceny jsou jen z ověřených akčních letáků. Ostatní suroviny '
              'koupíte ve stejném obchodě za běžnou cenu.',
              style: muted,
            ),
          ],
        ],
      ),
    );
  }
}

class _CookCard extends StatelessWidget {
  const _CookCard({
    required this.cook,
    required this.today,
    required this.onSwap,
  });

  final MenuCook cook;
  final DateTime today;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);
    final item = cook.item;
    final validTo = item.validTo;
    return HkCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => SaleDishScreen(item: item)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  cookLabel(cook),
                  style: const TextStyle(
                    color: AppColors.copperGold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onSwap,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Vyměnit'),
              ),
            ],
          ),
          Text(
            item.dish.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            [
              if (item.chain != null) 'Nákup: ${chainName(item.chain)}',
              if (validTo != null) validityLabel(validTo, today),
            ].join(' · '),
            style: muted,
          ),
          for (final o in item.onSale.values)
            Text('• ${o.product}: ${offerLine(o)}', style: muted),
        ],
      ),
    );
  }
}

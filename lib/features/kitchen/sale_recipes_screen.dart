import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/best_buy.dart' show PriceOffer;
import '../../core/material.dart';
import '../../core/sale_dishes.dart';
import '../../core/sale_recipes.dart';
import '../../core/stores.dart';
import '../../core/widgets.dart';
import '../../data/price_service.dart';
import 'best_buy_panel.dart' show PriceDiagnostics, kc, refreshMessage;
import 'sale_dish_screen.dart';
import 'sale_plan.dart';
import 'week_menu_screen.dart';

/// „Recepty z akcí“: co je teď v Sušici v akci (maso, smetana, brambory…),
/// co z toho uvařit a které recepty z kuchařky teď vyjdou levně.
/// Jen ověřené ceny z letáků, bez AI a zdarma.
class SaleRecipesScreen extends ConsumerStatefulWidget {
  const SaleRecipesScreen({super.key});

  @override
  ConsumerState<SaleRecipesScreen> createState() => _SaleRecipesScreenState();
}

class _SaleRecipesScreenState extends ConsumerState<SaleRecipesScreen> {
  bool _busy = false;
  PriceRefresh? _last;
  bool _thinking = false;
  final _ideas = <DishOnSale>[];
  String _ideasNote = '';
  final _wish = TextEditingController();

  @override
  void dispose() {
    _wish.dispose();
    super.dispose();
  }

  /// Gemini (zdarma) vymyslí další recepty z uložených ověřených akcí;
  /// už navržená jídla se posílají, aby se neopakovala.
  Future<void> _invent() async {
    final service = ref.read(priceServiceProvider);
    if (service == null) {
      showMessage(context, 'Návrhy receptů potřebují přihlášení k účtu.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _thinking = true;
      _ideasNote = '';
    });
    try {
      final result = await service.suggestRecipes(
        wish: _wish.text,
        avoid: [for (final d in _ideas) d.dish.title],
      );
      if (!mounted) return;
      setState(() {
        _ideas.insertAll(0, result.ideas);
        _ideasNote = result.ideas.isEmpty
            ? result.error
            : 'Nové návrhy: ${result.ideas.length}'
                  '${result.rejected.isEmpty ? '' : ' · zahozeno ${result.rejected.length} (bez skutečné akce)'}';
      });
    } catch (error) {
      if (mounted) setState(() => _ideasNote = 'Návrh se nepovedl: $error');
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  Future<void> _search({bool force = false}) async {
    final service = ref.read(priceServiceProvider);
    if (service == null) {
      showMessage(context, 'Hledání akcí potřebuje přihlášení k účtu.');
      return;
    }
    final recipes = ref.read(allRecipesProvider).value ?? const [];
    // Základní suroviny pro „Co z toho uvařit“ mají přednost, zbytek místa
    // (server prohledá 20 najednou) dostanou nejčastější suroviny z kuchařky.
    final products = <String>[...saleSearchTerms()];
    for (final name in ingredientsWorthSearching(recipes)) {
      if (products.length >= 20) break;
      if (groupOf(name) == null) products.add(name);
    }
    setState(() => _busy = true);
    try {
      final result = await service.refresh(products, force: force);
      await ref.read(priceOffersProvider.notifier).reload();
      if (!mounted) return;
      setState(() => _last = result);
      showMessage(context, refreshMessage(result));
    } catch (error) {
      if (mounted) showMessage(context, 'Hledání akcí selhalo: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _details() {
    final result = _last;
    if (result == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, controller) => PriceDiagnostics(
          result: result,
          controller: controller,
          onRetry: () {
            Navigator.of(sheet).pop();
            _search(force: true);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recipes = ref.watch(allRecipesProvider).value ?? const [];
    final offers = ref.watch(priceOffersProvider).value ?? const [];
    final today = DateTime.now();
    final list = recipesFromSales(recipes, offers, today);
    final usable = usableOffers(offers, today).length;
    final groups = offersByGroup(offers, today);
    final dishes = dishesFromSales(offers, today);
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recepty z akcí'),
        actions: [
          if (_last != null)
            IconButton(
              tooltip: 'Podrobnosti hledání',
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: _details,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          HkCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  usable == 0
                      ? 'Zatím nejsou uložené žádné ověřené akce.'
                      : 'Ověřených akcí v Sušici: $usable',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Projdu aktuální letáky Tesco, Penny, Lidl, Albert, JIP '
                  'a COOP: maso, smetanu, brambory, sýr, těstoviny a další '
                  'základ. Z toho, co je v akci, navrhnu jídla. Počítají se '
                  'jen ověřené ceny. Zdarma.',
                  style: muted,
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy ? null : _search,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.local_offer_outlined),
                  label: Text(
                    _busy ? 'Hledám v letácích… (až 2 min)' : 'Najít akce',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (usable == 0)
            const EmptyState(
              icon: Icons.local_offer_outlined,
              title: 'Klepněte na Najít akce',
              message: 'Aplikace projde letáky a navrhne, co z akcí uvařit.',
            )
          else ...[
            if (groups.isNotEmpty) ...[
              const SectionTitle('V akci teď'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final g in saleGroups)
                    if (groups[g.id] case final list?)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${g.label} od ${kc(list.first.price)} · '
                          '${chainById(list.first.chain)?.name ?? list.first.chain}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            HkCard(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WeekMenuScreen(
                    candidates: [..._ideas, ...dishes]..sort(compareDishes),
                  ),
                ),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.calendar_month_rounded,
                    color: AppColors.copperGold,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sestavit jídelníček na týden',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Oběd i večeře, jedno vaření na víc jídel, '
                          'každé jídlo ze svého obchodu.',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const SectionTitle('Vymyslet recept z akcí'),
            HkCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Gemini (zdarma) vymyslí recepty z ověřených akcí. Ceny '
                    'a obchody doplní aplikace jen ze skutečných akcí.',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _wish,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _thinking ? null : _invent(),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Přání (nepovinné)',
                      hintText: 'např. něco rychlého, zapečené, bez knedlíků',
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _thinking ? null : _invent,
                    icon: _thinking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined),
                    label: Text(
                      _thinking
                          ? 'Vymýšlím… (do minuty)'
                          : _ideas.isEmpty
                          ? 'Vymyslet recepty'
                          : 'Vymyslet další',
                    ),
                  ),
                  if (_ideasNote.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_ideasNote, style: muted),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (final d in _ideas)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _DishCard(item: d),
              ),
            const SectionTitle('Co z toho uvařit'),
            if (dishes.isEmpty)
              const Text(
                'Z hlavních surovin (maso, brambory, sýr…) teď nic v akci '
                'není. Zkuste to po vydání nových letáků, obvykle ve středu '
                'a ve čtvrtek.',
                style: muted,
              )
            else
              for (final MapEntry(key: chain, value: items) in _byChain(
                dishes,
              ).entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 6),
                  child: Text(
                    '${chainName(chain)} – ${items.length} '
                    '${items.length == 1
                        ? 'jídlo'
                        : items.length < 5
                        ? 'jídla'
                        : 'jídel'}',
                    style: const TextStyle(
                      color: AppColors.copperGold,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final d in items.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _DishCard(item: d),
                  ),
              ],
            const SizedBox(height: 8),
            const SectionTitle('Z vaší kuchařky'),
            if (list.isEmpty)
              const Text(
                'Suroviny z vašich receptů teď v ověřených akcích nejsou.',
                style: muted,
              )
            else
              for (final r in list.take(40))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RecipeCard(item: r),
                ),
          ],
        ],
      ),
    );
  }
}

String offerLine(PriceOffer o) =>
    '${kc(o.price)} ${chainById(o.chain)?.name ?? o.chain}'
    '${o.conditions.isEmpty ? '' : ' (${o.conditions})'}'
    ' · do ${o.validTo.day}. ${o.validTo.month}.';

class _DishCard extends StatelessWidget {
  const _DishCard({required this.item});

  final DishOnSale item;

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);
    final dish = item.dish;
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
                  dish.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${item.onSale.length}/${item.total} v akci',
                style: const TextStyle(color: AppColors.copperGold),
              ),
            ],
          ),
          Text(
            [
              if (item.chain != null) chainName(item.chain),
              if (item.validTo case final validTo?)
                validityLabel(validTo, DateTime.now()),
              if (dish.minutes > 0) '${dish.minutes} min',
            ].join(' · '),
            style: muted,
          ),
          const SizedBox(height: 4),
          for (final entry in item.onSale.entries)
            Text(
              '• ${entry.value.product}: ${offerLine(entry.value)}',
              style: muted,
            ),
          Text(
            'Zlevněné zboží na recept (4 porce): '
            '${kc(saleCost(item).total)}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          if (item.savings > 0)
            Text(
              'Ušetříte asi ${kc(item.savings)} proti běžné ceně',
              style: const TextStyle(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Consumer(
              builder: (context, ref, _) => TextButton.icon(
                onPressed: () => showAddDishToMenu(context, ref, item),
                icon: const Icon(Icons.event_available_rounded, size: 18),
                label: const Text('Do jídelníčku'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Jídla po obchodech; obchody seřazené podle nejlepšího jídla.
Map<String, List<DishOnSale>> _byChain(List<DishOnSale> dishes) {
  final out = <String, List<DishOnSale>>{};
  for (final d in dishes) {
    (out[d.chain ?? ''] ??= []).add(d);
  }
  return out;
}

class _RecipeCard extends StatelessWidget {
  const _RecipeCard({required this.item});

  final SaleRecipe item;

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);
    final r = item;
    return HkCard(
      onTap: () => context.push(Routes.recipe(r.recipe.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.recipe.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${r.hits.length}/${r.ingredientCount} v akci',
                style: const TextStyle(color: AppColors.copperGold),
              ),
            ],
          ),
          for (final h in r.hits)
            Text('• ${h.ingredient.name}: ${offerLine(h.offer)}', style: muted),
          if (r.savings > 0)
            Text(
              'Ušetříte asi ${kc(r.savings)} proti běžné ceně',
              style: const TextStyle(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
        ],
      ),
    );
  }
}

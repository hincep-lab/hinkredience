import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/sale_recipes.dart';
import '../../core/stores.dart';
import '../../core/widgets.dart';
import '../../data/price_service.dart';
import 'best_buy_panel.dart' show PriceDiagnostics, kc, refreshMessage;

/// „Recepty z akcí“: které recepty z kuchařky teď vyjdou levně, protože
/// jejich suroviny jsou v akci v Sušici (jen ověřené ceny z letáků).
class SaleRecipesScreen extends ConsumerStatefulWidget {
  const SaleRecipesScreen({super.key});

  @override
  ConsumerState<SaleRecipesScreen> createState() => _SaleRecipesScreenState();
}

class _SaleRecipesScreenState extends ConsumerState<SaleRecipesScreen> {
  bool _busy = false;
  PriceRefresh? _last;

  Future<void> _search({bool force = false}) async {
    final service = ref.read(priceServiceProvider);
    if (service == null) {
      showMessage(context, 'Hledání akcí potřebuje přihlášení k účtu.');
      return;
    }
    final recipes = ref.read(allRecipesProvider).value ?? const [];
    final products = ingredientsWorthSearching(recipes);
    if (products.isEmpty) {
      showMessage(context, 'V receptech nejsou suroviny k hledání.');
      return;
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
                  'Hledá se v aktuálních letácích Tesco, Penny, Lidl, '
                  'Albert, JIP a COOP podle nejčastějších surovin ve vašich '
                  'receptech. Počítají se jen ověřené ceny. Zdarma.',
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
          if (list.isEmpty)
            EmptyState(
              icon: Icons.local_offer_outlined,
              title: usable == 0
                  ? 'Klepněte na Najít akce'
                  : 'Žádný recept teď není v akci',
              message: usable == 0
                  ? 'Aplikace projde letáky a ukáže recepty, které teď '
                        'vyjdou levněji.'
                  : 'Suroviny z vašich receptů tento týden v akci nejsou.',
            )
          else
            for (final r in list.take(40))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: HkCard(
                  onTap: () => context.push(Routes.recipe(r.recipe.id)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              r.recipe.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            '${r.hits.length}/${r.ingredientCount} v akci',
                            style: const TextStyle(color: AppColors.copperGold),
                          ),
                        ],
                      ),
                      for (final h in r.hits)
                        Text(
                          '• ${h.ingredient.name}: ${kc(h.offer.price)} '
                          '${chainById(h.offer.chain)?.name ?? h.offer.chain}'
                          '${h.offer.conditions.isEmpty ? '' : ' (${h.offer.conditions})'}'
                          ' · do ${h.offer.validTo.day}. ${h.offer.validTo.month}.',
                          style: muted,
                        ),
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
                ),
              ),
        ],
      ),
    );
  }
}

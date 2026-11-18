import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/best_buy.dart';
import '../../core/material.dart';
import '../../core/offer_browse.dart';
import '../../core/sale_dishes.dart' show saleSearchTerms;
import '../../core/shopping.dart';
import '../../core/stores.dart';
import '../../core/widgets.dart';
import 'best_buy_panel.dart'
    show OfferImage, kc, refreshMessage, shortDay, showOfferDetail;

// „Akce v Sušici“: aktuální akce z letáků Tesco, Penny, Lidl, Albert, JIP
// a COOP. Ukazuje jen uložené nabídky z oficiálních zdrojů; neověřené jsou
// označené a do výpočtu nákupu se nepočítají. Budoucí akce zvlášť.

/// Barva štítku obchodu (rozlišení obchodů na první pohled).
Color chainColor(String chain) => switch (chain) {
  'tesco' => const Color(0xFF00539F),
  'penny' => const Color(0xFFCD1719),
  'lidl' => const Color(0xFF0050AA),
  'albert' => const Color(0xFF0B8A3E),
  'jip' => const Color(0xFFE2001A),
  'coop' => const Color(0xFF1E8C3A),
  _ => AppColors.outline,
};

/// Štítek obchodu (název řetězce v barvě obchodu).
class ChainBadge extends StatelessWidget {
  const ChainBadge(this.chain, {super.key});

  final String chain;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: chainColor(chain),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      chainById(chain)?.name ?? chain,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.3,
      ),
    ),
  );
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v'.replaceAll('.', ',');

/// „22,90 Kč/kg“
String unitPriceText(PriceOffer o) {
  final u = o.unitPrice;
  return u == null ? '' : '${kc(u.price)}/${u.unit}';
}

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 2) return 'právě teď';
  if (d.inHours < 1) return 'před ${d.inMinutes} min';
  if (d.inHours < 24) return 'před ${d.inHours} h';
  return '${at.day}. ${at.month}. v ${at.hour}:${at.minute.toString().padLeft(2, '0')}';
}

class OffersScreen extends ConsumerStatefulWidget {
  const OffersScreen({super.key});

  @override
  ConsumerState<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends ConsumerState<OffersScreen> {
  static const _autoKey = 'offers_auto_refresh_at';
  var _filter = const OfferFilter();
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoRefresh());
  }

  /// Nové letáky se stáhnou samy nejvýš dvakrát denně (server je čte jen
  /// při změně letáku, takže opakované otevření nic nestojí).
  Future<void> _autoRefresh() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final last = DateTime.tryParse(prefs.getString(_autoKey) ?? '');
    if (last != null && DateTime.now().difference(last).inHours < 12) return;
    await prefs.setString(_autoKey, DateTime.now().toIso8601String());
    await _refresh(silent: true);
  }

  Future<void> _refresh({bool silent = false, bool force = false}) async {
    final service = ref.read(priceServiceProvider);
    if (service == null) {
      if (!silent) showMessage(context, 'Akce potřebují přihlášení k účtu.');
      return;
    }
    // Základní suroviny + to, co je právě na nákupních seznamech.
    final products = <String>[...saleSearchTerms()];
    final lists = ref.read(shoppingListsProvider).value ?? const [];
    for (final l in lists) {
      for (final i in ref.read(shoppingItemsProvider(l.list.id)).value ?? []) {
        if (!i.checked && products.length < 20 && !products.contains(i.name)) {
          products.add(i.name);
        }
      }
    }
    setState(() => _busy = true);
    try {
      final r = await service.refresh(products.take(20).toList(), force: force);
      await ref.read(priceOffersProvider.notifier).reload();
      await ref.read(priceUpdatesProvider.notifier).reload();
      if (mounted && !silent) showMessage(context, refreshMessage(r));
    } catch (_) {
      await ref.read(priceUpdatesProvider.notifier).reload().catchError((_) {});
      if (mounted) {
        showMessage(
          context,
          'Letáky se teď nepodařilo stáhnout. Ukazuji poslední uložené akce.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add(PriceOffer o) async {
    final docs = await ref.read(docsRepositoryProvider.future);
    final chain = chainById(o.chain)?.name ?? o.chain;
    final item = shoppingFromOffer(o, chain);
    await docs.addToShopping([
      ShoppingDraft(
        name: item.name,
        quantity: item.quantity,
        unit: item.unit,
        note: item.note,
      ),
    ]);
    if (mounted) showMessage(context, 'Přidáno do nákupu: ${o.product}');
  }

  void _toggle<T>(Set<T> set, T value, OfferFilter Function(Set<T>) apply) {
    final next = {...set};
    if (!next.remove(value)) next.add(value);
    setState(() => _filter = apply(next));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(priceOffersProvider);
    final offers = async.value ?? const <PriceOffer>[];
    final updates = ref.watch(priceUpdatesProvider).value ?? const {};
    final cards = ref.watch(bestBuyPrefsProvider.select((p) => p.cards));
    final today = DateTime.now();
    final all = browseOffers(offers, today);
    final shown = browseOffers(offers, today, filter: _filter);
    final groups = presentGroups([...all.current, ...all.upcoming]);
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Akce v Sušici'),
        actions: [
          IconButton(
            key: const ValueKey('offers-refresh'),
            tooltip: 'Stáhnout nové letáky',
            onPressed: _busy ? null : () => _refresh(),
            icon: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(),
        child: ListView(
          key: const PageStorageKey('offers-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _UpdateStatus(updates: updates, now: today),
            const SizedBox(height: 8),
            _Filters(
              filter: _filter,
              groups: groups,
              onChain: (c) => _toggle(
                _filter.chains,
                c,
                (s) => _filter.copyWith(chains: s),
              ),
              onGroup: (g) => _toggle(
                _filter.groups,
                g,
                (s) => _filter.copyWith(groups: s),
              ),
              onDiscount: (d) =>
                  setState(() => _filter = _filter.copyWith(minDiscount: d)),
              onVerified: (v) =>
                  setState(() => _filter = _filter.copyWith(verifiedOnly: v)),
              onClear: () => setState(() => _filter = const OfferFilter()),
            ),
            const SizedBox(height: 4),
            _LoyaltyCards(cards: cards),
            const _SaleAlertsTile(),
            const SizedBox(height: 8),
            Text(
              '${shown.current.length} akcí platí dnes · '
              'ověřených ${shown.current.where((o) => o.verified).length}',
              key: const ValueKey('offers-count'),
              style: muted,
            ),
            const SizedBox(height: 6),
            if (async.isLoading && offers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (shown.current.isEmpty && shown.upcoming.isEmpty)
              EmptyState(
                icon: Icons.local_offer_outlined,
                title: all.current.isEmpty && all.upcoming.isEmpty
                    ? 'Zatím žádné uložené akce'
                    : 'Filtrům nic neodpovídá',
                message: all.current.isEmpty && all.upcoming.isEmpty
                    ? 'Klepněte na obnovit – aplikace projde aktuální letáky.'
                    : 'Zkuste ubrat filtry.',
              )
            else ...[
              for (final o in shown.current)
                OfferCard(
                  key: ValueKey('offer-${o.id}'),
                  offer: o,
                  today: today,
                  hasCard: cards.contains(o.chain),
                  onAdd: () => _add(o),
                ),
              if (shown.upcoming.isNotEmpty) ...[
                const SizedBox(height: 8),
                const SectionTitle('Brzy v akci'),
                for (final o in shown.upcoming)
                  OfferCard(
                    key: ValueKey('offer-${o.id}'),
                    offer: o,
                    today: today,
                    hasCard: cards.contains(o.chain),
                    onAdd: () => _add(o),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Kdy se letáky naposledy stáhly; varování, když poslední pokus selhal.
class _UpdateStatus extends StatelessWidget {
  const _UpdateStatus({required this.updates, required this.now});

  final Map<String, ChainUpdate> updates;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final failing = [
      for (final c in chains)
        if (updates[c.id]?.failing ?? false) c,
    ];
    final oks = [
      for (final u in updates.values)
        if (u.lastOk != null) u.lastOk!,
    ]..sort();
    return HkCard(
      key: const ValueKey('offers-status'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            oks.isEmpty
                ? 'Letáky se zatím nestáhly.'
                : 'Letáky aktualizovány ${_ago(oks.last, now)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          for (final c in failing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: AppColors.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${c.name}: leták se nepodařilo stáhnout'
                      '${updates[c.id]!.lastOk == null ? '' : ' – poslední úspěch ${_ago(updates[c.id]!.lastOk!, now)}'}.',
                      key: ValueKey('offers-warning-${c.id}'),
                      style: const TextStyle(fontSize: 12.5),
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

class _Filters extends StatelessWidget {
  const _Filters({
    required this.filter,
    required this.groups,
    required this.onChain,
    required this.onGroup,
    required this.onDiscount,
    required this.onVerified,
    required this.onClear,
  });

  final OfferFilter filter;
  final List<String> groups;
  final ValueChanged<String> onChain;
  final ValueChanged<String> onGroup;
  final ValueChanged<int> onDiscount;
  final ValueChanged<bool> onVerified;
  final VoidCallback onClear;

  Widget _row(String key, List<Widget> chips) => SizedBox(
    height: 40,
    child: ListView(
      key: PageStorageKey(key),
      scrollDirection: Axis.horizontal,
      children: [
        for (final c in chips)
          Padding(padding: const EdgeInsets.only(right: 6), child: c),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row('offers-chain-row', [
          for (final c in chains)
            FilterChip(
              key: ValueKey('filter-chain-${c.id}'),
              label: Text(c.name),
              selected: filter.chains.contains(c.id),
              onSelected: (_) => onChain(c.id),
            ),
        ]),
        if (groups.isNotEmpty)
          _row('offers-group-row', [
            for (final g in groups)
              FilterChip(
                key: ValueKey('filter-group-$g'),
                label: Text(groupLabel(g)),
                selected: filter.groups.contains(g),
                onSelected: (_) => onGroup(g),
              ),
          ]),
        _row('offers-discount-row', [
          FilterChip(
            key: const ValueKey('filter-verified'),
            label: const Text('Jen ověřené'),
            selected: filter.verifiedOnly,
            onSelected: onVerified,
          ),
          for (final d in const [0, 20, 30, 50])
            ChoiceChip(
              key: ValueKey('filter-discount-$d'),
              label: Text(d == 0 ? 'Každá sleva' : 'Sleva $d %+'),
              selected: filter.minDiscount == d,
              onSelected: (_) => onDiscount(d),
            ),
          if (filter.count > 0)
            ActionChip(
              key: const ValueKey('filter-clear'),
              label: const Text('Zrušit filtry'),
              onPressed: onClear,
            ),
        ]),
      ],
    );
  }
}

/// Vypínač upozornění na akce zboží z nákupních seznamů.
class _SaleAlertsTile extends ConsumerStatefulWidget {
  const _SaleAlertsTile();

  @override
  ConsumerState<_SaleAlertsTile> createState() => _SaleAlertsTileState();
}

class _SaleAlertsTileState extends ConsumerState<_SaleAlertsTile> {
  late bool _on = saleAlertsEnabled(ref.read(sharedPreferencesProvider));

  Future<void> _set(bool value) async {
    setState(() => _on = value);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(saleAlertsKey, value);
    if (value) {
      await prefs.setBool('family_notifications_asked', true);
      await ref.read(familyAlertsProvider).requestPermission();
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('sale-alerts'),
    contentPadding: EdgeInsets.zero,
    title: const Text(
      'Dát vědět, když je zboží ze seznamu v akci',
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    subtitle: const Text(
      'Oznámení v telefonu o nových ověřených akcích na věci, '
      'které máte (nebo jste měli) v nákupních seznamech.',
      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
    ),
    value: _on,
    onChanged: _set,
  );
}

/// Které věrnostní karty / aplikace uživatel má (počítá se jen s nimi).
class _LoyaltyCards extends ConsumerWidget {
  const _LoyaltyCards({required this.cards});

  final Set<String> cards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      key: const PageStorageKey('offers-cards'),
      tilePadding: EdgeInsets.zero,
      title: Text(
        cards.isEmpty
            ? 'Věrnostní karty: žádné'
            : 'Věrnostní karty: ${[for (final c in chains)
                if (cards.contains(c.id)) c.name].join(', ')}',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: const Text(
        'Ceny „s kartou“ se v nákupu počítají jen u obchodů, kde kartu nebo aplikaci máte.',
        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in chains)
              FilterChip(
                key: ValueKey('card-${c.id}'),
                label: Text(c.name),
                selected: cards.contains(c.id),
                onSelected: (on) {
                  final prefs = ref.read(bestBuyPrefsProvider);
                  final next = {...prefs.cards};
                  on ? next.add(c.id) : next.remove(c.id);
                  ref
                      .read(bestBuyPrefsProvider.notifier)
                      .update(prefs.copyWith(cards: next));
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Karta jedné akce.
class OfferCard extends StatelessWidget {
  const OfferCard({
    super.key,
    required this.offer,
    required this.today,
    required this.onAdd,
    this.hasCard = false,
  });

  final PriceOffer offer;
  final DateTime today;
  final VoidCallback onAdd;
  final bool hasCard;

  @override
  Widget build(BuildContext context) {
    final o = offer;
    final discount = o.discountPercent;
    final pack = o.packQty == null ? '' : '${_num(o.packQty!)} ${o.packUnit}';
    final unit = unitPriceText(o);
    final validity = o.startsAfter(today)
        ? 'Platí od ${shortDay(o.validFrom!)} do ${shortDay(o.validTo)}'
        : 'Platí do ${shortDay(o.validTo)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        onTap: () => showOfferDetail(context, o),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ChainBadge(o.chain),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    validity,
                    style: TextStyle(
                      fontSize: 12,
                      color: o.startsAfter(today)
                          ? AppColors.copperGold
                          : AppColors.textSecondary,
                      fontWeight: o.startsAfter(today)
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (!o.verified)
                  const _Pill(
                    'Neověřeno',
                    color: AppColors.textSecondary,
                    key: ValueKey('pill-unverified'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (o.imageUrl.isNotEmpty) ...[
                  OfferImage(o.imageUrl, size: 64),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        o.product,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (pack.isNotEmpty || unit.isNotEmpty)
                        Text(
                          [
                            if (pack.isNotEmpty) pack,
                            if (unit.isNotEmpty) unit,
                          ].join(' · '),
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 10,
              runSpacing: 4,
              children: [
                Text(
                  kc(o.price),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppColors.copperGold,
                  ),
                ),
                if (o.regularPrice != null && o.regularPrice! > o.price)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      kc(o.regularPrice!),
                      style: const TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                if (discount != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: _Pill('−$discount %', color: AppColors.success),
                  ),
              ],
            ),
            if (o.needsLoyalty || o.conditions.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                o.needsLoyalty
                    ? 'Jen s ${o.loyalty.isEmpty ? 'věrnostní kartou' : o.loyalty}'
                          '${hasCard ? '' : ' – kartu nemáte, do nákupu se nepočítá'}'
                    : o.conditions,
                style: TextStyle(
                  fontSize: 12.5,
                  color: o.needsLoyalty
                      ? AppColors.copper
                      : AppColors.textSecondary,
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: ValueKey('add-offer-${o.id}'),
                onPressed: onAdd,
                icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                label: const Text('Přidat do nákupu'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700),
    ),
  );
}

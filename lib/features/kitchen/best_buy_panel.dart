import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/best_buy.dart';
import '../../core/material.dart';
import '../../core/ocr.dart';
import '../../core/receipt_text.dart';
import '../../core/stores.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/price_service.dart';

// „Nejvýhodnější nákup“ přímo v nákupním seznamu: kompaktní panel nahoře,
// štítky akcí u položek, detail akce a ceny z účtenky. Počítá se jen
// s ověřenými cenami (akce z oficiálních webů, vlastní účtenky).

/// „39,90 Kč“
String kc(double value) =>
    '${value.toStringAsFixed(2).replaceAll('.', ',')} Kč';

/// „18. 11.“
String shortDay(DateTime d) => '${d.day}. ${d.month}.';

BuyItem buyItemOf(ShoppingItem item) => BuyItem(
  id: item.id,
  name: item.name,
  quantity: item.quantity,
  unit: item.unit,
);

/// Výpočet pro otevřené (nezaškrtnuté) položky seznamu.
final bestBuyProvider = Provider.family<BestBuy?, String>((ref, listId) {
  final items = ref.watch(shoppingItemsProvider(listId)).value;
  if (items == null) return null;
  final offers = ref.watch(priceOffersProvider).value ?? const <PriceOffer>[];
  final receipts =
      ref.watch(receiptPricesProvider).value ?? const <ReceiptPrice>[];
  return computeBestBuy(
    items: [
      for (final i in items)
        if (!i.checked) buyItemOf(i),
    ],
    offers: offers,
    receipts: receipts,
    today: DateTime.now(),
    loyaltyChains: ref.watch(bestBuyPrefsProvider.select((p) => p.cards)),
  );
});

/// Kompaktní panel nad nákupním seznamem.
class BestBuyPanel extends ConsumerStatefulWidget {
  const BestBuyPanel({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<BestBuyPanel> createState() => _BestBuyPanelState();
}

class _BestBuyPanelState extends ConsumerState<BestBuyPanel> {
  var _busy = false;

  Future<void> _refresh({bool force = false}) async {
    final service = ref.read(priceServiceProvider);
    final items = ref.read(shoppingItemsProvider(widget.listId)).value ?? [];
    final names = [
      for (final i in items)
        if (!i.checked) i.name,
    ];
    if (service == null) {
      showMessage(context, 'Hledání akcí potřebuje přihlášení.');
      return;
    }
    if (names.isEmpty) {
      showMessage(context, 'V seznamu není nic k nákupu.');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await service.refresh(names, force: force);
      await ref.read(priceOffersProvider.notifier).reload();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(refreshMessage(r)),
            duration: const Duration(seconds: 8),
            action: r.diag.isEmpty
                ? null
                : SnackBarAction(
                    label: 'Podrobnosti',
                    onPressed: () => _showDiagnostics(r),
                  ),
          ),
        );
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          'Akce se teď nepodařilo načíst. Zkuste to prosím později.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showDiagnostics(PriceRefresh r) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, controller) => PriceDiagnostics(
          result: r,
          controller: controller,
          onRetry: () {
            Navigator.of(sheet).pop();
            _refresh(force: true);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(bestBuyPrefsProvider);
    final notifier = ref.read(bestBuyPrefsProvider.notifier);
    final result = ref.watch(bestBuyProvider(widget.listId));
    if (!prefs.enabled || result == null || result.items.isEmpty) {
      return const SizedBox.shrink();
    }
    if (!result.hasPrices) {
      // Ceny zatím neznáme: jen jeden nenápadný řádek, ať seznam zůstane
      // hlavní věcí obrazovky.
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: HkCard(
          padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
          child: Row(
            children: [
              const Icon(
                Icons.savings_outlined,
                color: AppColors.copperGold,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Nejvýhodnější nákup – ceny zatím neznám',
                  maxLines: 2,
                  style: TextStyle(fontSize: 13),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                TextButton(
                  onPressed: _refresh,
                  child: const Text('Najít akce'),
                ),
              IconButton(
                tooltip: 'Ceny z účtenky',
                icon: const Icon(Icons.receipt_long_outlined),
                onPressed: () => showReceiptSheet(context, ref),
              ),
            ],
          ),
        ),
      );
    }
    final multi = prefs.multiStore;
    final total = multi
        ? result.combinationTotal
        : result.singleStore?.total ?? 0;
    final savings = multi ? result.savingsCombination : result.savingsSingle;
    // Součet je cenou nákupu jen se známou cenou VŠECH položek.
    final complete = multi
        ? result.combinationComplete
        : result.singleStore?.complete ?? false;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.savings_outlined,
                  color: AppColors.copperGold,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    prefs.collapsed && result.hasPrices
                        ? complete
                              ? 'Nejvýhodnější nákup · ${kc(total)}'
                              : 'Nejvýhodnější nákup · ceny jen části'
                        : 'Nejvýhodnější nákup',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'Najít aktuální akce',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: _refresh,
                  ),
                IconButton(
                  tooltip: prefs.collapsed ? 'Rozbalit' : 'Sbalit',
                  icon: Icon(
                    prefs.collapsed
                        ? Icons.expand_more_rounded
                        : Icons.expand_less_rounded,
                  ),
                  onPressed: () => notifier.update(
                    prefs.copyWith(collapsed: !prefs.collapsed),
                  ),
                ),
              ],
            ),
            if (!prefs.collapsed) ...[
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Jeden obchod'),
                      icon: Icon(Icons.store_outlined),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Více obchodů'),
                      icon: Icon(Icons.alt_route_rounded),
                    ),
                  ],
                  selected: {multi},
                  onSelectionChanged: (v) =>
                      notifier.update(prefs.copyWith(multiStore: v.first)),
                ),
              ),
              if (multi)
                _MultiSummary(
                  result: result,
                  total: total,
                  savings: savings,
                  grouped: prefs.groupByStore,
                  onGroup: (v) =>
                      notifier.update(prefs.copyWith(groupByStore: v)),
                )
              else
                _SingleSummary(result: result, savings: savings),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Jen ověřené ceny z aktuálních letáků obchodů a z '
                      'vašich účtenek.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => showReceiptSheet(context, ref),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('Účtenka'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Money extends StatelessWidget {
  const _Money({
    required this.total,
    required this.savings,
    required this.known,
    required this.all,
    required this.missing,
  });

  final double total;
  final double savings;

  /// Kolik položek má ověřenou cenu / kolik jich je v seznamu.
  final int known;
  final int all;
  final List<BuyItem> missing;

  @override
  Widget build(BuildContext context) {
    final complete = known == all;
    final saved = savings > 0
        ? Text(
            complete
                ? 'ušetříte ${kc(savings)}'
                : 'na nich ušetříte ${kc(savings)}',
            style: const TextStyle(
              color: AppColors.success,
              fontWeight: FontWeight.w600,
            ),
          )
        : null;
    if (!complete) {
      // Neúplné ceny: žádná „cena nákupu“, jen mezisoučet a co chybí.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cenu celého nákupu zatím nejde určit',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.copperGold,
            ),
          ),
          Text(
            'Mezisoučet $known z $all položek: ${kc(total)}',
            style: const TextStyle(fontSize: 13),
          ),
          Text(
            'Chybí ověřená cena: ${missing.map((i) => i.name).join(', ')}',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
            ),
          ),
          ?saved,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          kc(total),
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.copperGold,
          ),
        ),
        const SizedBox(width: 10),
        if (saved != null) Flexible(child: saved),
      ],
    );
  }
}

String _coverage(int known, int all) =>
    known == all ? 'ceny všech $all položek' : 'ceny $known z $all položek';

class _SingleSummary extends StatelessWidget {
  const _SingleSummary({required this.result, required this.savings});

  final BestBuy result;
  final double savings;

  @override
  Widget build(BuildContext context) {
    final best = result.singleStore!;
    final others = result.storePlans.skip(1).take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            best.store.label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          _Money(
            total: best.total,
            savings: savings,
            known: best.prices.length,
            all: result.items.length,
            missing: best.missing,
          ),
          if (best.complete)
            Text(
              _coverage(best.prices.length, result.items.length),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
          for (final p in best.prices)
            Text(
              '• ${p.item.name}: ${kc(p.cost)}'
              '${p.offer == null ? ' (účtenka)' : ' · ${p.offer!.product}${p.offer!.conditions.isEmpty ? '' : ' – ${p.offer!.conditions}'} · do ${shortDay(p.offer!.validTo)}'}',
              style: const TextStyle(fontSize: 12.5),
            ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final p in others)
              Text(
                p.complete
                    ? '${p.store.label}: ${kc(p.total)} (celý nákup)'
                    : '${p.store.label}: ${p.prices.length} z '
                          '${result.items.length} položek za ${kc(p.total)}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _MultiSummary extends StatelessWidget {
  const _MultiSummary({
    required this.result,
    required this.total,
    required this.savings,
    required this.grouped,
    required this.onGroup,
  });

  final BestBuy result;
  final double total;
  final double savings;
  final bool grouped;
  final ValueChanged<bool> onGroup;

  @override
  Widget build(BuildContext context) {
    final groups = result.combinationByStore;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Money(
            total: total,
            savings: savings,
            known: result.combination.length,
            all: result.items.length,
            missing: result.combinationMissing,
          ),
          for (final p in result.combination)
            Text(
              '• ${p.item.name}: ${kc(p.cost)} – ${p.store.label}'
              '${p.offer == null ? ' (účtenka)' : '${p.offer!.conditions.isEmpty ? '' : ', ${p.offer!.conditions}'} · do ${shortDay(p.offer!.validTo)}'}',
              style: const TextStyle(fontSize: 12.5),
            ),
          Text(
            [
              '${groups.length} '
                  '${groups.length == 1
                      ? 'obchod'
                      : groups.length < 5
                      ? 'obchody'
                      : 'obchodů'}',
              _coverage(result.combination.length, result.items.length),
            ].join(' · '),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Seskupit seznam podle prodejen'),
            value: grouped,
            onChanged: onGroup,
          ),
        ],
      ),
    );
  }
}

/// Malý štítek ověřené akce u položky seznamu.
class OfferTag extends StatelessWidget {
  const OfferTag({super.key, required this.offer, required this.onTap});

  final PriceOffer offer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chain = chainById(offer.chain)?.name ?? offer.chain;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.copper.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.copper.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.local_offer_outlined,
                size: 13,
                color: AppColors.copperGold,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '$chain · ${kc(offer.price)} · do ${shortDay(offer.validTo)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.copperGold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _providerLabel(String p) => switch (p) {
  'gemini' => 'Google Gemini (čtení akčního letáku)',
  'web' => 'data z webu obchodu',
  'openai' => 'OpenAI',
  'chatgpt' => 'ChatGPT',
  _ => 'ručně',
};

/// Detail akce: cena, platnost, prodejny, zdroj a jak byla ověřena.
Future<void> showOfferDetail(
  BuildContext context,
  PriceOffer offer, {
  List<PriceOffer> unverified = const [],
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    final chain = chainById(offer.chain);
    final stores = [
      for (final s in susiceStores)
        if (offer.appliesTo(s)) s,
    ];
    final discount =
        offer.regularPrice != null && offer.regularPrice! > offer.price
        ? ((1 - offer.price / offer.regularPrice!) * 100).round()
        : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                offer.product,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (offer.label.isNotEmpty)
                Text(
                  offer.label,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    kc(offer.price),
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.copperGold,
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (offer.regularPrice != null)
                    Text(
                      kc(offer.regularPrice!),
                      style: const TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  if (discount != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '−$discount %',
                      style: const TextStyle(
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              if (offer.packQty != null)
                Text(
                  'Balení: ${offer.packQty!.toString().replaceAll('.0', '').replaceAll('.', ',')} ${offer.packUnit}',
                ),
              const SizedBox(height: 10),
              _DetailRow(
                Icons.event_outlined,
                offer.validFrom == null
                    ? 'Platí do ${shortDay(offer.validTo)}${offer.validTo.year}'
                    : 'Platí ${shortDay(offer.validFrom!)} – ${shortDay(offer.validTo)}${offer.validTo.year}',
              ),
              _DetailRow(
                Icons.store_outlined,
                [for (final s in stores) s.label].join('\n'),
              ),
              if (offer.needsLoyalty)
                _DetailRow(
                  Icons.card_membership_rounded,
                  'Cena jen s ${offer.loyalty.isEmpty ? 'věrnostní kartou' : offer.loyalty}',
                ),
              if (offer.conditions.isNotEmpty)
                _DetailRow(Icons.info_outline_rounded, offer.conditions),
              _DetailRow(
                offer.verified
                    ? Icons.verified_outlined
                    : Icons.help_outline_rounded,
                offer.verified
                    ? 'Ověřeno: ${switch (offer.verifyMethod) {
                        'stránka' => 'cena i gramáž jsou na oficiální stránce obchodu',
                        'data' => 'cena z dat oficiálního webu obchodu',
                        'leták-text' => 'cena i gramáž stojí v textu oficiálního letáku',
                        _ => 'z oficiálního zdroje obchodu',
                      }}.'
                    : 'Neověřeno${offer.sourceTitle.isEmpty ? '' : ' (${offer.sourceTitle})'} – do výpočtu nákupu se nepočítá.',
              ),
              _DetailRow(
                Icons.travel_explore_outlined,
                'Nalezl: ${_providerLabel(offer.provider)}',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(offer.sourceUrl),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(
                  'Zdroj: ${Uri.tryParse(offer.sourceUrl)?.host ?? chain?.name ?? ''}',
                ),
              ),
              if (unverified.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Neověřené nabídky (jen pro informaci)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                for (final o in unverified)
                  Text(
                    '${chainById(o.chain)?.name ?? o.chain}: ${o.product} – '
                    '${kc(o.price)}, do ${shortDay(o.validTo)}',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  },
);

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ účtenka

/// Ceny z účtenky: vyfotit (čtení textu bez AI) nebo zapsat ručně.
Future<void> showReceiptSheet(BuildContext context, WidgetRef ref) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _ReceiptSheet(),
    );

class _ReceiptSheet extends ConsumerStatefulWidget {
  const _ReceiptSheet();

  @override
  ConsumerState<_ReceiptSheet> createState() => _ReceiptSheetState();
}

class _ReceiptSheetState extends ConsumerState<_ReceiptSheet> {
  String? _store;
  DateTime _date = DateTime.now();
  final _lines = <ReceiptLine>[];
  var _busy = false;
  String? _error;

  Future<void> _photo() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 90,
    );
    if (picked == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final text = await readTextFromImage(picked.path);
      final parsed = parseReceiptText(text);
      setState(() {
        _lines
          ..clear()
          ..addAll(parsed.lines);
        _store ??= parsed.storeId;
        if (parsed.date != null) _date = parsed.date!;
        if (parsed.lines.isEmpty) {
          _error =
              'Na účtence jsem nenašel položky s cenou. Zkuste ostřejší '
              'fotku nebo je zapište ručně.';
        }
      });
    } catch (error) {
      setState(
        () => _error = error is OcrException
            ? error.message
            : 'Účtenku se nepodařilo přečíst. Zkuste to znovu.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addManual() =>
      setState(() => _lines.add(ReceiptLine(product: '', price: 0)));

  Future<void> _save() async {
    final store = _store;
    final valid = [
      for (final l in _lines)
        if (l.product.trim().isNotEmpty && l.price > 0) l,
    ];
    if (store == null || valid.isEmpty) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveReceipts([
      for (final l in valid)
        ReceiptPrice(
          id: docs.newId(),
          storeId: store,
          product: l.product.trim(),
          price: l.price,
          packQty: l.packQty,
          packUnit: l.packUnit,
          boughtOn: _date,
          note: 'účtenka',
          updatedAt: docs.now(),
        ),
    ]);
    ref.read(syncProvider.notifier).schedule(const Duration(seconds: 1));
    if (!mounted) return;
    Navigator.of(context).pop();
    showMessage(context, 'Uloženo cen z účtenky: ${valid.length}.');
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _store != null &&
        _lines.any((l) => l.product.trim().isNotEmpty && l.price > 0);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ceny z účtenky',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'Skutečné ceny z vašeho nákupu. Uloží se k prodejně a porovnání '
              'je použije (sdílí se s rodinou).',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _store,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Prodejna'),
              items: [
                for (final s in susiceStores)
                  DropdownMenuItem(value: s.id, child: Text(s.label)),
              ],
              onChanged: (v) => setState(() => _store = v),
            ),
            const SizedBox(height: 6),
            Text(
              'Datum nákupu: ${_date.day}. ${_date.month}. ${_date.year}',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (ocrAvailable)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _photo,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Vyfotit účtenku'),
                    ),
                  ),
                if (ocrAvailable) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _addManual,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Zapsat ručně'),
                  ),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
            for (var i = 0; i < _lines.length; i++)
              _ReceiptLineRow(
                key: ObjectKey(_lines[i]),
                line: _lines[i],
                onChanged: () => setState(() {}),
                onRemove: () => setState(() => _lines.removeAt(i)),
              ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              onPressed: canSave ? _save : null,
              child: const Text('Uložit ceny'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptLineRow extends StatelessWidget {
  const _ReceiptLineRow({
    super.key,
    required this.line,
    required this.onChanged,
    required this.onRemove,
  });

  final ReceiptLine line;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              initialValue: line.product,
              decoration: const InputDecoration(labelText: 'Produkt'),
              onChanged: (v) {
                line.product = v;
                onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: line.price > 0
                  ? line.price.toStringAsFixed(2).replaceAll('.', ',')
                  : '',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Kč / ks'),
              onChanged: (v) {
                line.price =
                    double.tryParse(v.trim().replaceAll(',', '.')) ?? 0;
                onChanged();
              },
            ),
          ),
          IconButton(
            tooltip: 'Odebrat',
            icon: const Icon(Icons.close_rounded),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Krátká zpráva po hledání akcí (s konkrétní příčinou, když nic není).
String refreshMessage(PriceRefresh r) {
  if (r.scanned == 0 && r.cached > 0) {
    return 'Tyto letáky už jsou prohledané – zobrazuji uložené akce (nic se '
        'znovu nečerpalo). V Podrobnostech lze hledat znovu.';
  }
  final counts =
      'Nalezeno ${r.found} · uloženo ${r.saved}'
      '${r.duplicates > 0 ? ' · už uložené ${r.duplicates}' : ''}'
      ' · ověřených ${r.verified}'
      '${r.rejected > 0 ? ' · odmítnuto ${r.rejected}' : ''}.';
  if (r.noProvider) {
    return '$counts Na serveru chybí bezplatný klíč Google Gemini, letáky '
        'proto nemá kdo přečíst (jen data z webu Penny).';
  }
  if (r.found > 0) return counts;
  final why = r.chainErrors.isNotEmpty
      ? 'Problém: ${r.chainErrors.first}'
      : 'Hledané zboží teď v aktuálních letácích obchodů není.';
  return '$counts $why';
}

/// Jednou větou, zda Google Gemini v tomto hledání fungovalo.
String geminiStatusText(PriceRefresh r) {
  if (r.version.isEmpty) {
    return 'Na serveru běží stará verze funkce „prices“ – nasaďte prosím '
        'novou (čtení letáků).';
  }
  final model = r.geminiModel.isEmpty ? '' : ' (${r.geminiModel})';
  if (!r.geminiConfigured) {
    return 'Google Gemini: NENÍ nastaveno – chybí GEMINI_API_KEY. Letáky '
        'nemá kdo přečíst.';
  }
  if (r.geminiCalls == 0) {
    return 'Google Gemini$model: tentokrát nebylo potřeba volat.';
  }
  if (r.geminiOk == true) {
    return 'Google Gemini$model: FUNGUJE – ${r.geminiCalls} čtení letáků '
        '(zdarma)${r.geminiError.isEmpty ? '' : ', část selhala: ${r.geminiError}'}.';
  }
  return 'Google Gemini$model: NEFUNGUJE – ${r.geminiError}';
}

/// Diagnostika hledání akcí: po obchodech, jaký zdroj se použil, co se
/// stáhlo, co přečetla AI, co bylo odmítnuto (a proč) a co se uložilo.
class PriceDiagnostics extends StatelessWidget {
  const PriceDiagnostics({
    super.key,
    required this.result,
    required this.onRetry,
    this.controller,
  });

  final PriceRefresh result;
  final VoidCallback onRetry;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    final small = theme.textTheme.bodySmall;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text('Diagnostika hledání akcí', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'Nalezeno ${r.found} · ověřených ${r.verified} · neověřených '
          '${r.unverified} · uloženo ${r.saved} · už uložené '
          '${r.duplicates} · odmítnuto ${r.rejected} · z mezipaměti '
          '${r.cached}',
          style: small,
        ),
        const SizedBox(height: 8),
        Text(geminiStatusText(r), style: small),
        for (final d in r.diag) _chain(context, d),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Hledat znovu (bez mezipaměti)'),
        ),
        const SizedBox(height: 6),
        Text(
          'Do porovnání se počítají jen ověřené ceny: z dat webu obchodu, '
          'nebo přečtené z letáku a potvrzené textem letáku či druhým '
          'nezávislým čtením. Neověřené (?) se nezapočítávají.',
          style: small,
        ),
      ],
    );
  }

  Widget _chain(BuildContext context, Map<String, dynamic> d) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    List<Map<String, dynamic>> list(String k) => [
      for (final x in (d[k] as List?) ?? const [])
        if (x is Map) Map<String, dynamic>.from(x),
    ];
    final sources = list('sources');
    final pages = list('pages');
    final ai = list('ai');
    final offers = list('offers');
    final rejected = list('rejected');
    final errors = [for (final e in (d['errors'] as List?) ?? const []) '$e'];
    String txt(Object? v) => '${v ?? ''}';
    final lines = <String>[
      if (d['cached'] == true)
        'Tyto letáky už jsou prohledané (mezipaměť) – platí uložené akce.',
      for (final s in sources)
        s['kind'] == 'data'
            ? 'Zdroj: ${s['title']} – ${s['size']} položek (bez AI)'
            : 'Zdroj: ${s['title']}'
                  '${txt(s['valid_to']).isEmpty ? '' : ', platí ${txt(s['valid_from']).isEmpty ? '' : '${_day(txt(s['valid_from']))} – '}${_day(txt(s['valid_to']))}'}'
                  ', ${s['size']} stran'
                  '${(s['picked'] as List?)?.isNotEmpty == true
                      ? ', čteny strany ${(s['picked'] as List).join(', ')}'
                      : d['cached'] == true
                      ? ''
                      : s['text'] == true
                      ? ', hledané zboží v textu letáku není'
                      : ''}',
      for (final p in pages)
        if ((p['status'] as num?)?.toInt() != 200 || txt(p['note']).isNotEmpty)
          'Stahování ${_host(txt(p['url']))}: '
              '${(p['status'] as num?)?.toInt() == 200 ? 'v pořádku' : 'nestaženo'}'
              '${txt(p['note']).isEmpty ? '' : ' (${p['note']})'}',
      for (final a in ai)
        if (a['mode'] != 'data')
          '${a['mode'] == 'kontrola' ? 'Kontrolní čtení' : 'Čtení letáku'} '
              '(${a['model']}), ${txt(a['pages'])}: '
              '${a['status'] == 'ok' ? '${a['mode'] == 'kontrola' ? 'potvrzeno' : 'nabídek'} ${a['offers'] ?? 0}${txt(a['note']).isEmpty ? '' : ' – ${a['note']}'}' : 'CHYBA – ${a['error']}'}',
      for (final o in offers)
        '${o['verified'] == true ? '✓' : '?'} ${o['product']} '
            '${kc((o['price'] as num).toDouble())}'
            '${txt(o['pack']).isEmpty ? '' : ' / ${o['pack']}'}'
            '${txt(o['conditions']).isEmpty ? '' : ' (${o['conditions']})'}'
            ' do ${_day(txt(o['valid_to']))} – '
            '${o['reason']} (${o['saved']})',
      for (final x in rejected) '✗ ${x['product']}: ${x['reason']}',
      for (final e in errors) '! $e',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${d['name']}', style: theme.textTheme.labelLarge),
          if (lines.isEmpty) Text('Nic nenalezeno.', style: small),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(l, style: small),
            ),
        ],
      ),
    );
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;

  /// 2026-11-17 → 17. 11.
  static String _day(String iso) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(iso);
    return m == null
        ? iso
        : '${int.parse(m.group(3)!)}. ${int.parse(m.group(2)!)}.';
  }
}

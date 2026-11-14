import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';
import '../../data/ai_service.dart';
import 'ai_common.dart';
import 'draft_review_screen.dart';

/// Hledání receptů na internetu. Výsledky pocházejí ze skutečného webového
/// vyhledávání a každý má odkaz na zdroj; z vybraných jde složit „naše verze“.
class WebSearchScreen extends ConsumerStatefulWidget {
  const WebSearchScreen({
    super.key,
    this.initialQuery = '',
    this.similarRecipeId,
  });

  final String initialQuery;

  /// Když je zadaný, hledají se recepty podobné tomuto uloženému receptu.
  final String? similarRecipeId;

  @override
  ConsumerState<WebSearchScreen> createState() => _WebSearchScreenState();
}

class _WebSearchScreenState extends ConsumerState<WebSearchScreen> {
  late final _query = TextEditingController(text: widget.initialQuery);
  final _ingredients = TextEditingController();
  final _cuisine = TextEditingController();

  bool _filters = false;
  bool _useEquipment = true;
  int? _maxMinutes;
  String? _photoBase64;

  bool _searching = false;
  bool _composing = false;
  Object? _error;
  SearchOutcome? _outcome;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty ||
        widget.similarRecipeId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _ingredients.dispose();
    _cuisine.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final service = ref.read(aiServiceProvider);
    if (service == null || _searching) return;
    final similarId = widget.similarRecipeId;
    final similar = similarId == null
        ? null
        : ref.read(recipeProvider(similarId)).value;
    final query = _query.text.trim();
    final ingredients = splitIngredients(_ingredients.text);
    if (query.isEmpty &&
        ingredients.isEmpty &&
        _photoBase64 == null &&
        similar == null) {
      showMessage(
        context,
        'Napište název jídla, suroviny nebo přidejte fotku.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _outcome = null;
      _selected.clear();
    });
    try {
      final outcome = await service.search(
        query: query,
        ingredients: ingredients,
        cuisine: _cuisine.text,
        maxMinutes: _maxMinutes,
        useEquipment: _useEquipment,
        similarTo: query.isEmpty ? similar : null,
        imageBase64: _photoBase64,
      );
      if (!mounted) return;
      setState(() {
        _searching = false;
        _outcome = outcome;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = error;
      });
    }
  }

  Future<void> _ourVersion() async {
    final service = ref.read(aiServiceProvider);
    final outcome = _outcome;
    if (service == null || outcome == null || _composing) return;
    final picked = [
      for (final result in outcome.results)
        if (_selected.contains(result.url)) result,
    ];
    if (picked.isEmpty) return;
    setState(() {
      _composing = true;
      _error = null;
    });
    try {
      final proposal = await service.ourVersion(picked);
      if (!mounted) return;
      setState(() => _composing = false);
      context.push(
        Routes.draft,
        extra: DraftReviewArgs(proposal: proposal, heading: 'Naše verze'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _composing = false;
        _error = error;
      });
    }
  }

  Future<void> _addPhoto() async {
    final photo = await choosePhotoForAi(context);
    if (photo == null || !mounted) return;
    setState(() => _photoBase64 = photo);
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(aiServiceProvider);
    final outcome = _outcome;
    final error = _error;
    final similarId = widget.similarRecipeId;
    final similar = similarId == null
        ? null
        : ref.watch(recipeProvider(similarId)).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Hledat na internetu')),
      bottomNavigationBar: outcome == null || service == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: CopperButton(
                  label: _selected.isEmpty
                      ? 'Vyberte recepty pro naši verzi'
                      : 'Vytvořit naši verzi (${_selected.length})',
                  icon: Icons.auto_awesome_rounded,
                  busy: _composing,
                  onPressed: _selected.isEmpty ? null : _ourVersion,
                ),
              ),
            ),
      body: service == null
          ? const AiUnavailable()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    labelText: 'Co hledáme?',
                    hintText: similar == null
                        ? 'např. svíčková na smetaně'
                        : 'prázdné = podobné receptu „${similar.title}“',
                    prefixIcon: const Icon(Icons.travel_explore_rounded),
                    suffixIcon: IconButton(
                      tooltip: 'Hledat podle fotografie',
                      icon: Icon(
                        _photoBase64 == null
                            ? Icons.add_a_photo_outlined
                            : Icons.photo_rounded,
                        color: _photoBase64 == null
                            ? null
                            : AppColors.copperGold,
                      ),
                      onPressed: _photoBase64 == null
                          ? _addPhoto
                          : () => setState(() => _photoBase64 = null),
                    ),
                  ),
                ),
                if (_photoBase64 != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Fotografie je přiložená – klepnutím na ikonu ji odeberete.',
                      style: TextStyle(
                        color: AppColors.copperGold,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _filters = !_filters),
                    icon: Icon(
                      _filters ? Icons.expand_less_rounded : Icons.tune_rounded,
                    ),
                    label: Text(
                      _filters ? 'Skrýt upřesnění' : 'Upřesnit hledání',
                    ),
                  ),
                ),
                if (_filters) ...[
                  TextField(
                    controller: _ingredients,
                    decoration: const InputDecoration(
                      labelText: 'Suroviny, které chci využít',
                      hintText: 'kuře, smetana, paprika',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _cuisine,
                    decoration: const InputDecoration(
                      labelText: 'Typ kuchyně',
                      hintText: 'česká, italská, asijská…',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (minutes, label) in const [
                        (null, 'Bez limitu'),
                        (30, 'Do 30 min'),
                        (60, 'Do 1 h'),
                        (120, 'Do 2 h'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: _maxMinutes == minutes,
                          onSelected: (_) =>
                              setState(() => _maxMinutes = minutes),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Zohlednit moje vybavení'),
                    value: _useEquipment,
                    onChanged: (value) => setState(() => _useEquipment = value),
                  ),
                ],
                const SizedBox(height: 4),
                CopperButton(
                  label: 'Hledat recepty',
                  icon: Icons.search_rounded,
                  busy: _searching,
                  onPressed: _search,
                ),
                if (_searching)
                  const AiProgress(
                    label:
                        'Prohledávám internet a porovnávám recepty.\n'
                        'Obvykle to trvá 20–60 sekund.',
                  ),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  AiErrorCard(error: error),
                ],
                if (outcome != null) ...[
                  SectionTitle('Nalezené recepty (${outcome.results.length})'),
                  if (outcome.droppedUnverified > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Vyřazeno výsledků bez ověřitelného odkazu: '
                        '${outcome.droppedUnverified}.',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  for (final result in outcome.results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ResultCard(
                        result: result,
                        selected: _selected.contains(result.url),
                        onToggle: () => setState(() {
                          if (!_selected.remove(result.url)) {
                            _selected.add(result.url);
                          }
                        }),
                      ),
                    ),
                  if (outcome.hasComparison) ...[
                    const SectionTitle('Porovnání'),
                    HkCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Compare('Suroviny', outcome.compareIngredients),
                          _Compare('Postup', outcome.compareMethod),
                          _Compare(
                            'Teploty a časy',
                            outcome.compareTemperatures,
                          ),
                          _Compare('Hodnocení', outcome.compareRatings),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
    );
  }
}

class _Compare extends StatelessWidget {
  const _Compare(this.title, this.text);

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.copperGold,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(text, style: const TextStyle(height: 1.4)),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.selected,
    required this.onToggle,
  });

  final WebRecipe result;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final rating = result.rating;
    final minutes = result.totalMinutes;
    final meta = [
      if (rating != null)
        result.ratingCount == null
            ? '★ ${formatQuantity(rating)}'
            : '★ ${formatQuantity(rating)} (${result.ratingCount})',
      if (minutes != null && minutes > 0) formatMinutes(minutes),
      ...result.temperatures.take(2),
    ];
    return HkCard(
      onTap: onToggle,
      padding: const EdgeInsets.fromLTRB(6, 10, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(value: selected, onChanged: (_) => onToggle()),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                Text(
                  result.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                  ),
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      meta.join(' · '),
                      style: const TextStyle(
                        color: AppColors.copperGold,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                if (result.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      result.summary,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ),
                if (result.ingredients.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      result.ingredients.join(', '),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => openSource(context, result.url),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.open_in_new_rounded,
                          size: 15,
                          color: AppColors.copperGold,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            result.verified
                                ? 'Otevřít na ${result.site}'
                                : 'Otevřít na ${result.site} (odkaz neověřen)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.copperGold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
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

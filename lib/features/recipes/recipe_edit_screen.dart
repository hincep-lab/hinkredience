import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/recipe_groups.dart' show suggestedTags;
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/recipe_time.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';
import '../photos/photo_editor.dart';
import 'recipes_screen.dart' show categoryIcon;

/// Vytvoření nového receptu nebo úprava existujícího.
class RecipeEditScreen extends ConsumerStatefulWidget {
  const RecipeEditScreen({super.key, this.recipeId, this.initialCategory});

  /// `null` = nový recept.
  final String? recipeId;
  final String? initialCategory;

  @override
  ConsumerState<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _IngredientDraft {
  _IngredientDraft(
    this.id, {
    String quantity = '',
    String unit = '',
    String name = '',
  }) : quantity = TextEditingController(text: quantity),
       unit = TextEditingController(text: unit),
       name = TextEditingController(text: name);

  final String id;
  final TextEditingController quantity;
  final TextEditingController unit;
  final TextEditingController name;
  String note = '';

  void dispose() {
    quantity.dispose();
    unit.dispose();
    name.dispose();
  }
}

class _StepDraft {
  _StepDraft(
    this.id, {
    String instruction = '',
    String minutes = '',
    String temperature = '',
    this.kind = StepKind.auto,
    this.parallel = false,
  }) : instruction = TextEditingController(text: instruction),
       minutes = TextEditingController(text: minutes),
       temperature = TextEditingController(text: temperature);

  final String id;
  final TextEditingController instruction;
  final TextEditingController minutes;
  final TextEditingController temperature;

  /// Druh kroku z hlediska času; prázdné = rozpoznat z textu.
  String kind;

  /// Krok běží současně s předchozím.
  bool parallel;

  void dispose() {
    instruction.dispose();
    minutes.dispose();
    temperature.dispose();
  }
}

class _RecipeEditScreenState extends ConsumerState<RecipeEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _servings = TextEditingController(text: '4');
  final _prep = TextEditingController();
  final _cook = TextEditingController();
  final _rest = TextEditingController();
  final _total = TextEditingController();
  String _yieldUnit = YieldUnit.servings;

  /// Recept je sdílený s rodinou (vidí a upravují ho všichni členové).
  bool _shared = false;
  final _notes = TextEditingController();
  final _source = TextEditingController();
  final _changeSummary = TextEditingController();

  /// Uvolnění odebraných řádků se odkládá až na zavření obrazovky.
  final _retired = <VoidCallback>[];
  final _ingredients = <_IngredientDraft>[];
  final _steps = <_StepDraft>[];
  var _photos = <RecipePhoto>[];
  var _temperatures = <String>[];
  var _equipment = <String>[];
  var _tags = <String>[];
  String _category = '';
  double? _rating;

  late String _recipeId;
  Recipe? _original;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  Object? _loadError;

  bool get _isNew => widget.recipeId == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repository = await ref.read(recipeRepositoryProvider.future);
      if (_isNew) {
        _recipeId = repository.newId();
        _category = widget.initialCategory ?? '';
        _ingredients.add(_IngredientDraft(repository.newId()));
        _steps.add(_StepDraft(repository.newId()));
      } else {
        final recipe = await repository.getById(widget.recipeId!);
        if (recipe == null) throw StateError('Recept nenalezen.');
        _original = recipe;
        _recipeId = recipe.id;
        _title.text = recipe.title;
        _description.text = recipe.description;
        _servings.text = formatQuantity(recipe.servings);
        _prep.text = recipe.prepMinutes > 0 ? '${recipe.prepMinutes}' : '';
        _cook.text = recipe.cookMinutes > 0 ? '${recipe.cookMinutes}' : '';
        _rest.text = recipe.restMinutes > 0 ? '${recipe.restMinutes}' : '';
        _yieldUnit = YieldUnit.normalize(recipe.yieldUnit);
        _shared = recipe.visibility == RecipeVisibility.household;
        _total.text = recipe.totalMinutes > 0 ? '${recipe.totalMinutes}' : '';
        _notes.text = recipe.notes;
        _source.text = recipe.sourceUrl ?? '';
        _category = recipe.category;
        _rating = recipe.rating;
        _photos = [...recipe.photos];
        _temperatures = [...recipe.temperatures];
        _equipment = [...recipe.equipment];
        _tags = [...recipe.tags];
        for (final item in recipe.ingredients) {
          _ingredients.add(
            _IngredientDraft(
              item.id,
              quantity: item.quantity == null
                  ? ''
                  : formatQuantity(item.quantity!),
              unit: item.unit,
              name: item.name,
            )..note = item.note,
          );
        }
        for (final step in recipe.steps) {
          _steps.add(
            _StepDraft(
              step.id,
              instruction: step.instruction,
              minutes: step.durationMinutes == null
                  ? ''
                  : '${step.durationMinutes}',
              temperature: step.temperatureC == null
                  ? ''
                  : formatQuantity(step.temperatureC!),
              kind: step.kind,
              parallel: step.parallel,
            ),
          );
        }
      }
    } catch (error) {
      _loadError = error;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _description,
      _servings,
      _prep,
      _cook,
      _rest,
      _total,
      _notes,
      _source,
      _changeSummary,
    ]) {
      controller.dispose();
    }
    for (final draft in _ingredients) {
      draft.dispose();
    }
    for (final draft in _steps) {
      draft.dispose();
    }
    for (final dispose in _retired) {
      dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  // ------------------------------------------------------------ fotografie

  // -------------------------------------------------------------- kategorie

  Future<void> _chooseCategory() async {
    final categories = ref.read(categoriesProvider).value ?? defaultCategories;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Nová kategorie…'),
              onTap: () => Navigator.of(sheetContext).pop('\u0000new'),
            ),
            if (_category.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.block_rounded),
                title: const Text('Bez kategorie'),
                onTap: () => Navigator.of(sheetContext).pop(''),
              ),
            const Divider(),
            for (final category in categories)
              ListTile(
                leading: Icon(categoryIcon(category)),
                title: Text(category),
                trailing: category == _category
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(category),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == '\u0000new') {
      final name = await _askText(
        title: 'Nová kategorie',
        label: 'Název kategorie',
      );
      if (name == null || name.isEmpty) return;
      final repository = await ref.read(recipeRepositoryProvider.future);
      await repository.addCustomCategory(name);
      ref.invalidate(categoriesProvider);
      if (mounted) {
        setState(() {
          _category = name;
          _dirty = true;
        });
      }
    } else {
      setState(() {
        _category = selected;
        _dirty = true;
      });
    }
  }

  Future<String?> _askText({required String title, required String label}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Zrušit'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Přidat'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- uložení

  Recipe _build() {
    final now = DateTime.now().toUtc();
    final base =
        _original ??
        Recipe(
          id: _recipeId,
          title: '',
          createdAt: now,
          updatedAt: now,
          ownerId: ref.read(sessionProvider).userId,
        );
    final source = _source.text.trim();
    return base.copyWith(
      title: _title.text.trim(),
      description: _description.text.trim(),
      category: _category,
      servings: parseQuantity(_servings.text) ?? 4,
      householdId: _shared || _autoShare ? _householdFor(base) : null,
      visibility: (_shared || _autoShare) && _householdFor(base) != null
          ? RecipeVisibility.household
          : RecipeVisibility.private,
      yieldUnit: _yieldUnit,
      prepMinutes: int.tryParse(_prep.text.trim()) ?? 0,
      cookMinutes: int.tryParse(_cook.text.trim()) ?? 0,
      restMinutes: int.tryParse(_rest.text.trim()) ?? 0,
      totalMinutes: int.tryParse(_total.text.trim()) ?? 0,
      temperatures: _temperatures,
      equipment: _equipment,
      tags: _tags,
      notes: _notes.text.trim(),
      rating: _rating,
      photos: _photos,
      sourceUrl: source.isEmpty ? null : source,
      ingredients: [
        for (final draft in _ingredients)
          if (draft.name.text.trim().isNotEmpty)
            Ingredient(
              id: draft.id,
              name: draft.name.text.trim(),
              quantity: parseQuantity(draft.quantity.text),
              unit: draft.unit.text.trim(),
              note: draft.note,
            ),
      ],
      steps: [
        for (final draft in _steps)
          if (draft.instruction.text.trim().isNotEmpty)
            RecipeStep(
              id: draft.id,
              instruction: draft.instruction.text.trim(),
              durationMinutes: int.tryParse(draft.minutes.text.trim()),
              temperatureC: parseQuantity(draft.temperature.text),
              kind: draft.kind,
              parallel: draft.parallel,
            ),
      ],
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) {
      showMessage(context, 'Zkontrolujte označená pole.');
      return;
    }
    setState(() => _saving = true);
    try {
      final repository = await ref.read(recipeRepositoryProvider.future);
      final recipe = _build();
      if (_isNew) {
        await repository.create(recipe);
      } else {
        await repository.update(
          recipe,
          changeSummary: _changeSummary.text.trim(),
        );
      }
      if (!mounted) return;
      _dirty = false;
      showMessage(context, _isNew ? 'Recept uložen.' : 'Změny uloženy.');
      if (_isNew) {
        context.pushReplacement(Routes.recipe(recipe.id));
      } else {
        context.pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showMessage(context, 'Uložení se nepodařilo: $error');
      }
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await confirm(
      context,
      title: 'Zahodit změny?',
      message: 'Neuložené úpravy receptu se ztratí.',
      confirmLabel: 'Zahodit',
      destructive: true,
    );
    if (discard && mounted) {
      setState(() => _dirty = false);
      // Po překreslení už PopScope odchod povolí.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final title = _isNew ? 'Nový recept' : 'Upravit recept';
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ErrorState(error: _loadError!),
      );
    }

    final theme = Theme.of(context);
    final pieces = _yieldUnit == YieldUnit.pieces;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('Uložit'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Form(
          key: _formKey,
          onChanged: _markDirty,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              _photoStrip(),
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Název receptu *'),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Recept potřebuje název.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Krátký popis'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _chooseCategory,
                borderRadius: BorderRadius.circular(14),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Kategorie',
                    suffixIcon: Icon(Icons.expand_more_rounded),
                  ),
                  isEmpty: _category.isEmpty,
                  child: _category.isEmpty ? null : Text(_category),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _servings,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: pieces ? 'Počet kusů' : 'Počet porcí',
                      ),
                      validator: (value) {
                        final parsed = parseQuantity(value ?? '');
                        return parsed == null || parsed <= 0
                            ? 'Zadejte číslo.'
                            : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: YieldUnit.servings,
                          label: Text('Porce'),
                        ),
                        ButtonSegment(
                          value: YieldUnit.pieces,
                          label: Text('Kusy'),
                        ),
                      ],
                      selected: {_yieldUnit},
                      onSelectionChanged: (selection) => setState(() {
                        _yieldUnit = selection.first;
                        _dirty = true;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _minutesField(_prep, 'Aktivně (min)')),
                  const SizedBox(width: 10),
                  Expanded(child: _minutesField(_cook, 'Vaření (min)')),
                  const SizedBox(width: 10),
                  Expanded(child: _minutesField(_rest, 'Čekání (min)')),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  'Aktivně = práce u linky. Vaření = pečení, dušení, smažení. '
                  'Čekání = kynutí, marinování, chlazení, odpočinek.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Nápověda se přepočítává průběžně při psaní časů i kroků.
              ListenableBuilder(
                listenable: Listenable.merge([
                  _prep,
                  _cook,
                  _rest,
                  for (final step in _steps) ...[
                    step.instruction,
                    step.minutes,
                  ],
                ]),
                builder: (context, _) {
                  final auto = _build().copyWith(totalMinutes: 0).timeBreakdown;
                  return _minutesField(
                    _total,
                    'Celkový čas ručně (min)',
                    helper: auto.total > 0
                        ? 'Nevyplněno = spočítá se ${formatMinutes(auto.total)}'
                              '${auto.passive > 0 ? ' (z toho čekání ${formatMinutes(auto.passive)})' : ''}'
                              ' z časů výše a z kroků postupu.'
                        : 'Nevyplněno = spočítá se z časů výše a z kroků postupu.',
                  );
                },
              ),

              if ((ref.watch(shareAllRecipesProvider).value ?? false) ||
                  ref.watch(householdProvider).value != null ||
                  _shared) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.group_outlined),
                  title: const Text('Sdílet s rodinou'),
                  subtitle: Text(
                    _autoShare
                        ? 'Sdílí se automaticky (Více → Rodina).'
                        : 'Recept uvidí a budou moct upravit všichni '
                              'členové rodiny.',
                  ),
                  value: _shared || _autoShare,
                  onChanged: _autoShare
                      ? null
                      : (value) => setState(() {
                          _shared = value;
                          _dirty = true;
                        }),
                ),
                const SizedBox(height: 8),
              ],
              const SectionTitle('Suroviny'),
              for (var i = 0; i < _ingredients.length; i++) _ingredientRow(i),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final repository = await ref.read(
                      recipeRepositoryProvider.future,
                    );
                    setState(
                      () => _ingredients.add(
                        _IngredientDraft(repository.newId()),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Přidat surovinu'),
                ),
              ),

              const SectionTitle('Postup'),
              for (var i = 0; i < _steps.length; i++) _stepCard(i),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final repository = await ref.read(
                      recipeRepositoryProvider.future,
                    );
                    setState(() => _steps.add(_StepDraft(repository.newId())));
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Přidat krok'),
                ),
              ),

              const SectionTitle('Teploty'),
              _TagEditor(
                values: _temperatures,
                hint: 'např. Trouba 150 °C, sonda 68 °C',
                onChanged: (values) => setState(() {
                  _temperatures = values;
                  _dirty = true;
                }),
              ),

              const SectionTitle('Kuchyňské vybavení'),
              _TagEditor(
                values: _equipment,
                hint: 'např. Trouba, litinový hrnec',
                onChanged: (values) => setState(() {
                  _equipment = values;
                  _dirty = true;
                }),
              ),

              const SectionTitle('Štítky'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in suggestedTags)
                    FilterChip(
                      label: Text(tag),
                      selected: _tags.contains(tag),
                      onSelected: (on) => setState(() {
                        _tags = on
                            ? [..._tags, tag]
                            : [
                                for (final t in _tags)
                                  if (t != tag) t,
                              ];
                        _dirty = true;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _TagEditor(
                values: [
                  for (final t in _tags)
                    if (!suggestedTags.contains(t)) t,
                ],
                hint: 'vlastní štítek, např. Vánoce, Grilovačka',
                onChanged: (values) => setState(() {
                  _tags = [
                    for (final t in _tags)
                      if (suggestedTags.contains(t)) t,
                    ...values,
                  ];
                  _dirty = true;
                }),
              ),

              const SectionTitle('Hodnocení'),
              Align(
                alignment: Alignment.centerLeft,
                child: StarRating(
                  value: _rating,
                  size: 32,
                  onChanged: (value) => setState(() {
                    _rating = value;
                    _dirty = true;
                  }),
                ),
              ),

              const SectionTitle('Poznámky'),
              TextFormField(
                controller: _notes,
                textCapitalization: TextCapitalization.sentences,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  hintText: 'Tipy, zkušenosti, co příště udělat jinak…',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _source,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Zdroj (odkaz)',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
              ),
              if (!_isNew) ...[
                const SectionTitle('Historie úprav'),
                TextFormField(
                  controller: _changeSummary,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Co a proč se změnilo?',
                    helperText:
                        'Uloží se jako verze ${(_original?.currentVersion ?? 1) + 1}. '
                        'Předchozí verze zůstane zachována.',
                    helperMaxLines: 3,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              CopperButton(
                label: _isNew ? 'Uložit recept' : 'Uložit změny',
                icon: Icons.check_rounded,
                busy: _saving,
                onPressed: _save,
              ),
              if (_isNew) ...[
                const SizedBox(height: 10),
                Text(
                  '* povinné pole',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _minutesField(
    TextEditingController controller,
    String label, {
    String? helper,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
      ),
    );
  }

  /// Všechny recepty se sdílejí automaticky (nastavení v Rodině).
  bool get _autoShare =>
      ref.read(shareAllRecipesProvider).value == true &&
      ref.read(householdProvider).value != null;

  /// Rodina, se kterou se recept sdílí (stávající, jinak rodina uživatele).
  String? _householdFor(Recipe base) =>
      base.householdId ?? ref.read(householdProvider).value?.id;

  Widget _photoStrip() => PhotoListEditor(
    recipeId: _recipeId,
    photos: _photos,
    onChanged: (photos) => setState(() {
      _photos = photos;
      _dirty = true;
    }),
  );

  Widget _ingredientRow(int index) {
    final draft = _ingredients[index];
    return Padding(
      key: ValueKey(draft.id),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: TextFormField(
              controller: draft.quantity,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: 'Množ.',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 14,
                ),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                return text.isNotEmpty && parseQuantity(text) == null
                    ? 'Číslo'
                    : null;
              },
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 64,
            child: TextFormField(
              controller: draft.unit,
              textAlign: TextAlign.center,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'Jedn.',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextFormField(
              controller: draft.name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Surovina'),
            ),
          ),
          IconButton(
            tooltip: 'Odebrat surovinu',
            icon: const Icon(
              Icons.close_rounded,
              color: AppColors.textSecondary,
            ),
            onPressed: () => setState(() {
              _retired.add(_ingredients.removeAt(index).dispose);
              _dirty = true;
            }),
          ),
        ],
      ),
    );
  }

  Widget _stepCard(int index) {
    final draft = _steps[index];
    return Padding(
      key: ValueKey(draft.id),
      padding: const EdgeInsets.only(bottom: 10),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Text(
                  'Krok ${index + 1}',
                  style: const TextStyle(
                    color: AppColors.copperGold,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Posunout nahoru',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                  onPressed: index == 0
                      ? null
                      : () => setState(() {
                          _steps.insert(index - 1, _steps.removeAt(index));
                          _dirty = true;
                        }),
                ),
                IconButton(
                  tooltip: 'Posunout dolů',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_downward_rounded, size: 20),
                  onPressed: index == _steps.length - 1
                      ? null
                      : () => setState(() {
                          _steps.insert(index + 1, _steps.removeAt(index));
                          _dirty = true;
                        }),
                ),
                IconButton(
                  tooltip: 'Odebrat krok',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () => setState(() {
                    _retired.add(_steps.removeAt(index).dispose);
                    _dirty = true;
                  }),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                children: [
                  TextFormField(
                    controller: draft.instruction,
                    textCapitalization: TextCapitalization.sentences,
                    minLines: 2,
                    maxLines: 8,
                    decoration: const InputDecoration(hintText: 'Co udělat…'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: draft.minutes,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Čas (min)',
                            prefixIcon: Icon(Icons.timer_outlined, size: 20),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          controller: draft.temperature,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Teplota (°C)',
                            prefixIcon: Icon(
                              Icons.thermostat_rounded,
                              size: 20,
                            ),
                          ),
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            return text.isNotEmpty &&
                                    parseQuantity(text) == null
                                ? 'Zadejte číslo.'
                                : null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Druh času',
                            contentPadding: EdgeInsets.fromLTRB(12, 4, 8, 4),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: draft.kind,
                              isDense: true,
                              isExpanded: true,
                              items: [
                                DropdownMenuItem(
                                  value: StepKind.auto,
                                  child: Text(
                                    'Automaticky (${_kindName(inferKind(draft.instruction.text))})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const DropdownMenuItem(
                                  value: StepKind.active,
                                  child: Text('Aktivní příprava'),
                                ),
                                const DropdownMenuItem(
                                  value: StepKind.cook,
                                  child: Text('Vaření / pečení'),
                                ),
                                const DropdownMenuItem(
                                  value: StepKind.passive,
                                  child: Text('Čekání'),
                                ),
                              ],
                              onChanged: (value) => setState(() {
                                draft.kind = value ?? StepKind.auto;
                                _dirty = true;
                              }),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (index > 0)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Probíhá současně s předchozím krokem'),
                      subtitle: draft.parallel
                          ? const Text('Celkový čas neprodlužuje.')
                          : inferParallel(draft.instruction.text)
                          ? const Text(
                              'Rozpoznáno z textu („mezitím“, „zatímco“…).',
                            )
                          : null,
                      value:
                          draft.parallel ||
                          inferParallel(draft.instruction.text),
                      onChanged: inferParallel(draft.instruction.text)
                          ? null
                          : (value) => setState(() {
                              draft.parallel = value ?? false;
                              _dirty = true;
                            }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _kindName(String kind) => switch (kind) {
    StepKind.cook => 'vaření',
    StepKind.passive => 'čekání',
    _ => 'aktivní',
  };
}

/// Editor krátkých štítků (teploty, vybavení).
class _TagEditor extends StatefulWidget {
  const _TagEditor({
    required this.values,
    required this.hint,
    required this.onChanged,
  });

  final List<String> values;
  final String hint;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<_TagEditor> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    _controller.clear();
    if (widget.values.contains(value)) return;
    widget.onChanged([...widget.values, value]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.values.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in widget.values)
                  InputChip(
                    label: Text(value),
                    onDeleted: () => widget.onChanged([
                      for (final v in widget.values)
                        if (v != value) v,
                    ]),
                    deleteButtonTooltipMessage: 'Odebrat',
                  ),
              ],
            ),
          ),
        TextField(
          controller: _controller,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            hintText: widget.hint,
            suffixIcon: IconButton(
              tooltip: 'Přidat',
              icon: const Icon(Icons.add_rounded),
              onPressed: _add,
            ),
          ),
        ),
      ],
    );
  }
}

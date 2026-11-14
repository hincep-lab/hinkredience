import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';
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
  }) : instruction = TextEditingController(text: instruction),
       minutes = TextEditingController(text: minutes),
       temperature = TextEditingController(text: temperature);

  final String id;
  final TextEditingController instruction;
  final TextEditingController minutes;
  final TextEditingController temperature;

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
  final _total = TextEditingController();
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
        _total.text = recipe.totalMinutes > 0 ? '${recipe.totalMinutes}' : '';
        _notes.text = recipe.notes;
        _source.text = recipe.sourceUrl ?? '';
        _category = recipe.category;
        _rating = recipe.rating;
        _photos = [...recipe.photos];
        _temperatures = [...recipe.temperatures];
        _equipment = [...recipe.equipment];
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

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 85,
      );
      if (picked == null) return;
      final repository = await ref.read(recipeRepositoryProvider.future);
      final photo = await ref
          .read(photoStoreProvider)
          .import(
            recipeId: _recipeId,
            photoId: repository.newId(),
            sourcePath: picked.path,
          );
      if (!mounted) return;
      setState(() {
        _photos = [..._photos, photo];
        _dirty = true;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      showMessage(
        context,
        error.code.contains('denied')
            ? 'Aplikace nemá povolený přístup k fotkám. Povolte ho v nastavení telefonu.'
            : 'Fotku se nepodařilo přidat.',
      );
    } catch (_) {
      if (mounted) showMessage(context, 'Fotku se nepodařilo přidat.');
    }
  }

  void _choosePhotoSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Vybrat z galerie'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _addPhoto(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Vyfotit'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _addPhoto(ImageSource.camera);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

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
      prepMinutes: int.tryParse(_prep.text.trim()) ?? 0,
      cookMinutes: int.tryParse(_cook.text.trim()) ?? 0,
      totalMinutes: int.tryParse(_total.text.trim()) ?? 0,
      temperatures: _temperatures,
      equipment: _equipment,
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
    final autoTotal =
        (int.tryParse(_prep.text.trim()) ?? 0) +
        (int.tryParse(_cook.text.trim()) ?? 0);

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
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _servings,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Porce'),
                      validator: (value) {
                        final parsed = parseQuantity(value ?? '');
                        return parsed == null || parsed <= 0
                            ? 'Zadejte číslo.'
                            : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _minutesField(_prep, 'Příprava (min)')),
                  const SizedBox(width: 10),
                  Expanded(child: _minutesField(_cook, 'Vaření (min)')),
                ],
              ),
              const SizedBox(height: 12),
              _minutesField(
                _total,
                'Celkový čas (min)',
                helper: autoTotal > 0
                    ? 'Nevyplněno = příprava + vaření (${formatMinutes(autoTotal)})'
                    : 'Nevyplněno = příprava + vaření',
              ),

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
                    helperMaxLines: 2,
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
        helperMaxLines: 2,
      ),
    );
  }

  Widget _photoStrip() {
    return SizedBox(
      height: 120,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final photo in _photos)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 120,
                      height: 120,
                      child: RecipePhotoView(photo: photo),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton.filled(
                      tooltip: 'Odebrat fotku',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.background.withValues(
                          alpha: 0.7,
                        ),
                        foregroundColor: AppColors.text,
                        minimumSize: const Size(32, 32),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(() {
                        _photos = [
                          for (final p in _photos)
                            if (p.id != photo.id) p,
                        ];
                        _dirty = true;
                      }),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            width: 120,
            child: HkCard(
              onTap: _choosePhotoSource,
              padding: const EdgeInsets.all(8),
              radius: 16,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_a_photo_outlined,
                      color: AppColors.copperGold,
                      size: 30,
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Přidat fotku',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/personalization.dart';
import '../../core/screen_wake.dart';
import '../../core/recipe_time.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';
import '../kitchen/diary_screen.dart' show diaryDate;
import '../kitchen/add_to_shopping_sheet.dart';
import 'personal_cards.dart';
import '../cooking/actual_amount.dart';
import '../photos/photo_editor.dart';
import '../ai/ai_common.dart';
import '../ai/draft_review_screen.dart';

/// Podoba receptu pro export do souboru (bez cest k souborům v telefonu).
Map<String, dynamic> recipeExportJson(Recipe recipe) {
  final json = recipe.toJson()
    ..remove('owner_id')
    ..remove('household_id');
  json['photos'] = [for (final photo in recipe.photos) photo.toRemoteJson()];
  return {'format': 'hinkredience.recipe', 'format_version': 1, 'recipe': json};
}

/// Bezpečný název souboru z názvu receptu: „Svíčková na smetaně“ → „svickova-na-smetane“.
String exportFileName(String title) {
  final slug = foldForSearch(title)
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'recept' : slug;
}

class RecipeDetailScreen extends ConsumerStatefulWidget {
  const RecipeDetailScreen({super.key, required this.recipeId});

  final String recipeId;

  @override
  ConsumerState<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

enum _Tab { recipe, steps, notes }

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen> {
  _Tab _tab = _Tab.recipe;
  double? _servings;
  final _checked = <String>{};

  /// Odškrtnuté (hotové) kroky postupu – příprava na režim vaření.
  final _doneSteps = <String>{};
  int _photoIndex = 0;

  /// Zobrazit suroviny bez chilli (jen pohled, recept se nemění).
  bool _mild = false;

  Future<void> _saveMild(Recipe recipe) async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    final copy = await repository.duplicate(
      recipe.id,
      ownerId: ref.read(sessionProvider).userId,
      title: '${recipe.title} (bez chilli)',
      transform: withoutChilli,
    );
    if (!mounted || copy == null) return;
    showMessage(context, 'Uloženo jako „${copy.title}“.');
    context.push(Routes.recipe(copy.id));
  }

  Future<void> _toShopping(Recipe recipe) => showAddRecipeToShopping(
    context,
    recipe: recipe,
    servings: _servings ?? recipe.servings,
  );

  Future<void> _toPlan(Recipe recipe) async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Kdy uvaříte „${recipe.title}“?',
    );
    if (day == null || !mounted) return;
    final meal = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final type in MealType.all)
              ListTile(
                title: Text(MealType.label(type)),
                onTap: () => Navigator.of(context).pop(type),
              ),
          ],
        ),
      ),
    );
    if (meal == null) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveMeal(
      MealPlanEntry(
        id: docs.newId(),
        day: dayKey(day),
        mealType: meal,
        recipeId: recipe.id,
        title: recipe.title,
        servings: _servings ?? recipe.servings,
        updatedAt: docs.now(),
      ),
    );
    if (mounted) {
      showMessage(
        context,
        'Naplánováno: ${MealType.label(meal)} ${day.day}. ${day.month}.',
      );
    }
  }

  Future<void> _toggleFavorite(Recipe recipe) async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    await repository.setFavorite(recipe.id, !recipe.isFavorite);
  }

  /// Nechá AI navrhnout úpravu receptu. Návrh se jen zobrazí ke kontrole;
  /// uložením vznikne nová verze a původní recept zůstane v historii.
  Future<void> _improve(Recipe recipe, {required bool withWeb}) async {
    final service = ref.read(aiServiceProvider);
    if (service == null) {
      showMessage(context, 'AI kuchař potřebuje přihlášení k účtu.');
      return;
    }
    final instruction = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _ImproveDialog(withWeb: withWeb),
    );
    if (instruction == null || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  withWeb
                      ? 'Porovnávám recept s internetem…'
                      : 'Přemýšlím nad vylepšením…',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      final proposal = await service.improve(
        recipe,
        instruction: instruction,
        withWeb: withWeb,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      context.push(
        Routes.draft,
        extra: DraftReviewArgs(
          proposal: proposal,
          targetRecipeId: recipe.id,
          heading: withWeb ? 'Lepší postup' : 'Návrh vylepšení',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      showMessage(context, aiErrorText(error));
    }
  }

  Future<void> _share(Recipe recipe) async {
    await SharePlus.instance.share(
      ShareParams(text: recipe.toShareText(), subject: recipe.title),
    );
  }

  Future<void> _export(Recipe recipe) async {
    try {
      final json = const JsonEncoder.withIndent('  ')
          .convert(recipeExportJson(recipe));
      if (kIsWeb) {
        // Prohlížeč nemá dočasnou složku – soubor se rovnou stáhne.
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile.fromData(
                utf8.encode(json),
                mimeType: 'application/json',
                name: '${exportFileName(recipe.title)}.json',
              ),
            ],
            fileNameOverrides: ['${exportFileName(recipe.title)}.json'],
            subject: recipe.title,
          ),
        );
        return;
      }
      final directory = await getTemporaryDirectory();
      final file = File(
        p.join(directory.path, '${exportFileName(recipe.title)}.json'),
      );
      await file.writeAsString(json);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          subject: recipe.title,
        ),
      );
    } catch (error) {
      if (mounted) showMessage(context, 'Export se nepodařil: $error');
    }
  }

  Future<void> _duplicate(Recipe recipe) async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    final copy = await repository.duplicate(
      recipe.id,
      ownerId: ref.read(sessionProvider).userId,
    );
    if (!mounted || copy == null) return;
    showMessage(context, 'Kopie vytvořena.');
    context.pushReplacement(Routes.recipe(copy.id));
  }

  Future<void> _delete(Recipe recipe) async {
    final confirmed = await confirm(
      context,
      title: 'Přesunout do koše?',
      message:
          '„${recipe.title}“ se přesune do koše. Obnovit ho můžete v nabídce Více → Koš.',
      confirmLabel: 'Do koše',
      destructive: true,
    );
    if (!confirmed) return;
    final repository = await ref.read(recipeRepositoryProvider.future);
    await repository.softDelete(recipe.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    context.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Recept je v koši.'),
          action: SnackBarAction(
            label: 'Vrátit',
            onPressed: () => repository.restore(recipe.id),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(recipeProvider(widget.recipeId));
    // Při otevřeném receptu displej nezhasne (lze vypnout v nastavení).
    return KeepScreenOn(
      child: async.when(
        loading: () => Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (error, stack) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(error: error),
        ),
        data: (recipe) => recipe == null
            ? Scaffold(
                appBar: AppBar(),
                body: const EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'Recept nenalezen',
                  message: 'Tento recept v kuchařce není.',
                ),
              )
            : _content(context, recipe),
      ),
    );
  }

  Widget _content(BuildContext context, Recipe recipe) {
    final theme = Theme.of(context);
    final servings = _servings ?? recipe.servings;
    final aiEnabled = ref.watch(aiEnabledProvider);
    final shown = _mild ? withoutChilli(recipe) : recipe;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 300,
            backgroundColor: AppColors.background,
            leading: const _CircleBack(),
            actions: [
              _CircleAction(
                tooltip: recipe.isFavorite
                    ? 'Odebrat z oblíbených'
                    : 'Přidat mezi oblíbené',
                icon: recipe.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_outline_rounded,
                color: recipe.isFavorite ? AppColors.copperGold : null,
                onPressed: recipe.isDeleted
                    ? null
                    : () => _toggleFavorite(recipe),
              ),
              _CircleAction(
                tooltip: 'Sdílet',
                icon: Icons.ios_share_rounded,
                onPressed: () => _share(recipe),
              ),
              PopupMenuButton<String>(
                tooltip: 'Další možnosti',
                icon: const _CircleIcon(Icons.more_horiz_rounded),
                onSelected: (value) => switch (value) {
                  'edit' => context.push(Routes.editRecipe(recipe.id)),
                  'photos' => context.push(Routes.recipePhotos(recipe.id)),
                  'shopping' => _toShopping(recipe),
                  'plan' => _toPlan(recipe),
                  'diary' => context.push(Routes.diaryFor(recipe.id)),
                  'ai_improve' => _improve(recipe, withWeb: false),
                  'ai_web' => _improve(recipe, withWeb: true),
                  'ai_chat' => context.push(Routes.aiChat(recipeId: recipe.id)),
                  'ai_similar' => context.push(
                    Routes.webSearchWith(similarRecipeId: recipe.id),
                  ),
                  'duplicate' => _duplicate(recipe),
                  'export' => _export(recipe),
                  'delete' => _delete(recipe),
                  _ => null,
                },
                itemBuilder: (context) => [
                  if (!recipe.isDeleted)
                    const PopupMenuItem(value: 'edit', child: Text('Upravit')),
                  if (!recipe.isDeleted)
                    const PopupMenuItem(
                      value: 'photos',
                      child: Text('Fotografie'),
                    ),
                  if (!recipe.isDeleted)
                    const PopupMenuItem(
                      value: 'shopping',
                      child: Text('Přidat do nákupního seznamu'),
                    ),
                  if (!recipe.isDeleted)
                    const PopupMenuItem(
                      value: 'plan',
                      child: Text('Naplánovat'),
                    ),
                  const PopupMenuItem(
                    value: 'diary',
                    child: Text('Historie vaření'),
                  ),
                  if (!recipe.isDeleted && aiEnabled) ...const [
                    PopupMenuItem(
                      value: 'ai_improve',
                      child: Text('Vylepšit s AI'),
                    ),
                    PopupMenuItem(
                      value: 'ai_web',
                      child: Text('Najdi lepší postup'),
                    ),
                    PopupMenuItem(
                      value: 'ai_chat',
                      child: Text('Zeptat se AI kuchaře'),
                    ),
                    PopupMenuItem(
                      value: 'ai_similar',
                      child: Text('Najít podobné na internetu'),
                    ),
                    PopupMenuDivider(),
                  ],
                  const PopupMenuItem(
                    value: 'duplicate',
                    child: Text('Duplikovat'),
                  ),
                  const PopupMenuItem(
                    value: 'export',
                    child: Text('Exportovat do souboru'),
                  ),
                  if (!recipe.isDeleted)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Přesunout do koše',
                        style: TextStyle(color: AppColors.danger),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 4),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: _PhotoHeader(
                recipe: recipe,
                index: _photoIndex,
                onChanged: (index) => setState(() => _photoIndex = index),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
            sliver: SliverList.list(
              children: [
                Text(recipe.title, style: theme.textTheme.headlineMedium),
                if (recipe.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    recipe.description,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (recipe.rating != null)
                      _Meta(
                        icon: Icons.star_rounded,
                        text: formatQuantity(recipe.rating!),
                      ),
                    if (recipe.effectiveTotalMinutes > 0)
                      _Meta(
                        icon: Icons.schedule_rounded,
                        text: formatMinutes(recipe.effectiveTotalMinutes),
                      ),
                    if (recipe.category.isNotEmpty)
                      _Meta(
                        icon: Icons.local_dining_rounded,
                        text: recipe.category,
                      ),
                  ],
                ),
                if (!recipe.isDeleted) ...[
                  const SizedBox(height: 14),
                  CopperButton(
                    label: 'Vařit krok za krokem',
                    icon: Icons.restaurant_rounded,
                    onPressed: () => context.push(
                      Routes.cook(recipe.id, servings: _servings),
                    ),
                  ),
                  _CookedLine(recipe: recipe),
                ],
                _ConflictBanner(recipe: recipe),
                if (!recipe.isDeleted) ...[
                  DiaryReminderCard(recipeId: recipe.id),
                  ChilliCard(
                    recipe: recipe,
                    mild: _mild,
                    onMild: (value) => setState(() => _mild = value),
                    onSaveCopy: () => _saveMild(recipe),
                  ),
                ],
                if (recipe.isDeleted) ...[
                  const SizedBox(height: 12),
                  const HkCard(
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          color: AppColors.danger,
                        ),
                        SizedBox(width: 12),
                        Expanded(child: Text('Tento recept je v koši.')),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SegmentedButton<_Tab>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Tab.recipe, label: Text('Recept')),
                    ButtonSegment(value: _Tab.steps, label: Text('Postup')),
                    ButtonSegment(value: _Tab.notes, label: Text('Poznámky')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (value) =>
                      setState(() => _tab = value.first),
                  style: SegmentedButton.styleFrom(
                    backgroundColor: AppColors.backgroundSecondary,
                    foregroundColor: AppColors.text,
                    selectedBackgroundColor: AppColors.copper,
                    selectedForegroundColor: const Color(0xFF1B1108),
                    side: const BorderSide(color: AppColors.outline),
                  ),
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: switch (_tab) {
                      _Tab.recipe => _IngredientsTab(
                        recipe: shown,
                        servings: servings,
                        checked: _checked,
                        onServings: (value) =>
                            setState(() => _servings = value),
                        onToggle: (id) => setState(() {
                          if (!_checked.remove(id)) _checked.add(id);
                        }),
                        onShopping: () => _toShopping(shown),
                        onActual: (item) async {
                          final value = await askActualAmount(
                            context,
                            ingredient: item,
                            recipeServings: shown.servings,
                            currentServings: servings,
                          );
                          if (value != null && mounted) {
                            setState(() => _servings = value);
                          }
                        },
                      ),
                      _Tab.steps => _StepsTab(
                        recipe: recipe,
                        done: _doneSteps,
                        onToggle: (id) => setState(() {
                          if (!_doneSteps.remove(id)) _doneSteps.add(id);
                        }),
                      ),
                      _Tab.notes => _NotesTab(
                        recipe: recipe,
                        servings: servings,
                      ),
                    },
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

/// Kolikrát se recept vařil a jak dopadl naposledy (z deníku).
class _CookedLine extends ConsumerWidget {
  const _CookedLine({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(recipeDiaryProvider(recipe.id)).value ?? const [];
    if (history.isEmpty) return const SizedBox.shrink();
    final last = history.first;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () => context.push(Routes.diaryFor(recipe.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Vařeno ${history.length}× · naposledy ${diaryDate(last.cookedAt)}'
            '${last.toImprove.isEmpty ? '' : ' · zlepšit: ${last.toImprove}'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

/// Upozornění na souběžnou úpravu (telefon i ChatGPT / druhý telefon).
class _ConflictBanner extends ConsumerWidget {
  const _ConflictBanner({required this.recipe});

  final Recipe recipe;

  Future<void> _resolve(
    BuildContext context,
    WidgetRef ref, {
    required bool keepLocal,
  }) async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    await repository.resolveConflict(recipe.id, keepLocal: keepLocal);
    if (!context.mounted) return;
    showMessage(
      context,
      keepLocal
          ? 'Ponechána vaše úprava. Druhá podoba je v historii verzí.'
          : 'Použita verze z jiného zařízení. Vaše úprava je v historii verzí.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflict = ref.watch(recipeConflictProvider(recipe.id)).value;
    if (conflict == null) return const SizedBox.shrink();
    final other = conflict.recipe;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: HkCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.call_split_rounded, color: AppColors.danger),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Recept byl změněn v telefonu i jinde',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Na serveru je jiná podoba (ChatGPT nebo druhý telefon)'
              '${other.title != recipe.title ? ': „${other.title}“' : ''}. '
              'Vyberte, kterou ponechat. Ta druhá se uloží do historie '
              'verzí, nic se neztratí.',
              style: const TextStyle(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _resolve(context, ref, keepLocal: true),
                  child: const Text('Ponechat moji úpravu'),
                ),
                OutlinedButton(
                  onPressed: () => _resolve(context, ref, keepLocal: false),
                  child: const Text('Použít verzi ze serveru'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleIcon extends StatelessWidget {
  const _CircleIcon(this.icon, {this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 21, color: color ?? AppColors.text),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: _CircleIcon(icon, color: color),
    );
  }
}

class _CircleBack extends StatelessWidget {
  const _CircleBack();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Zpět',
      onPressed: () => context.pop(),
      icon: const _CircleIcon(Icons.arrow_back_ios_new_rounded),
    );
  }
}

class _PhotoHeader extends StatelessWidget {
  const _PhotoHeader({
    required this.recipe,
    required this.index,
    required this.onChanged,
  });

  final Recipe recipe;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final photos = recipe.photos;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (photos.isEmpty)
          const PhotoPlaceholder()
        else
          PageView.builder(
            itemCount: photos.length,
            onPageChanged: onChanged,
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => openPhotoViewer(context, photos, initialIndex: i),
              child: Semantics(
                button: true,
                label: 'Zobrazit fotku přes celou obrazovku',
                child: RecipePhotoView(photo: photos[i]),
              ),
            ),
          ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99000000),
                  Colors.transparent,
                  Colors.transparent,
                  AppColors.background,
                ],
                stops: [0, 0.3, 0.62, 1],
              ),
            ),
          ),
        ),
        if (photos.length > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < photos.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == index ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == index
                          ? AppColors.copperGold
                          : AppColors.text.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: AppColors.copperGold),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 15)),
      ],
    );
  }
}

class _IngredientsTab extends StatelessWidget {
  const _IngredientsTab({
    required this.recipe,
    required this.servings,
    required this.checked,
    required this.onServings,
    required this.onToggle,
    required this.onShopping,
    required this.onActual,
  });

  final Recipe recipe;
  final double servings;
  final Set<String> checked;
  final ValueChanged<double> onServings;
  final ValueChanged<String> onToggle;
  final VoidCallback onShopping;

  /// Klepnutí na množství: „mám jí jinak“ → přepočet celého receptu.
  final ValueChanged<Ingredient> onActual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pieces = YieldUnit.normalize(recipe.yieldUnit) == YieldUnit.pieces;
    final scaled = (servings - recipe.servings).abs() > 1e-9;
    final time = recipe.timeBreakdown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Suroviny (${yieldLabel(servings, recipe.yieldUnit)})',
                style: theme.textTheme.titleMedium,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.copper),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: pieces ? 'Méně kusů' : 'Méně porcí',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove_rounded),
                    onPressed: servings > 1
                        ? () => onServings(servings - 1)
                        : null,
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 26),
                    child: Text(
                      formatQuantity(servings),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: pieces ? 'Více kusů' : 'Více porcí',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add_rounded),
                    onPressed: servings < 999
                        ? () => onServings(servings + 1)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (scaled)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Přepočítáno z ${yieldLabel(recipe.servings, recipe.yieldUnit)}. '
              'Množství jsou zaokrouhlená, aby šla odměřit.',
              style: const TextStyle(
                color: AppColors.copperGold,
                fontSize: 12.5,
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (recipe.ingredients.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Recept zatím nemá suroviny.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final item in recipe.ingredients)
          InkWell(
            onTap: () => onToggle(item.id),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Checkbox(
                    value: checked.contains(item.id),
                    onChanged: (_) => onToggle(item.id),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.nameLabel(
                            fromServings: recipe.servings,
                            toServings: servings,
                          ),
                          style: TextStyle(
                            fontSize: 15.5,
                            color: checked.contains(item.id)
                                ? AppColors.textSecondary
                                : AppColors.text,
                            decoration: checked.contains(item.id)
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (item.note.isNotEmpty)
                          Text(
                            item.noteLabel(
                              fromServings: recipe.servings,
                              toServings: servings,
                            ),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: item.quantity == null ? null : () => onActual(item),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Text(
                        item.amountLabel(
                          fromServings: recipe.servings,
                          toServings: servings,
                        ),
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationStyle: TextDecorationStyle.dotted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (recipe.ingredients.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text(
            'Nevážíte předem? Klepněte na množství a zadejte, kolik suroviny '
            'máte – zbytek se přepočítá.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Poměry surovin'),
              children: [RatioList(recipe: recipe)],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: onShopping,
            icon: const Icon(Icons.add_shopping_cart_rounded),
            label: const Text('Přidat do nákupního seznamu'),
          ),
        ],
        if (time.total > 0) ...[
          const SizedBox(height: 16),
          Text('Čas', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _TimeSummary(time: time),
        ],
        if (recipe.temperatures.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Teploty', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _Chips(values: recipe.temperatures, icon: Icons.thermostat_rounded),
        ],
        if (recipe.equipment.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Vybavení', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _Chips(values: recipe.equipment, icon: Icons.countertops_rounded),
        ],
      ],
    );
  }
}

/// Rozpad času receptu: aktivní příprava, vaření, čekání a skutečný celek.
class _TimeSummary extends StatelessWidget {
  const _TimeSummary({required this.time});

  final TimeBreakdown time;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (time.active > 0) ('Aktivní příprava', time.active),
      if (time.cook > 0) ('Vaření / pečení', time.cook),
      if (time.passive > 0) ('Čekání', time.passive),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (parts.isNotEmpty)
          Row(
            children: [
              for (final (index, part) in parts.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: _InfoBox(
                    label: part.$1,
                    value: formatMinutes(part.$2),
                  ),
                ),
              ],
            ],
          ),
        if (parts.isNotEmpty) const SizedBox(height: 8),
        HkCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          radius: 14,
          child: Row(
            children: [
              const Icon(Icons.schedule_rounded, color: AppColors.copperGold),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Celkem',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              Text(
                formatMinutes(time.total),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
        if (time.passive > 0 || time.overlap > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              [
                if (time.passive > 0)
                  'Čekání zahrnuje kynutí, marinování, chlazení a odpočinek.',
                if (time.overlap > 0)
                  'Souběžné kroky (${formatMinutes(time.overlap)}) se '
                      'nezapočítávají dvakrát.',
              ].join(' '),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return HkCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      radius: 14,
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({required this.values, required this.icon});

  final List<String> values;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          Chip(
            avatar: Icon(icon, size: 18, color: AppColors.copperGold),
            label: Text(value),
          ),
      ],
    );
  }
}

class _StepsTab extends StatelessWidget {
  const _StepsTab({
    required this.recipe,
    required this.done,
    required this.onToggle,
  });

  final Recipe recipe;
  final Set<String> done;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    if (recipe.steps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Recept zatím nemá popsaný postup.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'Klepnutím na krok ho odškrtnete jako hotový.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
        ),
        for (var i = 0; i < recipe.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HkCard(
              onTap: () => onToggle(recipe.steps[i].id),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: done.contains(recipe.steps[i].id)
                        ? 'Krok ${i + 1} hotový'
                        : 'Krok ${i + 1}',
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: done.contains(recipe.steps[i].id)
                            ? null
                            : AppColors.copperGradient,
                        color: done.contains(recipe.steps[i].id)
                            ? AppColors.backgroundSecondary
                            : null,
                        shape: BoxShape.circle,
                      ),
                      child: done.contains(recipe.steps[i].id)
                          ? const Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: AppColors.copperGold,
                            )
                          : Text(
                              '${i + 1}',
                              style: const TextStyle(
                                color: Color(0xFF1B1108),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recipe.steps[i].instruction,
                          style: TextStyle(
                            fontSize: 15.5,
                            height: 1.45,
                            color: done.contains(recipe.steps[i].id)
                                ? AppColors.textSecondary
                                : null,
                            decoration: done.contains(recipe.steps[i].id)
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (recipe.steps[i].temperatureC != null ||
                            recipe.steps[i].durationMinutes != null) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 14,
                            children: [
                              if (recipe.steps[i].temperatureC != null)
                                _Meta(
                                  icon: Icons.thermostat_rounded,
                                  text:
                                      '${formatQuantity(recipe.steps[i].temperatureC!)} °C',
                                ),
                              if (recipe.steps[i].durationMinutes != null)
                                _Meta(
                                  icon: Icons.timer_outlined,
                                  text: formatMinutes(
                                    recipe.steps[i].durationMinutes!,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NotesTab extends ConsumerWidget {
  const _NotesTab({required this.recipe, required this.servings});

  final Recipe recipe;

  /// Právě zvolená výtěžnost – rozsahy množství v poznámkách se jí přizpůsobí.
  final double servings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final versions = ref.watch(recipeVersionsProvider(recipe.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Hodnocení', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        StarRating(
          value: recipe.rating,
          size: 30,
          onChanged: recipe.isDeleted
              ? null
              : (value) async {
                  final repository = await ref.read(
                    recipeRepositoryProvider.future,
                  );
                  await repository.setRating(recipe.id, value);
                },
        ),
        const SizedBox(height: 16),
        Text('Poznámky', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          recipe.notes.isEmpty
              ? 'Zatím bez poznámek.'
              : scaleRangesInText(
                  recipe.notes,
                  scaleFactor(recipe.servings, servings),
                  requireUnit: true,
                ),
          style: TextStyle(
            height: 1.45,
            color: recipe.notes.isEmpty
                ? AppColors.textSecondary
                : AppColors.text,
          ),
        ),
        if (recipe.sourceUrl != null && recipe.sourceUrl!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Zdroj', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          SelectableText(
            recipe.sourceUrl!,
            style: const TextStyle(color: AppColors.copperGold),
          ),
        ],
        const SizedBox(height: 16),
        Text('Historie', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          [
            'Vytvořeno ${formatDate(recipe.createdAt)}',
            'Naposledy upraveno ${formatDate(recipe.updatedAt)}',
            if (recipe.lastCookedAt != null)
              'Naposledy vařeno ${formatDate(recipe.lastCookedAt!)}',
          ].join('\n'),
          style: const TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 10),
        versions.when(
          loading: () => const SizedBox.shrink(),
          error: (error, stack) => const SizedBox.shrink(),
          data: (list) => Column(
            children: [
              for (final version in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: HkCard(
                    radius: 14,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Verze ${version.versionNumber}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.copperGold,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            version.changeSummary.isEmpty
                                ? 'Úprava receptu'
                                : version.changeSummary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatDate(version.createdAt),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12.5,
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
    );
  }
}

/// Dotaz na upřesnění před návrhem vylepšení. Vrací text (i prázdný),
/// nebo `null` při zrušení.
class _ImproveDialog extends StatefulWidget {
  const _ImproveDialog({required this.withWeb});

  final bool withWeb;

  @override
  State<_ImproveDialog> createState() => _ImproveDialogState();
}

class _ImproveDialogState extends State<_ImproveDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.withWeb ? 'Najdi lepší postup' : 'Vylepšit s AI'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.withWeb
                ? 'AI porovná recept s recepty na internetu a navrhne '
                      'konkrétní změny. Původní recept zůstane zachován.'
                : 'AI navrhne úpravy podle vašeho vybavení a chutí. '
                      'Původní recept zůstane zachován.',
            style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Na co se zaměřit? (nepovinné)',
              hintText: 'např. šťavnatější maso, kratší příprava',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Navrhnout'),
        ),
      ],
    );
  }
}

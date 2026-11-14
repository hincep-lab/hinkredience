import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';

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
  int _photoIndex = 0;

  Future<void> _toggleFavorite(Recipe recipe) async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    await repository.setFavorite(recipe.id, !recipe.isFavorite);
  }

  Future<void> _share(Recipe recipe) async {
    await SharePlus.instance.share(
      ShareParams(text: recipe.toShareText(), subject: recipe.title),
    );
  }

  Future<void> _export(Recipe recipe) async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        p.join(directory.path, '${exportFileName(recipe.title)}.json'),
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(recipeExportJson(recipe)),
      );
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
    return async.when(
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
    );
  }

  Widget _content(BuildContext context, Recipe recipe) {
    final theme = Theme.of(context);
    final servings = _servings ?? recipe.servings;

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
                  'duplicate' => _duplicate(recipe),
                  'export' => _export(recipe),
                  'delete' => _delete(recipe),
                  _ => null,
                },
                itemBuilder: (context) => [
                  if (!recipe.isDeleted)
                    const PopupMenuItem(value: 'edit', child: Text('Upravit')),
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
                        recipe: recipe,
                        servings: servings,
                        checked: _checked,
                        onServings: (value) =>
                            setState(() => _servings = value),
                        onToggle: (id) => setState(() {
                          if (!_checked.remove(id)) _checked.add(id);
                        }),
                      ),
                      _Tab.steps => _StepsTab(recipe: recipe),
                      _Tab.notes => _NotesTab(recipe: recipe),
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
            itemBuilder: (context, i) => RecipePhotoView(photo: photos[i]),
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
  });

  final Recipe recipe;
  final double servings;
  final Set<String> checked;
  final ValueChanged<double> onServings;
  final ValueChanged<String> onToggle;

  String _servingsLabel(double value) {
    final text = formatQuantity(value);
    if (value == 1) return '$text porce';
    return value > 1 && value < 5 && value == value.roundToDouble()
        ? '$text porce'
        : '$text porcí';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Suroviny (${_servingsLabel(servings)})',
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
                    tooltip: 'Méně porcí',
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
                    tooltip: 'Více porcí',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add_rounded),
                    onPressed: servings < 99
                        ? () => onServings(servings + 1)
                        : null,
                  ),
                ],
              ),
            ),
          ],
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
                          item.name,
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
                            item.note,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    item.amountLabel(
                      fromServings: recipe.servings,
                      toServings: servings,
                    ),
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (recipe.prepMinutes > 0 ||
            recipe.cookMinutes > 0 ||
            recipe.effectiveTotalMinutes > 0) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              if (recipe.prepMinutes > 0)
                Expanded(
                  child: _InfoBox(
                    label: 'Příprava',
                    value: formatMinutes(recipe.prepMinutes),
                  ),
                ),
              if (recipe.prepMinutes > 0) const SizedBox(width: 8),
              if (recipe.cookMinutes > 0)
                Expanded(
                  child: _InfoBox(
                    label: 'Vaření',
                    value: formatMinutes(recipe.cookMinutes),
                  ),
                ),
              if (recipe.cookMinutes > 0) const SizedBox(width: 8),
              Expanded(
                child: _InfoBox(
                  label: 'Celkem',
                  value: formatMinutes(recipe.effectiveTotalMinutes),
                ),
              ),
            ],
          ),
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
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
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
  const _StepsTab({required this.recipe});

  final Recipe recipe;

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
      children: [
        for (var i = 0; i < recipe.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HkCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      gradient: AppColors.copperGradient,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        color: Color(0xFF1B1108),
                        fontWeight: FontWeight.w800,
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
                          style: const TextStyle(fontSize: 15.5, height: 1.45),
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
  const _NotesTab({required this.recipe});

  final Recipe recipe;

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
          recipe.notes.isEmpty ? 'Zatím bez poznámek.' : recipe.notes,
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

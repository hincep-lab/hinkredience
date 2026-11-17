import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/app_update.dart';
import '../../core/material.dart';
import '../../core/personalization.dart';
import '../../core/recipe_groups.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';
import '../sync/sync_status.dart';
import 'home_widgets.dart';

/// Doporučené recepty bez deníku a chutí (oblíbené a hodnocení napřed).
List<Recipe> recommendRecipes(List<Recipe> recipes, {int limit = 6}) => [
  for (final r in recommend(recipes: recipes, limit: limit)) r.recipe,
];

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  var _filters = const RecipeFilters();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _setFilters(RecipeFilters filters) => setState(() => _filters = filters);

  void _clearFilters() {
    _search.clear();
    FocusScope.of(context).unfocus();
    _setFilters(const RecipeFilters());
  }

  void _focusSearch() {
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    _searchFocus.requestFocus();
  }

  void _togglePrep(PrepMethod p) {
    final next = {..._filters.prep};
    if (!next.remove(p)) next.add(p);
    _setFilters(_filters.copyWith(prep: next));
  }

  void _toggleTime(TimeFilter t) =>
      _setFilters(_filters.copyWith(time: _filters.time == t ? null : t));

  void _toggleOccasion(String o) {
    final next = {..._filters.occasions};
    if (!next.remove(o)) next.add(o);
    _setFilters(_filters.copyWith(occasions: next));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final recipesAsync = ref.watch(recipesProvider);
    final recipes = [
      for (final r in recipesAsync.value ?? const <Recipe>[])
        if (!r.isDeleted) r,
    ];
    final favorites = [
      for (final r in recipes)
        if (r.isFavorite) r,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final open = ref.watch(openSessionProvider).value;
    final wishCount = (ref.watch(wishesProvider).value ?? const [])
        .where((w) => !w.isPlanned)
        .length;
    final aiBadge = ref.watch(aiEnabledProvider) ? null : 'Vypnuto';
    final results = _filters.isEmpty ? null : _filters.apply(recipes);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          key: const Key('home-scroll'),
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _Header(
              onMenu: () => context.push(Routes.more),
              onSearch: _focusSearch,
              onAlerts: () => context.push(Routes.family),
              alertDot: wishCount > 0,
            ),
            _Hero(
              name: settings.greetingName,
              search: _search,
              focus: _searchFocus,
              onChanged: (value) =>
                  _setFilters(_filters.copyWith(query: value)),
              onClear: () {
                _search.clear();
                _setFilters(_filters.copyWith(query: ''));
              },
            ),
            const SizedBox(height: 14),
            _PrepRow(selected: _filters.prep, onToggle: _togglePrep),
            const SizedBox(height: 14),
            _TimeOccasionRow(
              time: _filters.time,
              occasions: _filters.occasions,
              onTime: _toggleTime,
              onOccasion: _toggleOccasion,
            ),
            if (results != null)
              ..._results(results)
            else ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const UpdateCard(),
                    if (open != null && open.recipeId != null)
                      _CookingNow(
                        title: open.recipeTitle,
                        onTap: () => context.push(Routes.cook(open.recipeId!)),
                      ),
                  ],
                ),
              ),
              HomeSectionHeader(
                icon: Icons.grid_view_rounded,
                title: 'Kategorie receptů',
                actionLabel: 'Zobrazit všechny',
                onAction: () => context.go(Routes.recipes),
              ),
              if (recipesAsync.isLoading && recipes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (recipes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _FirstRecipeCard(
                    onTap: () => context.push(Routes.newRecipe),
                  ),
                )
              else
                GroupGrid(
                  recipes: recipes,
                  onSelected: (group) =>
                      context.go(Routes.recipesWith(group: group.id)),
                ),
              HomeSectionHeader(
                icon: Icons.local_fire_department_rounded,
                title: 'Oblíbené recepty',
                actionLabel: 'Zobrazit všechny',
                onAction: () => context.go(Routes.favorites),
              ),
              FavoritesStrip(recipes: favorites),
              if (recipes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _Recommended(
                    items: recommend(
                      recipes: recipes,
                      diary: ref.watch(diaryProvider).value ?? const [],
                      profile: ref.watch(tasteProfileProvider),
                    ),
                  ),
                ),
              const HomeSectionHeader(
                icon: Icons.apps_rounded,
                title: 'Další funkce',
              ),
              SizedBox(
                height: 116,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final tile in [
                      _FeatureTile(
                        icon: Icons.auto_awesome_rounded,
                        title: 'AI kuchař',
                        badge: aiBadge,
                        subtitle: 'Poradí, upraví, vymyslí',
                        onTap: () => context.push(Routes.ai),
                      ),
                      _FeatureTile(
                        icon: Icons.travel_explore_rounded,
                        title: 'Hledat recepty',
                        badge: aiBadge,
                        subtitle: 'Na internetu, se zdroji',
                        onTap: () => context.push(Routes.webSearch),
                      ),
                      _FeatureTile(
                        icon: Icons.add_rounded,
                        title: 'Nový recept',
                        subtitle: 'Napsat vlastní',
                        onTap: () => context.push(Routes.newRecipe),
                      ),
                      _FeatureTile(
                        icon: Icons.download_rounded,
                        title: 'Import receptu',
                        subtitle: 'Text, odkaz, video, fotka',
                        onTap: () => context.push(Routes.importRecipe),
                      ),
                      _FeatureTile(
                        icon: Icons.local_offer_outlined,
                        title: 'Recepty z akcí',
                        subtitle: 'Levně v Sušici',
                        onTap: () => context.push(Routes.saleRecipes),
                      ),
                      _FeatureTile(
                        icon: Icons.kitchen_outlined,
                        title: 'Co mám doma',
                        subtitle: 'Recepty z toho, co máte',
                        onTap: () => context.push(Routes.pantry),
                      ),
                      _FeatureTile(
                        icon: Icons.thermostat_rounded,
                        title: 'Teploty',
                        subtitle: 'Jádro, sous-vide',
                        onTap: () => context.push(Routes.temperatures),
                      ),
                      _FeatureTile(
                        icon: Icons.edit_note_rounded,
                        title: 'Kuchařský deník',
                        subtitle: 'Časy, fotky, zlepšení',
                        onTap: () => context.push(Routes.diary),
                      ),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: SizedBox(width: 150, child: tile),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _results(List<Recipe> results) => [
    HomeSectionHeader(
      icon: Icons.manage_search_rounded,
      title: 'Nalezeno: ${receptyCount(results.length)}',
      actionLabel: 'Zrušit',
      onAction: _clearFilters,
    ),
    if (results.isEmpty)
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text(
          'Tomuto výběru neodpovídá žádný recept. Recepty bez uvedeného času '
          'se do časových filtrů nezapočítávají a příležitost se bere jen ze '
          'štítků receptu.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      )
    else
      RecipeResultsGrid(recipes: results),
  ];
}

class _Header extends StatelessWidget {
  const _Header({
    required this.onMenu,
    required this.onSearch,
    required this.onAlerts,
    required this.alertDot,
  });

  final VoidCallback onMenu;
  final VoidCallback onSearch;
  final VoidCallback onAlerts;
  final bool alertDot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF232325))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Nabídka',
            onPressed: onMenu,
            icon: const Icon(Icons.menu_rounded, size: 30),
          ),
          const SizedBox(width: 2),
          Image.asset('assets/images/chef_hat.png', width: 42, height: 42),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'HINKredience°',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                Text(
                  'Moje kuchařka',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          _RoundButton(
            tooltip: 'Hledat',
            icon: Icons.search_rounded,
            onTap: onSearch,
          ),
          const SizedBox(width: 8),
          _RoundButton(
            tooltip: 'Upozornění a rodina',
            icon: Icons.notifications_none_rounded,
            onTap: onAlerts,
            dot: alertDot,
          ),
          const SizedBox(width: 8),
          const DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFF2A2F3A),
              shape: BoxShape.circle,
            ),
            child: SyncStatusButton(),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.dot = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFF26262A),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, size: 26, color: Colors.white),
                if (dot)
                  Positioned(
                    top: 10,
                    right: 11,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: AppColors.copper,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.name,
    required this.search,
    required this.focus,
    required this.onChanged,
    required this.onClear,
  });

  final String name;
  final TextEditingController search;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 196,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            bottom: 26,
            width: MediaQuery.sizeOf(context).width * 0.72,
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                stops: [0, 0.35],
                colors: [Color(0x00000000), Color(0xFF000000)],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: Image.asset(
                'assets/images/hero.jpg',
                fit: BoxFit.cover,
                alignment: Alignment.centerRight,
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            top: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Ahoj $name 👋',
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 31,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 12, color: Colors.black)],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Co dobrého dnes uvaříme?',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 10, color: Colors.black)],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 0,
            child: ValueListenableBuilder(
              valueListenable: search,
              builder: (context, value, _) => TextField(
                controller: search,
                focusNode: focus,
                textInputAction: TextInputAction.search,
                onChanged: onChanged,
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Hledat recept, surovinu nebo štítek…',
                  hintStyle: const TextStyle(color: Color(0xFFB0B0B4)),
                  filled: true,
                  fillColor: const Color(0xE61E1E21),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(left: 14, right: 8),
                    child: Icon(Icons.search_rounded, size: 28),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 50),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Vymazat hledání',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: onClear,
                        ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: const BorderSide(
                      color: Color(0xFF6A6A6E),
                      width: 1.3,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: const BorderSide(
                      color: AppColors.copper,
                      width: 1.6,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrepRow extends StatelessWidget {
  const _PrepRow({required this.selected, required this.onToggle});

  final Set<PrepMethod> selected;
  final ValueChanged<PrepMethod> onToggle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: PrepMethod.values.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final p = PrepMethod.values[index];
          return FilterPill(
            icon: p.icon,
            label: p.label,
            selected: selected.contains(p),
            onTap: () => onToggle(p),
          );
        },
      ),
    );
  }
}

class _TimeOccasionRow extends StatelessWidget {
  const _TimeOccasionRow({
    required this.time,
    required this.occasions,
    required this.onTime,
    required this.onOccasion,
  });

  final TimeFilter? time;
  final Set<String> occasions;
  final ValueChanged<TimeFilter> onTime;
  final ValueChanged<String> onOccasion;

  Widget _label(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 22, color: AppColors.copper),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 15.5, color: Colors.white)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(Icons.schedule_rounded, 'Podle času'),
                Row(
                  children: [
                    for (final t in TimeFilter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterPill(
                          label: t.label,
                          selected: time == t,
                          onTap: () => onTime(t),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: VerticalDivider(width: 1, color: Color(0xFF3A3A3C)),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(Icons.star_outline_rounded, 'Podle příležitosti'),
                Row(
                  children: [
                    for (final o in occasionTags)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterPill(
                          label: o,
                          selected: occasions.contains(o),
                          onTap: () => onOccasion(o),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CookingNow extends StatelessWidget {
  const _CookingNow({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HkCard(
        onTap: onTap,
        child: Row(
          children: [
            const Icon(
              Icons.local_fire_department_rounded,
              color: AppColors.copperGold,
              size: 30,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Rozvařeno',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const Text(
              'Pokračovat',
              style: TextStyle(color: AppColors.copperGold),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Štítek v rohu („Brzy“, „Vypnuto“); dlaždice se štítkem je ztlumená.
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return HkCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Stack(
        children: [
          Opacity(
            opacity: badge != null ? 0.55 : 1,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: AppColors.copperGold, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                    color: AppColors.copperGold,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FirstRecipeCard extends StatelessWidget {
  const _FirstRecipeCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HkCard(
      onTap: onTap,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              gradient: AppColors.copperGradient,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.add_rounded,
              color: Color(0xFF1B1108),
              size: 30,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Přidej první recept',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                const Text(
                  'Kuchařka je zatím prázdná. Začni tím, co umíš nejlíp.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Recommended extends StatelessWidget {
  const _Recommended({required this.items});

  final List<Recommendation> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Doporučujeme dnes'),
        SizedBox(
          height: 214,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final recipe = items[index].recipe;
              final reason = items[index].reasons.firstOrNull;
              return SizedBox(
                width: 168,
                child: HkCard(
                  padding: EdgeInsets.zero,
                  onTap: () => context.push(Routes.recipe(recipe.id)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(17),
                          ),
                          child: RecipeCover(recipe: recipe),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              recipe.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            if (reason != null)
                              Text(
                                reason,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.copperGold,
                                  fontSize: 12.5,
                                ),
                              )
                            else
                              RecipeMetaLine(recipe: recipe),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Karta chytré aktualizace: stahování na pozadí, „Nainstalovat“, nebo
/// u webové verze „Načíst novou verzi“. Bez nové verze se nezobrazí.
class UpdateCard extends ConsumerWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdaterProvider);
    final updater = ref.read(appUpdaterProvider.notifier);
    String mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} MB';
    final (
      String title,
      String detail,
      IconData icon,
      VoidCallback? onTap,
    ) = switch (update.phase) {
      UpdatePhase.none => ('', '', Icons.check, null),
      UpdatePhase.waitingForWifi => (
        'Nová verze ${update.build}',
        'Stáhne se sama na Wi-Fi'
            '${update.size > 0 ? ' (${mb(update.size)})' : ''}'
            ' · klepnutím stáhnete hned',
        Icons.wifi_rounded,
        updater.downloadNow,
      ),
      UpdatePhase.downloading => (
        'Stahuji novou verzi ${update.build}…',
        update.progress == null
            ? 'na pozadí, aplikaci můžete dál používat'
            : '${(update.progress! * 100).round()} % · na pozadí',
        Icons.downloading_rounded,
        null,
      ),
      UpdatePhase.ready => (
        'Nová verze ${update.build} je připravená',
        update.message.isNotEmpty
            ? update.message
            : 'Klepněte na Nainstalovat a potvrďte instalaci',
        Icons.system_update_rounded,
        updater.install,
      ),
      UpdatePhase.failed => (
        'Novou verzi se nepodařilo stáhnout',
        update.message,
        Icons.error_outline_rounded,
        updater.downloadNow,
      ),
      UpdatePhase.webReload => (
        'Je venku nová verze ${update.build}',
        'Načte se sama při dalším návratu do aplikace · klepnutím hned',
        Icons.refresh_rounded,
        updater.reloadNow,
      ),
    };
    if (update.phase == UpdatePhase.none) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: HkCard(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.copperGold, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        detail,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (update.phase == UpdatePhase.ready)
                  FilledButton(
                    onPressed: updater.install,
                    child: const Text('Nainstalovat'),
                  ),
              ],
            ),
            if (update.phase == UpdatePhase.downloading) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: update.progress),
            ],
          ],
        ),
      ),
    );
  }
}

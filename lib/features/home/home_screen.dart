import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';

/// Doporučené recepty pro hlavní obrazovku: oblíbené a nejlépe hodnocené
/// napřed, potom naposledy upravené. (Doporučení podle historie vaření
/// přibude s kuchařským deníkem.)
List<Recipe> recommendRecipes(List<Recipe> recipes, {int limit = 6}) {
  final sorted = [...recipes]
    ..sort((a, b) {
      final favorite = (b.isFavorite ? 1 : 0) - (a.isFavorite ? 1 : 0);
      if (favorite != 0) return favorite;
      final rating = (b.rating ?? 0).compareTo(a.rating ?? 0);
      if (rating != 0) return rating;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  return sorted.take(limit).toList();
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submitSearch(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    _search.clear();
    FocusScope.of(context).unfocus();
    context.go(Routes.recipesWith(query: query));
  }

  void _comingSoon(String title, String stage, String description) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Připravujeme – $stage',
                style: const TextStyle(color: AppColors.copperGold),
              ),
              const SizedBox(height: 12),
              Text(
                description,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final recipes = ref.watch(recipesProvider);
    final list = recipes.value ?? const <Recipe>[];
    final favorites = list.where((r) => r.isFavorite).length;
    final aiBadge = ref.watch(aiEnabledProvider) ? null : 'Vypnuto';

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              sliver: SliverList.list(
                children: [
                  const Row(
                    children: [
                      Expanded(child: Wordmark(fontSize: 26)),
                      _SyncIndicator(),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Ahoj ${settings.greetingName} 👋',
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Co dnes společně uvaříme?',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.copperGold,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _submitSearch,
                    decoration: InputDecoration(
                      hintText: 'Co dnes uvaříme?',
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: AppColors.textSecondary,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: const BorderSide(color: AppColors.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: const BorderSide(color: AppColors.outline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: const BorderSide(
                          color: AppColors.copperGold,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.45,
                children: [
                  _FeatureTile(
                    icon: Icons.menu_book_rounded,
                    title: 'Recepty',
                    subtitle: list.isEmpty
                        ? 'Moje sbírka'
                        : 'Moje sbírka · ${list.length}',
                    onTap: () => context.go(Routes.recipes),
                  ),
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
                    icon: Icons.download_rounded,
                    title: 'Import receptu',
                    badge: aiBadge,
                    subtitle: 'Text, odkaz, fotka',
                    onTap: () => context.push(Routes.importRecipe),
                  ),
                  _FeatureTile(
                    icon: Icons.calendar_month_rounded,
                    title: 'Plán vaření',
                    subtitle: 'Jídelníček na míru',
                    badge: 'Brzy',
                    onTap: () => _comingSoon(
                      'Plán vaření',
                      'Etapa 4',
                      'Týdenní kalendář snídaní, obědů a večeří sdílený '
                          's rodinou. Databáze je na něj už připravená.',
                    ),
                  ),
                  _FeatureTile(
                    icon: Icons.shopping_cart_outlined,
                    title: 'Nákupní seznam',
                    subtitle: 'Podle receptů',
                    badge: 'Brzy',
                    onTap: () => _comingSoon(
                      'Nákupní seznam',
                      'Etapa 4',
                      'Seznam se slučováním surovin z receptů a sdílením '
                          'v domácnosti. Databáze je na něj už připravená.',
                    ),
                  ),
                  _FeatureTile(
                    icon: Icons.favorite_outline_rounded,
                    title: 'Oblíbené',
                    subtitle: favorites == 0
                        ? 'Moje top recepty'
                        : 'Moje top recepty · $favorites',
                    onTap: () => context.go(Routes.favorites),
                  ),
                  _FeatureTile(
                    icon: Icons.edit_note_rounded,
                    title: 'Kuchařský deník',
                    subtitle: 'Tipy a úpravy',
                    badge: 'Brzy',
                    onTap: () => _comingSoon(
                      'Kuchařský deník',
                      'Etapa 4',
                      'Záznam každého vaření: skutečné časy a teploty, fotky, '
                          'co se povedlo a co zlepšit.',
                    ),
                  ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              sliver: SliverToBoxAdapter(
                child: recipes.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, stack) => ErrorState(error: error),
                  data: (data) => data.isEmpty
                      ? _FirstRecipeCard(
                          onTap: () => context.push(Routes.newRecipe),
                        )
                      : _Recommended(recipes: recommendRecipes(data)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final signedIn = ref.watch(sessionProvider).isSignedIn;

    final (IconData icon, String tooltip, Color color) = switch (sync) {
      _ when !signedIn => (
        Icons.phone_android_rounded,
        'Recepty jsou uložené jen v telefonu',
        AppColors.textSecondary,
      ),
      SyncState(running: true) => (
        Icons.sync_rounded,
        'Synchronizuji…',
        AppColors.copperGold,
      ),
      SyncState(lastError: final String _) => (
        Icons.cloud_off_rounded,
        'Synchronizace se nepodařila',
        AppColors.danger,
      ),
      SyncState(pending: > 0) => (
        Icons.cloud_upload_outlined,
        'Čeká na odeslání: ${sync.pending}',
        AppColors.copperGold,
      ),
      _ => (
        Icons.cloud_done_outlined,
        'Synchronizováno',
        AppColors.textSecondary,
      ),
    };

    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: color),
      onPressed: () => context.go(Routes.more),
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
  const _Recommended({required this.recipes});

  final List<Recipe> recipes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Doporučené recepty'),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: recipes.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final recipe = recipes[index];
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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/recipe.dart';
import 'app_colors.dart';
import 'app_theme.dart';
import 'formatters.dart';
import 'material.dart';

/// Nápis HINKredience° – „HINK“ stříbrně, „redience°“ měděně.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.fontSize = 24});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'HINKredience',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'HINK',
              style: TextStyle(
                color: const Color(0xFFE9E4DF),
                fontWeight: FontWeight.w800,
                fontSize: fontSize,
                letterSpacing: 0.5,
              ),
            ),
            TextSpan(
              text: 'redience°',
              style: TextStyle(
                color: AppColors.copperGold,
                fontWeight: FontWeight.w500,
                fontSize: fontSize,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        maxLines: 1,
      ),
    );
  }
}

/// Karta s měděným obrysem a jemným přechodem.
class HkCard extends StatelessWidget {
  const HkCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppTheme.radius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.cardGradient,
        borderRadius: borderRadius,
        border: Border.all(color: AppColors.outline),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          splashColor: AppColors.copper.withValues(alpha: 0.18),
          highlightColor: AppColors.copper.withValues(alpha: 0.08),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Hlavní tlačítko – měděný přechod, zaoblené, velké.
class CopperButton extends StatelessWidget {
  const CopperButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    const foreground = Color(0xFF1B1108);
    return Opacity(
      opacity: enabled || busy ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.copperGradient,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppColors.copper.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 54),
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: foreground,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, color: foreground, size: 22),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: foreground,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Jedna fotografie receptu – ze souboru v telefonu, jinak ze serveru.
class RecipePhotoView extends ConsumerWidget {
  const RecipePhotoView({
    super.key,
    required this.photo,
    this.fit = BoxFit.cover,
    this.thumbnail = false,
  });

  final RecipePhoto photo;
  final BoxFit fit;

  /// Malý náhled (seznamy, karty). Načte se rychleji a šetří paměť.
  final bool thumbnail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(photoStoreProvider);
    final file =
        (thumbnail ? store.thumbnailFile(photo) : null) ??
        store.localFile(photo);
    if (file != null) {
      return Image.file(
        file,
        fit: fit,
        // Velkou fotku v seznamu dekódujeme zmenšenou – rychlejší posouvání.
        cacheWidth: thumbnail ? 600 : null,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => const PhotoPlaceholder(),
      );
    }
    // Fotka zatím není v telefonu (stáhne se při synchronizaci) – načteme
    // ji ze serveru přes dočasnou podepsanou adresu.
    final remotePath = thumbnail
        ? (photo.thumbPath ?? photo.remotePath)
        : photo.remotePath;
    if (remotePath == null) return const PhotoPlaceholder();
    final url = ref.watch(signedPhotoUrlProvider(remotePath));
    return url.when(
      data: (value) => value == null
          ? const PhotoPlaceholder()
          : Image.network(
              value,
              fit: fit,
              cacheWidth: thumbnail ? 600 : null,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => const PhotoPlaceholder(),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const PhotoPlaceholder(loading: true),
            ),
      error: (error, stack) => const PhotoPlaceholder(),
      loading: () => const PhotoPlaceholder(loading: true),
    );
  }
}

/// Zástupná plocha pro recept bez fotografie.
class PhotoPlaceholder extends StatelessWidget {
  const PhotoPlaceholder({super.key, this.loading = false, this.icon});

  final bool loading;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.9,
          colors: [Color(0xFF3A2A1E), Color(0xFF15110F)],
        ),
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : LayoutBuilder(
                builder: (context, constraints) => Icon(
                  icon ?? Icons.restaurant_rounded,
                  color: AppColors.copper.withValues(alpha: 0.7),
                  size: (constraints.biggest.shortestSide * 0.36).clamp(
                    18.0,
                    72.0,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Titulní fotografie receptu (první v pořadí) nebo zástupná plocha.
class RecipeCover extends StatelessWidget {
  const RecipeCover({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    if (recipe.photos.isEmpty) return const PhotoPlaceholder();
    // První fotka je hlavní.
    return RecipePhotoView(photo: recipe.photos.first, thumbnail: true);
  }
}

/// Řádek s údaji o receptu: hodnocení, kategorie, celkový čas.
class RecipeMetaLine extends StatelessWidget {
  const RecipeMetaLine({super.key, required this.recipe, this.fontSize = 12.5});

  final Recipe recipe;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final rating = recipe.rating;
    final rest = [
      if (recipe.category.isNotEmpty) recipe.category,
      if (recipe.effectiveTotalMinutes > 0)
        formatMinutes(recipe.effectiveTotalMinutes),
    ].join(' · ');
    if (rating == null && rest.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(color: AppColors.copperGold, fontSize: fontSize);
    return Row(
      children: [
        if (rating != null) ...[
          Icon(
            Icons.star_rounded,
            size: fontSize + 3,
            color: AppColors.copperGold,
          ),
          const SizedBox(width: 2),
          Text(
            rest.isEmpty
                ? formatQuantity(rating)
                : '${formatQuantity(rating)} · ',
            style: style,
          ),
        ],
        Flexible(
          child: Text(
            rest,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// Hodnocení hvězdičkami 1–5. S [onChanged] je interaktivní;
/// opětovné klepnutí na stejnou hvězdu hodnocení zruší.
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    this.onChanged,
    this.size = 22,
  });

  final double? value;
  final ValueChanged<double?>? onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final current = value ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var star = 1; star <= 5; star++)
          Semantics(
            button: onChanged != null,
            label: '$star z 5 hvězd',
            child: InkResponse(
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(current == star ? null : star.toDouble()),
              radius: size,
              child: Padding(
                padding: EdgeInsets.all(onChanged == null ? 0 : 6),
                child: Icon(
                  current >= star
                      ? Icons.star_rounded
                      : current >= star - 0.5
                      ? Icons.star_half_rounded
                      : Icons.star_outline_rounded,
                  color: AppColors.copperGold,
                  size: size,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Prázdný stav se vysvětlením a volitelnou akcí.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.copper),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: 260,
                child: CopperButton(
                  label: actionLabel!,
                  icon: Icons.add_rounded,
                  onPressed: onAction,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Chybový stav s možností zkusit znovu.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 48,
              color: AppColors.danger,
            ),
            const SizedBox(height: 12),
            Text(
              'Něco se nepovedlo',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Zkusit znovu'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Nadpis oddílu.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Potvrzovací dialog. Vrací `true` po potvrzení.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Zrušit'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? TextButton.styleFrom(foregroundColor: AppColors.danger)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

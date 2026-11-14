import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';

/// Česká zpráva k chybě z AI.
String aiErrorText(Object error) =>
    error is AiException ? error.message : 'Něco se nepovedlo: $error';

/// Otevře zdrojovou stránku v prohlížeči.
Future<void> openSource(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  var opened = false;
  if (uri != null) {
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      opened = false;
    }
  }
  if (!opened && context.mounted) {
    showMessage(context, 'Odkaz se nepodařilo otevřít: $url');
  }
}

/// Vybere fotografii a vrátí ji zmenšenou jako base64 (JPEG) pro AI.
/// Vrací `null`, když uživatel výběr zrušil.
Future<String?> pickPhotoForAi(BuildContext context, ImageSource source) async {
  try {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1400,
      maxHeight: 1400,
      imageQuality: 72,
    );
    if (picked == null) return null;
    final bytes = await File(picked.path).readAsBytes();
    return base64Encode(bytes);
  } on PlatformException catch (error) {
    if (context.mounted) {
      showMessage(
        context,
        'Fotografii se nepodařilo načíst: ${error.message ?? error.code}',
      );
    }
    return null;
  }
}

/// Nabídne fotoaparát nebo galerii a vrátí fotografii pro AI.
Future<String?> choosePhotoForAi(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Vyfotit'),
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Vybrat z galerie'),
            onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  return pickPhotoForAi(context, source);
}

/// Obsah obrazovky, když AI nejde použít (bez účtu nebo bez připojení).
class AiUnavailable extends ConsumerWidget {
  const AiUnavailable({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasBackend = ref.watch(appConfigProvider).hasSupabase;
    return EmptyState(
      icon: Icons.auto_awesome_rounded,
      title: 'AI kuchař potřebuje účet',
      message: hasBackend
          ? 'AI běží na serveru, aby v telefonu nebyl žádný tajný klíč. '
                'Přihlaste se a můžete začít.'
          : 'AI běží na serveru. Nejdřív nastavte připojení k Supabase '
                'v nabídce Více a přihlaste se.',
      actionLabel: hasBackend ? 'Přihlásit se' : 'Otevřít nastavení',
      onAction: () => context.go(hasBackend ? Routes.auth : Routes.more),
    );
  }
}

/// Chybová karta s možností zkusit akci znovu.
class AiErrorCard extends StatelessWidget {
  const AiErrorCard({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final problem = error;
    final setup =
        problem is AiException &&
        (problem.notConfigured || problem.notDeployed);
    return HkCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                setup ? Icons.build_circle_outlined : Icons.error_outline,
                color: setup ? AppColors.copperGold : AppColors.danger,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  setup ? 'AI ještě není nastavená' : 'Nepovedlo se',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            aiErrorText(error),
            style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRetry,
                child: const Text('Zkusit znovu'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Seznam zdrojů jako klepnutelné odkazy.
class SourceLinks extends StatelessWidget {
  const SourceLinks({super.key, required this.sources, this.title = 'Zdroje'});

  final List<AiSource> sources;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        for (final source in sources)
          InkWell(
            onTap: () => openSource(context, source.url),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  const Icon(
                    Icons.open_in_new_rounded,
                    size: 15,
                    color: AppColors.copperGold,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      source.title.isEmpty
                          ? source.host
                          : '${source.title} · ${source.host}',
                      maxLines: 2,
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
    );
  }
}

/// Průběh dlouhé akce s popisem, co se děje.
class AiProgress extends StatelessWidget {
  const AiProgress({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

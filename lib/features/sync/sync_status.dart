import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';

/// Popis stavu synchronizace pro uživatele.
({IconData icon, String label, Color color}) syncPhaseLook(
  SyncPhase phase,
  SyncState state,
) => switch (phase) {
  SyncPhase.localOnly => (
    icon: Icons.phone_android_rounded,
    label: 'Jen v telefonu',
    color: AppColors.textSecondary,
  ),
  SyncPhase.syncing => (
    icon: Icons.sync_rounded,
    label: 'Synchronizuji…',
    color: AppColors.copperGold,
  ),
  SyncPhase.synced => (
    icon: Icons.cloud_done_outlined,
    label: 'Synchronizováno',
    color: AppColors.textSecondary,
  ),
  SyncPhase.pending => (
    icon: Icons.cloud_upload_outlined,
    label: 'Čeká na synchronizaci (${state.pending})',
    color: AppColors.copperGold,
  ),
  SyncPhase.offline => (
    icon: Icons.cloud_off_rounded,
    label: 'Offline',
    color: AppColors.textSecondary,
  ),
  SyncPhase.error => (
    icon: Icons.error_outline_rounded,
    label: 'Chyba synchronizace',
    color: AppColors.danger,
  ),
  SyncPhase.conflict => (
    icon: Icons.call_split_rounded,
    label: 'Recept změněn na dvou místech',
    color: AppColors.danger,
  ),
};

String _time(DateTime time) {
  final local = time.toLocal();
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.day}. ${local.month}. v ${local.hour}:$minute';
}

/// Nenápadná ikona stavu synchronizace; po klepnutí ukáže podrobnosti.
class SyncStatusButton extends ConsumerWidget {
  const SyncStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(syncProvider);
    final phase = state.phaseFor(enabled: ref.watch(syncEnabledProvider));
    final look = syncPhaseLook(phase, state);
    return IconButton(
      tooltip: look.label,
      icon: Icon(look.icon, color: look.color),
      onPressed: () => showSyncDetails(context),
    );
  }
}

/// Spodní panel s podrobnostmi synchronizace a tlačítkem pro opakování.
Future<void> showSyncDetails(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const SafeArea(child: _SyncDetails()),
    );

class _SyncDetails extends ConsumerWidget {
  const _SyncDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(syncProvider);
    final enabled = ref.watch(syncEnabledProvider);
    final phase = state.phaseFor(enabled: enabled);
    final look = syncPhaseLook(phase, state);
    final recipes = ref.watch(allRecipesProvider).value ?? const [];

    final lines = <String>[
      if (phase == SyncPhase.localOnly)
        ref.watch(supabaseClientProvider) == null
            ? 'Připojení k Supabase není nastavené. Recepty jsou uložené jen v tomto telefonu.'
            : 'Pro synchronizaci se přihlaste. Do té doby jsou recepty jen v tomto telefonu.',
      if (phase == SyncPhase.offline) 'Telefon je bez internetu. Recepty i stažené fotky fungují dál, změny se odešlou samy po připojení.',
      if (enabled && state.lastSuccess != null)
        'Naposledy synchronizováno ${_time(state.lastSuccess!)}.',
      if (enabled && state.pending > 0)
        'Čeká na odeslání: ${state.pending} ${state.pending == 1 ? 'recept' : 'receptů'}.',
      if (enabled && state.nextRetry != null && !state.running)
        'Další pokus proběhne sám v ${_time(state.nextRetry!).split(' v ').last}.',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(look.icon, color: look.color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(look.label, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                line,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          if (state.conflicts > 0) ...[
            const SizedBox(height: 6),
            const Text(
              'Tyto recepty byly upraveny v telefonu i jinde (ChatGPT, druhý '
              'telefon). Otevřete je a vyberte, kterou podobu ponechat – '
              'druhá zůstane v historii verzí.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            _ConflictList(recipes: [for (final r in recipes) (r.id, r.title)]),
          ],
          if (state.errors.isNotEmpty && phase != SyncPhase.offline) ...[
            const SizedBox(height: 6),
            Text('Podrobnosti', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: SelectableText(
                  state.errors.join('\n\n'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
          if (enabled) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: state.running
                  ? null
                  : () => ref.read(syncProvider.notifier).syncNow(),
              icon: const Icon(Icons.sync_rounded),
              label: Text(
                state.errors.isEmpty ? 'Synchronizovat nyní' : 'Zkusit znovu',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConflictList extends ConsumerWidget {
  const _ConflictList({required this.recipes});

  final List<(String, String)> recipes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicted = [
      for (final (id, title) in recipes)
        if (ref.watch(recipeConflictProvider(id)).value != null) (id, title),
    ];
    return Column(
      children: [
        for (final (id, title) in conflicted)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.call_split_rounded,
              color: AppColors.danger,
            ),
            title: Text(title),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).pop();
              context.push(Routes.recipe(id));
            },
          ),
      ],
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/quick_timers.dart';
import '../../core/widgets.dart';
import '../sync/sync_status.dart';

const _buildNumber = String.fromEnvironment('BUILD_NUMBER');

/// Verze aplikace včetně čísla sestavení z GitHub Actions, je-li známé.
const appVersionLabel = _buildNumber == ''
    ? 'Verze 1.5.0 · Etapa 4'
    : 'Verze 1.5.0 · sestavení $_buildNumber · Etapa 4';

/// Záložka „Více“: účet, synchronizace, koš, nastavení.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  String _time(DateTime time) {
    final local = time.toLocal();
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day}. ${local.month}. v ${local.hour}:$minute';
  }

  Future<void> _editGreeting(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(
      text: ref.read(settingsProvider).greetingName,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Oslovení'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Jak vás má aplikace oslovovat?',
            helperText: 'Zobrazí se jako „Ahoj …“',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Zrušit'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(settingsProvider.notifier).setGreetingName(name);
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final pending = ref.read(syncProvider).pending;
    final confirmed = await confirm(
      context,
      title: 'Odhlásit se?',
      message: pending > 0
          ? 'Pozor: $pending receptů ještě není odesláno na server. '
                'Zůstanou v telefonu a odešlou se po příštím přihlášení.'
          : 'Recepty zůstanou uložené na serveru i v tomto telefonu.',
      confirmLabel: 'Odhlásit',
    );
    if (!confirmed) return;
    try {
      await ref.read(sessionProvider.notifier).signOut();
      await ref.read(settingsProvider.notifier).setSkipAuth(false);
      if (context.mounted) context.go(Routes.auth);
    } catch (error) {
      if (context.mounted) {
        showMessage(context, 'Odhlášení se nepodařilo: $error');
      }
    }
  }

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final result = await ref.read(syncProvider.notifier).syncNow();
    if (!context.mounted || result == null) return;
    showMessage(
      context,
      result.ok
          ? 'Hotovo. Staženo ${result.pulled}, odesláno ${result.pushed}.'
          : result.errors.first,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(settingsProvider);
    final sync = ref.watch(syncProvider);
    final hasBackend = ref.watch(supabaseClientProvider) != null;
    final trashCount = ref.watch(trashProvider).value?.length ?? 0;

    final phase = sync.phaseFor(enabled: ref.watch(syncEnabledProvider));
    final look = syncPhaseLook(phase, sync);
    final String syncText;
    if (!hasBackend) {
      syncText = 'Vypnuto – připojení k Supabase není nastavené.';
    } else if (!session.isSignedIn) {
      syncText = 'Vypnuto – přihlaste se.';
    } else if (phase == SyncPhase.synced && sync.lastSuccess != null) {
      syncText = 'Synchronizováno ${_time(sync.lastSuccess!)} · automaticky';
    } else {
      syncText = '${look.label} · podrobnosti';
    }

    final running = ref.watch(quickTimersProvider).length;
    Widget arrow() => const Icon(Icons.chevron_right_rounded);
    const divider = Divider(indent: 16, endIndent: 16);

    return Scaffold(
      appBar: AppBar(title: const Text('Nabídka')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // ---------------------------------------------- profil a stav
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AppColors.backgroundSecondary,
                    child: Icon(
                      Icons.person_rounded,
                      color: AppColors.copperGold,
                    ),
                  ),
                  title: Text(
                    'Ahoj ${settings.greetingName}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    session.isSignedIn
                        ? session.email ?? 'Přihlášený uživatel'
                        : hasBackend
                        ? 'Nepřihlášeno'
                        : 'Bez účtu',
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () => _editGreeting(context, ref),
                ),
                divider,
                ListTile(
                  leading: Icon(look.icon, color: look.color),
                  title: const Text('Synchronizace'),
                  subtitle: Text(syncText),
                  trailing: arrow(),
                  onTap: () => showSyncDetails(context),
                ),
                if (!session.isSignedIn && hasBackend) ...[
                  divider,
                  ListTile(
                    leading: const Icon(Icons.login_rounded),
                    title: const Text('Přihlásit se'),
                    subtitle: const Text(
                      'Zapne zálohu a synchronizaci mezi zařízeními',
                    ),
                    trailing: arrow(),
                    onTap: () => context.go(Routes.auth),
                  ),
                ],
              ],
            ),
          ),

          // ---------------------------------------------- nástroje
          const SectionTitle('Do kuchyně'),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.05,
            children: [
              _MenuTile(
                icon: Icons.timer_outlined,
                label: 'Minutka',
                badge: running > 0 ? '$running' : null,
                onTap: () => context.push(Routes.timer),
              ),
              _MenuTile(
                icon: Icons.kitchen_outlined,
                label: 'Co mám doma',
                onTap: () => context.push(Routes.pantry),
              ),
              _MenuTile(
                icon: Icons.local_offer_outlined,
                label: 'Recepty z akcí',
                onTap: () => context.push(Routes.saleRecipes),
              ),
              _MenuTile(
                icon: Icons.calendar_month_rounded,
                label: 'Plán vaření',
                onTap: () => context.push(Routes.plan),
              ),
              _MenuTile(
                icon: Icons.thermostat_rounded,
                label: 'Teploty',
                onTap: () => context.push(Routes.temperatures),
              ),
              _MenuTile(
                icon: Icons.scale_outlined,
                label: 'Převody',
                onTap: () => context.push(Routes.converter),
              ),
              _MenuTile(
                icon: Icons.edit_note_rounded,
                label: 'Deník',
                onTap: () => context.push(Routes.diary),
              ),
            ],
          ),

          // ---------------------------------------------- rodina a AI
          const SectionTitle('Rodina a ChatGPT'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.group_outlined),
                  title: const Text('Rodina'),
                  subtitle: const Text(
                    'Společné recepty, plán vaření a nákupní seznam',
                  ),
                  trailing: arrow(),
                  onTap: () => context.push(Routes.family),
                ),
                divider,
                ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('Propojení s ChatGPT'),
                  subtitle: const Text(
                    'Recepty z ChatGPT rovnou do kuchařky, bez placeného API',
                  ),
                  trailing: arrow(),
                  onTap: () => context.push(Routes.chatGpt),
                ),
              ],
            ),
          ),

          // ---------------------------------------------- nastavení
          const SectionTitle('Nastavení'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.restaurant_menu_rounded),
                  title: const Text('Kuchyně a chutě'),
                  subtitle: const Text(
                    'Vybavení a preference pro ChatGPT a AI kuchaře',
                  ),
                  trailing: arrow(),
                  onTap: () => context.push(Routes.kitchen),
                ),
                divider,
                SwitchListTile(
                  secondary: const Icon(Icons.light_mode_outlined),
                  title: const Text('Nevypínat obrazovku při vaření'),
                  subtitle: const Text(
                    'Při otevřeném receptu displej nezhasne. Mimo recept se '
                    'telefon uspává normálně.',
                  ),
                  value: settings.keepScreenOn,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setKeepScreenOn(value),
                ),
                divider,
                SwitchListTile(
                  secondary: const Icon(Icons.auto_awesome_rounded),
                  title: const Text('AI funkce v aplikaci'),
                  subtitle: Text(
                    settings.aiEnabled
                        ? 'Zapnuto – AI kuchař, hledání a import. '
                              'Každý požadavek se platí přes OpenAI API.'
                        : 'Vypnuto – aplikace neodesílá žádné placené '
                              'požadavky na AI.',
                  ),
                  value: settings.aiEnabled,
                  onChanged: (value) =>
                      ref.read(settingsProvider.notifier).setAiEnabled(value),
                ),
              ],
            ),
          ),

          // ---------------------------------------------- účet a data
          const SectionTitle('Účet a data'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                if (hasBackend && session.isSignedIn) ...[
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('Synchronizovat nyní'),
                    enabled: !sync.running,
                    onTap: () => _syncNow(context, ref),
                  ),
                  divider,
                ],
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Koš'),
                  subtitle: Text(
                    trashCount == 0
                        ? 'Prázdný'
                        : 'Smazané recepty k obnovení: $trashCount',
                  ),
                  trailing: arrow(),
                  onTap: () => context.push(Routes.trash),
                ),
                divider,
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Připojení k Supabase'),
                  subtitle: Text(hasBackend ? 'Nastaveno' : 'Nenastaveno'),
                  trailing: arrow(),
                  onTap: () => context.push(Routes.connection),
                ),
                if (session.isSignedIn) ...[
                  divider,
                  ListTile(
                    leading: const Icon(Icons.logout_rounded),
                    title: const Text('Odhlásit se'),
                    onTap: () => _signOut(context, ref),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 28),
          const Center(child: Wordmark(fontSize: 20)),
          const SizedBox(height: 4),
          Text(
            'Dvě hlavy. Jedna dokonalá chuť.\n$appVersionLabel\n© Pavel Hink',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// Dlaždice nástroje v menu Více.
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Číslo v rohu (např. počet běžících minutek).
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return HkCard(
      onTap: onTap,
      padding: const EdgeInsets.all(8),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: AppColors.copperGold, size: 30),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (badge != null)
            Positioned(
              top: 0,
              right: 0,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: AppColors.copper,
                child: Text(
                  badge!,
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

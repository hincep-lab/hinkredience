import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/material.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('Více')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const SectionTitle('Účet'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                if (session.isSignedIn) ...[
                  ListTile(
                    leading: const Icon(Icons.account_circle_outlined),
                    title: Text(session.email ?? 'Přihlášený uživatel'),
                    subtitle: const Text('Přihlášeno'),
                  ),
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.logout_rounded),
                    title: const Text('Odhlásit se'),
                    onTap: () => _signOut(context, ref),
                  ),
                ] else if (hasBackend)
                  ListTile(
                    leading: const Icon(Icons.login_rounded),
                    title: const Text('Přihlásit se'),
                    subtitle: const Text(
                      'Zapne zálohu a synchronizaci mezi zařízeními',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.go(Routes.auth),
                  )
                else
                  const ListTile(
                    leading: Icon(Icons.phone_android_rounded),
                    title: Text('Bez účtu'),
                    subtitle: Text('Recepty jsou uložené jen v tomto telefonu'),
                  ),
              ],
            ),
          ),

          const SectionTitle('Synchronizace'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(look.icon, color: look.color),
                  title: const Text('Stav'),
                  subtitle: Text(syncText),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showSyncDetails(context),
                ),
                if (hasBackend && session.isSignedIn) ...[
                  const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('Synchronizovat nyní'),
                    enabled: !sync.running,
                    onTap: () => _syncNow(context, ref),
                  ),
                ],
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Připojení k Supabase'),
                  subtitle: Text(hasBackend ? 'Nastaveno' : 'Nenastaveno'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.connection),
                ),
              ],
            ),
          ),

          const SectionTitle('ChatGPT a AI'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('Propojení s ChatGPT'),
                  subtitle: const Text(
                    'Recepty z ChatGPT rovnou do kuchařky, bez placeného API',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.chatGpt),
                ),
                const Divider(indent: 16, endIndent: 16),
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

          const SectionTitle('Nastavení'),
          HkCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SwitchListTile(
              secondary: const Icon(Icons.light_mode_outlined),
              title: const Text('Nevypínat obrazovku při vaření'),
              subtitle: const Text(
                'Při otevřeném receptu displej nezhasne. Mimo recept se '
                'telefon uspává normálně.',
              ),
              value: settings.keepScreenOn,
              onChanged: (value) =>
                  ref.read(settingsProvider.notifier).setKeepScreenOn(value),
            ),
          ),

          const SectionTitle('Kuchařka'),
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
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.family),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.edit_note_rounded),
                  title: const Text('Kuchařský deník'),
                  subtitle: const Text('Historie vaření, výsledky, fotky'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.diary),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.waving_hand_outlined),
                  title: const Text('Oslovení'),
                  subtitle: Text('Ahoj ${settings.greetingName}'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _editGreeting(context, ref),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.kitchen_outlined),
                  title: const Text('Kuchyně a chutě'),
                  subtitle: const Text(
                    'Vybavení a preference pro ChatGPT a AI kuchaře',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.kitchen),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Koš'),
                  subtitle: Text(
                    trashCount == 0
                        ? 'Prázdný'
                        : 'Smazané recepty k obnovení: $trashCount',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.trash),
                ),
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

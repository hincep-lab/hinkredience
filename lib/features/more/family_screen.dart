import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/web_push.dart';
import '../../core/widgets.dart';

/// Rodinné účty: společná kuchařka, plán vaření a nákupní seznam.
class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: 'Hinkovi');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Založit rodinu'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Název'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Založit'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(householdStoreProvider)!.create(name);
      ref.invalidate(householdProvider);
    } catch (error) {
      if (context.mounted)
        showMessage(context, 'Rodinu se nepodařilo založit: $error');
    }
  }

  Future<void> _addMember(
    BuildContext context,
    WidgetRef ref,
    Household house,
  ) async {
    final controller = TextEditingController();
    final email = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Přidat člena'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Zadejte e-mail, se kterým se člen rodiny přihlašuje do '
              'HINKredience. Musí už mít účet.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-mail'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Přidat'),
          ),
        ],
      ),
    );
    if (email == null || !email.contains('@')) return;
    try {
      final name = await ref
          .read(householdStoreProvider)!
          .addMember(house.id, email);
      ref.invalidate(householdProvider);
      if (context.mounted) showMessage(context, 'Do rodiny přibyl(a) $name.');
    } catch (error) {
      if (context.mounted) {
        showMessage(context, '$error'.replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _leave(
    BuildContext context,
    WidgetRef ref,
    Household house,
  ) async {
    final ok = await confirm(
      context,
      title: 'Opustit rodinu?',
      message:
          'Přestanete vidět rodinné recepty, společný plán a nákup. Vaše '
          'vlastní recepty a deník zůstanou.',
      confirmLabel: 'Opustit',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(householdStoreProvider)!.leave(house.id);
    ref.invalidate(householdProvider);
    ref.read(syncProvider.notifier).syncNow();
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    Household house,
    HouseholdMember m,
  ) async {
    final ok = await confirm(
      context,
      title: 'Odebrat člena?',
      message: '${m.name} přestane vidět rodinné recepty, plán a nákup.',
      confirmLabel: 'Odebrat',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(householdStoreProvider)!.removeMember(house.id, m.userId);
    ref.invalidate(householdProvider);
  }

  Future<void> _setAutoShare(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    try {
      final count = await ref
          .read(householdStoreProvider)!
          .setShareAllRecipes(enabled);
      ref.invalidate(shareAllRecipesProvider);
      await ref.read(syncProvider.notifier).syncNow();
      if (!context.mounted) return;
      showMessage(
        context,
        enabled
            ? 'Recepty se teď sdílejí automaticky. Nově nasdíleno: $count.'
            : 'Nové recepty už se nesdílejí automaticky. Dosud sdílené '
                  'zůstávají sdílené.',
      );
    } catch (error) {
      if (context.mounted) showMessage(context, '$error');
    }
  }

  Future<void> _shareAllNow(BuildContext context, WidgetRef ref) async {
    try {
      final count = await ref
          .read(householdStoreProvider)!
          .shareAllRecipesNow();
      await ref.read(syncProvider.notifier).syncNow();
      if (!context.mounted) return;
      showMessage(
        context,
        count == 0
            ? 'Všechny vaše recepty už rodina vidí.'
            : 'Rodině nasdíleno receptů: $count.',
      );
    } catch (error) {
      if (context.mounted) showMessage(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(householdStoreProvider);
    final async = ref.watch(householdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Rodina')),
      body: store == null
          ? const EmptyState(
              icon: Icons.group_outlined,
              title: 'Rodina potřebuje účet',
              message:
                  'Přihlaste se (Více → Účet). Rodina se sdílí přes server.',
            )
          : async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => ErrorState(error: error),
              data: (house) => ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  const Text(
                    'V rodině sdílíte recepty označené „Sdílet s rodinou“ '
                    '(nebo všechny, když zapnete automatické sdílení), plán '
                    'vaření a nákupní seznam. Soukromé recepty, kuchařský deník '
                    'a chutě si každý nechává pro sebe.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (house == null)
                    CopperButton(
                      label: 'Založit rodinu',
                      icon: Icons.group_add_outlined,
                      onPressed: () => _create(context, ref),
                    )
                  else ...[
                    SectionTitle(house.name),
                    HkCard(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          for (final m in house.members)
                            ListTile(
                              leading: Icon(
                                m.isOwner
                                    ? Icons.star_rounded
                                    : Icons.person_outline_rounded,
                              ),
                              title: Text(m.isMe ? '${m.name} (vy)' : m.name),
                              subtitle: Text(m.isOwner ? 'Zakladatel' : 'Člen'),
                              trailing: house.amOwner && !m.isMe
                                  ? IconButton(
                                      tooltip: 'Odebrat',
                                      icon: const Icon(
                                        Icons.person_remove_outlined,
                                      ),
                                      onPressed: () =>
                                          _remove(context, ref, house, m),
                                    )
                                  : null,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SectionTitle('Moje recepty'),
                    HkCard(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            secondary: const Icon(Icons.group_outlined),
                            title: const Text(
                              'Automaticky sdílet všechny moje recepty',
                            ),
                            subtitle: const Text(
                              'Každý váš recept – i nový nebo z ChatGPT – '
                              'uvidí a upraví celá rodina.',
                            ),
                            value:
                                ref.watch(shareAllRecipesProvider).value ??
                                false,
                            onChanged: (value) =>
                                _setAutoShare(context, ref, value),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: () => _shareAllNow(context, ref),
                            icon: const Icon(Icons.share_outlined),
                            label: const Text('Sdílet všechny recepty teď'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SectionTitle('Oznámení'),
                    if (kIsWeb)
                      const _WebPushTile()
                    else
                      const _FamilyNotificationsTile(),
                    const SizedBox(height: 12),
                    if (house.amOwner)
                      FilledButton.icon(
                        onPressed: () => _addMember(context, ref, house),
                        icon: const Icon(Icons.person_add_alt_rounded),
                        label: const Text('Přidat člena e-mailem'),
                      ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => _leave(context, ref, house),
                      icon: const Icon(
                        Icons.logout_rounded,
                        color: AppColors.danger,
                      ),
                      label: const Text(
                        'Opustit rodinu',
                        style: TextStyle(color: AppColors.danger),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

/// Vypínač oznámení „někdo z rodiny něco chce“.
class _FamilyNotificationsTile extends ConsumerStatefulWidget {
  const _FamilyNotificationsTile();

  @override
  ConsumerState<_FamilyNotificationsTile> createState() =>
      _FamilyNotificationsTileState();
}

class _FamilyNotificationsTileState
    extends ConsumerState<_FamilyNotificationsTile> {
  late bool _on =
      ref.read(sharedPreferencesProvider).getBool(familyNotificationsKey) ??
      true;

  Future<void> _set(bool value) async {
    setState(() => _on = value);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(familyNotificationsKey, value);
    if (value) {
      await prefs.setBool('family_notifications_asked', true);
      final allowed = await ref.read(familyAlertsProvider).requestPermission();
      if (!allowed && mounted) {
        showMessage(
          context,
          'Oznámení jsou v telefonu zakázaná. Povolte je v Nastavení '
          'telefonu → Aplikace → HINKredience → Oznámení.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return HkCard(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.notifications_active_outlined),
        title: const Text('Dát vědět, když někdo něco chce'),
        subtitle: const Text(
          'Oznámení, když někdo z rodiny přidá přání „mám chuť na…“ '
          'nebo něco na nákupní seznam.',
        ),
        value: _on,
        onChanged: _set,
      ),
    );
  }
}

/// Web a aplikace z plochy iPhonu: oznámení i do zavřené aplikace.
class _WebPushTile extends ConsumerStatefulWidget {
  const _WebPushTile();

  @override
  ConsumerState<_WebPushTile> createState() => _WebPushTileState();
}

class _WebPushTileState extends ConsumerState<_WebPushTile> {
  bool? _on;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final endpoint = await webPushCurrent();
    if (mounted) {
      setState(
        () => _on = endpoint.isNotEmpty && webPushPermission() == 'granted',
      );
    }
  }

  Future<void> _set(bool value) async {
    final push = ref.read(pushServiceProvider);
    if (push == null) return;
    setState(() => _busy = true);
    try {
      if (value) {
        await push.enableThisDevice();
        if (mounted) {
          showMessage(context, 'Oznámení jsou zapnutá na tomto zařízení.');
        }
      } else {
        await push.disableThisDevice();
      }
      if (mounted) setState(() => _on = value);
    } catch (error) {
      if (mounted) {
        showMessage(
          context,
          webPushPermission() == 'denied'
              ? 'Oznámení jsou v prohlížeči zakázaná. Povolte je v nastavení '
                    'prohlížeče (u iPhonu: Nastavení → Oznámení → HINKredience°).'
              : 'Oznámení se nepodařilo zapnout: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    final push = ref.read(pushServiceProvider);
    if (push == null) return;
    setState(() => _busy = true);
    try {
      final sent = await push.test();
      if (mounted) {
        showMessage(
          context,
          sent == 0
              ? 'Žádné zařízení oznámení nepřijalo. Zkuste oznámení vypnout '
                    'a znovu zapnout.'
              : 'Odesláno – oznámení by mělo za chvilku přijít.',
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, 'Zkouška se nepodařila: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!webPushSupported()) {
      return const HkCard(
        padding: EdgeInsets.all(14),
        child: Text(
          'Tady oznámení nejdou. Na iPhonu otevřete HINKredience° z plochy '
          '(v Safari: Sdílet → Přidat na plochu) a zapněte je tam. Na '
          'Androidu a počítači fungují v Chromu.',
          style: TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
      );
    }
    return HkCard(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Dát vědět, když někdo něco chce'),
            subtitle: const Text(
              'Oznámení na tomto zařízení – i když je aplikace zavřená – '
              'když někdo z rodiny přidá přání nebo něco na nákup.',
            ),
            value: _on ?? false,
            onChanged: _busy || _on == null ? null : _set,
          ),
          if (_on == true)
            OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.notifications_outlined),
              label: const Text('Poslat zkušební oznámení'),
            ),
        ],
      ),
    );
  }
}

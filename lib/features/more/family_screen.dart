import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/kitchen_providers.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
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
                    'V rodině sdílíte recepty označené „Sdílet s rodinou“, plán '
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

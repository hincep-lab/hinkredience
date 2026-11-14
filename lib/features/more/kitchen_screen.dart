import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';
import '../ai/ai_common.dart';

/// Kuchyňské vybavení a chuťové preference. Jsou uložené na serveru
/// a AI kuchař z nich vychází při každém návrhu (dlouhodobá paměť).
class KitchenScreen extends ConsumerStatefulWidget {
  const KitchenScreen({super.key});

  @override
  ConsumerState<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends ConsumerState<KitchenScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(kitchenProvider);
    } catch (error) {
      if (mounted) showMessage(context, 'Změnu se nepodařilo uložit: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _ask(String title, String label, String hint) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Zrušit'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Přidat'),
          ),
        ],
      ),
    );
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _addEquipment() async {
    final store = ref.read(kitchenStoreProvider);
    final name = await _ask(
      'Nové vybavení',
      'Název zařízení nebo nádobí',
      'např. Litinový hrnec 5 l',
    );
    if (store == null || name == null) return;
    await _run(() => store.addEquipment(name));
  }

  Future<void> _addPreference() async {
    final store = ref.read(kitchenStoreProvider);
    final label = await _ask(
      'Nová preference',
      'Co má AI vědět o vaší chuti?',
      'např. Méně cukru v dezertech',
    );
    if (store == null || label == null) return;
    await _run(() => store.addPreference(label));
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(kitchenStoreProvider);
    final kitchen = ref.watch(kitchenProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Kuchyně a chutě')),
      body: store == null
          ? const AiUnavailable()
          : kitchen.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => ErrorState(
                error: error,
                onRetry: () => ref.invalidate(kitchenProvider),
              ),
              data: (data) => ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  const Text(
                    'Z těchto údajů vychází AI kuchař při každém návrhu. '
                    'Co tu není, o vás neví.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  if (data.equipment.isEmpty && data.preferences.isEmpty) ...[
                    const SizedBox(height: 16),
                    CopperButton(
                      label: 'Načíst výchozí profil Pavla Hinka',
                      icon: Icons.download_done_rounded,
                      busy: _busy,
                      onPressed: () => _run(store.seedDefaults),
                    ),
                  ],
                  SectionTitle(
                    'Vybavení (${data.equipment.length})',
                    trailing: IconButton(
                      tooltip: 'Přidat vybavení',
                      icon: const Icon(Icons.add_rounded),
                      onPressed: _busy ? null : _addEquipment,
                    ),
                  ),
                  if (data.equipment.isEmpty)
                    const Text(
                      'Zatím žádné vybavení.',
                      style: TextStyle(color: AppColors.textSecondary),
                    )
                  else
                    HkCard(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          for (final item in data.equipment)
                            _row(
                              item,
                              icon: Icons.kitchen_outlined,
                              onDelete: () =>
                                  _run(() => store.deleteEquipment(item.id)),
                            ),
                        ],
                      ),
                    ),
                  SectionTitle(
                    'Chuťové preference (${data.preferences.length})',
                    trailing: IconButton(
                      tooltip: 'Přidat preferenci',
                      icon: const Icon(Icons.add_rounded),
                      onPressed: _busy ? null : _addPreference,
                    ),
                  ),
                  if (data.preferences.isEmpty)
                    const Text(
                      'Zatím žádné preference.',
                      style: TextStyle(color: AppColors.textSecondary),
                    )
                  else
                    HkCard(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          for (final item in data.preferences)
                            _row(
                              item,
                              onToggle: (value) => _run(
                                () =>
                                    store.setPreferenceEnabled(item.id, value),
                              ),
                              onDelete: () =>
                                  _run(() => store.deletePreference(item.id)),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _row(
    MemoryItem item, {
    IconData? icon,
    ValueChanged<bool>? onToggle,
    required VoidCallback onDelete,
  }) {
    return ListTile(
      leading: onToggle == null
          ? Icon(icon)
          : Switch(value: item.enabled, onChanged: _busy ? null : onToggle),
      title: Text(item.label),
      subtitle: item.detail.isEmpty ? null : Text(item.detail),
      trailing: IconButton(
        tooltip: 'Odebrat',
        icon: const Icon(Icons.close_rounded),
        onPressed: _busy ? null : onDelete,
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/pantry.dart';
import '../../core/widgets.dart';

/// „Co mám doma“: zadáte suroviny, které máte, a aplikace najde recepty,
/// které z nich uvaříte (nejdřív ty, kterým nic nechybí).
class PantryScreen extends ConsumerStatefulWidget {
  const PantryScreen({super.key});

  @override
  ConsumerState<PantryScreen> createState() => _PantryScreenState();
}

class _PantryScreenState extends ConsumerState<PantryScreen> {
  static const _key = 'pantry_items';
  final _input = TextEditingController();
  late List<String> _items;
  bool _staples = true;

  @override
  void initState() {
    super.initState();
    try {
      _items = ref.read(sharedPreferencesProvider).getStringList(_key) ?? [];
    } catch (_) {
      _items = [];
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _save() {
    try {
      ref.read(sharedPreferencesProvider).setStringList(_key, _items);
    } catch (_) {}
  }

  void _add(String text) {
    final added = [
      for (final part in text.split(RegExp(r'[,;\n]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (added.isEmpty) return;
    setState(() {
      for (final a in added) {
        if (!_items.any((i) => i.toLowerCase() == a.toLowerCase())) {
          _items.add(a);
        }
      }
      _input.clear();
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final recipes = ref.watch(allRecipesProvider).value ?? const [];
    final matches = matchPantry(recipes, _items, withStaples: _staples);
    final ready = matches.where((m) => m.missing.isEmpty).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Co mám doma'),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: 'Vymazat vše',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () {
                setState(_items.clear);
                _save();
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _input,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Co máte doma?',
              hintText: 'např. vejce, mouka, kuře',
              suffixIcon: IconButton(
                tooltip: 'Přidat',
                icon: const Icon(Icons.add_circle_outline_rounded),
                onPressed: () => _add(_input.text),
              ),
            ),
            onSubmitted: _add,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final item in _items)
                InputChip(
                  label: Text(item),
                  onDeleted: () {
                    setState(() => _items.remove(item));
                    _save();
                  },
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sůl, pepř, olej a vodu mám vždy'),
            value: _staples,
            onChanged: (v) => setState(() => _staples = v),
          ),
          if (_items.isEmpty)
            const EmptyState(
              icon: Icons.kitchen_outlined,
              title: 'Napište, co máte v lednici',
              message:
                  'Najdu recepty z vaší kuchařky, které z toho uvaříte, '
                  'a ukážu, co případně chybí.',
            )
          else if (matches.isEmpty)
            const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Žádný recept se nenašel',
              message: 'Zkuste přidat další suroviny.',
            )
          else ...[
            SectionTitle(
              ready > 0
                  ? 'Uvaříte hned: $ready · další s nákupem'
                  : 'Recepty, ke kterým něco dokoupíte',
            ),
            for (final m in matches.take(40))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: HkCard(
                  onTap: () => context.push(Routes.recipe(m.recipe.id)),
                  child: Row(
                    children: [
                      Icon(
                        m.missing.isEmpty
                            ? Icons.check_circle_rounded
                            : Icons.shopping_basket_outlined,
                        color: m.missing.isEmpty
                            ? AppColors.success
                            : AppColors.copperGold,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.recipe.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              m.missing.isEmpty
                                  ? 'Máte všechno (${m.total} surovin)'
                                  : 'Chybí: ${m.missing.map((i) => i.name).join(', ')}',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${m.have.length}/${m.total}',
                        style: const TextStyle(color: AppColors.copperGold),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

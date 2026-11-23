import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/quick_timers.dart';

/// Kostra hlavních záložek se spodní navigací (Domů, Recepty, Nákupní
/// seznam, Plánování, Oblíbené, Štítky). Nad navigací se ukáže
/// doběhnutá minutka, ať jste na kterékoli záložce.
class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(quickTimersProvider);
    final ringing = ref.read(quickTimersProvider.notifier).ringing();
    return Scaffold(
      body: shell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final timer in ringing)
            Material(
              color: AppColors.copper,
              child: InkWell(
                onTap: () => context.push(Routes.timer),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.alarm_rounded, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Doběhlo: ${timer.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () =>
                            ref.read(quickTimersProvider.notifier).stop(timer),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          HkBottomNav(
            currentIndex: shell.currentIndex,
            onSelected: (index) => shell.goBranch(
              index,
              // Opětovné klepnutí na aktivní záložku vrátí na její začátek.
              initialLocation: index == shell.currentIndex,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const _navItems = [
  _NavItem('Domů', Icons.home_outlined, Icons.home_rounded),
  _NavItem(
    'Recepty',
    Icons.restaurant_menu_rounded,
    Icons.restaurant_menu_rounded,
  ),
  _NavItem(
    'Nákupní seznam',
    Icons.shopping_cart_outlined,
    Icons.shopping_cart_rounded,
  ),
  _NavItem(
    'Plánování',
    Icons.calendar_month_outlined,
    Icons.calendar_month_rounded,
  ),
  _NavItem('Oblíbené', Icons.favorite_outline_rounded, Icons.favorite_rounded),
  _NavItem('Štítky', Icons.sell_outlined, Icons.sell_rounded),
];

/// Spodní lišta podle předlohy: šest položek, aktivní oranžová.
/// Popisky mohou mít dva řádky a lišta se zvětší podle nastavení písma.
class HkBottomNav extends StatelessWidget {
  const HkBottomNav({
    super.key,
    required this.currentIndex,
    required this.onSelected,
  });

  final int currentIndex;
  final ValueChanged<int> onSelected;

  static const _labelSize = 11.5;
  static const _labelHeight = 1.05;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final labelSize = MediaQuery.textScalerOf(context).scale(_labelSize);
    final extraHeight = (labelSize - _labelSize).clamp(0.0, double.infinity);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF151516),
        border: Border(top: BorderSide(color: Color(0xFF2A2A2C))),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: 66 + 2 * extraHeight * _labelHeight,
          child: Row(
            children: [
              for (final (index, item) in _navItems.indexed)
                Expanded(
                  child: _NavButton(
                    item: item,
                    selected: index == currentIndex,
                    onTap: () => onSelected(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.copper : const Color(0xFFE8E8EA);
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? item.activeIcon : item.icon,
                color: color,
                size: 25,
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.copper : const Color(0xFFD0D0D3),
                  fontSize: HkBottomNav._labelSize,
                  height: HkBottomNav._labelHeight,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

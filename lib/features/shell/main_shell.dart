import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/quick_timers.dart';

/// Kostra hlavních záložek se spodní navigací. Nad navigací se ukáže
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
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFF2E2620))),
            ),
            child: NavigationBar(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: (index) => shell.goBranch(
                index,
                // Opětovné klepnutí na aktivní záložku vrátí na její začátek.
                initialLocation: index == shell.currentIndex,
              ),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(
                    Icons.home_rounded,
                    color: AppColors.copperGold,
                  ),
                  label: 'Domů',
                ),
                NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book_rounded),
                  label: 'Recepty',
                ),
                NavigationDestination(
                  icon: Icon(Icons.shopping_cart_outlined),
                  selectedIcon: Icon(Icons.shopping_cart_rounded),
                  label: 'Nákupy',
                ),
                NavigationDestination(
                  icon: Icon(Icons.favorite_outline_rounded),
                  selectedIcon: Icon(Icons.favorite_rounded),
                  label: 'Oblíbené',
                ),
                NavigationDestination(
                  icon: Icon(Icons.menu_rounded),
                  selectedIcon: Icon(Icons.menu_rounded),
                  label: 'Více',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

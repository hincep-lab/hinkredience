import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app/providers.dart';
import 'material.dart';

/// Ovládání zhasínání displeje. Rozhraní kvůli testům.
abstract interface class ScreenWake {
  /// `true` = displej nezhasne, `false` = běžné uspávání telefonu.
  Future<void> keepOn(bool on);
}

class WakelockScreenWake implements ScreenWake {
  const WakelockScreenWake();

  @override
  Future<void> keepOn(bool on) async {
    try {
      await (on ? WakelockPlus.enable() : WakelockPlus.disable());
    } catch (error) {
      // Bez podpory na zařízení se nic nestane – aplikace funguje dál.
      debugPrint('Nevypínání obrazovky nefunguje: $error');
    }
  }
}

final screenWakeProvider = Provider<ScreenWake>(
  (ref) => const WakelockScreenWake(),
);

/// Sleduje, která obrazovka je navrchu. Dialogy, menu a spodní panely
/// (PopupRoute) se nepočítají – recept pod nimi je pořád „otevřený“.
class ScreenRouteObserver extends NavigatorObserver {
  final _stack = <Route<dynamic>>[];

  /// Obrazovka navrchu (bez dialogů a menu); `null` = zatím neznámá.
  final current = ValueNotifier<Route<dynamic>?>(null);

  bool _counts(Route<dynamic> route) => route is! PopupRoute;

  void _publish() => current.value = _stack.isEmpty ? null : _stack.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_counts(route)) {
      _stack.add(route);
      _publish();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.remove(route)) _publish();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.remove(route)) _publish();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute != null && _counts(newRoute)) {
        _stack[index] = newRoute;
      } else {
        _stack.removeAt(index);
      }
    } else if (newRoute != null && _counts(newRoute)) {
      _stack.add(newRoute);
    }
    _publish();
  }
}

/// Jediný pozorovatel pro hlavní navigaci aplikace.
final appRouteObserver = ScreenRouteObserver();

/// Dokud je [child] na obrazovce navrchu a aplikace v popředí, displej
/// nezhasne (pokud to uživatel nevypnul v nastavení).
///
/// Vypne se, když:
/// - uživatel odejde z obrazovky (zpět nebo na jinou obrazovku navrch),
/// - aplikace jde do pozadí nebo se telefon zamkne,
/// - uživatel funkci vypne v nastavení.
///
/// Dialogy a menu nad receptem displej nevypínají. Ruční zamčení telefonu
/// funguje vždy normálně.
class KeepScreenOn extends ConsumerStatefulWidget {
  const KeepScreenOn({super.key, required this.child, this.observer});

  final Widget child;

  /// Pozorovatel navigace; výchozí je [appRouteObserver].
  final ScreenRouteObserver? observer;

  @override
  ConsumerState<KeepScreenOn> createState() => _KeepScreenOnState();
}

class _KeepScreenOnState extends ConsumerState<KeepScreenOn>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool _applied = false;
  ModalRoute<dynamic>? _route;
  late final ScreenWake _wake = ref.read(screenWakeProvider);
  late final ScreenRouteObserver _observer =
      widget.observer ?? appRouteObserver;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _observer.current.addListener(_update);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  bool get _onTop {
    final top = _observer.current.value;
    return top == null || _route == null || identical(top, _route);
  }

  void _update() {
    if (!mounted) return;
    final wanted =
        ref.read(settingsProvider).keepScreenOn && _onTop && _foreground;
    if (wanted == _applied) return;
    _applied = wanted;
    _wake.keepOn(wanted);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _observer.current.removeListener(_update);
    if (_applied) {
      _applied = false;
      _wake.keepOn(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Změna v nastavení se projeví hned.
    ref.listen(
      settingsProvider.select((s) => s.keepScreenOn),
      (_, _) => _update(),
    );
    return widget.child;
  }
}

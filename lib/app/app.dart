import 'package:cupertino_ui/cupertino_ui.dart'
    show GlobalCupertinoLocalizations;
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../core/material.dart';
import 'providers.dart';
import 'router.dart';

class HinkredienceApp extends ConsumerStatefulWidget {
  const HinkredienceApp({super.key});

  @override
  ConsumerState<HinkredienceApp> createState() => _HinkredienceAppState();
}

class _HinkredienceAppState extends ConsumerState<HinkredienceApp> {
  late final _router = createRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Udržuje synchronizaci naživu po celou dobu běhu aplikace.
    ref.watch(syncProvider.select((s) => s.running));

    return MaterialApp.router(
      title: 'HINKredience°',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      locale: const Locale('cs'),
      supportedLocales: const [Locale('cs')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}

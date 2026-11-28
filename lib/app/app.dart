import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../core/material.dart';
import '../core/receipt_share.dart';
import 'kitchen_providers.dart' show checkSaleAlerts;
import 'providers.dart';
import 'router.dart';

class HinkredienceApp extends ConsumerStatefulWidget {
  const HinkredienceApp({super.key});

  @override
  ConsumerState<HinkredienceApp> createState() => _HinkredienceAppState();
}

class _HinkredienceAppState extends ConsumerState<HinkredienceApp> {
  late final _router = createRouter();
  StreamSubscription<String>? _shared;

  /// PDF účtenky sdílené z jiné aplikace; otevře se až po přihlášení.
  String? _pendingReceipt;

  @override
  void initState() {
    super.initState();
    _router.routerDelegate.addListener(_openPendingReceipt);
    _shared = ReceiptShare.shared.listen(_receiveReceipt);
    ReceiptShare.initial().then((path) {
      if (path != null) _receiveReceipt(path);
    });
  }

  void _receiveReceipt(String path) {
    _pendingReceipt = path;
    _openPendingReceipt();
  }

  void _openPendingReceipt() {
    final path = _pendingReceipt;
    if (path == null || !mounted) return;
    final location = _router.routerDelegate.currentConfiguration.uri.path;
    if (location == Routes.splash || location == Routes.auth) return;
    _pendingReceipt = null;
    // Až po dokončení právě probíhající navigace.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_router.push(Routes.receiptPdf(path))),
    );
  }

  @override
  void dispose() {
    _shared?.cancel();
    _router.routerDelegate.removeListener(_openPendingReceipt);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Udržuje synchronizaci naživu po celou dobu běhu aplikace.
    ref.watch(syncProvider.select((s) => s.running));
    // Po úspěšné synchronizaci: nové akce na zboží ze seznamů → oznámení.
    ref.listen(syncProvider.select((s) => s.lastSuccess), (prev, next) {
      if (next != null && next != prev) checkSaleAlerts(ref);
    });

    return MaterialApp.router(
      title: 'HINKredience°',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      locale: const Locale('cs'),
      supportedLocales: const [Locale('cs')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}

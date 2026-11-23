import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';

/// Úvodní obrazovka s logem. Během ní se otevře databáze a rozhodne se,
/// zda ukázat přihlášení, nebo rovnou kuchařku.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await ref
          .read(recipeRepositoryProvider.future)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Případnou chybu databáze ukáže až seznam receptů.
    }
    if (!mounted) return;

    final hasBackend = ref.read(supabaseClientProvider) != null;
    final signedIn = ref.read(sessionProvider).isSignedIn;
    final skipAuth = ref.read(settingsProvider).skipAuth;
    final needsAuth = hasBackend && !signedIn && !skipAuth;
    context.go(needsAuth ? Routes.auth : Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: const Alignment(0, -0.35),
            child: AspectRatio(
              aspectRatio: 1,
              child: ShaderMask(
                shaderCallback: (rect) => const RadialGradient(
                  radius: 0.72,
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, 0.72, 1],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: Image.asset(
                  'assets/images/logo_full.jpg',
                  fit: BoxFit.cover,
                  semanticLabel:
                      'HINKredience – Dvě hlavy. Jedna dokonalá chuť.',
                ),
              ),
            ),
          ),
          const SafeArea(
            child: Align(
              alignment: Alignment(0, 0.86),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(height: 18),
                  Text(
                    'Načítám tvou kuchyni…',
                    style: TextStyle(color: AppColors.text, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

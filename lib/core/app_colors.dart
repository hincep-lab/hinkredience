import 'material.dart';

/// Barevná paleta HINKredience°: téměř černé pozadí, oranžový akcent
/// (podle vizuální předlohy redesignu).
abstract final class AppColors {
  static const background = Color(0xFF0B0B0D);
  static const backgroundSecondary = Color(0xFF151516);
  static const card = Color(0xFF1C1C1E);
  static const copper = Color(0xFFF28C1E);
  static const copperGold = Color(0xFFF7A43A);
  static const text = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB5B5B8);

  /// Jemný obrys karet a tlačítek.
  static const outline = Color(0xFF3A3A3C);
  static const danger = Color(0xFFE5645A);
  static const success = Color(0xFF7BC47F);

  static const copperGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [copperGold, copper],
  );

  static const cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF222224), Color(0xFF19191B)],
  );
}

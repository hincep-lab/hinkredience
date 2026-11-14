import 'material.dart';

/// Barevná paleta HINKredience° (kap. 2 zadání).
abstract final class AppColors {
  static const background = Color(0xFF0B0B0D);
  static const backgroundSecondary = Color(0xFF171719);
  static const card = Color(0xFF211A17);
  static const copper = Color(0xFFC87935);
  static const copperGold = Color(0xFFE8A45D);
  static const text = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB8B4B0);

  /// Jemný měděný obrys karet.
  static const outline = Color(0xFF4A3424);
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
    colors: [Color(0xFF2A201B), Color(0xFF1A1513)],
  );
}

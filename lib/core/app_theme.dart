import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'material.dart';

/// Tmavý prémiový motiv s měděnými akcenty.
abstract final class AppTheme {
  static const radius = 18.0;

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.copperGold,
      onPrimary: Color(0xFF1B1108),
      primaryContainer: AppColors.copper,
      onPrimaryContainer: Color(0xFF1B1108),
      secondary: AppColors.copper,
      onSecondary: Color(0xFF1B1108),
      secondaryContainer: Color(0xFF3A281B),
      onSecondaryContainer: AppColors.copperGold,
      tertiary: AppColors.copperGold,
      onTertiary: Color(0xFF1B1108),
      error: AppColors.danger,
      onError: Color(0xFF1B0907),
      surface: AppColors.background,
      onSurface: AppColors.text,
      onSurfaceVariant: AppColors.textSecondary,
      surfaceContainerLowest: AppColors.background,
      surfaceContainerLow: AppColors.backgroundSecondary,
      surfaceContainer: AppColors.backgroundSecondary,
      surfaceContainerHigh: AppColors.card,
      surfaceContainerHighest: Color(0xFF262628),
      outline: AppColors.outline,
      outlineVariant: Color(0xFF2A2A2C),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: AppColors.text,
      onInverseSurface: AppColors.background,
      inversePrimary: AppColors.copper,
    );

    final base = ThemeData(colorScheme: scheme, brightness: Brightness.dark);
    final textTheme = base.textTheme
        .apply(bodyColor: AppColors.text, displayColor: AppColors.text)
        .copyWith(
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            letterSpacing: -0.4,
          ),
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.text,
            letterSpacing: -0.2,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            color: AppColors.text,
            height: 1.4,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            color: AppColors.textSecondary,
          ),
          labelSmall: base.textTheme.labelSmall?.copyWith(
            color: AppColors.textSecondary,
          ),
        );

    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.outline),
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: textTheme,
      appBarTheme: AppBarThemeData(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2A2A2C),
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: AppColors.backgroundSecondary,
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        floatingLabelStyle: const TextStyle(color: AppColors.copperGold),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.copperGold, width: 1.5),
        ),
        errorBorder: fieldBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: fieldBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.copper,
          foregroundColor: const Color(0xFF1B1108),
          minimumSize: const Size(64, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.copperGold,
          minimumSize: const Size(64, 52),
          side: const BorderSide(color: AppColors.copper),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.copperGold),
      ),
      iconTheme: const IconThemeData(color: AppColors.text),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.copper,
        foregroundColor: Color(0xFF1B1108),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.backgroundSecondary,
        selectedColor: AppColors.copper,
        side: const BorderSide(color: AppColors.outline),
        labelStyle: textTheme.labelLarge?.copyWith(color: AppColors.text),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: const Color(0xFF1B1108),
        ),
        checkmarkColor: const Color(0xFF1B1108),
        shape: const StadiumBorder(),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFF3A281B),
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? AppColors.copperGold
                : AppColors.textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.copperGold
                : AppColors.textSecondary,
          ),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: AppColors.copperGold,
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: AppColors.copperGold,
        dividerColor: Color(0xFF2A2A2C),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.card,
        contentTextStyle: const TextStyle(color: AppColors.text),
        actionTextColor: AppColors.copperGold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.backgroundSecondary,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.backgroundSecondary,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.backgroundSecondary,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        side: const BorderSide(color: AppColors.textSecondary, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.copper
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Color(0xFF1B1108)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.copperGold,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.copperGold,
        textColor: AppColors.text,
      ),
    );
  }
}

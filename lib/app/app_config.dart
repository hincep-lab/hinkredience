import 'package:shared_preferences/shared_preferences.dart';

/// Připojení k Supabase.
///
/// Hodnoty lze zadat při sestavení (`--dart-define=SUPABASE_URL=…`,
/// `--dart-define=SUPABASE_ANON_KEY=…`) nebo později v aplikaci
/// (Více → Připojení k Supabase). Veřejný „anon“ klíč není tajný – data chrání
/// Row Level Security v databázi. Žádné tajné klíče v aplikaci nejsou.
class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.fromBuild,
  });

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// `true`, pokud hodnoty pocházejí ze sestavení a nejdou v aplikaci změnit.
  final bool fromBuild;

  bool get hasSupabase => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static const _envUrl = String.fromEnvironment('SUPABASE_URL');
  static const _envKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const _prefUrl = 'supabase_url';
  static const _prefKey = 'supabase_anon_key';

  static AppConfig load(SharedPreferences prefs) {
    if (_envUrl.isNotEmpty && _envKey.isNotEmpty) {
      return const AppConfig(
        supabaseUrl: _envUrl,
        supabaseAnonKey: _envKey,
        fromBuild: true,
      );
    }
    return AppConfig(
      supabaseUrl: prefs.getString(_prefUrl) ?? '',
      supabaseAnonKey: prefs.getString(_prefKey) ?? '',
      fromBuild: false,
    );
  }

  static Future<void> save(
    SharedPreferences prefs, {
    required String url,
    required String anonKey,
  }) async {
    await prefs.setString(_prefUrl, url.trim());
    await prefs.setString(_prefKey, anonKey.trim());
  }

  /// Ověří tvar adresy projektu. Vrací text chyby, nebo `null`.
  static String? validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Zadejte adresu ve tvaru https://xxxx.supabase.co';
    }
    if (uri.scheme != 'https') return 'Adresa musí začínat https://';
    return null;
  }
}

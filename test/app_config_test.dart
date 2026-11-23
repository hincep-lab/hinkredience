import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('testovací sestavení ignoruje uložené nastavení serveru', () async {
    SharedPreferences.setMockInitialValues({
      'supabase_url': 'https://example.invalid',
      'supabase_anon_key': 'test-key',
    });
    final config = AppConfig.load(await SharedPreferences.getInstance());
    if (const bool.fromEnvironment('HINKREDIENCE_PREVIEW')) {
      expect(config.hasSupabase, isFalse);
      expect(config.fromBuild, isTrue);
    } else {
      expect(config.supabaseUrl, 'https://example.invalid');
      expect(config.hasSupabase, isTrue);
      expect(config.fromBuild, isFalse);
    }
  });
}

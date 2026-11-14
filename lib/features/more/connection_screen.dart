import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_config.dart';
import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';

/// Nastavení připojení k Supabase (adresa projektu a veřejný klíč).
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _url;
  late final TextEditingController _key;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(appConfigProvider);
    _url = TextEditingController(text: config.supabaseUrl);
    _key = TextEditingController(text: config.supabaseAnonKey);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await AppConfig.save(
      ref.read(sharedPreferencesProvider),
      url: _url.text,
      anonKey: _key.text,
    );
    if (mounted) setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Připojení k Supabase')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Supabase je databáze, do které se kuchařka zálohuje a přes kterou '
              'se synchronizuje mezi zařízeními. Oba údaje najdete v nastavení '
              'svého projektu (Project Settings → API).',
              style: TextStyle(color: AppColors.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 16),
            if (config.fromBuild)
              const HkCard(
                child: Text(
                  'Připojení je pevně nastavené při sestavení aplikace '
                  'a tady ho nelze změnit.',
                ),
              )
            else ...[
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Adresa projektu (Project URL)',
                  hintText: 'https://xxxx.supabase.co',
                ),
                validator: (value) => AppConfig.validateUrl(value ?? ''),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _key,
                autocorrect: false,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Veřejný klíč (anon / publishable key)',
                  helperText: 'Vkládejte jen veřejný klíč. Klíč service_role sem nepatří.',
                  helperMaxLines: 2,
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.length < 20) return 'Vložte celý klíč.';
                  if (text.contains('service_role')) {
                    return 'Toto vypadá jako tajný klíč. Použijte veřejný.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              CopperButton(
                label: 'Uložit připojení',
                icon: Icons.check_rounded,
                onPressed: _save,
              ),
              if (_saved) ...[
                const SizedBox(height: 16),
                const HkCard(
                  child: Row(
                    children: [
                      Icon(
                        Icons.restart_alt_rounded,
                        color: AppColors.copperGold,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Uloženo. Aplikaci teď úplně zavřete a znovu otevřete – '
                          'připojení se načte při startu.',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

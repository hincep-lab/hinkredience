import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';

/// Adresa MCP serveru HINKredience pro daný projekt Supabase.
String mcpServerUrl(String supabaseUrl) {
  final base = supabaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  return base.isEmpty ? '' : '$base/functions/v1/mcp';
}

/// Návod na propojení kuchařky s ChatGPT přes MCP server. ChatGPT pak
/// pracuje se stejnou databází receptů jako aplikace – bez placeného API.
class ChatGptScreen extends ConsumerWidget {
  const ChatGptScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = mcpServerUrl(ref.watch(appConfigProvider).supabaseUrl);
    final signedIn = ref.watch(sessionProvider).isSignedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('Propojení s ChatGPT')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text(
            'Recepty můžete vytvářet a upravovat přímo v ChatGPT a ukládat je '
            'do této kuchařky. Využívá se vaše předplatné ChatGPT, aplikace za '
            'to žádné požadavky na AI neplatí.',
            style: TextStyle(color: AppColors.textSecondary, height: 1.45),
          ),
          const SectionTitle('Adresa serveru'),
          if (url.isEmpty)
            const Text(
              'Nejdřív nastavte připojení k Supabase (Více → Připojení k Supabase).',
              style: TextStyle(color: AppColors.textSecondary),
            )
          else
            HkCard(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      url,
                      style: const TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zkopírovat adresu',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        showMessage(context, 'Adresa je zkopírovaná.');
                      }
                    },
                  ),
                ],
              ),
            ),
          const SectionTitle('Jak propojit'),
          const _Step(
            1,
            'Na počítači otevřete chatgpt.com a v nastavení aplikací '
            '(Apps / Plugins) zvolte přidání vlastního MCP serveru. '
            'Podle tarifu může být potřeba zapnout vývojářský režim.',
          ),
          const _Step(
            2,
            'Vložte adresu serveru uvedenou výše a jako způsob ověření '
            'vyberte OAuth.',
          ),
          const _Step(
            3,
            'ChatGPT otevře přihlašovací stránku HINKredience. Přihlaste se '
            'stejným e-mailem a heslem jako v této aplikaci a přístup '
            'potvrďte.',
          ),
          const _Step(
            4,
            'V ChatGPT pak stačí napsat například „Ulož recept do '
            'HINKredience“. Zápis ChatGPT před provedením ukáže ke '
            'schválení. Recept se v telefonu objeví po synchronizaci.',
          ),
          const SizedBox(height: 8),
          HkCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.shield_outlined, color: AppColors.copperGold),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    signedIn
                        ? 'ChatGPT uvidí jen recepty vašeho účtu. Úpravy vždy '
                              'vytvoří novou verzi a smazání jen přesune recept '
                              'do koše, odkud ho tady obnovíte.'
                        : 'Propojení vyžaduje účet: přihlaste se v nabídce '
                              'Více, aby se recepty synchronizovaly se serverem.',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Podrobný postup včetně nastavení serveru je v souboru '
            'docs/chatgpt.md v repozitáři projektu.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              gradient: AppColors.copperGradient,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Color(0xFF1B1108),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
        ],
      ),
    );
  }
}

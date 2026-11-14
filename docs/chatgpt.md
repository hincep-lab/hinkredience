# Propojení HINKredience° s ChatGPT (MCP server)

ChatGPT se připojuje k serverové funkci Supabase [`mcp`](../supabase/functions/mcp/index.ts).
Ta mu dává 12 nástrojů nad stejnou databází, jakou používá mobilní aplikace.
Recepty tak vytváříte a upravujete v ChatGPT v rámci svého předplatného;
aplikace za to žádné požadavky na AI neplatí.

## Jak je to zabezpečené

- ChatGPT se přihlašuje přes **OAuth 2.1** proti Supabase Auth vašeho projektu.
  Přihlásíte se stejným e-mailem a heslem jako v aplikaci a přístup výslovně
  potvrdíte na stránce [`web/oauth/consent`](../web/oauth/consent/index.html).
- MCP server každý požadavek ověří a s databází mluví **tokenem přihlášeného
  uživatele**. Platí proto stejná Row Level Security jako v aplikaci – ChatGPT
  vidí a mění jen recepty vašeho účtu. Žádný servisní klíč se nepoužívá.
- Bez platného tokenu server odpoví `401` a na databázi vůbec nesáhne.
- Úprava receptu vždy vytvoří **novou verzi**, původní zůstává v historii.
  „Smazání“ recept jen **přesune do koše**, odkud ho v aplikaci obnovíte.
- Zápisy ChatGPT před provedením ukazuje ke schválení (nástroje pro čtení
  jsou označené jako `readOnlyHint`, ostatní bere jako zápis).
- Server nepředpokládá žádný přístup k paměti ani historii ChatGPT. ChatGPT
  ví jen to, co mu vrátí nástroje.

## Nástroje

| Nástroj | Co dělá | Zápis |
| --- | --- | --- |
| `get_recipes` | přehled receptů (filtr kategorie, oblíbené) | ne |
| `get_recipe` | úplný recept se surovinami a postupem | ne |
| `search_recipes` | hledání v receptech bez ohledu na diakritiku, i v surovinách | ne |
| `create_recipe` | uloží nový recept | ano |
| `update_recipe` | upraví recept (jen změněná pole), vytvoří novou verzi | ano |
| `delete_recipe` | přesune recept do koše | ano |
| `get_recipe_versions` | historie verzí: co, proč, kdy, výsledek, hodnocení | ne |
| `create_recipe_version` | uloží celou novou podobu jako další verzi | ano |
| `add_cooking_note` | přidá poznámku z vaření | ano |
| `get_cooking_history` | kuchařský deník a poznámky | ne |
| `get_kitchen_equipment` | vybavení a chuťové preference | ne |
| `update_kitchen_equipment` | přidá, upraví nebo odebere vybavení | ano |

## Co potřebuje váš účet ChatGPT

Vlastní MCP servery se v ChatGPT přidávají na webu (chatgpt.com), ne v mobilní
aplikaci. Dostupnost se liší podle tarifu a OpenAI ji průběžně mění:

- Podle nápovědy OpenAI je plná podpora MCP včetně zápisů určená pro tarify
  Business, Enterprise a Edu.
- U osobních tarifů Plus a Pro se zdroje rozcházejí: některé uvádějí vývojářský
  režim s plnou podporou, jiné jen čtení. **Jistotu dá až pokus na vašem účtu.**
- Tarif Free vlastní MCP servery nepodporuje.

Když by váš účet dovolil jen čtení, půjdou recepty z ChatGPT číst a hledat,
ale ne ukládat. Aktuální stav: <https://help.openai.com/en/articles/12584461>.

## Nastavení serveru (jednorázově)

Kroky 1 a 2 jsou hotové, pokud je v [README](../README.md) uvedeno, že jsou
migrace spuštěné a funkce `mcp` nasazená.

1. **Migrace** – v SQL Editoru spusťte
   [`20261114000006_recipe_api.sql`](../supabase/migrations/20261114000006_recipe_api.sql).
2. **Funkce** – nasaďte `supabase/functions/mcp/index.ts` jako funkci `mcp`
   (Edge Functions → Deploy a new function → Via Editor, nebo
   `supabase functions deploy mcp --no-verify-jwt`).
3. **Vypnout kontrolu JWT u brány** – Edge Functions → `mcp` → Settings →
   vypnout *Verify JWT with legacy secret*. Funkce si token ověřuje sama a jen
   tak může vrátit hlavičku, podle které ChatGPT najde přihlášení. Bez tohoto
   kroku se propojení nespustí.
4. **Přihlašovací stránka** – soubor `web/oauth/consent/index.html` musí být
   dostupný na veřejné adrese HTTPS (neobsahuje nic tajného). Například
   GitHub Pages, Cloudflare Pages nebo Netlify. Výsledná adresa bude
   `https://<váš-web>/oauth/consent/`.
5. **Supabase Auth → URL Configuration** – jako *Site URL* nastavte
   `https://<váš-web>` (bez cesty).
6. **Supabase Auth → OAuth Server** – zapněte OAuth 2.1 server, jako
   *Authorization Path* zadejte `/oauth/consent/` a povolte dynamickou
   registraci klientů (*Allow Dynamic OAuth Apps*), aby se ChatGPT mohl
   zaregistrovat sám.
7. **Podpisové klíče** – v Authentication → Signing Keys by měl být aktivní
   asymetrický klíč (ES256/RS256). U nových projektů bývá výchozí.

Adresa serveru pro ChatGPT:

```
https://wjqpzoeheonjwdyyezhb.supabase.co/functions/v1/mcp
```

Najdete ji i v aplikaci: Více → Propojení s ChatGPT.

## Připojení v ChatGPT

1. Na počítači otevřete <https://chatgpt.com/plugins>, klikněte na **+**
   a zvolte **Add custom MCP server**. (Podle tarifu může být potřeba nejdřív
   zapnout vývojářský režim v Settings → Apps → Advanced settings.)
2. Název: `HINKredience`. Server URL: adresa výše. Authentication: **OAuth**.
3. Potvrďte upozornění a vytvořte plugin. ChatGPT otevře přihlašovací stránku
   HINKredience – přihlaste se a klikněte na **Povolit přístup**.
4. Plugin nainstalujte a v novém chatu ho zapněte.

## Vyzkoušení

Postupně v ChatGPT napište:

1. „Jaké recepty mám v HINKredience?“ → měl by zavolat `get_recipes`.
2. „Vymysli recept na pečenou kachnu podle mého vybavení a ulož ho do
   HINKredience.“ → `get_kitchen_equipment`, potom `create_recipe` (schválit).
3. V telefonu: Více → Synchronizovat nyní → recept je v kuchařce.
4. V telefonu recept upravte, synchronizujte a v ChatGPT napište
   „Načti z HINKredience recept na kachnu a sniž teplotu na 150 °C.“
   → `get_recipe`, `update_recipe` → v aplikaci přibude verze 2.

## Odpojení

- V ChatGPT plugin odeberte.
- V Supabase: Authentication → OAuth Apps → klienta ChatGPT smažte. Tím
  přestanou platit i jeho tokeny.

## Co je a není ověřeno

Ověřeno automatickými testy (`deno test supabase/functions`,
`cd supabase/tests && npm test`):

- protokol MCP (initialize, tools/list, tools/call), odmítnutí bez tokenu
  a s neplatným tokenem, metadata pro OAuth,
- všech 12 nástrojů proti maketě databáze, včetně toho, že klient nemůže
  podstrčit cizího vlastníka ani neplatné id,
- atomické uložení receptu a verzí ve skutečném PostgreSQL včetně oprávnění.

**Neověřeno:** skutečné přihlášení ChatGPT přes OAuth, přihlašovací stránka
proti živému projektu a chování na vašem tarifu ChatGPT. To jde vyzkoušet až
po krocích 3–7 výše.

# Propojení HINKredience° s ChatGPT (MCP server)

ChatGPT se připojuje k serverové funkci Supabase [`mcp`](../supabase/functions/mcp/index.ts).
Ta mu dává 12 nástrojů nad stejnou databází, jakou používá mobilní aplikace.
Recepty tak vytváříte a upravujete v ChatGPT v rámci svého předplatného;
aplikace za to žádné požadavky na AI neplatí.

## Jak je to zabezpečené

- ChatGPT se přihlašuje přes **OAuth 2.1** proti Supabase Auth vašeho projektu.
  Přihlásíte se stejným e-mailem a heslem jako v aplikaci a přístup výslovně
  potvrdíte na stránce <https://hincep-lab.github.io/hinkredience-login/oauth/consent/>.
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
| `list_recipes_with_photos` | recepty s fotkami a jejich hlavní fotka (okénko + obrázky) | ne |
| `get_recipe_photos` | všechny fotky jednoho receptu, pořadí, hlavní fotka | ne |
| `get_recipe_photo` | jedna fotka v plné kvalitě, aby ji ChatGPT mohl prohlédnout | ne |
| `upload_recipe_photo` | uloží fotku poslanou do konverzace k receptu | ano |
| `set_recipe_cover_photo` | nastaví hlavní fotku (např. „druhou“ = `position: 2`) | ano |
| `reorder_recipe_photos` | změní pořadí fotek | ano |
| `delete_recipe_photo` | odebere fotku z receptu (soubor zůstane, zná-li ho historie verzí) | ano |

### Jak se přenášejí fotky

Fotky jsou v soukromém úložišti Supabase. Server je čte a zapisuje vždy
s přístupovým tokenem přihlášeného uživatele, takže platí stejná oprávnění
(RLS) jako v aplikaci. Žádné veřejné odkazy nevznikají.

- **Obrázek přímo v odpovědi** – nástroje vracejí fotky jako standardní MCP
  obsah typu `image` (base64, JPEG/PNG/WebP). Pro přehledy se posílají
  náhledy 480 px, pro `get_recipe_photo` plná fotka.
- **Okénko s fotkami** – `list_recipes_with_photos` a `get_recipe_photos` mají
  okénko podle standardu MCP Apps (`ui://hinkredience/photos.html`). Okénko
  smí načítat obrázky jen z domény projektu Supabase a používá podepsané
  odkazy platné 15 minut.
- **Nahrání fotky z konverzace** – `upload_recipe_photo` má parametr `photo`
  označený `_meta["openai/fileParams"]`; ChatGPT do něj předá dočasný odkaz na
  soubor, který uživatel poslal. Server stáhne nejvýše 10 MB, ověří podle
  obsahu, že jde o JPEG, PNG nebo WebP, a uloží ho do složky uživatele.
  Odkazy smějí být jen `https` na veřejný server (ne IP adresy ani
  `localhost`). Jiní MCP klienti mohou poslat `image_base64`.

## Co potřebuje váš účet ChatGPT

Vlastní MCP servery se v ChatGPT přidávají na webu (chatgpt.com), ne v mobilní
aplikaci. Dostupnost se liší podle tarifu a OpenAI ji průběžně mění:

- OpenAI při uvedení vývojářského režimu (září 2025) oznámilo zápisové akce
  pro tarify **Plus a Pro**; od října 2025 i pro Business, Enterprise a Edu.
- Jednotlivé novější zdroje uvádějí u Plus jen čtení. **Jistotu dá až pokus
  na vašem účtu** – nabídka se průběžně mění.
- Tarif Free vlastní MCP servery nepodporuje.

Když by váš účet dovolil jen čtení, půjdou recepty z ChatGPT číst a hledat,
ale ne ukládat. Aktuální stav: <https://help.openai.com/en/articles/12584461>.

## Nastavení serveru (jednorázově)

Kroky 1 a 2 jsou hotové, pokud je v [README](../README.md) uvedeno, že jsou
migrace spuštěné a funkce `mcp` nasazená.

1. **Migrace** – v SQL Editoru spusťte
   [`20261114000006_recipe_api.sql`](../supabase/migrations/20261114000006_recipe_api.sql),
   [`20261114000007_yield_and_time.sql`](../supabase/migrations/20261114000007_yield_and_time.sql)
   a [`20261115000008_sync_tombstones.sql`](../supabase/migrations/20261115000008_sync_tombstones.sql).
   Všechny jen přidávají a dají se spustit opakovaně.
2. **Funkce** – nasaďte `supabase/functions/mcp/index.ts` jako funkci `mcp`
   (Edge Functions → Deploy a new function → Via Editor, nebo
   `supabase functions deploy mcp --no-verify-jwt`).
3. **Vypnout kontrolu JWT u brány** – Edge Functions → `mcp` → Settings →
   vypnout *Verify JWT with legacy secret*. Funkce si token ověřuje sama a jen
   tak může vrátit hlavičku, podle které ChatGPT najde přihlášení. Bez tohoto
   kroku se propojení nespustí.
4. **Přihlašovací stránka** – je nasazená z veřejného repozitáře
   [hincep-lab/hinkredience-login](https://github.com/hincep-lab/hinkredience-login)
   přes GitHub Pages (kopie souborů je ve složce [`web/`](../web)):
   <https://hincep-lab.github.io/hinkredience-login/oauth/consent/>.
   Neobsahuje nic tajného a knihovnu supabase-js má uloženou u sebe.
5. **Supabase Auth → URL Configuration** – jako *Site URL* nastavte
   `https://hincep-lab.github.io/hinkredience-login`.
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
5. „Podívej se na fotky v mojí kuchařce.“ → `list_recipes_with_photos`.
6. „Vidíš novou fotku lososa?“ → `search_recipes`, `get_recipe_photo`.
7. Pošlete fotku a napište „Vlož ji ke králíkovi.“ → `upload_recipe_photo`
   (schválit) → fotka se v aplikaci objeví sama do pár sekund.
8. „Nastav druhou fotku palačinek jako hlavní.“ → `set_recipe_cover_photo`.

Synchronizace v telefonu je automatická – ruční „Synchronizovat nyní“ už
není potřeba.

## Odpojení

- V ChatGPT plugin odeberte.
- V Supabase: Authentication → OAuth Apps → klienta ChatGPT smažte. Tím
  přestanou platit i jeho tokeny.

## Co je a není ověřeno

**Fotky v ChatGPT nejsou zatím ověřené na skutečném účtu.** Podle zpráv
vývojářů z roku 2026 ChatGPT obrázky typu `image` z MCP nástrojů nezobrazuje
spolehlivě (někdy dorazí jen text). Proto server posílá fotky dvojí cestou:
obrázky v odpovědi a okénko MCP Apps s podepsanými odkazy. Co z toho ChatGPT
na vašem účtu skutečně ukáže, se ověří až po zapnutí přihlášení (kroky 3–6).

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

# Automatické titulní fotografie – bezpečné testování

Tato experimentální funkce **není zapnutá ani nasazená**. Nemění Flutter aplikaci ani databázové schéma.

## Ochranná opatření
- Workflow je jen `workflow_dispatch`; bez pravidelného plánovače.
- Výchozí spuštění je **dry-run** (žádné placené generování, žádný zápis fotografií).
- Při `apply=true` nejvýše 1 až 5 obrázků za spuštění, default 1.
- Cílí pouze na recepty konkrétního `HINK_OWNER_ID`, které mají prázdné `photos`.
- Před uložením fotografie kontroluje, zda `photos` zůstává prázdné; nezasahuje do stávajících fotek.
- Při selhání aktualizace databáze odstraňuje nově nahraný soubor, pokud to služba dovolí.
- GitHub workflow má `contents: read`, jedinou souběžnou instanci a oddělené prostředí `recipe-covers`.

## Před použitím
1. Na GitHubu vytvořit Environment `recipe-covers` s povinným schválením pro `apply=true` (pozor: GitHub Actions nemá podmíněné schvalování podle inputu; doporučuje se schválení každého běhu tohoto prostředí).
2. Do jeho tajemství vložit `HINK_SUPABASE_URL`, `HINK_SUPABASE_SERVICE_ROLE_KEY`, `HINK_OWNER_ID` a `HINK_OPENAI_API_KEY`. Pro skutečný zápis je navíc nutný samostatný secret `HINK_COVER_WRITES_ENABLED=true`; bez něj je režim `--apply` blokován. **Nikdy je nevkládat do souborů, do chatu ani do veřejného zdrojového kódu.**
3. `HINK_SUPABASE_SERVICE_ROLE_KEY` obchází RLS. Ideálně nahradit omezenou serverovou funkci před produkčním provozem. Zkontrolovat oprávnění prostředí.
4. Nejprve v testovacím prostředí ověřit čtení receptů, generování PNG, nahrání do bucketu `recipe-photos`, synchronizaci a závod mezi dvěma změnami.
5. Teprve potom nastavit `HINK_COVER_WRITES_ENABLED=true` v chráněném Environment a ručně spustit s `apply=true`, `limit=1`. Ověřit v aplikaci obrázek, původní data a běh synchronizace.
6. Nezapínat denní plánovač, dokud tyto kontroly neprojdou.

## Limity
Použití OpenAI Images API je placené a vyžaduje samostatný API kredit. Limit 1–5 za běh **není** rozpočtový limit v korunách; pro produkční provoz je potřeba doplnit účetní limit a přepínač vypnutí. Model lze změnit proměnnou `HINK_IMAGE_MODEL`.

Záměrně nejsou změněny `main`, release workflow ani nasazená aplikace.

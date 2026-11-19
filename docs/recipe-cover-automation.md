# Automatické hlavní fotografie receptů

Recepty bez fotky dostanou realistickou fotografii hotového jídla
z **Cloudflare Workers AI (FLUX.1 schnell) na bezplatném tarifu Workers Free**.
Po vyčerpání denního přídělu (10 000 neuronů) požadavky jen selžou – nic se
neúčtuje a není potřeba platební karta. **Ve výchozím stavu je vše vypnuté.**

## Jak to funguje

1. Jednou denně (11:13 UTC) databáze sama zavolá serverovou funkci
   `recipe-covers` (pg_cron + pg_net). Funkci jde spustit jen tajným klíčem
   plánované úlohy, který je uložený v databázi a nikdy ji neopustí.
2. Databázová funkce `cover_reserve` v jedné transakci se zámkem vybere nejvýš
   5 receptů **bez fotky** (nejstarší první), ohlídá denní limit
   (`daily_limit`, nejvýš 5) a každému založí úlohu (`recipe_cover_jobs`).
   Recept má nejvýš 2 nepovedené pokusy.
3. Funkce vygeneruje jeden obrázek (FLUX.1 schnell, 8 kroků, 1024 × 1024).
4. Nahraje ho do `recipe-photos/<vlastník>/<recept>/<fotka>.jpg` (nebo `.png`)
   s `x-upsert: false` – existující soubor nepřepíše.
5. `cover_attach_if_empty` ho nastaví jako hlavní fotku **jen když recept
   žádnou nemá** – podmínka je přímo v `UPDATE`. Suroviny, postup ani verze
   receptu se nemění. Aplikace i ChatGPT fotku uvidí po synchronizaci.
6. Funkce ověří, že recept má právě tuto fotku a soubor existuje; výsledek
   a případná chyba zůstanou v `recipe_cover_jobs`.

## Ochrana

| Riziko | Ochrana |
|---|---|
| Přepsání existující fotky | `UPDATE … where photos je prázdné`; soubor `x-upsert: false`; kód nikde nemaže |
| Dvojí generování | jedna aktivní úloha na recept (unikátní index), zámek běhu; nahraný obrázek se příště jen dokončí |
| Platba | tarif Workers Free nemá placené překročení – po vyčerpání přídělu chyba 429; ta se nepočítá jako pokus, recept počká na další den |
| Únik klíčů | servisní klíč zůstává v Supabase; Cloudflare token (jen Workers AI) je v Secrets funkce; GitHub žádné klíče nepotřebuje |
| Spuštění cizím | jen s tajným klíčem plánované úlohy; uživatelé ani veřejnost nemají k tabulkám a funkcím přístup |
| Omyl s adresou projektu | servisní klíč se pošle jen na `wjqpzoeheonjwdyyezhb.supabase.co` |
| Jiný (placený) model | v databázi je povolen jen model `@cf/…` (Workers AI) |

## Ovládání (SQL, jen správce)

```sql
update recipe_cover_settings set enabled = true  where id = 1;  -- zapnout
update recipe_cover_settings set enabled = false where id = 1;  -- okamžitě vypnout
update recipe_cover_settings set daily_limit = 3 where id = 1;  -- limit (0–5)
select * from cover_usage();                                     -- přehled
select status, error, created_at from recipe_cover_jobs order by created_at desc limit 20;
```

Zkušební běh bez generování a zápisu: `{"action": "dry-run", "limit": 5}`.

## Před zapnutím

1. Bezplatný účet na cloudflare.com (tarif Free, bez karty).
2. API token s oprávněním **Workers AI – Read** (Profile → API Tokens → Create
   Token → šablona „Workers AI“) a ID účtu (32 znaků, Workers & Pages → vpravo).
3. V Supabase → Edge Functions → Secrets: `COVERS_CF_ACCOUNT_ID`
   a `COVERS_CF_API_TOKEN` (nikdy do repozitáře ani do chatu).
4. Použít migraci `20261118000023_recipe_covers.sql` a nasadit funkci
   `recipe-covers` (bez ověření JWT – přihlašuje se klíčem plánované úlohy).
5. Zkušební běh `dry-run`, pak jeden ostrý obrázek (`daily_limit = 1`),
   kontrola v aplikaci, teprve potom `daily_limit = 5`.

## Testy

- `supabase/functions/recipe-covers/index_test.ts` – generování, JPEG i PNG,
  nahrání bez přepisu, závod s jinou fotkou, odmítnutý požadavek, vyčerpaný
  příděl, přerušené spojení, dokončení bez nového generování, dry-run, klíče
  a oprávnění (Deno, bez sítě).
- `supabase/tests/rls.test.mjs` – migrace v izolované databázi (PGlite):
  vypnutý stav, výběr jen receptů bez fotky, denní limit, odložení,
  2 pokusy, vypínač, zákaz přepsání fotky, neměnnost ostatních receptů,
  oprávnění.

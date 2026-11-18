# Automatické hlavní fotografie receptů

Recepty bez fotky dostanou realistickou fotografii hotového jídla vygenerovanou
přes OpenAI Images API. **Ve výchozím stavu je vše vypnuté.**

## Jak to funguje

1. Jednou denně (11:13 UTC) databáze sama zavolá serverovou funkci
   `recipe-covers` (pg_cron + pg_net). Funkci jde spustit jen tajným klíčem
   plánované úlohy, který je uložený v databázi a nikdy ji neopustí.
2. Databázová funkce `cover_reserve` v jedné transakci se zámkem:
   - vybere nejvýš 5 receptů **bez fotky** (nejstarší první),
   - ohlídá denní limit (`daily_limit`, nejvýš 5) a měsíční rozpočet
     (`monthly_budget_usd`, nejvýš 20 USD),
   - každému receptu založí úlohu (`recipe_cover_jobs`), recept má nejvýš 2 pokusy.
3. Funkce vygeneruje jeden JPEG (výchozí `gpt-image-2`, kvalita `medium`,
   1536 × 1024 – široký formát, který se dobře ořízne na kartu i záhlaví).
4. Nahraje ho do `recipe-photos/<vlastník>/<recept>/<fotka>.jpg`
   s `x-upsert: false` (existující soubor nepřepíše).
5. `cover_attach_if_empty` ho nastaví jako hlavní fotku **jen když recept
   žádnou nemá** – podmínka je přímo v příkazu `UPDATE`. Suroviny, postup ani
   verze receptu se nemění. Aplikace i ChatGPT fotku uvidí po synchronizaci.
6. Funkce ověří, že recept má právě tuto fotku a soubor existuje; výsledek
   a případná chyba zůstanou v `recipe_cover_jobs`.

## Ochrana

| Riziko | Ochrana |
|---|---|
| Přepsání existující fotky | `UPDATE … where photos je prázdné`; soubor `x-upsert: false`; kód nikde nemaže |
| Dvojí generování | jedna aktivní úloha na recept (unikátní index), zámek běhu |
| Dvojí účtování po chybě | nahraný, ale nepřiřazený obrázek se příště jen dokončí; přerušený požadavek se počítá jako zaplacený |
| Překročení rozpočtu | denní limit a měsíční rozpočet v databázi (útrata = počet objednaných obrázků × cena) |
| Únik klíčů | servisní klíč zůstává v Supabase; OpenAI má vlastní klíč `COVERS_OPENAI_API_KEY` jen v Secrets funkce; GitHub žádné klíče nepotřebuje |
| Spuštění cizím | jen s tajným klíčem plánované úlohy; uživatelé ani veřejnost nemají k tabulkám a funkcím přístup |
| Omyl s adresou projektu | servisní klíč se pošle jen na `wjqpzoeheonjwdyyezhb.supabase.co` |

## Náklady (OpenAI, listopad 2026)

| Model | Kvalita | 1536 × 1024 |
|---|---|---|
| gpt-image-2 | medium | ~0,041 USD |
| gpt-image-2 | low | ~0,005 USD |
| GPT Image 1 mini | medium | ~0,015 USD |

Výchozí nastavení: `gpt-image-2`, `medium`, cena pro rozpočet 0,041 USD,
5 fotek denně, rozpočet 2 USD měsíčně. Všech 35 receptů bez fotky ≈ 1,45 USD.
Kvalita `high` je v databázi záměrně zakázaná (4× dražší).

## Ovládání (SQL, jen správce)

```sql
-- zapnout / okamžitě vypnout
update recipe_cover_settings set enabled = true  where id = 1;
update recipe_cover_settings set enabled = false where id = 1;
-- limity
update recipe_cover_settings set daily_limit = 3, monthly_budget_usd = 1.00 where id = 1;
-- útrata a výsledky
select * from cover_usage();
select status, error, created_at from recipe_cover_jobs order by created_at desc limit 20;
```

Zkušební běh bez generování a zápisu: `{"action": "dry-run", "limit": 5}`.

## Před zapnutím

1. V OpenAI založit samostatný projekt s rozpočtovým limitem (např. 3 USD)
   a v něm API klíč.
2. Klíč vložit do Supabase → Edge Functions → Secrets jako
   `COVERS_OPENAI_API_KEY` (nikdy do repozitáře ani do chatu).
3. Použít migraci `20261118000023_recipe_covers.sql` a nasadit funkci
   `recipe-covers` (bez ověření JWT – přihlašuje se klíčem plánované úlohy).
4. Zkušební běh `dry-run`, pak jeden ostrý obrázek (`daily_limit = 1`),
   kontrola v aplikaci, teprve potom `daily_limit = 5`.

## Testy

- `supabase/functions/recipe-covers/index_test.ts` – generování, nahrání,
  závod s jinou fotkou, odmítnutý a přerušený požadavek, dokončení bez
  nového generování, dry-run, klíče a oprávnění (Deno, bez sítě).
- `supabase/tests/rls.test.mjs` – migrace v izolované databázi (PGlite):
  vypnutý stav, výběr jen receptů bez fotky, denní limit, rozpočet, vypínač,
  zákaz přepsání fotky, neměnnost ostatních receptů, oprávnění.

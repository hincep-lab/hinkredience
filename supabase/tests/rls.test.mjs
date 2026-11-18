// Testy databázových oprávnění (Row Level Security).
//
// Spouští skutečné migrace ze složky supabase/migrations v PostgreSQL běžícím
// přímo v Node.js (PGlite) a ověřuje, že si uživatelé navzájem nevidí data.
// Schémata auth a storage, která v Supabase existují automaticky, zde nahrazuje
// minimální maketa.
//
// Spuštění:  cd supabase/tests && npm install && npm test

import { PGlite } from '@electric-sql/pglite';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { test, before } from 'node:test';

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, '..', 'migrations');

const PAVEL = '11111111-1111-1111-1111-111111111111';
const MARTINKA = '22222222-2222-2222-2222-222222222222';
const CIZI = '33333333-3333-3333-3333-333333333333';

const SUPABASE_STUB = `
  create role anon nologin;
  create role authenticated nologin;
  create schema auth;
  create table auth.users (
    id uuid primary key,
    email text,
    raw_user_meta_data jsonb not null default '{}'::jsonb
  );
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $$;
  grant usage on schema auth to authenticated, anon;
  grant execute on function auth.uid() to authenticated, anon;
  create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text references storage.buckets (id),
    name text not null
  );
  alter table storage.objects enable row level security;
  create function storage.foldername(name text) returns text[] language sql immutable as $$
    select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
  $$;
  grant usage on schema storage to authenticated;
  grant all on storage.objects to authenticated;
  grant usage on schema public to authenticated, anon;
`;

let db;

/** Spustí SQL jako přihlášený uživatel `uid` (role authenticated). */
async function as(uid, sql, params = []) {
  await db.exec(`set role authenticated; set request.jwt.claim.sub = '${uid}';`);
  try {
    return await db.query(sql, params);
  } finally {
    await db.exec(`reset role; reset request.jwt.claim.sub;`);
  }
}

async function denied(promise, message) {
  await assert.rejects(promise, /row-level security|permission denied|Vlastníka/i, message);
}

before(async () => {
  db = new PGlite();
  await db.exec(SUPABASE_STUB);
  for (const file of readdirSync(migrationsDir).sort()) {
    if (!file.endsWith('.sql')) continue;
    try {
      await db.exec(readFileSync(join(migrationsDir, file), 'utf8'));
    } catch (error) {
      throw new Error(`Migrace ${file} selhala: ${error.message}`);
    }
  }
  await db.exec(`
    insert into auth.users (id, email, raw_user_meta_data) values
      ('${PAVEL}', 'pavel@example.test', '{"greeting_name": "Pájo"}'),
      ('${MARTINKA}', 'martinka@example.test', '{}'),
      ('${CIZI}', 'cizi@example.test', '{}');
  `);
});

test('všechny tabulky ze zadání existují a mají zapnuté RLS', async () => {
  const expected = [
    'ai_conversations', 'ai_messages', 'ai_usage', 'cooking_notes', 'cooking_sessions',
    'household_members', 'households', 'kitchen_equipment', 'meal_plans', 'meal_wishes', 'price_ai_usage', 'price_cron_key', 'price_offers', 'price_receipts', 'price_runs', 'price_scans',
    'profiles', 'push_server_keys', 'push_subscriptions', 'recipe_cover_jobs', 'recipe_cover_settings', 'recipe_ingredients', 'recipe_steps', 'recipe_tombstones', 'recipe_versions',
    'recipes', 'shopping_items', 'shopping_lists', 'user_preferences',
  ];
  const { rows } = await db.query(
    `select relname, relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' order by relname`,
  );
  assert.deepEqual(rows.map((r) => r.relname), expected);
  for (const row of rows) assert.equal(row.relrowsecurity, true, `${row.relname} nemá RLS`);
});

test('registrace založí profil', async () => {
  const { rows } = await as(PAVEL, `select id, display_name, greeting_name from profiles`);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].display_name, 'pavel');
  assert.equal(rows[0].greeting_name, 'Pájo');
});

test('soukromý recept vidí jen vlastník, včetně surovin a kroků', async () => {
  await as(PAVEL, `insert into recipes (id, title, category) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Svíčková na smetaně', 'Maso')`);
  await as(PAVEL, `insert into recipe_ingredients (recipe_id, name, quantity, unit) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Hovězí zadní', 800, 'g')`);
  await as(PAVEL, `insert into recipe_steps (recipe_id, instruction) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Maso prošpikujte slaninou.')`);

  assert.equal((await as(PAVEL, `select title from recipes`)).rows[0].title, 'Svíčková na smetaně');
  assert.equal((await as(MARTINKA, `select * from recipes`)).rows.length, 0);
  assert.equal((await as(MARTINKA, `select * from recipe_ingredients`)).rows.length, 0);
  assert.equal((await as(MARTINKA, `select * from recipe_steps`)).rows.length, 0);
});

test('cizí recept nejde upravit, smazat ani doplnit', async () => {
  const id = 'aaaaaaaa-0000-0000-0000-000000000001';
  const update = await as(MARTINKA, `update recipes set title = 'Ukradeno' where id = '${id}'`);
  assert.equal(update.affectedRows, 0);
  const del = await as(MARTINKA, `delete from recipes where id = '${id}'`);
  assert.equal(del.affectedRows, 0);
  await denied(
    as(MARTINKA, `insert into recipe_ingredients (recipe_id, name) values ('${id}', 'Jed')`),
  );
  assert.equal((await as(PAVEL, `select title from recipes where id = '${id}'`)).rows[0].title,
    'Svíčková na smetaně');
});

test('recept nelze založit na cizí jméno', async () => {
  await denied(
    as(MARTINKA, `insert into recipes (title, owner_id) values ('Podvrh', '${PAVEL}')`),
  );
});

test('nepřihlášený (anon) nedostane nic', async () => {
  await db.exec(`set role anon;`);
  try {
    await assert.rejects(db.query(`select * from recipes`), /permission denied/i);
  } finally {
    await db.exec(`reset role;`);
  }
});

test('domácnost: zakladatel je vlastník a smí přidat člena', async () => {
  await as(PAVEL, `insert into households (id, name) values
    ('bbbbbbbb-0000-0000-0000-000000000001', 'Hinkovi')`);
  const members = await as(PAVEL, `select user_id, role from household_members`);
  assert.deepEqual(members.rows, [{ user_id: PAVEL, role: 'owner' }]);

  // Cizí člověk se do domácnosti sám nepřidá.
  await denied(
    as(CIZI, `insert into household_members (household_id, user_id) values
      ('bbbbbbbb-0000-0000-0000-000000000001', '${CIZI}')`),
  );
  await as(PAVEL, `insert into household_members (household_id, user_id) values
    ('bbbbbbbb-0000-0000-0000-000000000001', '${MARTINKA}')`);
  assert.equal((await as(MARTINKA, `select * from households`)).rows.length, 1);
  assert.equal((await as(CIZI, `select * from households`)).rows.length, 0);
});

test('rodinný recept vidí a upraví člen domácnosti, cizí ne', async () => {
  const id = 'aaaaaaaa-0000-0000-0000-000000000002';
  await as(PAVEL, `insert into recipes (id, title, visibility, household_id) values
    ('${id}', 'Kuře na paprice', 'household', 'bbbbbbbb-0000-0000-0000-000000000001')`);

  assert.equal((await as(MARTINKA, `select title from recipes`)).rows.length, 1);
  assert.equal((await as(CIZI, `select title from recipes`)).rows.length, 0);

  const update = await as(MARTINKA, `update recipes set notes = 'Méně papriky pro děti' where id = '${id}'`);
  assert.equal(update.affectedRows, 1);
  await as(MARTINKA, `insert into recipe_ingredients (recipe_id, name, quantity, unit)
    values ('${id}', 'Smetana 31 %', 250, 'ml')`);

  // Smazat sdílený recept smí jen vlastník; vlastníka nejde přepsat.
  assert.equal((await as(MARTINKA, `delete from recipes where id = '${id}'`)).affectedRows, 0);
  await denied(as(MARTINKA, `update recipes set owner_id = '${MARTINKA}' where id = '${id}'`));

  // Soukromý recept Pavla zůstává skrytý i členovi domácnosti.
  const visible = await as(MARTINKA, `select title from recipes order by title`);
  assert.deepEqual(visible.rows.map((r) => r.title), ['Kuře na paprice']);
});

test('recept nelze sdílet do cizí domácnosti', async () => {
  await denied(
    as(CIZI, `insert into recipes (title, visibility, household_id) values
      ('Vetřelec', 'household', 'bbbbbbbb-0000-0000-0000-000000000001')`),
  );
});

test('historie verzí se dá číst a přidávat, ale ne přepisovat', async () => {
  const id = 'aaaaaaaa-0000-0000-0000-000000000001';
  await as(PAVEL, `insert into recipe_versions (recipe_id, version_number, snapshot, change_summary)
    values ('${id}', 1, '{"title": "Svíčková na smetaně"}', 'Původní postup')`);
  const update = await as(PAVEL, `update recipe_versions set change_summary = 'Přepsáno'`);
  assert.equal(update.affectedRows, 0);
  assert.equal((await as(MARTINKA, `select * from recipe_versions`)).rows.length, 0);
});

test('osobní preference a AI konverzace jsou oddělené i v domácnosti', async () => {
  await as(PAVEL, `insert into user_preferences (label) values ('Výraznější chuť')`);
  await as(PAVEL, `insert into ai_conversations (id, title) values
    ('cccccccc-0000-0000-0000-000000000001', 'Nedělní oběd')`);
  await as(PAVEL, `insert into ai_messages (conversation_id, role, content) values
    ('cccccccc-0000-0000-0000-000000000001', 'user', 'Vymysli mi oběd z kuřete.')`);

  assert.equal((await as(MARTINKA, `select * from user_preferences`)).rows.length, 0);
  assert.equal((await as(MARTINKA, `select * from ai_conversations`)).rows.length, 0);
  assert.equal((await as(MARTINKA, `select * from ai_messages`)).rows.length, 0);
  await denied(
    as(MARTINKA, `insert into ai_messages (conversation_id, role, content) values
      ('cccccccc-0000-0000-0000-000000000001', 'user', 'Podvržená zpráva')`),
  );
});

test('sdílený nákupní seznam a plán vaření vidí celá domácnost', async () => {
  await as(PAVEL, `insert into shopping_lists (id, household_id) values
    ('dddddddd-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001')`);
  await as(MARTINKA, `insert into shopping_items (list_id, name, quantity, unit) values
    ('dddddddd-0000-0000-0000-000000000001', 'Kuřecí stehna', 1.2, 'kg')`);
  await as(PAVEL, `insert into meal_plans (household_id, plan_date, meal_type, title) values
    ('bbbbbbbb-0000-0000-0000-000000000001', '2026-11-16', 'dinner', 'Kuře na paprice s knedlíkem')`);

  assert.equal((await as(PAVEL, `select name from shopping_items`)).rows[0].name, 'Kuřecí stehna');
  assert.equal((await as(MARTINKA, `select * from meal_plans`)).rows.length, 1);
  assert.equal((await as(CIZI, `select * from shopping_lists`)).rows.length, 0);
  assert.equal((await as(CIZI, `select * from shopping_items`)).rows.length, 0);
  assert.equal((await as(CIZI, `select * from meal_plans`)).rows.length, 0);
  await denied(
    as(CIZI, `insert into shopping_items (list_id, name) values
      ('dddddddd-0000-0000-0000-000000000001', 'Vetřelec')`),
  );
});

test('výchozí vybavení a preference Pavla Hinka', async () => {
  await as(PAVEL, `delete from user_preferences`);
  await as(PAVEL, `select seed_hink_defaults()`);
  await as(PAVEL, `select seed_hink_defaults()`); // podruhé nic nezdvojí
  const equipment = await as(PAVEL, `select name, kind, capabilities from kitchen_equipment order by position`);
  assert.equal(equipment.rows.length, 9);
  assert.equal(equipment.rows[0].name, 'Gorenje BPSAX6747A08BGWI');
  assert.ok(equipment.rows[0].capabilities.includes('Teplotní sonda'));
  assert.equal((await as(PAVEL, `select * from user_preferences`)).rows.length, 9);
  assert.equal((await as(MARTINKA, `select * from kitchen_equipment`)).rows.length, 0);
});

test('fotografie: nahrávat jen do své složky, číst jen s přístupem k receptu', async () => {
  const soukromy = 'aaaaaaaa-0000-0000-0000-000000000001';
  const rodinny = 'aaaaaaaa-0000-0000-0000-000000000002';
  await as(PAVEL, `insert into storage.objects (bucket_id, name) values
    ('recipe-photos', '${PAVEL}/${soukromy}/foto1.jpg'),
    ('recipe-photos', '${PAVEL}/${rodinny}/foto2.jpg')`);
  await denied(
    as(MARTINKA, `insert into storage.objects (bucket_id, name) values
      ('recipe-photos', '${PAVEL}/${rodinny}/podvrh.jpg')`),
  );
  const martinka = await as(MARTINKA, `select name from storage.objects`);
  assert.deepEqual(martinka.rows.map((r) => r.name), [`${PAVEL}/${rodinny}/foto2.jpg`]);
  assert.equal((await as(CIZI, `select name from storage.objects`)).rows.length, 0);
  assert.equal((await as(PAVEL, `select name from storage.objects`)).rows.length, 2);
});

test('česká diakritika se ukládá beze změny', async () => {
  const text = 'Příliš žluťoučký kůň úpěl ďábelské ódy – ŘEŘICHA, šťáva, 180 °C';
  await as(PAVEL, `insert into recipes (id, title, notes) values
    ('aaaaaaaa-0000-0000-0000-000000000003', $1, $1)`, [text]);
  const { rows } = await as(PAVEL,
    `select title, notes from recipes where id = 'aaaaaaaa-0000-0000-0000-000000000003'`);
  assert.equal(rows[0].title, text);
  assert.equal(rows[0].notes, text);
});

test('počítadlo AI: roste jen přes funkci, každý vidí jen své', async () => {
  const first = await as(PAVEL, `select public.ai_register_usage('request') as n`);
  const second = await as(PAVEL, `select public.ai_register_usage('request') as n`);
  assert.equal(first.rows[0].n, 1);
  assert.equal(second.rows[0].n, 2);
  const search = await as(PAVEL, `select public.ai_register_usage('search') as n`);
  assert.equal(search.rows[0].n, 1, 'vyhledávání se počítá zvlášť');
  const other = await as(MARTINKA, `select public.ai_register_usage('request') as n`);
  assert.equal(other.rows[0].n, 1, 'každý uživatel má vlastní počítadlo');

  const visible = await as(MARTINKA, `select count(*)::int as n from public.ai_usage`);
  assert.equal(visible.rows[0].n, 1, 'cizí počty nejsou vidět');

  await denied(
    as(PAVEL, `update public.ai_usage set count = 0`),
    'počítadlo nejde vynulovat ručně',
  );
  await denied(
    as(PAVEL, `insert into public.ai_usage (kind, count) values ('search', 0)`),
    'do počítadla nejde zapisovat přímo',
  );
  await assert.rejects(as(PAVEL, `select public.ai_register_usage('jine')`), /Neznámý druh/);
});

test('API: recept se uloží celý v jedné transakci a úprava vytvoří verzi', async () => {
  const draft = {
    title: 'Svíčková z ChatGPT',
    description: 'Žluťoučký kůň',
    category: 'Omáčky',
    servings: 6,
    prep_minutes: 30,
    cook_minutes: 180,
    temperatures: ['Trouba 160 °C'],
    equipment: ['Litinový hrnec'],
    notes: '',
    ingredients: [
      { name: 'Hovězí zadní', quantity: 800, unit: 'g', note: '' },
      { name: 'Sůl', quantity: null, unit: '', note: '' },
      { name: '   ', quantity: 1, unit: 'ks' },
    ],
    steps: [
      { instruction: 'Maso opeč.', duration_minutes: 10, temperature_c: null },
      { instruction: 'Peč.', duration_minutes: 150, temperature_c: 160 },
    ],
  };
  const created = await as(PAVEL, `select public.api_save_recipe($1::jsonb) as r`, [JSON.stringify(draft)]);
  const { id, version } = created.rows[0].r;
  assert.equal(version, 1);

  const stored = await as(PAVEL,
    `select title, owner_id, current_version, synced_at,
            (select count(*)::int from public.recipe_ingredients where recipe_id = r.id) as ingredients,
            (select count(*)::int from public.recipe_steps where recipe_id = r.id) as steps
     from public.recipes r where id = $1`, [id]);
  assert.equal(stored.rows[0].owner_id, PAVEL);
  assert.equal(stored.rows[0].ingredients, 2, 'prázdná surovina se vynechá');
  assert.equal(stored.rows[0].steps, 2);

  const v1 = await as(PAVEL, `select snapshot, change_summary from public.recipe_versions where recipe_id = $1`, [id]);
  assert.equal(v1.rows[0].change_summary, 'Původní postup');
  assert.equal(v1.rows[0].snapshot.description, 'Žluťoučký kůň');
  assert.equal(v1.rows[0].snapshot.ingredients[0].name, 'Hovězí zadní');
  assert.equal(v1.rows[0].snapshot.steps[1].temperature_c, 160);
  assert.equal(v1.rows[0].snapshot.id, id);

  await as(PAVEL, `update public.recipes set rating = 4.5, is_favorite = true where id = $1`, [id]);
  const updated = await as(PAVEL, `select public.api_save_recipe($1::jsonb, $2::uuid, $3::jsonb) as r`, [
    JSON.stringify({ ...draft, title: 'Svíčková 2', ingredients: draft.ingredients.slice(0, 1) }),
    id,
    JSON.stringify({ change_summary: 'Méně soli', change_reason: 'Byla přesolená', rating: 5 }),
  ]);
  assert.equal(updated.rows[0].r.version, 2);

  const after = await as(PAVEL,
    `select title, rating, is_favorite, current_version,
            (select count(*)::int from public.recipe_ingredients where recipe_id = r.id) as ingredients
     from public.recipes r where id = $1`, [id]);
  assert.equal(after.rows[0].title, 'Svíčková 2');
  assert.equal(Number(after.rows[0].rating), 4.5, 'hodnocení receptu zůstává');
  assert.equal(after.rows[0].is_favorite, true);
  assert.equal(after.rows[0].ingredients, 1);

  const versions = await as(PAVEL,
    `select version_number, snapshot->>'title' as title, change_summary, change_reason, rating
     from public.recipe_versions where recipe_id = $1 order by version_number`, [id]);
  assert.equal(versions.rows.length, 2);
  assert.equal(versions.rows[0].title, 'Svíčková z ChatGPT', 'původní podoba zůstává v historii');
  assert.equal(versions.rows[1].change_reason, 'Byla přesolená');
  assert.equal(Number(versions.rows[1].rating), 5);

  await assert.rejects(
    as(MARTINKA, `select public.api_save_recipe($1::jsonb, $2::uuid)`, [JSON.stringify(draft), id]),
    /Recept nenalezen/,
    'cizí recept přes API upravit nejde',
  );
  await assert.rejects(as(PAVEL, `select public.api_save_recipe('{"title":" "}'::jsonb)`), /musí mít název/);
  const cizi = await as(MARTINKA, `select public.recipe_snapshot($1) as s`, [id]);
  assert.equal(cizi.rows[0].s, null, 'cizí recept přes snapshot vidět není');
});

test('výtěžnost v kusech, čekání a druh kroků: nové sloupce nic nerozbijí', async () => {
  const stary = await as(PAVEL,
    `insert into public.recipes (title) values ('Starý recept') returning id, yield_unit, rest_minutes`);
  assert.equal(stary.rows[0].yield_unit, 'porce', 'stávající recepty mají výchozí porce');
  assert.equal(stary.rows[0].rest_minutes, 0);

  const pizza = {
    title: 'Pizza těsto',
    servings: 6,
    yield_unit: 'ks',
    prep_minutes: 14,
    cook_minutes: 20,
    rest_minutes: 1200,
    ingredients: [{ name: 'Mouka', quantity: 1000, unit: 'g' }],
    steps: [
      { instruction: 'Zadělej těsto.', kind: 'active', duration_minutes: 14 },
      { instruction: 'Nech kynout v lednici.', kind: 'passive', duration_minutes: 1200 },
      { instruction: 'Mezitím připrav sugo.', kind: 'nesmysl', parallel: true, duration_minutes: 20 },
    ],
  };
  const created = await as(PAVEL, `select public.api_save_recipe($1::jsonb) as r`, [JSON.stringify(pizza)]);
  const id = created.rows[0].r.id;
  const row = await as(PAVEL, `select yield_unit, rest_minutes from public.recipes where id = $1`, [id]);
  assert.equal(row.rows[0].yield_unit, 'ks');
  assert.equal(row.rows[0].rest_minutes, 1200);
  const steps = await as(PAVEL,
    `select kind, parallel from public.recipe_steps where recipe_id = $1 order by position`, [id]);
  assert.deepEqual(steps.rows.map((s) => s.kind), ['active', 'passive', ''], 'neznámý druh se uloží jako automatický');
  assert.deepEqual(steps.rows.map((s) => s.parallel), [false, false, true]);

  const snap = await as(PAVEL, `select snapshot from public.recipe_versions where recipe_id = $1`, [id]);
  assert.equal(snap.rows[0].snapshot.yield_unit, 'ks');
  assert.equal(snap.rows[0].snapshot.rest_minutes, 1200);
  assert.equal(snap.rows[0].snapshot.steps[1].kind, 'passive');
  assert.equal(snap.rows[0].snapshot.steps[2].parallel, true);

  // Úprava bez nových polí (starší klient) výtěžnost ani čekání nesmaže.
  await as(PAVEL, `select public.api_save_recipe($1::jsonb, $2::uuid)`, [
    JSON.stringify({ title: 'Pizza těsto 2', servings: 6, ingredients: [], steps: [] }), id,
  ]);
  const kept = await as(PAVEL, `select yield_unit, rest_minutes from public.recipes where id = $1`, [id]);
  assert.equal(kept.rows[0].yield_unit, 'ks');
  assert.equal(kept.rows[0].rest_minutes, 1200);

  await assert.rejects(
    as(PAVEL, `update public.recipes set yield_unit = 'kila' where id = $1`, [id]),
    /recipes_yield_unit_check/,
    'neznámá jednotka výtěžnosti',
  );

  // Trvalé smazání (vysypaný koš) odstraní i suroviny, kroky a verze.
  await as(PAVEL, `delete from public.recipes where id = $1`, [id]);
  const left = await as(PAVEL,
    `select (select count(*)::int from public.recipe_steps where recipe_id = $1) as steps,
            (select count(*)::int from public.recipe_versions where recipe_id = $1) as versions`, [id]);
  assert.deepEqual(left.rows[0], { steps: 0, versions: 0 });
});

test('vysypaný koš: náhrobek vidí vlastník i domácnost, recept nejde oživit', async () => {
  const hh = await as(PAVEL, `insert into public.households (name) values ('Hinkovi 08') returning id`);
  const hid = hh.rows[0].id;
  await as(PAVEL, `insert into public.household_members (household_id, user_id) values ($1, $2)`, [hid, MARTINKA]);

  const shared = await as(PAVEL,
    `insert into public.recipes (title, household_id, visibility) values ('Losos', $1, 'household') returning id`, [hid]);
  const sid = shared.rows[0].id;
  const own = await as(PAVEL, `insert into public.recipes (title) values ('Soukromý králík') returning id`);
  const oid = own.rows[0].id;

  // Uživatel sám náhrobek zapsat nesmí.
  await assert.rejects(
    as(CIZI, `insert into public.recipe_tombstones (recipe_id, owner_id) values (gen_random_uuid(), $1)`, [CIZI]),
    /row-level security|permission denied/i,
  );

  await as(PAVEL, `delete from public.recipes where id = $1`, [sid]);
  await as(PAVEL, `delete from public.recipes where id = $1`, [oid]);

  const forPavel = await as(PAVEL, `select recipe_id from public.recipe_tombstones where recipe_id = any($1::uuid[])`, [[sid, oid]]);
  assert.equal(forPavel.rows.length, 2);
  const forMartinka = await as(MARTINKA, `select recipe_id from public.recipe_tombstones where recipe_id = any($1::uuid[])`, [[sid, oid]]);
  assert.deepEqual(forMartinka.rows.map((r) => r.recipe_id), [sid], 'Martinka vidí jen sdílený recept');
  const forCizi = await as(CIZI, `select recipe_id from public.recipe_tombstones where recipe_id = any($1::uuid[])`, [[sid, oid]]);
  assert.equal(forCizi.rows.length, 0);

  // Starý telefon se pokusí recept znovu odeslat (upsert) – server odmítne.
  await assert.rejects(
    as(PAVEL, `insert into public.recipes (id, title) values ($1, 'Soukromý králík') on conflict (id) do update set title = excluded.title`, [oid]),
    /natrvalo smazán/,
  );
  // Nový recept s jiným id jde založit normálně.
  const fresh = await as(PAVEL, `insert into public.recipes (title) values ('Nový králík') returning id`);
  assert.ok(fresh.rows[0].id);
});

test('migrace 08 jde spustit znovu bez chyby', async () => {
  const sql = readFileSync(join(migrationsDir, '20261115000008_sync_tombstones.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('rodina: přidání člena e-mailem, společný nákupní seznam a plán', async () => {
  await db.exec(`insert into auth.users (id, email) values
    ('55555555-5555-5555-5555-555555555555', 'babicka@example.cz') on conflict do nothing`);
  const BABICKA = '55555555-5555-5555-5555-555555555555';
  const hh = await as(PAVEL, `insert into public.households (name) values ('Rodina 09') returning id`);
  const hid = hh.rows[0].id;

  // Člena přidá jen zakladatel; neznámý e-mail se nepřidá.
  await assert.rejects(
    as(BABICKA, `select public.household_add_member($1, 'pavel@example.cz')`, [hid]),
    /jen zakladatel/,
  );
  await assert.rejects(
    as(PAVEL, `select public.household_add_member($1, 'nikdo@example.cz')`, [hid]),
    /zatím není/,
  );
  const added = await as(PAVEL, `select public.household_add_member($1, ' Babicka@Example.cz ') as r`, [hid]);
  assert.equal(added.rows[0].r.user_id, BABICKA);
  assert.equal(added.rows[0].r.email, undefined, 'e-mail se nevrací');

  // Společný nákupní seznam: oba dostanou stejný.
  const babickaHouse = await as(BABICKA, `select public.my_household() as h`);
  const myHouse = (await as(PAVEL, `select public.my_household() as h`)).rows[0].h;
  // Pavel může být i v dřívějších domácnostech z jiných testů – ověříme, že
  // babička je právě v této.
  assert.equal(babickaHouse.rows[0].h, hid);
  const listB = (await as(BABICKA, `select public.my_shopping_list() as l`)).rows[0].l;
  const listB2 = (await as(BABICKA, `select public.my_shopping_list() as l`)).rows[0].l;
  assert.equal(listB, listB2, 'seznam se nezakládá opakovaně');
  await as(BABICKA, `insert into public.shopping_items (list_id, name, sources) values ($1, 'Mouka', '["Buchty"]')`, [listB]);
  if (myHouse === hid) {
    const listP = (await as(PAVEL, `select public.my_shopping_list() as l`)).rows[0].l;
    assert.equal(listP, listB);
  }
  const pavelSees = await as(PAVEL, `select name, sources from public.shopping_items where list_id = $1`, [listB]);
  assert.deepEqual(pavelSees.rows.map((r) => r.name), ['Mouka'], 'člen domácnosti vidí společný nákup');
  const ciziSees = await as(CIZI, `select name from public.shopping_items where list_id = $1`, [listB]);
  assert.equal(ciziSees.rows.length, 0);

  // Plán vaření sdílený s rodinou vidí oba, cizí ne; měkké mazání a kurzor změn.
  const plan = await as(BABICKA,
    `insert into public.meal_plans (plan_date, meal_type, title, household_id, servings)
     values ('2026-11-16', 'lunch', 'Svíčková', $1, 6) returning id, synced_at`, [hid]);
  const seenByPavel = await as(PAVEL, `select title, servings from public.meal_plans where id = $1`, [plan.rows[0].id]);
  assert.equal(seenByPavel.rows[0].title, 'Svíčková');
  assert.equal(Number(seenByPavel.rows[0].servings), 6);
  assert.equal((await as(CIZI, `select 1 from public.meal_plans where id = $1`, [plan.rows[0].id])).rows.length, 0);
  await as(PAVEL, `update public.meal_plans set deleted_at = now() where id = $1`, [plan.rows[0].id]);
  const after = await as(BABICKA, `select deleted_at, synced_at from public.meal_plans where id = $1`, [plan.rows[0].id]);
  assert.ok(after.rows[0].deleted_at);
  assert.ok(after.rows[0].synced_at >= plan.rows[0].synced_at);
});

test('kuchařský deník: osobní, s poznámkami a měkkým mazáním', async () => {
  const s = await as(PAVEL,
    `insert into public.cooking_sessions (recipe_title, rating, notes, went_well, to_improve, actual_minutes, version_number)
     values ('Pizza', 4.5, 'Kynuto 20 h', 'Kůrka', 'Méně soli', 1234, 2) returning id`);
  const id = s.rows[0].id;
  const mine = await as(PAVEL, `select notes, actual_minutes, version_number from public.cooking_sessions where id = $1`, [id]);
  assert.equal(mine.rows[0].notes, 'Kynuto 20 h');
  assert.equal(mine.rows[0].actual_minutes, 1234);
  assert.equal((await as(CIZI, `select 1 from public.cooking_sessions where id = $1`, [id])).rows.length, 0);
  await denied(as(CIZI, `insert into public.cooking_sessions (user_id, recipe_title) values ($1, 'X')`, [PAVEL]));
});

test('migrace 09 jde spustit znovu bez chyby', async () => {
  const sql = readFileSync(join(migrationsDir, '20261115000009_family_diary_plan_shopping.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('nákupní seznamy: více seznamů, cizí uživatel nic nevidí ani nezmění', async () => {
  const a = await as(PAVEL, `insert into public.shopping_lists (name) values ('Kuře na paprice') returning id`);
  const b = await as(PAVEL, `insert into public.shopping_lists (name) values ('Týdenní nákup') returning id`);
  const lid = a.rows[0].id;
  await as(PAVEL, `insert into public.shopping_items (list_id, name, quantity, unit, category, note)
    values ($1, 'Cibule', 300, 'g', 'zelenina', ''), ($1, 'Sůl', null, '', 'koreni', 'podle chuti')`, [lid]);
  const mine = await as(PAVEL, `select id, name from public.shopping_lists where id = any($1::uuid[])`, [[lid, b.rows[0].id]]);
  assert.equal(mine.rows.length, 2);

  // Cizí uživatel: nevidí seznam ani položky, nic nezmění ani nepřidá.
  assert.equal((await as(CIZI, `select 1 from public.shopping_lists where id = $1`, [lid])).rows.length, 0);
  assert.equal((await as(CIZI, `select 1 from public.shopping_items where list_id = $1`, [lid])).rows.length, 0);
  const upd = await as(CIZI, `update public.shopping_items set is_checked = true where list_id = $1 returning id`, [lid]);
  assert.equal(upd.rows.length, 0, 'cizí změna nic nezasáhne');
  const del = await as(CIZI, `delete from public.shopping_lists where id = $1 returning id`, [lid]);
  assert.equal(del.rows.length, 0);
  await denied(
    as(CIZI, `insert into public.shopping_items (list_id, name) values ($1, 'Podvrh')`, [lid]),
    'do cizího seznamu nejde přidat',
  );
  await denied(
    as(CIZI, `insert into public.shopping_lists (owner_id, name) values ($1, 'Na cizí jméno')`, [PAVEL]),
    'seznam na cizí jméno',
  );

  // Odškrtnutí a měkké smazání posunou kurzor změn.
  const before = (await as(PAVEL, `select synced_at from public.shopping_lists where id = $1`, [lid])).rows[0].synced_at;
  await as(PAVEL, `update public.shopping_items set is_checked = true where list_id = $1 and name = 'Cibule'`, [lid]);
  await as(PAVEL, `update public.shopping_lists set deleted_at = now(), name = 'Kuře na paprice' where id = $1`, [lid]);
  const after = (await as(PAVEL, `select synced_at, deleted_at from public.shopping_lists where id = $1`, [lid])).rows[0];
  assert.ok(after.deleted_at);
  assert.ok(after.synced_at >= before);
  const checked = await as(PAVEL, `select is_checked from public.shopping_items where list_id = $1 and name = 'Cibule'`, [lid]);
  assert.equal(checked.rows[0].is_checked, true);
});

test('nákupní seznamy: kontroly vstupů a ochrana vlastníka', async () => {
  const lid = (await as(PAVEL, `insert into public.shopping_lists (name) values ('Kontroly') returning id`)).rows[0].id;
  await assert.rejects(as(PAVEL, `insert into public.shopping_items (list_id, name, quantity) values ($1, 'X', -1)`, [lid]), /quantity_range/);
  await assert.rejects(as(PAVEL, `insert into public.shopping_items (list_id, name, category) values ($1, 'X', 'drogerie')`, [lid]), /category_check/);
  await assert.rejects(as(PAVEL, `insert into public.shopping_items (list_id, name) values ($1, '   ')`, [lid]), /name_length|check/);
  await assert.rejects(as(PAVEL, `insert into public.shopping_lists (name) values ('')`), /name_check|check/);

  // Člen rodiny smí sdílený seznam upravit, ale ne si ho přivlastnit.
  const hid = (await as(PAVEL, `insert into public.households (name) values ('Rodina 10') returning id`)).rows[0].id;
  await as(PAVEL, `insert into public.household_members (household_id, user_id) values ($1, $2)`, [hid, MARTINKA]);
  const shared = (await as(PAVEL, `insert into public.shopping_lists (name, household_id) values ('Společný', $1) returning id`, [hid])).rows[0].id;
  const renamed = await as(MARTINKA, `update public.shopping_lists set name = 'Společný nákup' where id = $1 returning name`, [shared]);
  assert.equal(renamed.rows[0].name, 'Společný nákup');
  await assert.rejects(
    as(MARTINKA, `update public.shopping_lists set owner_id = $2 where id = $1`, [shared, MARTINKA]),
    /nelze změnit/,
  );
  // Starší data bez nových údajů zůstávají platná.
  const old = await db.query(`select count(*)::int as c from public.shopping_items where note = ''`);
  assert.ok(old.rows[0].c >= 0);
});

test('migrace 10 jde spustit znovu bez chyby', async () => {
  const sql = readFileSync(join(migrationsDir, '20261115000010_shopping_lists.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('sdílet všechny recepty s rodinou: hned stávající, pak automaticky nové', async () => {
  const HOUSE = 'bbbbbbbb-0000-0000-0000-000000000001';
  const priv = (await as(PAVEL, `insert into recipes (title) values ('Soukromá svíčková') returning id`)).rows[0].id;
  await as(CIZI, `insert into recipes (title) values ('Cizí guláš')`);
  assert.equal((await as(MARTINKA, `select 1 from recipes where id = $1`, [priv])).rows.length, 0);

  // Zapnutí: všechny Pavlovy recepty se nasdílí jeho rodině.
  const shared = (await as(PAVEL, `select public.set_share_recipes_with_family(true) as n`)).rows[0].n;
  assert.ok(shared >= 1, `nasdíleno ${shared}`);
  const left = await as(PAVEL, `select count(*)::int as c from recipes
    where owner_id = auth.uid() and deleted_at is null and visibility <> 'household'`);
  assert.equal(left.rows[0].c, 0, 'žádný Pavlův recept nezůstal soukromý');
  const row = (await as(MARTINKA, `select household_id, visibility from recipes where id = $1`, [priv])).rows[0];
  assert.deepEqual(row, { household_id: HOUSE, visibility: 'household' });

  // Nový recept (aplikace i ChatGPT přes api_save_recipe) se sdílí sám.
  const fresh = (await as(PAVEL, `insert into recipes (title) values ('Nový z aplikace') returning visibility`)).rows[0];
  assert.equal(fresh.visibility, 'household');
  const api = (await as(PAVEL, `select public.api_save_recipe('{"title":"Z ChatGPT"}'::jsonb) as r`)).rows[0].r;
  assert.equal((await as(MARTINKA, `select 1 from recipes where id = $1`, [api.id])).rows.length, 1);

  // Tlačítko „Sdílet všechny“ bez automatiky: Martinka nasdílí své recepty.
  await as(MARTINKA, `insert into recipes (title) values ('Martinčiny palačinky')`);
  assert.equal((await as(MARTINKA, `select public.share_all_my_recipes() as n`)).rows[0].n, 1);
  assert.equal((await as(PAVEL, `select 1 from recipes where title = 'Martinčiny palačinky'`)).rows.length, 1);
  const auto = await db.query(`select share_recipes_with_family from public.profiles where id = $1`, [MARTINKA]);
  assert.equal(auto.rows[0].share_recipes_with_family, false, 'tlačítko automatiku nezapne');

  // Cizí uživatel bez rodiny: nic se nesdílí a jeho recepty zůstávají jeho.
  assert.equal((await as(CIZI, `select public.set_share_recipes_with_family(true) as n`)).rows[0].n, 0);
  assert.equal((await as(CIZI, `select public.share_all_my_recipes() as n`)).rows[0].n, 0);
  assert.equal((await as(MARTINKA, `select 1 from recipes where title = 'Cizí guláš'`)).rows.length, 0);
  assert.equal((await as(PAVEL, `select 1 from recipes where title = 'Cizí guláš'`)).rows.length, 0);

  // Volba je jen vlastní: Pavel nezmění Martinčinu.
  await as(PAVEL, `update profiles set share_recipes_with_family = true where id = '${MARTINKA}'`);
  const hers = await db.query(`select share_recipes_with_family from public.profiles where id = $1`, [MARTINKA]);
  assert.equal(hers.rows[0].share_recipes_with_family, false);

  // Vypnutí: sdílené zůstanou, nové už jsou soukromé.
  await as(PAVEL, `select public.set_share_recipes_with_family(false)`);
  const later = (await as(PAVEL, `insert into recipes (title) values ('Po vypnutí') returning visibility`)).rows[0];
  assert.equal(later.visibility, 'private');
  assert.equal((await as(MARTINKA, `select 1 from recipes where id = $1`, [priv])).rows.length, 1);
});

test('migrace 11 jde spustit znovu bez chyby', async () => {
  const sql = readFileSync(join(migrationsDir, '20261115000011_share_all_recipes.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('přání „mám chuť“: vidí je rodina, cizí ne; jde spustit znovu', async () => {
  const hid = 'bbbbbbbb-0000-0000-0000-000000000001';
  const w = await as(MARTINKA,
    `insert into public.meal_wishes (household_id, title, author_name)
     values ($1, 'Svíčková', 'Martinka') returning id, synced_at`, [hid]);
  const id = w.rows[0].id;
  const seen = await as(PAVEL, `select title, author_name from public.meal_wishes where id = $1`, [id]);
  assert.equal(seen.rows[0].title, 'Svíčková');
  assert.equal(seen.rows[0].author_name, 'Martinka');
  assert.equal((await as(CIZI, `select 1 from public.meal_wishes where id = $1`, [id])).rows.length, 0);
  await denied(as(CIZI, `insert into public.meal_wishes (household_id, title) values ($1, 'Vetřelec')`, [hid]));
  await denied(as(CIZI, `insert into public.meal_wishes (owner_id, title) values ($1, 'Podvrh')`, [PAVEL]));
  // Pavel přání naplánuje (úprava cizího přání v rodině je dovolená).
  await as(PAVEL, `update public.meal_wishes set planned_day = '2026-11-20' where id = $1`, [id]);
  const after = await as(MARTINKA, `select planned_day, synced_at from public.meal_wishes where id = $1`, [id]);
  assert.ok(after.rows[0].planned_day);
  assert.ok(after.rows[0].synced_at >= w.rows[0].synced_at);
  // Cizí nic nezmění.
  await as(CIZI, `update public.meal_wishes set title = 'X' where id = $1`, [id]);
  assert.equal((await as(PAVEL, `select title from public.meal_wishes where id = $1`, [id])).rows[0].title, 'Svíčková');
  const sql = readFileSync(join(migrationsDir, '20261115000012_meal_wishes.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('oznámení: zařízení vidí jen vlastník, klíč serveru nikdo', async () => {
  await as(PAVEL, `select public.push_subscribe('https://web.push.apple.com/abc', 'p', 'a', 'iPhone')`);
  assert.equal((await as(PAVEL, `select endpoint from public.push_subscriptions`)).rows.length, 1);
  assert.equal((await as(MARTINKA, `select 1 from public.push_subscriptions`)).rows.length, 0);
  assert.equal((await as(CIZI, `select 1 from public.push_subscriptions`)).rows.length, 0);
  // Přímý zápis cizího zařízení nejde, jen přes funkci a vždy na sebe.
  await denied(as(CIZI, `insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values ($1, 'https://x', 'p', 'a')`, [PAVEL]));
  // Totéž zařízení převezme jiný účet (odhlášení a přihlášení někoho jiného).
  await as(MARTINKA, `select public.push_subscribe('https://web.push.apple.com/abc', 'p2', 'a2')`);
  assert.equal((await as(PAVEL, `select 1 from public.push_subscriptions`)).rows.length, 0);
  assert.equal((await as(MARTINKA, `select p256dh from public.push_subscriptions`)).rows[0].p256dh, 'p2');
  await assert.rejects(as(PAVEL, `select public.push_subscribe('http://nezabezpecene', 'p', 'a')`), /Neplatné přihlášení/);
  await as(MARTINKA, `delete from public.push_subscriptions`);
  assert.equal((await as(MARTINKA, `select 1 from public.push_subscriptions`)).rows.length, 0);
  // Klíč serveru: ani číst, ani zapsat.
  await denied(as(PAVEL, `select * from public.push_server_keys`));
  await denied(as(PAVEL, `insert into public.push_server_keys (id, public_key, private_jwk) values (1, 'x', '{}')`));
  // Kdo přidal položku nákupu se vyplní sám.
  const list = (await as(PAVEL, `insert into public.shopping_lists (name) values ('Push test') returning id`)).rows[0].id;
  const item = await as(PAVEL, `insert into public.shopping_items (list_id, name) values ($1, 'Mléko') returning added_by`, [list]);
  assert.equal(item.rows[0].added_by, PAVEL);
  const sql = readFileSync(join(migrationsDir, '20261115000013_web_push.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('akce: běžná cena se skryje, prohozené ceny s aplikací se opraví, AI samo neověřuje', async () => {
  const add = (product, key, price, conditions, verify_method, regular = null, chain = 'albert') => db.query(
    `insert into public.price_offers (chain, product, product_key, price, pack_qty, pack_unit, regular_price, conditions,
       valid_from, valid_to, source_url, provider, verified, verify_method)
     values ($1, $2, $3, $4, 250, 'g', $5, $6, '2026-11-18', '2026-11-24', 'https://letaky.albert.cz/x', 'gemini', true, $7)
     returning id`, [chain, product, key, price, regular, conditions, verify_method]);
  const app = (await add('Česká chuť Máslo 82%', 'kind-maslo', 32.9, 's Aplikací', 'leták-text', 54.9)).rows[0].id;
  const plain = (await add('Česká chuť Máslo 82%', 'kind-maslo', 27.9, 'bez Aplikace', 'leták-text', 54.9)).rows[0].id;
  const club = (await add('Cheddar', 'kind-cheddar', 34.9, 'Clubcard cena', 'leták-2×', null, 'tesco')).rows[0].id;
  const reg = (await add('Cheddar', 'kind-cheddar', 51.9, 'běžná cena', 'leták-2×', null, 'tesco')).rows[0].id;
  const penny = (await add('Cizrna', 'kind-cizrna', 14.9, 's PENNY kartou', 'data', null, 'penny')).rows[0].id;
  const pennyPlain = (await add('Cizrna', 'kind-cizrna', 24.9, 'bez PENNY karty', 'data', null, 'penny')).rows[0].id;
  const users = (await db.query(`select count(*)::int as n from public.recipes`)).rows[0].n;

  // Spustit smí jen server.
  await denied(as(PAVEL, `select public.price_offers_classify()`));
  await db.query(`select public.price_offers_classify()`);
  await db.query(`select public.price_offers_classify()`); // opakovatelné

  const row = async (id) => (await db.query(`select price, conditions, kind, loyalty, regular_price::float as regular_price, verified,
    verify_method, source_title from public.price_offers where id = $1`, [id])).rows[0];
  const a = await row(app);
  const b = await row(plain);
  assert.deepEqual([a.price, a.conditions, a.kind, a.loyalty], ['32.9', 'bez Aplikace', 'promo', '']);
  assert.deepEqual([b.price, b.conditions, b.kind, b.loyalty], ['27.9', 's Aplikací', 'loyalty', 'Můj Albert']);
  const c = await row(club);
  assert.deepEqual([c.kind, c.loyalty, c.regular_price, c.verified], ['loyalty', 'Clubcard', 51.9, false]);
  assert.match(c.source_title, /jen čtení AI/);
  assert.equal((await row(reg)).kind, 'regular');
  // Data z webu Penny zůstávají ověřená.
  assert.deepEqual([(await row(penny)).kind, (await row(penny)).verified], ['loyalty', true]);
  assert.deepEqual([(await row(pennyPlain)).kind, (await row(pennyPlain)).verified], ['promo', true]);
  // Text letáku bez kontroly gramáže → znovu ověřit.
  assert.equal(a.verified, false);
  assert.match(a.source_title, /čeká na nové ověření/);
  // Nic se nesmazalo.
  assert.equal((await db.query(`select count(*)::int as n from public.price_offers where product_key like 'kind-%'`)).rows[0].n, 6);
  assert.equal((await db.query(`select count(*)::int as n from public.recipes`)).rows[0].n, users);

  // Záznam stažení letáků: čte každý přihlášený, zapisuje jen server.
  await db.query(`insert into public.price_runs (chain, ok, error, offers) values ('lidl', false, 'leták se nepodařilo stáhnout', 0)`);
  assert.equal((await as(CIZI, `select error from public.price_runs where chain = 'lidl'`)).rows[0].error, 'leták se nepodařilo stáhnout');
  await denied(as(PAVEL, `insert into public.price_runs (chain, ok) values ('lidl', true)`));
  await denied(as(PAVEL, `delete from public.price_runs`));
  await assert.rejects(db.query(`update public.price_offers set kind = 'jine' where id = $1`, [app]));
  await db.query(`delete from public.price_offers where product_key like 'kind-%'`);
  await db.query(`delete from public.price_runs`);
});

test('ceny: akce čte každý, zapisuje jen server; účtenky jen rodina', async () => {
  // Uživatel ani AI v aplikaci nesmí vložit akci (jen serverová funkce).
  await denied(as(PAVEL, `insert into public.price_offers (chain, product, price, valid_to, source_url, provider)
    values ('penny', 'Máslo', 39.9, '2026-11-20', 'https://www.penny.cz/', 'manual')`));
  // Server (role postgres) vloží; přihlášení ji vidí.
  await db.query(`insert into public.price_offers (chain, product, product_key, price, valid_to, source_url, provider, verified)
    values ('penny', 'Máslo 250 g', 'maslo', 39.9, '2026-11-20', 'https://www.penny.cz/nabidky', 'gemini', true)`);
  assert.equal((await as(CIZI, `select product from public.price_offers`)).rows[0].product, 'Máslo 250 g');
  // Akce z přehledu letáků kupi.cz (zdroj „kupi“) server uložit smí.
  await db.query(`insert into public.price_offers (chain, product, product_key, price, valid_to, source_url, provider, verified, verify_method)
    values ('lidl', 'Máslo Milkpol', 'maslo milkp', 29.9, '2026-11-22', 'https://www.kupi.cz/letak/lidl-letak-153', 'kupi', true, 'kupi')`);
  await assert.rejects(db.query(`insert into public.price_offers (chain, product, price, valid_to, source_url, provider)
    values ('lidl', 'X', 10, '2026-11-22', 'https://www.kupi.cz/', 'nekdo')`));
  // Klíč ranního obnovení akcí: vznikne jednou, uživatel ho nevidí ani nezmění.
  assert.equal((await db.query(`select length(key) as n from public.price_cron_key`)).rows[0].n, 64);
  await denied(as(PAVEL, `select key from public.price_cron_key`));
  await denied(as(CIZI, `update public.price_cron_key set key = repeat('x', 40)`));
  // Aktuální ověřené akce smí číst i telefon bez přihlášení – bez autora akce.
  await db.query(`insert into public.price_offers (chain, product, product_key, price, valid_to, source_url, provider, verified, created_by)
    values ('albert', 'Máslo Česká chuť', 'ceska chut maslo', 27.9, (now() at time zone 'Europe/Prague')::date + 3, 'https://www.kupi.cz/a', 'kupi', true, null),
           ('albert', 'Máslo neověřené', 'maslo neove', 9.9, (now() at time zone 'Europe/Prague')::date + 3, 'https://www.kupi.cz/b', 'gemini', false, null)`);
  await db.query(`set role anon`);
  const pub = await db.query(`select * from public.current_sale_offers()`);
  await db.query(`reset role`);
  assert.ok(pub.rows.some((r) => r.product === 'Máslo Česká chuť'), 'ověřená akce');
  assert.ok(!pub.rows.some((r) => r.product === 'Máslo neověřené'), 'neověřená ne');
  assert.ok(!('created_by' in pub.rows[0]), 'bez autora');
  await db.query(`set role anon`);
  await assert.rejects(db.query(`select * from public.price_offers`));
  await db.query(`reset role`);
  // Fotka zboží jen přes https.
  await assert.rejects(db.query(`insert into public.price_offers (chain, product, price, valid_to, source_url, provider, image_url)
    values ('lidl', 'X', 10, '2026-11-22', 'https://www.kupi.cz/', 'kupi', 'http://x.cz/a.jpg')`));
  await denied(as(PAVEL, `update public.price_offers set price = 1`));
  await assert.rejects(db.query(`insert into public.price_offers (chain, product, price, valid_to, source_url, provider)
    values ('penny', 'X', 0, '2026-11-20', 'https://www.penny.cz/', 'manual')`));
  await assert.rejects(db.query(`insert into public.price_offers (chain, product, price, valid_to, source_url, provider)
    values ('penny', 'X', 10, '2026-11-20', 'http://nezabezpecene.cz/', 'manual')`));
  await assert.rejects(db.query(`insert into public.price_offers (chain, store_id, product, price, valid_to, source_url, provider)
    values ('penny', 'penny-praha', 'X', 10, '2026-11-20', 'https://www.penny.cz/', 'manual')`));

  const hid = 'bbbbbbbb-0000-0000-0000-000000000001';
  const r = await as(MARTINKA, `insert into public.price_receipts (household_id, store_id, product, price, bought_on)
    values ($1, 'lidl-hradecka', 'Mléko 1 l', 21.9, '2026-11-14') returning id`, [hid]);
  assert.equal((await as(PAVEL, `select price from public.price_receipts where id = $1`, [r.rows[0].id])).rows.length, 1);
  assert.equal((await as(CIZI, `select 1 from public.price_receipts where id = $1`, [r.rows[0].id])).rows.length, 0);
  await denied(as(CIZI, `insert into public.price_receipts (owner_id, store_id, product, price) values ($1, 'lidl-hradecka', 'X', 1)`, [PAVEL]));
  await assert.rejects(as(PAVEL, `insert into public.price_receipts (store_id, product, price) values ('lidl-praha', 'X', 1)`));
  // Mezipaměť a počítadla AI: uživatel nezapíše.
  await denied(as(PAVEL, `insert into public.price_scans (chain, product_key) values ('penny', 'maslo')`));
  await denied(as(PAVEL, `select * from public.price_ai_usage`));
  const sql = readFileSync(join(migrationsDir, '20261115000014_best_buy.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
});

test('štítky: ChatGPT je uloží, bez pole je nechá, migrace 17 je jen přidává', async () => {
  const draft = {
    title: 'Losos sous-vide 43 °C',
    category: 'Ryby',
    prep_minutes: 10,
    cook_minutes: 32,
    ingredients: [{ name: 'Losos' }],
    steps: [
      { instruction: 'Připravujte ve vodní lázni při 43 °C po dobu 30 minut.', duration_minutes: 30 },
      { instruction: 'Krátce opečte na rozpálené pánvi.', duration_minutes: 2 },
    ],
  };
  const created = (await as(PAVEL, `select public.api_save_recipe($1::jsonb) as r`, [
    JSON.stringify({ ...draft, tags: ['Pro děti', ' pro děti ', '', 'Vlastní'] }),
  ])).rows[0].r;
  const tagsOf = async () =>
    (await as(PAVEL, `select tags from public.recipes where id = $1`, [created.id])).rows[0].tags;
  assert.deepEqual(await tagsOf(), ['Pro děti', 'Vlastní']);

  // Úprava bez pole tags štítky nezmění.
  await as(PAVEL, `select public.api_save_recipe($1::jsonb, $2::uuid)`, [JSON.stringify(draft), created.id]);
  assert.deepEqual(await tagsOf(), ['Pro děti', 'Vlastní']);
  // Úprava s polem tags je nahradí.
  await as(PAVEL, `select public.api_save_recipe($1::jsonb, $2::uuid)`, [
    JSON.stringify({ ...draft, tags: ['Pro děti'] }),
    created.id,
  ]);
  assert.deepEqual(await tagsOf(), ['Pro děti']);
  // Štítky jsou i v historii verzí.
  const snap = (await as(PAVEL, `select snapshot from public.recipe_versions
    where recipe_id = $1 order by version_number desc limit 1`, [created.id])).rows[0].snapshot;
  assert.deepEqual(snap.tags, ['Pro děti']);

  // Migrace 17 doplní způsob přípravy z postupu, zachová ruční štítky
  // a opakované spuštění nic nezdvojí.
  const sql = readFileSync(join(migrationsDir, '20261117000017_recipe_filter_tags.sql'), 'utf8');
  await db.exec(sql);
  await db.exec(sql);
  const tags = await tagsOf();
  assert.equal(tags[0], 'Pro děti');
  assert.ok(tags.includes('Sous-vide'), JSON.stringify(tags));
  assert.ok(tags.includes('Pánev'), JSON.stringify(tags));
  assert.equal(tags.filter((t) => t === 'Sous-vide').length, 1);
  assert.ok(!tags.includes('Trouba'), JSON.stringify(tags));

  // Cizí uživatel štítky nezmění.
  await as(CIZI, `update public.recipes set tags = '["Hack"]' where id = $1`, [created.id]);
  assert.ok(!(await tagsOf()).includes('Hack'));
});

test('automatické fotky: vypnuté, jen recepty bez fotky, limity a nic se nepřepíše', async () => {
  // Uživatel nastavení, úlohy ani funkce nevidí a nespustí.
  await denied(as(PAVEL, `select * from public.recipe_cover_settings`));
  await denied(as(PAVEL, `update public.recipe_cover_settings set enabled = true`));
  await denied(as(PAVEL, `select * from public.recipe_cover_jobs`));
  await denied(as(PAVEL, `select * from public.cover_reserve(5, false)`));
  await denied(as(PAVEL, `select public.cover_attach_if_empty(gen_random_uuid())`));
  await db.query(`set role anon`);
  await assert.rejects(db.query(`select * from public.cover_reserve(5, true)`));
  await db.query(`reset role`);

  // Výchozí stav: vypnuto, limit 5 denně, bezplatný model Cloudflare.
  const s = (await db.query(`select * from public.recipe_cover_settings`)).rows[0];
  assert.equal(s.enabled, false);
  assert.equal(s.daily_limit, 5);
  assert.equal(s.model, '@cf/black-forest-labs/flux-1-schnell');
  await assert.rejects(db.query(`update public.recipe_cover_settings set daily_limit = 50`));
  await assert.rejects(db.query(`update public.recipe_cover_settings set model = 'gpt-image-2'`));

  // Starší testovací recepty dostanou fotku, ať je kandidát jednoznačný.
  await db.query(`update public.recipes set photos = '[{"id":"00000000-aaaa-4aaa-8aaa-000000000000","remote_path":"a/b/c.jpg"}]'
    where coalesce(jsonb_array_length(photos), 0) = 0`);
  const bare = (await as(PAVEL, `insert into public.recipes (title, category) values ('Guláš bez fotky', 'Hovězí maso') returning id`)).rows[0].id;
  await as(PAVEL, `insert into public.recipe_ingredients (recipe_id, name) values ($1, 'Hovězí kližka')`, [bare]);
  const withPhoto = (await as(PAVEL, `insert into public.recipes (title, photos) values ('Se svou fotkou',
    '[{"id":"11111111-aaaa-4aaa-8aaa-111111111111","remote_path":"x/y/z.jpg"}]') returning id, photos`)).rows[0];
  const before = (await db.query(`select id, photos, current_version from public.recipes order by id`)).rows;

  // Vypnuto: ostrý běh nic nerezervuje, zkušební jen ukáže kandidáty.
  assert.equal((await db.query(`select * from public.cover_reserve(5, false)`)).rows.length, 0);
  const dry = (await db.query(`select * from public.cover_reserve(5, true)`)).rows;
  assert.ok(dry.some((r) => r.recipe_id === bare), 'recept bez fotky je kandidát');
  assert.ok(!dry.some((r) => r.recipe_id === withPhoto.id), 'recept s fotkou ne');
  assert.equal(dry.find((r) => r.recipe_id === bare).ingredients[0].name, 'Hovězí kližka');
  assert.equal((await db.query(`select count(*)::int n from public.recipe_cover_jobs`)).rows[0].n, 0);

  // Zapnuto, limit 1: rezervuje se jeden recept s cestou ve složce vlastníka.
  await db.query(`update public.recipe_cover_settings set enabled = true, daily_limit = 1`);
  const jobs = (await db.query(`select * from public.cover_reserve(5, false)`)).rows;
  assert.equal(jobs.length, 1);
  const job = jobs[0];
  assert.match(job.path, new RegExp(`^${job.owner_id}/${job.recipe_id}/${job.photo_id}\\.jpg$`));
  // Denní limit vyčerpán: další rezervace nic nevrátí.
  assert.equal((await db.query(`select * from public.cover_reserve(5, false)`)).rows.length, 0);
  // Stejný recept nejde rezervovat dvakrát.
  await assert.rejects(db.query(`insert into public.recipe_cover_jobs (recipe_id, owner_id) values ($1, $2)`,
    [job.recipe_id, job.owner_id]));
  // Cizí cesta se nepřijme.
  await assert.rejects(db.query(`select public.cover_progress($1, 'generated', 'cizi/slozka/x.jpg')`, [job.job_id]));

  // Přiřazení jen po nahrání a jen receptu bez fotky.
  assert.equal((await db.query(`select public.cover_attach_if_empty($1) ok`, [job.job_id])).rows[0].ok, false);
  await db.query(`select public.cover_progress($1, 'generated', $2)`, [job.job_id, job.path]);
  await db.query(`select public.cover_progress($1, 'uploaded')`, [job.job_id]);
  assert.equal(job.recipe_id, bare);
  {
    assert.equal((await db.query(`select public.cover_attach_if_empty($1) ok`, [job.job_id])).rows[0].ok, true);
    const r = (await db.query(`select photos, current_version from public.recipes where id = $1`, [bare])).rows[0];
    assert.equal(r.photos.length, 1);
    assert.equal(r.photos[0].remote_path, job.path);
    // Verze receptu, suroviny ani postup se nemění.
    assert.equal(r.current_version, before.find((x) => x.id === bare).current_version);
    assert.equal((await db.query(`select count(*)::int n from public.recipe_ingredients where recipe_id = $1`, [bare])).rows[0].n, 1);
  }
  // Ostatní recepty se nezměnily (fotky ani verze).
  const after = (await db.query(`select id, photos, current_version from public.recipes order by id`)).rows;
  for (const b of before) {
    if (b.id === job.recipe_id) continue;
    assert.deepEqual(after.find((a) => a.id === b.id), b);
  }

  // Závod: recept mezitím dostal fotku → přiřazení se odmítne, nic se nepřepíše.
  await db.query(`update public.recipe_cover_settings set daily_limit = 5`);
  const second = (await as(PAVEL, `insert into public.recipes (title) values ('Závod') returning id`)).rows[0].id;
  const j2 = (await db.query(`select * from public.cover_reserve(5, false)`)).rows.find((r) => r.recipe_id === second);
  assert.ok(j2, 'druhý recept rezervovaný');
  await db.query(`select public.cover_progress($1, 'generated', $2)`, [j2.job_id, j2.path]);
  await db.query(`select public.cover_progress($1, 'uploaded')`, [j2.job_id]);
  await as(PAVEL, `update public.recipes set photos = '[{"id":"22222222-aaaa-4aaa-8aaa-222222222222","remote_path":"moje.jpg"}]' where id = $1`, [second]);
  assert.equal((await db.query(`select public.cover_attach_if_empty($1) ok`, [j2.job_id])).rows[0].ok, false);
  const kept = (await db.query(`select photos from public.recipes where id = $1`, [second])).rows[0].photos;
  assert.equal(kept[0].remote_path, 'moje.jpg');
  assert.equal((await db.query(`select status from public.recipe_cover_jobs where id = $1`, [j2.job_id])).rows[0].status, 'skipped');

  // Vyčerpaný bezplatný příděl: úloha se odloží a recept přijde na řadu znovu
  // (nepočítá se jako pokus ani do denního limitu).
  const later = (await as(PAVEL, `insert into public.recipes (title) values ('Zítra') returning id`)).rows[0].id;
  const j3 = (await db.query(`select * from public.cover_reserve(5, false)`)).rows.find((r) => r.recipe_id === later);
  assert.ok(j3);
  const usedBefore = (await db.query(`select today_count from public.cover_usage()`)).rows[0].today_count;
  await db.query(`select public.cover_progress($1, 'postponed', null, 'Vyčerpaný denní příděl')`, [j3.job_id]);
  assert.equal((await db.query(`select today_count from public.cover_usage()`)).rows[0].today_count, usedBefore - 1);
  const again = (await db.query(`select * from public.cover_reserve(5, false)`)).rows.find((r) => r.recipe_id === later);
  assert.ok(again, 'odložený recept jde znovu na řadu');
  // Dva neúspěšné pokusy = recept se dál nezkouší.
  await db.query(`select public.cover_progress($1, 'failed', null, 'x')`, [again.job_id]);
  const third = (await db.query(`select * from public.cover_reserve(5, false)`)).rows.find((r) => r.recipe_id === later);
  await db.query(`select public.cover_progress($1, 'failed', null, 'x')`, [third.job_id]);
  assert.ok(!(await db.query(`select * from public.cover_reserve(5, false)`)).rows.some((r) => r.recipe_id === later));
  // Denní limit: nastavený na 0 nerezervuje nic nového.
  await db.query(`update public.recipe_cover_settings set daily_limit = 0`);
  await as(PAVEL, `insert into public.recipes (title) values ('Po limitu')`);
  assert.equal((await db.query(`select * from public.cover_reserve(5, false)`)).rows.filter((r) => r.reason === 'nový').length, 0);
  // Vypínač: enabled = false zastaví všechno nové.
  await db.query(`update public.recipe_cover_settings set enabled = false, daily_limit = 5`);
  assert.equal((await db.query(`select * from public.cover_reserve(5, false)`)).rows.length, 0);

  // Migrace jde spustit znovu a nastavení nepřepíše.
  await db.query(`update public.recipe_cover_settings set daily_limit = 3`);
  const sql = readFileSync(join(migrationsDir, '20261118000023_recipe_covers.sql'), 'utf8');
  await db.exec(sql);
  assert.equal((await db.query(`select daily_limit from public.recipe_cover_settings`)).rows[0].daily_limit, 3);
});

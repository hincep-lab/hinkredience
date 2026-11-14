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
    'ai_conversations', 'ai_messages', 'cooking_notes', 'cooking_sessions',
    'household_members', 'households', 'kitchen_equipment', 'meal_plans',
    'profiles', 'recipe_ingredients', 'recipe_steps', 'recipe_versions',
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

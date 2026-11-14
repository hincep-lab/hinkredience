// Testy MCP serveru – bez sítě, Supabase nahrazuje maketa.
// Spuštění:  deno test supabase/functions/mcp

import { cleanRecipe, type Env, fold, handle, tools } from "./index.ts";

function assert(condition: unknown, message = "assert"): asserts condition {
  if (!condition) throw new Error(message);
}
function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}\n  skutečnost: ${a}\n  očekáváno: ${e}`);
}

const env: Env = {
  supabaseUrl: "https://projekt.supabase.co",
  anonKey: "verejny-klic",
  publicUrl: "https://projekt.supabase.co/functions/v1/mcp",
};

const ID1 = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";

const svickova = {
  id: ID1,
  title: "Svíčková na smetaně",
  description: "Klasika",
  category: "Omáčky",
  servings: 4,
  prep_minutes: 30,
  cook_minutes: 180,
  temperatures: ["Trouba 160 °C"],
  equipment: ["Litinový hrnec"],
  notes: "Den předem naložit.",
  rating: 4.5,
  is_favorite: true,
  current_version: 2,
  photos: [{ id: "p1", remote_path: "u/r/p1.jpg" }],
  updated_at: "2026-11-14T10:00:00Z",
  created_at: "2026-11-01T10:00:00Z",
  owner_id: "uzivatel-1",
  recipe_ingredients: [
    { position: 1, name: "Smetana", quantity: 250, unit: "ml", note: "" },
    { position: 0, name: "Hovězí zadní", quantity: 800, unit: "g", note: "" },
  ],
  recipe_steps: [{ position: 0, instruction: "Opeč maso.", duration_minutes: 10, temperature_c: null }],
};
const gulas = {
  id: ID2,
  title: "Hovězí guláš",
  description: "",
  category: "Maso",
  servings: 6,
  notes: "",
  updated_at: "2026-11-10T10:00:00Z",
  recipe_ingredients: [{ position: 0, name: "Cibule", quantity: 3, unit: "ks", note: "" }],
  recipe_steps: [],
};

interface Call {
  url: string;
  method: string;
  body: any;
  headers: Record<string, string>;
}

function world(options: { user?: boolean; recipes?: any[]; tables?: Record<string, any[]>; rpcError?: string } = {}) {
  const calls: Call[] = [];
  const recipes = options.recipes ?? [svickova, gulas];
  const fetchImpl = async (input: string, init: RequestInit = {}): Promise<Response> => {
    const method = init.method ?? "GET";
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    calls.push({ url: input, method, body, headers: (init.headers ?? {}) as Record<string, string> });
    const ok = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

    if (input.endsWith("/auth/v1/user")) {
      return options.user === false ? ok({ message: "invalid JWT" }, 401) : ok({ id: "uzivatel-1" });
    }
    if (input.includes("/rest/v1/rpc/api_save_recipe")) {
      if (options.rpcError) return ok({ message: options.rpcError }, 400);
      return ok({ id: body.p_recipe_id ?? "33333333-3333-4333-8333-333333333333", version: body.p_recipe_id ? 3 : 1 });
    }
    const table = input.split("/rest/v1/")[1]?.split("?")[0] ?? "";
    const query = input.split("?")[1] ?? "";
    if (table === "recipes" && method === "GET") {
      const id = query.match(/(?:^|&)id=eq\.([0-9a-f-]+)/)?.[1];
      return ok(id ? recipes.filter((r) => r.id === id) : recipes);
    }
    if (table === "recipes" && method === "PATCH") {
      const id = query.match(/(?:^|&)id=eq\.([0-9a-f-]+)/)?.[1];
      return ok(recipes.filter((r) => r.id === id).map((r) => ({ ...r, ...body })));
    }
    if (method === "POST") return ok([{ id: "novy-radek", ...body }], 201);
    if (method === "PATCH" || method === "DELETE") return ok(options.tables?.[table] ?? []);
    return ok(options.tables?.[table] ?? []);
  };
  return { fetchImpl, calls };
}

function post(body: unknown, token: string | null = "token-uzivatele") {
  return new Request("https://projekt.supabase.co/functions/v1/mcp", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

async function call(w: ReturnType<typeof world>, name: string, args: unknown = {}) {
  const response = await handle(
    post({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name, arguments: args } }),
    env,
    w.fetchImpl,
  );
  assertEquals(response.status, 200);
  const body = await response.json();
  return body.result as { isError?: boolean; content: { text: string }[]; structuredContent?: any };
}

Deno.test("bez tokenu vrátí 401 s odkazem na metadata pro OAuth", async () => {
  const w = world();
  const response = await handle(post({ jsonrpc: "2.0", id: 1, method: "tools/list" }, null), env, w.fetchImpl);
  assertEquals(response.status, 401);
  const challenge = response.headers.get("WWW-Authenticate") ?? "";
  assert(challenge.startsWith("Bearer "), challenge);
  assert(
    challenge.includes('resource_metadata="https://projekt.supabase.co/functions/v1/mcp/.well-known/oauth-protected-resource"'),
    challenge,
  );
  assertEquals(w.calls.length, 0, "bez tokenu se na databázi vůbec nesahá");
});

Deno.test("neplatný token vrátí 401 a žádná data", async () => {
  const w = world({ user: false });
  const response = await handle(
    post({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_recipes", arguments: {} } }),
    env,
    w.fetchImpl,
  );
  assertEquals(response.status, 401);
  assert(response.headers.get("WWW-Authenticate"));
  assert(!w.calls.some((c) => c.url.includes("/rest/v1/")));
});

Deno.test("metadata chráněného zdroje ukazují na Supabase Auth", async () => {
  const response = await handle(
    new Request("https://projekt.supabase.co/functions/v1/mcp/.well-known/oauth-protected-resource"),
    env,
    world().fetchImpl,
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    resource: "https://projekt.supabase.co/functions/v1/mcp",
    authorization_servers: ["https://projekt.supabase.co/auth/v1"],
    bearer_methods_supported: ["header"],
    resource_name: "HINKredience°",
  });
});

Deno.test("initialize dohodne verzi protokolu a oznámení vrací 202", async () => {
  const w = world();
  const init = await handle(
    post({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {} } }),
    env,
    w.fetchImpl,
  );
  const body = await init.json();
  assertEquals(body.result.protocolVersion, "2025-06-18");
  assertEquals(body.result.serverInfo.name, "hinkredience");
  assert(body.result.capabilities.tools);
  assert(body.result.instructions.length > 50);

  const unknown = await handle(
    post({ jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "1999-01-01" } }),
    env,
    w.fetchImpl,
  );
  assertEquals((await unknown.json()).result.protocolVersion, "2025-11-25");

  const notified = await handle(post({ jsonrpc: "2.0", method: "notifications/initialized" }), env, w.fetchImpl);
  assertEquals(notified.status, 202);

  const ping = await handle(post({ jsonrpc: "2.0", id: 3, method: "ping" }), env, w.fetchImpl);
  assertEquals((await ping.json()).result, {});

  const missing = await handle(post({ jsonrpc: "2.0", id: 4, method: "neco/jineho" }), env, w.fetchImpl);
  assertEquals((await missing.json()).error.code, -32601);
});

Deno.test("tools/list: všech 12 nástrojů ze zadání, čtecí jsou označené", async () => {
  const response = await handle(post({ jsonrpc: "2.0", id: 1, method: "tools/list" }), env, world().fetchImpl);
  const list = (await response.json()).result.tools as any[];
  assertEquals(list.map((t) => t.name).sort(), [
    "add_cooking_note",
    "create_recipe",
    "create_recipe_version",
    "delete_recipe",
    "get_cooking_history",
    "get_kitchen_equipment",
    "get_recipe",
    "get_recipe_versions",
    "get_recipes",
    "search_recipes",
    "update_kitchen_equipment",
    "update_recipe",
  ]);
  const readOnly = list.filter((t) => t.annotations.readOnlyHint).map((t) => t.name).sort();
  assertEquals(readOnly, [
    "get_cooking_history",
    "get_kitchen_equipment",
    "get_recipe",
    "get_recipe_versions",
    "get_recipes",
    "search_recipes",
  ]);
  for (const tool of list) {
    assertEquals(tool.inputSchema.type, "object", tool.name);
    assertEquals(tool.securitySchemes, [{ type: "oauth2", scopes: [] }], tool.name);
    assert(tool.description.length > 30, tool.name);
  }
  assertEquals(tools.length, 12);
});

Deno.test("get_recipes čte tokenem uživatele a nevrací interní pole", async () => {
  const w = world();
  const result = await call(w, "get_recipes", { favorites_only: true, category: "Omáčky" });
  assertEquals(result.isError, false);
  assertEquals(result.structuredContent.count, 2);
  const first = result.structuredContent.recipes[0];
  assertEquals(first.title, "Svíčková na smetaně");
  assert(!("owner_id" in first) && !("photos" in first) && !("ingredients" in first));
  assertEquals(JSON.parse(result.content[0].text), result.structuredContent);

  const db = w.calls.find((c) => c.url.includes("/rest/v1/recipes"))!;
  assertEquals(db.headers.Authorization, "Bearer token-uzivatele");
  assertEquals(db.headers.apikey, "verejny-klic");
  assert(db.url.includes("deleted_at=is.null"), "koš se nevypisuje");
  assert(db.url.includes("is_favorite=eq.true"));
  assert(db.url.includes(`category=eq.${encodeURIComponent("Omáčky")}`));
});

Deno.test("get_recipe vrací suroviny a kroky ve správném pořadí", async () => {
  const result = await call(world(), "get_recipe", { recipe_id: ID1 });
  const recipe = result.structuredContent.recipe;
  assertEquals(recipe.ingredients.map((i: any) => i.name), ["Hovězí zadní", "Smetana"]);
  assertEquals(recipe.steps[0].instruction, "Opeč maso.");
  assertEquals(recipe.photo_count, 1);
  assert(!("owner_id" in recipe));
});

Deno.test("neplatné nebo neznámé id je chyba nástroje, ne pád", async () => {
  const w = world();
  const bad = await call(w, "get_recipe", { recipe_id: "1; drop table recipes" });
  assertEquals(bad.isError, true);
  assert(!w.calls.some((c) => c.url.includes("drop")), "neplatné id se do dotazu nedostane");

  const missing = await call(world({ recipes: [] }), "get_recipe", { recipe_id: ID1 });
  assertEquals(missing.isError, true);
  assert(missing.content[0].text.includes("nenalezen"));
});

Deno.test("search_recipes hledá bez diakritiky i v surovinách", async () => {
  const byTitle = await call(world(), "search_recipes", { query: "SVICKOVA" });
  assertEquals(byTitle.structuredContent.recipes.map((r: any) => r.id), [ID1]);
  const byIngredient = await call(world(), "search_recipes", { query: "cibule gulas" });
  assertEquals(byIngredient.structuredContent.recipes.map((r: any) => r.id), [ID2]);
  const none = await call(world(), "search_recipes", { query: "sushi" });
  assertEquals(none.structuredContent.count, 0);
  assertEquals((await call(world(), "search_recipes", { query: "  " })).isError, true);
});

Deno.test("create_recipe uloží očištěný recept přes atomickou funkci", async () => {
  const w = world();
  const result = await call(w, "create_recipe", {
    title: "  Kachna s červeným zelím ",
    servings: 4,
    ingredients: [
      { name: "Kachna", quantity: 2.2, unit: "kg" },
      { name: "", quantity: 1 },
      { name: "Sůl", quantity: -5 },
    ],
    steps: [{ instruction: "Peč.", duration_minutes: 150.4, temperature_c: 160 }, { instruction: " " }],
    owner_id: "cizi-uzivatel",
  });
  assertEquals(result.isError, false);
  assertEquals(result.structuredContent.version, 1);

  const rpc = w.calls.find((c) => c.url.includes("api_save_recipe"))!;
  assertEquals(rpc.body.p_recipe.title, "Kachna s červeným zelím");
  assertEquals(rpc.body.p_recipe.ingredients, [
    { name: "Kachna", quantity: 2.2, unit: "kg", note: "" },
    { name: "Sůl", quantity: null, unit: "", note: "" },
  ]);
  assertEquals(rpc.body.p_recipe.steps, [{ instruction: "Peč.", duration_minutes: 150, temperature_c: 160 }]);
  assert(!("owner_id" in rpc.body.p_recipe), "vlastníka klient podstrčit nemůže");
  assert(!("p_recipe_id" in rpc.body));
  assertEquals(rpc.headers.Authorization, "Bearer token-uzivatele");

  assertEquals((await call(world(), "create_recipe", { title: " ", ingredients: [], steps: [] })).isError, true);
});

Deno.test("update_recipe doplní neměněná pole ze stávajícího receptu", async () => {
  const w = world();
  const result = await call(w, "update_recipe", {
    recipe_id: ID1,
    change_summary: "Nižší teplota",
    change_reason: "Šťavnatější maso",
    temperatures: ["Trouba 150 °C"],
  });
  assertEquals(result.structuredContent.version, 3);
  const rpc = w.calls.find((c) => c.url.includes("api_save_recipe"))!;
  assertEquals(rpc.body.p_recipe_id, ID1);
  assertEquals(rpc.body.p_recipe.title, "Svíčková na smetaně", "název zůstal");
  assertEquals(rpc.body.p_recipe.temperatures, ["Trouba 150 °C"], "teplota se změnila");
  assertEquals(rpc.body.p_recipe.ingredients.length, 2, "suroviny zůstaly");
  assertEquals(rpc.body.p_recipe.ingredients[0].name, "Hovězí zadní");
  assertEquals(rpc.body.p_meta, { change_summary: "Nižší teplota", change_reason: "Šťavnatější maso" });
  assert(!("source_url" in rpc.body.p_recipe), "neuvedený zdroj se nepřepisuje");
});

Deno.test("create_recipe_version předá důvod, výsledek a hodnocení", async () => {
  const w = world();
  await call(w, "create_recipe_version", {
    recipe_id: ID1,
    change_summary: "Delší pečení",
    result_note: "Výborné",
    rating: 5,
    title: "Svíčková 3",
    ingredients: [{ name: "Hovězí", quantity: 1, unit: "kg" }],
    steps: [{ instruction: "Peč 3 h." }],
  });
  const rpc = w.calls.find((c) => c.url.includes("api_save_recipe"))!;
  assertEquals(rpc.body.p_meta.rating, 5);
  assertEquals(rpc.body.p_meta.result_note, "Výborné");
  assertEquals(rpc.body.p_recipe.title, "Svíčková 3");
  assertEquals(rpc.body.p_recipe.notes, "", "nová verze nepřebírá nic potichu");
});

Deno.test("delete_recipe jen přesouvá do koše", async () => {
  const w = world();
  const result = await call(w, "delete_recipe", { recipe_id: ID2 });
  assertEquals(result.structuredContent.deleted, true);
  const patch = w.calls.find((c) => c.method === "PATCH")!;
  assert(patch.url.includes(`id=eq.${ID2}`) && patch.url.includes("deleted_at=is.null"));
  assert(typeof patch.body.deleted_at === "string");
  assert(!w.calls.some((c) => c.method === "DELETE"), "natrvalo se nemaže");

  assertEquals((await call(world({ recipes: [] }), "delete_recipe", { recipe_id: ID2 })).isError, true);
});

Deno.test("poznámka z vaření, historie a vybavení", async () => {
  const w = world({
    tables: {
      cooking_sessions: [{ recipe_title: "Svíčková", rating: 5 }],
      cooking_notes: [{ note: "Příště víc brusinek" }],
      kitchen_equipment: [{ id: ID2, name: "Gorenje BPSAX6747A08BGWI", capabilities: ["Teplotní sonda"] }],
      user_preferences: [{ label: "Výraznější chuť" }],
    },
  });
  const note = await call(w, "add_cooking_note", { recipe_id: ID1, note: " Příště víc brusinek " });
  assertEquals(note.isError, false);
  const insert = w.calls.find((c) => c.method === "POST" && c.url.includes("cooking_notes"))!;
  assertEquals(insert.body, { recipe_id: ID1, note: "Příště víc brusinek" });

  const history = await call(w, "get_cooking_history", { recipe_id: ID1 });
  assertEquals(history.structuredContent.sessions.length, 1);
  assertEquals(history.structuredContent.notes[0].note, "Příště víc brusinek");
  assert(w.calls.some((c) => c.url.includes(`cooking_sessions`) && c.url.includes(`recipe_id=eq.${ID1}`)));

  const kitchen = await call(w, "get_kitchen_equipment");
  assertEquals(kitchen.structuredContent.taste_preferences, ["Výraznější chuť"]);
  assertEquals(kitchen.structuredContent.equipment[0].name, "Gorenje BPSAX6747A08BGWI");

  const added = await call(w, "update_kitchen_equipment", { action: "add", name: "Wok", capabilities: ["Indukce"] });
  assertEquals(added.isError, false);
  const removed = await call(w, "update_kitchen_equipment", { action: "remove", equipment_id: ID2 });
  assertEquals(removed.structuredContent.removed, true);
  assertEquals((await call(w, "update_kitchen_equipment", { action: "add" })).isError, true);
  assertEquals((await call(w, "update_kitchen_equipment", { action: "update", equipment_id: "x" })).isError, true);
  assertEquals((await call(w, "update_kitchen_equipment", { action: "smazat_vse", equipment_id: ID2 })).isError, true);
});

Deno.test("chyba databáze se klientovi nevyzradí, česká hláška ano", async () => {
  const secret = await call(world({ rpcError: 'relation "tajna_tabulka" does not exist' }), "create_recipe", {
    title: "A",
    ingredients: [],
    steps: [],
  });
  assertEquals(secret.isError, true);
  assert(!secret.content[0].text.includes("tajna_tabulka"));

  const known = await call(world({ rpcError: "Recept nenalezen." }), "update_recipe", {
    recipe_id: ID1,
    change_summary: "x",
  });
  assertEquals(known.content[0].text, "Recept nenalezen.");

  const unknownTool = await handle(
    post({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "spust_sql", arguments: {} } }),
    env,
    world().fetchImpl,
  );
  assertEquals((await unknownTool.json()).error.code, -32602);
});

Deno.test("jiné metody a rozbitý JSON", async () => {
  const w = world();
  const get = await handle(new Request("https://projekt.supabase.co/functions/v1/mcp"), env, w.fetchImpl);
  assertEquals(get.status, 405);
  const broken = await handle(
    new Request("https://projekt.supabase.co/functions/v1/mcp", {
      method: "POST",
      headers: { Authorization: "Bearer t" },
      body: "{nejson",
    }),
    env,
    w.fetchImpl,
  );
  assertEquals(broken.status, 400);
  const options = await handle(
    new Request("https://projekt.supabase.co/functions/v1/mcp", { method: "OPTIONS" }),
    env,
    w.fetchImpl,
  );
  assertEquals(options.status, 204);
});

Deno.test("pomocné funkce", () => {
  assertEquals(fold("Žluťoučký KŮŇ"), "zlutoucky kun");
  const merged = cleanRecipe({ notes: "nové" }, { title: "Starý", notes: "staré", servings: 6, ingredients: [{ name: "A" }] });
  assertEquals(merged.title, "Starý");
  assertEquals(merged.notes, "nové");
  assertEquals(merged.servings, 6);
  assertEquals((merged.ingredients as any[]).length, 1);
  assertEquals(cleanRecipe({ title: "X", servings: 0 }).servings, 4);
});

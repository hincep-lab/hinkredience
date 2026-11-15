// Testy nákupních seznamů v MCP serveru – maketa databáze si pamatuje stav
// a napodobuje Row Level Security (každý vidí jen své seznamy).
// Spuštění:  deno test supabase/functions/mcp

import {
  type Env,
  formatShoppingAmount,
  guessCategory,
  handle,
  normalizeUnit,
  planShoppingMerge,
  tools,
} from "./index.ts";

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

const RECIPE_ID = "11111111-1111-4111-8111-111111111111";
const kure = {
  id: RECIPE_ID,
  title: "Kuře na paprice",
  servings: 4,
  yield_unit: "porce",
  owner_id: "pavel",
  deleted_at: null,
  recipe_ingredients: [
    { position: 0, name: "Kuřecí stehna s kostí", quantity: 1.5, unit: "kg", note: "" },
    { position: 1, name: "Cibule", quantity: 200, unit: "g", note: "" },
    { position: 2, name: "Smetana 31 %", quantity: 500, unit: "ml", note: "" },
    { position: 3, name: "Sůl", quantity: null, unit: "", note: "podle chuti" },
  ],
  recipe_steps: [],
};

/** Maketa Supabase: tabulky v paměti, uživatel podle tokenu. */
function database() {
  const lists: any[] = [];
  const items: any[] = [];
  let seq = 0;
  const uuid = () => `00000000-0000-4000-8000-${String(++seq).padStart(12, "0")}`;
  const users: Record<string, string> = { "token-pavel": "pavel", "token-cizi": "cizi" };

  const fetchImpl = async (input: string, init: RequestInit = {}): Promise<Response> => {
    const method = init.method ?? "GET";
    const headers = (init.headers ?? {}) as Record<string, string>;
    const user = users[(headers.Authorization ?? headers.authorization ?? "").replace("Bearer ", "")];
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    const ok = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

    if (input.endsWith("/auth/v1/user")) return user ? ok({ id: user }) : ok({ message: "invalid JWT" }, 401);
    if (input.includes("/rest/v1/rpc/my_household")) return ok(null);

    const table = input.split("/rest/v1/")[1]?.split("?")[0] ?? "";
    const query = new URLSearchParams(input.split("?")[1] ?? "");
    const visibleList = (l: any) => l.owner_id === user;
    const visibleItem = (i: any) => lists.some((l) => l.id === i.list_id && visibleList(l));
    const matches = (row: any) => {
      for (const [key, value] of query) {
        if (["select", "order", "limit"].includes(key)) continue;
        if (value === "is.null" && row[key] !== null && row[key] !== undefined) return false;
        if (value.startsWith("eq.")) {
          const want = value.slice(3);
          if (String(row[key]) !== want) return false;
        }
      }
      return true;
    };

    if (table === "recipes") return ok(user === "pavel" ? [kure].filter(matches) : []);

    const rows = table === "shopping_lists" ? lists : table === "shopping_items" ? items : null;
    if (!rows) return ok([]);
    const visible = table === "shopping_lists" ? visibleList : visibleItem;

    if (method === "GET") {
      let found = rows.filter((r) => visible(r) && matches(r));
      if (table === "shopping_lists" && (query.get("select") ?? "").includes("shopping_items(")) {
        found = found.map((l) => ({ ...l, shopping_items: items.filter((i) => i.list_id === l.id) }));
      }
      if ((query.get("order") ?? "").startsWith("updated_at.desc")) {
        found = [...found].sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
      }
      return ok(found.map((r) => ({ ...r })));
    }
    if (method === "POST") {
      const row = { id: uuid(), deleted_at: null, ...body };
      if (table === "shopping_lists") {
        row.owner_id = row.owner_id ?? user;
        if (row.owner_id !== user) return ok({ message: "new row violates row-level security policy" }, 403);
        row.household_id = row.household_id ?? null;
      } else if (!visibleItem(row)) {
        return ok({ message: "new row violates row-level security policy" }, 403);
      }
      rows.push(row);
      return ok([{ ...row }], 201);
    }
    if (method === "PATCH") {
      const changed = rows.filter((r) => visible(r) && matches(r));
      for (const r of changed) Object.assign(r, body);
      return ok(changed.map((r) => ({ ...r })));
    }
    return ok([]);
  };
  return { fetchImpl, lists, items };
}

async function call(db: ReturnType<typeof database>, name: string, args: unknown = {}, token = "token-pavel") {
  const response = await handle(
    new Request(env.publicUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    }),
    env,
    db.fetchImpl,
  );
  assertEquals(response.status, 200);
  const body = await response.json();
  return body.result as { isError?: boolean; content: { text: string }[]; structuredContent?: any };
}

const KURE_NA_PAPRICE = [
  { name: "Kuřecí stehna s kostí", quantity: 1.5, unit: "kg" },
  { name: "Cibule", quantity: 300, unit: "g" },
  { name: "Červená paprika", quantity: 2, unit: "ks" },
  { name: "Smetana 31 %", quantity: 500, unit: "ml" },
  { name: "Sladká paprika mletá", quantity: 30, unit: "g" },
  { name: "Máslo", quantity: 60, unit: "g" },
  { name: "Hladká mouka", quantity: 45, unit: "g" },
  { name: "Kuřecí vývar", quantity: 2.5, unit: "l" },
  { name: "Demi-glace", quantity: 50, unit: "g" },
  { name: "Paprikový olej", quantity: 10, unit: "ml" },
  { name: "Řepkový olej", quantity: 20, unit: "ml" },
  { name: "Bobkový list", quantity: 2, unit: "ks" },
  { name: "Nové koření", quantity: 5, unit: "kuliček" },
  { name: "Černý pepř", quantity: 8, unit: "kuliček" },
  { name: "Sůl", quantity: null, unit: "", note: "podle chuti" },
  { name: "Cukr", quantity: 5, unit: "g" },
];

Deno.test("nástroje nákupních seznamů jsou v seznamu a mají správné příznaky", () => {
  const names = [
    "create_shopping_list",
    "get_shopping_lists",
    "get_shopping_list",
    "add_shopping_items",
    "update_shopping_item",
    "remove_shopping_item",
    "clear_checked_items",
    "add_recipe_to_shopping_list",
  ];
  for (const name of names) assert(tools.some((t) => t.name === name), name);
  const byName = (n: string) => tools.find((t) => t.name === n)!;
  assert(byName("get_shopping_lists").readOnly);
  assert(byName("get_shopping_list").readOnly);
  assert(byName("remove_shopping_item").destructive);
  assert(byName("clear_checked_items").destructive);
  assert(!byName("add_shopping_items").readOnly);
});

Deno.test("kategorie a jednotky", () => {
  const cases: Record<string, string> = {
    "Kuřecí stehna s kostí": "maso",
    "Cibule": "zelenina",
    "Červená paprika": "zelenina",
    "Smetana 31 %": "mlecne",
    "Sladká paprika mletá": "koreni",
    "Máslo": "mlecne",
    "Hladká mouka": "ostatni",
    "Kuřecí vývar": "ostatni",
    "Demi-glace": "ostatni",
    "Paprikový olej": "ostatni",
    "Bobkový list": "koreni",
    "Nové koření": "koreni",
    "Černý pepř": "koreni",
    "Sůl": "koreni",
    "Cukr": "ostatni",
    "Mléko": "mlecne",
  };
  for (const [name, category] of Object.entries(cases)) assertEquals(guessCategory(name), category, name);
  assertEquals(normalizeUnit("litry"), "l");
  assertEquals(normalizeUnit("gramů"), "g");
  assertEquals(formatShoppingAmount(1500, "g"), "1,5 kg");
  assertEquals(formatShoppingAmount(2500, "ml"), "2,5 l");
  assertEquals(formatShoppingAmount(null, ""), "");
});

Deno.test("sloučení: 200 g + 300 g cibule = 500 g, 0,5 kg + 200 g = 700 g, kusy zvlášť", () => {
  const existing = [{ id: "a", name: "Cibule", quantity: 200, unit: "g", is_checked: false, sources: [] }];
  const plan = planShoppingMerge(existing, [
    { name: "cibule", quantity: 300, unit: "g", category: "zelenina", note: "", source: "Guláš" },
    { name: "Mrkev", quantity: 0.5, unit: "kg", category: "zelenina", note: "", source: "" },
    { name: "Mrkev", quantity: 200, unit: "g", category: "zelenina", note: "", source: "" },
    { name: "Cibule", quantity: 1, unit: "ks", category: "zelenina", note: "", source: "" },
  ]);
  assertEquals(plan.updates.length, 1);
  assertEquals(plan.updates[0].quantity, 500);
  assertEquals(plan.updates[0].sources, ["Guláš"]);
  assertEquals(plan.inserts.map((i) => [i.name, i.quantity, i.unit]), [["Mrkev", 700, "g"], ["Cibule", 1, "ks"]]);
  // Bez sloučení vzniknou samostatné položky.
  const separate = planShoppingMerge(existing, [
    { name: "Cibule", quantity: 300, unit: "g", category: "zelenina", note: "", source: "" },
  ], false);
  assertEquals(separate.updates.length, 0);
  assertEquals(separate.inserts.length, 1);
  // Koupená položka se nesčítá, přidá se nová.
  const checked = planShoppingMerge([{ ...existing[0], is_checked: true }], [
    { name: "Cibule", quantity: 300, unit: "g", category: "zelenina", note: "", source: "" },
  ]);
  assertEquals(checked.inserts.length, 1);
});

Deno.test("seznam „Kuře na paprice“: vytvoření, přehled, odškrtnutí, smazání nakoupeného", async () => {
  const db = database();
  const created = await call(db, "create_shopping_list", { name: "Kuře na paprice", items: KURE_NA_PAPRICE });
  assert(!created.isError, created.content[0].text);
  const listId = created.structuredContent.list_id;
  assertEquals(created.structuredContent.remaining_count, 16);
  assertEquals(db.items.length, 16);
  assert(db.items.every((i) => i.list_id === listId));
  // Kilogramy a litry se ukládají v gramech a mililitrech, zobrazují se zpět čitelně.
  const stehna = db.items.find((i) => i.name === "Kuřecí stehna s kostí");
  assertEquals([stehna.quantity, stehna.unit, stehna.category], [1500, "g", "maso"]);
  const toBuy: string[] = created.structuredContent.to_buy;
  assert(toBuy.includes("Kuřecí stehna s kostí – 1,5 kg"), toBuy.join("|"));
  assert(toBuy.includes("Kuřecí vývar – 2,5 l"), toBuy.join("|"));
  assert(toBuy.includes("Sůl (podle chuti)"), toBuy.join("|"));
  assertEquals(
    created.structuredContent.categories.map((c: any) => c.category),
    ["maso", "zelenina", "mlecne", "koreni", "ostatni"],
  );

  const overview = await call(db, "get_shopping_lists");
  assertEquals(overview.structuredContent.lists[0].name, "Kuře na paprice");
  assertEquals(overview.structuredContent.lists[0].remaining_count, 16);

  // „Označ máslo jako koupené“ – podle názvu, bez id.
  const butter = await call(db, "update_shopping_item", { name: "máslo", checked: true });
  assert(!butter.isError, butter.content[0].text);
  assertEquals(db.items.find((i) => i.name === "Máslo").is_checked, true);
  const after = await call(db, "get_shopping_list", { list_name: "kuře na paprice" });
  assertEquals(after.structuredContent.remaining_count, 15);
  assert(!after.structuredContent.to_buy.some((t: string) => t.startsWith("Máslo")));

  // Vrácení do nákupu a úprava množství.
  await call(db, "update_shopping_item", { name: "Máslo", checked: false, quantity: 80 });
  assertEquals(db.items.find((i) => i.name === "Máslo").is_checked, false);
  assertEquals(db.items.find((i) => i.name === "Máslo").quantity, 80);

  // Přidání: „Přidej do nákupu 2 litry mléka“ + sloučení cibule.
  const added = await call(db, "add_shopping_items", {
    list_id: listId,
    items: [{ name: "Mléko", quantity: 2, unit: "litry" }, { name: "Cibule", quantity: 200, unit: "g" }],
  });
  assertEquals(added.structuredContent.added, 1);
  assertEquals(added.structuredContent.merged_with_existing, ["Cibule"]);
  assertEquals(db.items.find((i) => i.name === "Cibule").quantity, 500);
  const milk = db.items.find((i) => i.name === "Mléko");
  assertEquals([milk.quantity, milk.unit, milk.category], [2000, "ml", "mlecne"]);

  // Odstranění jedné položky a všech koupených (měkké smazání).
  await call(db, "remove_shopping_item", { name: "Cukr" });
  assert(db.items.find((i) => i.name === "Cukr").deleted_at);
  await call(db, "update_shopping_item", { name: "Sůl", checked: true });
  await call(db, "update_shopping_item", { name: "Bobkový list", checked: true });
  const cleared = await call(db, "clear_checked_items", { list_id: listId });
  assertEquals(cleared.structuredContent.removed_count, 2);
  assertEquals(cleared.structuredContent.remaining_count, 14);
  assertEquals(db.items.length, 17, "nic se fyzicky nemaže, jen se označí deleted_at");
});

Deno.test("recept do nákupu: přepočet porcí, vynechané suroviny, sloučení", async () => {
  const db = database();
  const created = await call(db, "create_shopping_list", {
    name: "Víkend",
    items: [{ name: "Cibule", quantity: 300, unit: "g" }],
  });
  const listId = created.structuredContent.list_id;
  const result = await call(db, "add_recipe_to_shopping_list", {
    recipe_id: RECIPE_ID,
    list_id: listId,
    servings: 6,
    exclude: ["sůl"],
  });
  assert(!result.isError, result.content[0].text);
  assertEquals(result.structuredContent.servings, 6);
  assertEquals(db.items.find((i) => i.name === "Kuřecí stehna s kostí").quantity, 2250);
  assertEquals(db.items.find((i) => i.name === "Cibule").quantity, 600, "300 g + 200 g × 1,5");
  assertEquals(db.items.find((i) => i.name === "Smetana 31 %").quantity, 750);
  assert(!db.items.some((i) => i.name === "Sůl"), "sůl má doma");
  assertEquals(db.items.find((i) => i.name === "Smetana 31 %").sources, ["Kuře na paprice"]);

  // Bez seznamu: založí nový podle new_list_name.
  const fresh = await call(db, "add_recipe_to_shopping_list", { recipe_id: RECIPE_ID, new_list_name: "Na neděli" });
  assertEquals(fresh.structuredContent.name, "Na neděli");
  assertEquals(fresh.structuredContent.servings, 4);
  assertEquals(db.lists.length, 2);
});

Deno.test("cizí uživatel seznam nevidí ani nezmění", async () => {
  const db = database();
  const created = await call(db, "create_shopping_list", { name: "Kuře na paprice", items: KURE_NA_PAPRICE });
  const listId = created.structuredContent.list_id;
  const itemId = db.items[0].id;

  const lists = await call(db, "get_shopping_lists", {}, "token-cizi");
  assertEquals(lists.structuredContent.count, 0);
  const read = await call(db, "get_shopping_list", { list_id: listId }, "token-cizi");
  assert(read.isError);
  const update = await call(db, "update_shopping_item", { item_id: itemId, checked: true }, "token-cizi");
  assert(update.isError);
  const remove = await call(db, "remove_shopping_item", { item_id: itemId }, "token-cizi");
  assert(remove.isError);
  const add = await call(db, "add_shopping_items", { list_id: listId, items: [{ name: "Podvrh" }] }, "token-cizi");
  assert(add.isError);
  const clear = await call(db, "clear_checked_items", { list_id: listId }, "token-cizi");
  assert(clear.isError);
  assert(db.items.every((i) => !i.is_checked && !i.deleted_at));
  assertEquals(db.items.length, 16);
});

Deno.test("validace vstupů", async () => {
  const db = database();
  await call(db, "create_shopping_list", { name: "Test" });
  const bad = [
    ["create_shopping_list", { name: "   " }],
    ["add_shopping_items", { items: [{ name: "X", quantity: -1 }] }],
    ["add_shopping_items", { items: [{ name: "" }] }],
    ["add_shopping_items", { items: "mléko" }],
    ["add_shopping_items", { items: Array.from({ length: 101 }, () => ({ name: "X" })) }],
    ["update_shopping_item", { item_id: "není-uuid", checked: true }],
    ["update_shopping_item", { name: "Neexistuje", checked: true }],
    ["get_shopping_list", { list_id: "'; drop table x; --" }],
    ["add_recipe_to_shopping_list", { recipe_id: "x" }],
  ] as const;
  for (const [name, args] of bad) {
    const result = await call(db, name, args);
    assert(result.isError, `${name} ${JSON.stringify(args).slice(0, 60)} měl selhat`);
  }
  assertEquals(db.items.length, 0);
});

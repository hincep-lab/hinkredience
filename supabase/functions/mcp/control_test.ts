// Testy: import receptu z odkazu bez AI a ovládání aplikace z ChatGPT.
import {
  type Env,
  handle,
  isoMinutes,
  isSafePageUrl,
  parseIngredientLine,
  recipeFromJsonLd,
  recipeFromText,
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
const RID = "11111111-1111-4111-8111-111111111111";

const PAGE = `<!doctype html><html><head><title>Kuře</title>
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage","name":"x"},
{"@type":["Recipe"],"name":"Kuře na paprice &amp; knedlík","description":"<p>Babiččino</p>","recipeYield":["4 porce"],
"prepTime":"PT20M","cookTime":"PT1H10M","recipeCategory":"Hlavní jídlo",
"recipeIngredient":["1,5 kg kuřecích stehen","2 cibule","500 ml smetany (31 %)","sůl podle chuti","½ lžičky pepře"],
"recipeInstructions":[{"@type":"HowToSection","name":"Maso","itemListElement":[{"@type":"HowToStep","text":"Osolte maso."},
{"@type":"HowToStep","text":"Opečte dozlatova."}]},{"@type":"HowToStep","text":"Přilijte smetanu."}]}]}</script>
</head><body>…</body></html>`;

const YT = `<html><head><meta property="og:title" content="Rychlé lívance"></head><body>
<script>var ytInitialPlayerResponse = {"videoDetails":{"shortDescription":"Lívance za 15 minut!\\n\\nSuroviny:\\n250 g hladké mouky\\n2 vejce\\n300 ml mléka\\n\\nPostup:\\n1. Vše smíchejte.\\n2. Pečte na pánvi.\\n\\nhttps://instagram.com/x"}};</script>
</body></html>`;

function web(pages: Record<string, Response | (() => Response)>) {
  const calls: { url: string; method: string; body: any }[] = [];
  const fetchImpl = async (input: string, init: RequestInit = {}): Promise<Response> => {
    const method = init.method ?? "GET";
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    calls.push({ url: input, method, body });
    const ok = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
    if (input.endsWith("/auth/v1/user")) return ok({ id: "uzivatel-1" });
    if (input in pages) {
      const page = pages[input];
      return typeof page === "function" ? page() : page.clone();
    }
    if (input.includes("/rest/v1/rpc/api_save_recipe")) return ok({ id: RID, version: 1 });
    if (input.includes("/rest/v1/rpc/my_household")) return ok("dddddddd-dddd-4ddd-8ddd-dddddddddddd");
    if (input.includes("/rest/v1/rpc/set_share_recipes_with_family")) return ok(7);
    if (input.includes("/rest/v1/rpc/share_all_my_recipes")) return ok(3);
    if (input.includes("/rest/v1/recipes") && method === "GET") {
      return ok([{ id: RID, title: "Svíčková", photos: [], owner_id: "uzivatel-1", updated_at: "x" }]);
    }
    if (method === "POST") return ok([{ id: "22222222-2222-4222-8222-222222222222", ...body }], 201);
    if (method === "PATCH") return ok([{ id: RID, title: "Svíčková", ...body }]);
    return ok([]);
  };
  return { fetchImpl, calls };
}

async function call(w: ReturnType<typeof web>, name: string, args: unknown = {}) {
  const response = await handle(
    new Request(env.publicUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        Authorization: "Bearer token",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    }),
    env,
    w.fetchImpl,
  );
  const body = await response.json();
  return body.result as { isError?: boolean; content: { text: string }[]; structuredContent?: any };
}

Deno.test("suroviny z řádku textu", () => {
  assertEquals(parseIngredientLine("500 g hladké mouky"), { name: "hladké mouky", quantity: 500, unit: "g", note: "" });
  assertEquals(parseIngredientLine("1,5 kg kuřecích stehen"), { name: "kuřecích stehen", quantity: 1.5, unit: "kg", note: "" });
  assertEquals(parseIngredientLine("2 cibule"), { name: "cibule", quantity: 2, unit: "ks", note: "" });
  assertEquals(parseIngredientLine("500 ml smetany (31 %)"), { name: "smetany", quantity: 500, unit: "ml", note: "31 %" });
  assertEquals(parseIngredientLine("½ lžičky pepře").quantity, 0.5);
  assertEquals(parseIngredientLine("½ lžičky pepře").unit, "lžička");
  assertEquals(parseIngredientLine("- Mouka hladká 500 g"), { name: "Mouka hladká", quantity: 500, unit: "g", note: "" });
  assertEquals(parseIngredientLine("sůl podle chuti"), { name: "sůl podle chuti", quantity: null, unit: "", note: "" });
  assertEquals(isoMinutes("PT1H10M"), 70);
  assertEquals(isoMinutes("P0DT45M"), 45);
  assertEquals(isoMinutes("PT45M"), 45);
});

Deno.test("recept ze strukturovaných dat stránky (@graph, sekce kroků)", () => {
  const recipe = recipeFromJsonLd(PAGE, "https://recepty.example/kure")!;
  assertEquals(recipe.title, "Kuře na paprice & knedlík");
  assertEquals(recipe.description, "Babiččino");
  assertEquals([recipe.servings, recipe.prep_minutes, recipe.cook_minutes], [4, 20, 70]);
  assertEquals((recipe.ingredients as any[]).length, 5);
  assertEquals((recipe.steps as any[]).map((s) => s.instruction), ["Osolte maso.", "Opečte dozlatova.", "Přilijte smetanu."]);
  assertEquals(recipeFromJsonLd("<html></html>", "x"), null);
});

Deno.test("recept z popisu (text bez struktury)", () => {
  const recipe = recipeFromText("Suroviny:\n250 g mouky\n2 vejce\nPostup:\n1. Smíchejte.\n2. Pečte.", "Lívance", "u")!;
  assertEquals((recipe.ingredients as any[]).map((i) => i.name), ["mouky", "vejce"]);
  assertEquals((recipe.steps as any[]).map((s) => s.instruction), ["Smíchejte.", "Pečte."]);
});

Deno.test("bezpečné odkazy: jen veřejné http(s) stránky", () => {
  assert(isSafePageUrl("https://www.toprecepty.cz/recept/1"));
  assert(isSafePageUrl("http://recepty.example/a"));
  for (const bad of ["file:///etc/passwd", "http://localhost/x", "http://127.0.0.1/", "http://10.0.0.1/", "http://[::1]/", "https://x.internal/", "ftp://a.b/c", "https://u:p@a.cz/"]) {
    assert(!isSafePageUrl(bad), bad);
  }
});

Deno.test("import_recipe_from_url: návrh, uložení, YouTube popis, přesměrování na interní adresu", async () => {
  const w = web({
    "https://recepty.example/kure": new Response(PAGE, { status: 200 }),
    "https://www.youtube.com/watch?v=abc": new Response(YT, { status: 200 }),
    "https://zkracovac.example/x": () => new Response(null, { status: 302, headers: { location: "http://169.254.169.254/latest" } }),
    "https://prazdna.example/": new Response("<html><title>Nic</title></html>", { status: 200 }),
  });
  const draft = await call(w, "import_recipe_from_url", { url: "https://recepty.example/kure" });
  assert(!draft.isError, draft.content[0].text);
  assertEquals(draft.structuredContent.saved, false);
  assertEquals(draft.structuredContent.method, "structured");
  assertEquals(draft.structuredContent.recipe.source_url, "https://recepty.example/kure");
  assert(!w.calls.some((c) => c.url.includes("api_save_recipe")), "bez save se nic neukládá");

  const saved = await call(w, "import_recipe_from_url", { url: "https://recepty.example/kure", save: true });
  assertEquals(saved.structuredContent.recipe_id, RID);
  const rpc = w.calls.find((c) => c.url.includes("api_save_recipe"))!;
  assertEquals(rpc.body.p_recipe.title, "Kuře na paprice & knedlík");

  const video = await call(w, "import_recipe_from_url", { url: "https://www.youtube.com/watch?v=abc" });
  assertEquals(video.structuredContent.method, "description");
  assertEquals(video.structuredContent.recipe.title, "Rychlé lívance");
  assertEquals(video.structuredContent.recipe.ingredients.length, 3);
  assertEquals(video.structuredContent.recipe.steps.length, 2);

  const redirect = await call(w, "import_recipe_from_url", { url: "https://zkracovac.example/x" });
  assert(redirect.isError);
  assert(!w.calls.some((c) => c.url.includes("169.254")), "na interní adresu se nesáhlo");
  assert((await call(w, "import_recipe_from_url", { url: "https://prazdna.example/" })).isError);
  assert((await call(w, "import_recipe_from_url", { url: "file:///etc/passwd" })).isError);
});

Deno.test("plán vaření, deník, oblíbené, sdílení a chutě z ChatGPT", async () => {
  const w = web({});
  const plan = await call(w, "plan_meal", { date: "2026-11-18", meal_type: "oběd", recipe_id: RID, servings: 6 });
  assert(!plan.isError, plan.content[0].text);
  const insert = w.calls.find((c) => c.method === "POST" && c.url.includes("/meal_plans"))!;
  assertEquals(
    [insert.body.plan_date, insert.body.meal_type, insert.body.recipe_id, insert.body.title, insert.body.servings, insert.body.household_id],
    ["2026-11-18", "lunch", RID, "Svíčková", 6, "dddddddd-dddd-4ddd-8ddd-dddddddddddd"],
  );
  assert((await call(w, "plan_meal", { date: "18.11.", meal_type: "lunch", title: "x" })).isError);
  assert((await call(w, "plan_meal", { date: "2026-11-18", meal_type: "svačina", title: "x" })).isError);

  await call(w, "remove_meal_plan_entry", { entry_id: RID });
  const removal = w.calls.find((c) => c.method === "PATCH" && c.url.includes("/meal_plans"))!;
  assert(removal.body.deleted_at, "měkké smazání");

  const log = await call(w, "log_cooking", { recipe_id: RID, rating: 4.3, to_improve: "Víc soli" });
  assert(!log.isError, log.content[0].text);
  const session = w.calls.find((c) => c.method === "POST" && c.url.includes("/cooking_sessions"))!;
  assertEquals([session.body.status, session.body.rating, session.body.to_improve], ["finished", 4.5, "Víc soli"]);

  await call(w, "set_recipe_favorite", { recipe_id: RID, favorite: true });
  assert((await call(w, "rate_recipe", { recipe_id: RID, rating: 7 })).isError);
  const share = await call(w, "share_all_recipes", { automatic: true });
  assertEquals(share.structuredContent.newly_shared, 7);
  assertEquals((await call(w, "share_all_recipes", {})).structuredContent.newly_shared, 3);
  assert((await call(w, "update_taste_preferences", { action: "add" })).isError);
  assert(!(await call(w, "update_taste_preferences", { action: "add", label: "Bez koriandru" })).isError);
  assert((await call(w, "set_greeting_name", { name: "  " })).isError);
});

Deno.test("nové nástroje mají správné příznaky", () => {
  const byName = (n: string) => tools.find((t) => t.name === n)!;
  for (const n of ["get_meal_plan", "get_trash", "get_family"]) assert(byName(n).readOnly, n);
  for (const n of ["remove_meal_plan_entry"]) assert(byName(n).destructive, n);
  assertEquals(tools.length, 43);
});

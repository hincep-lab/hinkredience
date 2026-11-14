// Testy serverové funkce „ai“ – bez sítě, Supabase i OpenAI nahrazuje maketa.
// Spuštění:  deno test supabase/functions/ai

import {
  collectSources,
  type Env,
  extractPageText,
  handle,
  isPublicHost,
  normalizeUrl,
  sanitizeRecipe,
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
  openaiKey: "sk-test",
  model: "model-chat",
  searchModel: "model-hledani",
  dailyLimit: 3,
  searchDailyLimit: 1,
};

const recipe = {
  title: "Svíčková na smetaně",
  description: "Klasika.",
  category: "Omáčky",
  servings: 4,
  prep_minutes: 30,
  cook_minutes: 180,
  temperatures: ["Trouba 160 °C"],
  equipment: ["Litinový hrnec"],
  notes: "",
  ingredients: [{ name: "Hovězí zadní", quantity: 800, unit: "g", note: "" }],
  steps: [{ instruction: "Maso osol a opeč.", duration_minutes: 10, temperature_c: null }],
};

interface Call {
  url: string;
  method: string;
  body: any;
  headers: Record<string, string>;
}

/** Maketa sítě. `openai` vrací tělo odpovědi Responses API pro daný požadavek. */
function world(options: {
  openai?: (body: any) => unknown;
  openaiStatus?: number;
  user?: boolean;
  usage?: Record<string, number>;
  page?: string;
  tables?: Record<string, unknown[]>;
} = {}) {
  const calls: Call[] = [];
  const usage = { request: 0, search: 0, ...(options.usage ?? {}) };
  const inserted: Record<string, any[]> = {};
  const fetchImpl = async (input: string, init: RequestInit = {}): Promise<Response> => {
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    const headers = (init.headers ?? {}) as Record<string, string>;
    calls.push({ url: input, method: init.method ?? "GET", body, headers });
    const ok = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

    if (input.endsWith("/auth/v1/user")) {
      return options.user === false ? ok({ message: "bad jwt" }, 401) : ok({ id: "uzivatel-1" });
    }
    if (input.includes("/rest/v1/rpc/ai_register_usage")) {
      const kind = body.p_kind as "request" | "search";
      usage[kind] += 1;
      return ok(usage[kind]);
    }
    if (input.includes("/rest/v1/")) {
      const table = input.split("/rest/v1/")[1].split("?")[0];
      if ((init.method ?? "GET") === "POST") {
        const row = { id: `${table}-${(inserted[table]?.length ?? 0) + 1}`, ...body };
        (inserted[table] ??= []).push(row);
        return ok([row], 201);
      }
      if (init.method === "PATCH") return ok([]);
      return ok(options.tables?.[table] ?? []);
    }
    if (input === "https://api.openai.com/v1/responses") {
      if (options.openaiStatus) return ok({ error: { message: "chyba" } }, options.openaiStatus);
      return ok(options.openai ? options.openai(body) : {});
    }
    if (options.page !== undefined) {
      return new Response(options.page, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } });
    }
    return new Response("nenalezeno", { status: 404 });
  };
  return { fetchImpl, calls, usage, inserted };
}

function message(payload: unknown, annotations: unknown[] = []) {
  return {
    type: "message",
    role: "assistant",
    content: [{ type: "output_text", text: JSON.stringify(payload), annotations }],
  };
}

function request(body: unknown, token: string | null = "token-uzivatele") {
  return new Request("https://projekt.supabase.co/functions/v1/ai", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: "verejny-klic",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

Deno.test("bez přihlášení vrátí 401 a OpenAI nezavolá", async () => {
  const w = world();
  const response = await handle(request({ action: "chat", message: "ahoj" }, null), env, w.fetchImpl);
  assertEquals(response.status, 401);
  assert(!w.calls.some((c) => c.url.includes("openai")), "OpenAI se nesmí volat");
});

Deno.test("neplatný token vrátí 401", async () => {
  const w = world({ user: false });
  const response = await handle(request({ action: "chat", message: "ahoj" }), env, w.fetchImpl);
  assertEquals(response.status, 401);
  assert(!w.calls.some((c) => c.url.includes("openai")));
});

Deno.test("bez klíče OpenAI vrátí srozumitelnou chybu 503", async () => {
  const w = world();
  const response = await handle(
    request({ action: "chat", message: "ahoj" }),
    { ...env, openaiKey: "" },
    w.fetchImpl,
  );
  assertEquals(response.status, 503);
  assertEquals((await response.json()).error.code, "ai_not_configured");
  assertEquals(w.usage.request, 0, "nenastavená AI se nepočítá do limitu");
});

Deno.test("denní limit zastaví požadavek před voláním OpenAI", async () => {
  const w = world({ usage: { request: 3 } });
  const response = await handle(request({ action: "chat", message: "ahoj" }), env, w.fetchImpl);
  assertEquals(response.status, 429);
  assertEquals((await response.json()).error.code, "daily_limit");
  assert(!w.calls.some((c) => c.url.includes("openai")));
});

Deno.test("limit vyhledávání se počítá zvlášť", async () => {
  const w = world({ usage: { search: 1 } });
  const response = await handle(request({ action: "search", query: "svíčková" }), env, w.fetchImpl);
  assertEquals(response.status, 429);
  assertEquals((await response.json()).error.code, "search_limit");
});

Deno.test("chat: uloží konverzaci, pošle paměť a vrátí návrh receptu", async () => {
  const w = world({
    tables: {
      user_preferences: [{ label: "Výraznější chuť", kind: "taste" }],
      kitchen_equipment: [{ name: "Gorenje BPSAX6747A08BGWI", capabilities: ["Teplotní sonda"], notes: "" }],
    },
    openai: () => ({
      status: "completed",
      output: [message({ reply: "Tady je svíčková.", recipe, change_summary: "" })],
    }),
  });
  const response = await handle(
    request({ action: "chat", message: "Vymysli svíčkovou s přesnými gramážemi – žluťoučký kůň." }),
    env,
    w.fetchImpl,
  );
  assertEquals(response.status, 200);
  const data = await response.json();
  assertEquals(data.reply, "Tady je svíčková.");
  assertEquals(data.recipe.title, "Svíčková na smetaně");
  assertEquals(data.conversation_id, "ai_conversations-1");

  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  assertEquals(openai.body.model, "model-chat");
  assertEquals(openai.body.store, false);
  assertEquals(openai.body.text.format.strict, true);
  assert(openai.body.instructions.includes("Výraznější chuť"), "paměť obsahuje preference");
  assert(openai.body.instructions.includes("Teplotní sonda"), "paměť obsahuje vybavení");
  assertEquals(openai.headers.Authorization, "Bearer sk-test");

  const db = w.calls.find((c) => c.url.includes("/rest/v1/user_preferences"))!;
  assertEquals(db.headers.Authorization, "Bearer token-uzivatele", "databáze se čte tokenem uživatele");

  assertEquals(w.inserted.ai_messages.length, 2);
  assertEquals(w.inserted.ai_messages[0].role, "user");
  assert(w.inserted.ai_messages[0].content.includes("žluťoučký kůň"), "diakritika zůstává");
  assertEquals(w.inserted.ai_messages[1].attachments[0].type, "recipe_proposal");
});

Deno.test("chat: prázdná paměť se modelu přizná", async () => {
  const w = world({
    openai: () => ({ output: [message({ reply: "Ahoj.", recipe: null, change_summary: "" })] }),
  });
  const response = await handle(request({ action: "chat", message: "ahoj" }), env, w.fetchImpl);
  const data = await response.json();
  assertEquals(data.recipe, null);
  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  assert(openai.body.instructions.includes("zatím nejsou uložené žádné preference"));
});

Deno.test("chat: navazuje na uloženou historii konverzace", async () => {
  const w = world({
    tables: {
      ai_messages: [
        { role: "assistant", content: "Druhá" },
        { role: "user", content: "První" },
      ],
    },
    openai: () => ({ output: [message({ reply: "Třetí.", recipe: null, change_summary: "" })] }),
  });
  await handle(request({ action: "chat", message: "A dál?", conversation_id: "k1" }), env, w.fetchImpl);
  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  assertEquals(openai.body.input.map((m: any) => m.role), ["user", "assistant", "user"]);
  assertEquals(openai.body.input[0].content, "První");
  assert(!w.inserted.ai_conversations, "nová konverzace se nezakládá");
});

Deno.test("hledání: vynutí webové vyhledávání a pustí jen ověřitelné odkazy", async () => {
  const result = (title: string, url: string) => ({
    title,
    url,
    site: "",
    summary: "s",
    ingredients: ["hovězí 800 g"],
    method: "m",
    temperatures: ["160 °C"],
    total_minutes: 240,
    rating: 4.6,
    rating_count: 120,
  });
  const w = world({
    openai: () => ({
      output: [
        {
          type: "web_search_call",
          status: "completed",
          action: {
            type: "search",
            sources: [
              { url: "https://www.recepty.cz/recept/svickova-123/", title: "Svíčková" },
              { url: "https://kucharka.example/svickova", title: "Svíčková 2" },
            ],
          },
        },
        message({
          results: [
            result("Svíčková z Receptů", "https://recepty.cz/recept/svickova-123?utm_source=x"),
            result("Jiná stránka téhož webu", "https://kucharka.example/jina-svickova"),
            result("Vymyšlený zdroj", "https://neexistuje.example/svickova"),
            result("Duplicitní", "https://www.recepty.cz/recept/svickova-123"),
          ],
          comparison: { ingredients: "a", method: "b", temperatures_times: "c", ratings: "d" },
        }),
      ],
    }),
  });
  const response = await handle(request({ action: "search", query: "svíčková" }), env, w.fetchImpl);
  assertEquals(response.status, 200);
  const data = await response.json();
  assertEquals(data.results.length, 2, "vymyšlený a duplicitní výsledek vypadnou");
  assertEquals(data.results[0].verified, true);
  assertEquals(data.results[1].verified, false, "jiná stránka známého webu je označená");
  assertEquals(data.dropped_unverified, 1);
  assertEquals(data.results[0].site, "recepty.cz");

  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  assertEquals(openai.body.model, "model-hledani");
  assertEquals(openai.body.tools[0].type, "web_search");
  assertEquals(openai.body.tool_choice, "required");
  assertEquals(openai.body.include, ["web_search_call.action.sources"]);
  assertEquals(w.usage.search, 1);
});

Deno.test("hledání: bez ověřitelných zdrojů vrátí chybu, ne vymyšlené recepty", async () => {
  const w = world({
    openai: () => ({
      output: [
        message({
          results: [{
            title: "Z hlavy",
            url: "https://vymysleno.example/a",
            site: "",
            summary: "",
            ingredients: [],
            method: "",
            temperatures: [],
            total_minutes: null,
            rating: 5,
            rating_count: null,
          }],
          comparison: { ingredients: "", method: "", temperatures_times: "", ratings: "" },
        }),
      ],
    }),
  });
  const response = await handle(request({ action: "search", query: "svíčková" }), env, w.fetchImpl);
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "no_results");
});

Deno.test("vylepšení: vrací změny s důvody a úplný recept", async () => {
  const w = world({
    openai: () => ({
      output: [message({
        summary: "Delší pečení.",
        changes: [{ what: "Teplota 150 °C", why: "Šťavnatější maso" }, { what: "", why: "prázdné vypadne" }],
        recipe: { ...recipe, title: "Svíčková 2" },
      })],
    }),
  });
  const response = await handle(request({ action: "improve", recipe, instruction: "víc chuti" }), env, w.fetchImpl);
  const data = await response.json();
  assertEquals(data.changes.length, 1);
  assertEquals(data.recipe.title, "Svíčková 2");
  assertEquals(data.sources, []);
  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  assert(!openai.body.tools, "bez požadavku se internet neprohledává");
  assertEquals(w.usage.search, 0);
});

Deno.test("vylepšení s internetem se počítá jako vyhledávání", async () => {
  const w = world({
    openai: () => ({ output: [message({ summary: "", changes: [], recipe })] }),
  });
  await handle(request({ action: "improve", recipe, with_web: true }), env, w.fetchImpl);
  assertEquals(w.usage.search, 1);
  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  assertEquals(openai.body.tool_choice, "required");
});

Deno.test("import z odkazu: načte stránku a předá text i strukturovaná data", async () => {
  const page = `<html><head><title>Guláš &amp; knedlík</title>
    <script type="application/ld+json">{"@type":"Recipe","name":"Guláš"}</script>
    <style>p{color:red}</style></head>
    <body><nav>menu</nav><h1>Hovězí guláš</h1><p>800&nbsp;g hovězího, 150&deg;C</p>
    <script>alert(1)</script></body></html>`;
  const w = world({
    page,
    openai: () => ({ output: [message({ found: true, message: "Zkontroluj sůl.", recipe })] }),
  });
  const response = await handle(
    request({ action: "import", url: "https://www.recepty.cz/gulas" }),
    env,
    w.fetchImpl,
  );
  assertEquals(response.status, 200);
  const data = await response.json();
  assertEquals(data.source_url, "https://www.recepty.cz/gulas");
  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  const sent = openai.body.input[0].content as string;
  assert(sent.includes('"@type":"Recipe"'), "JSON-LD je součástí podkladu");
  assert(sent.includes("Guláš & knedlík"), "entity v titulku jsou převedené");
  assert(sent.includes("800 g hovězího, 150°C"));
  assert(!sent.includes("alert(1)") && !sent.includes("color:red") && !sent.includes("menu"));
});

Deno.test("import: adresy do vnitřní sítě se odmítnou", async () => {
  for (const url of ["http://localhost/x", "http://192.168.1.1/a", "http://10.0.0.5/", "ftp://recepty.cz/a", "http://169.254.169.254/latest"]) {
    const w = world({ page: "<html></html>" });
    const response = await handle(request({ action: "import", url }), env, w.fetchImpl);
    assertEquals(response.status, 400, url);
    assert(!w.calls.some((c) => c.url === url), `adresa ${url} se nesmí načíst`);
  }
});

Deno.test("import: podklad bez receptu vrátí chybu se zprávou", async () => {
  const w = world({
    openai: () => ({ output: [message({ found: false, message: "To je článek o počasí.", recipe: null })] }),
  });
  const response = await handle(request({ action: "import", text: "Zítra bude pršet." }), env, w.fetchImpl);
  assertEquals(response.status, 422);
  assertEquals((await response.json()).error.message, "To je článek o počasí.");
});

Deno.test("import z fotografie posílá obrázek modelu", async () => {
  const w = world({
    openai: () => ({ output: [message({ found: true, message: "", recipe })] }),
  });
  await handle(request({ action: "import", image_base64: "QUJD" }), env, w.fetchImpl);
  const openai = w.calls.find((c) => c.url.includes("openai"))!;
  const parts = openai.body.input[0].content;
  assertEquals(parts[1].type, "input_image");
  assertEquals(parts[1].image_url, "data:image/jpeg;base64,QUJD");
});

Deno.test("chyby OpenAI se převádějí na srozumitelné zprávy", async () => {
  const quota = world({ openaiStatus: 429 });
  const r1 = await handle(request({ action: "chat", message: "ahoj" }), env, quota.fetchImpl);
  assertEquals(r1.status, 503);
  assertEquals((await r1.json()).error.code, "ai_quota");

  const key = world({ openaiStatus: 401 });
  const r2 = await handle(request({ action: "chat", message: "ahoj" }), env, key.fetchImpl);
  assertEquals((await r2.json()).error.code, "ai_key_invalid");

  const refusal = world({
    openai: () => ({ output: [{ type: "message", content: [{ type: "refusal", refusal: "ne" }] }] }),
  });
  const r3 = await handle(request({ action: "chat", message: "ahoj" }), env, refusal.fetchImpl);
  assertEquals(r3.status, 422);

  const cut = world({ openai: () => ({ status: "incomplete", output: [] }) });
  const r4 = await handle(request({ action: "chat", message: "ahoj" }), env, cut.fetchImpl);
  assertEquals((await r4.json()).error.code, "ai_incomplete");
});

Deno.test("neznámá akce a prázdný vstup", async () => {
  const w = world();
  assertEquals((await handle(request({ action: "smazat_vse" }), env, w.fetchImpl)).status, 400);
  assertEquals((await handle(request({ action: "chat", message: "   " }), env, w.fetchImpl)).status, 400);
  assertEquals((await handle(request({ action: "our_version", sources: [] }), env, w.fetchImpl)).status, 400);
});

Deno.test("pomocné funkce", () => {
  assertEquals(normalizeUrl("https://WWW.Recepty.cz/Recept/A/?utm=1#x"), "recepty.cz/recept/a");
  assertEquals(normalizeUrl("není adresa"), "");
  assert(isPublicHost("https://www.recepty.cz/a"));
  assert(!isPublicHost("http://intranet/a"));
  assert(!isPublicHost("http://172.20.1.1/a"));
  assert(!isPublicHost("http://[::1]/a"));

  assertEquals(sanitizeRecipe({ title: "  " }), null);
  const clean = sanitizeRecipe({
    title: "Kachna",
    servings: -3,
    ingredients: [{ name: "Kachna", quantity: -1, unit: "ks" }, { name: "" }],
    steps: [{ instruction: "Peč.", duration_minutes: 90.4, temperature_c: 9999 }, {}],
  })!;
  assertEquals(clean.servings, 0.5);
  assertEquals((clean.ingredients as any[]).length, 1);
  assertEquals((clean.ingredients as any[])[0].quantity, null);
  assertEquals((clean.steps as any[])[0], { instruction: "Peč.", duration_minutes: 90, temperature_c: null });

  const sources = collectSources({
    output: [
      { type: "web_search_call", action: { sources: [{ url: "https://a.cz/x" }, { url: "javascript:alert(1)" }] } },
      { type: "message", content: [{ annotations: [{ type: "url_citation", url: "https://a.cz/x/", title: "A" }, { type: "url_citation", url: "https://b.cz/y", title: "B" }] }] },
    ],
  });
  assertEquals(sources.map((s) => s.url), ["https://a.cz/x", "https://b.cz/y"]);

  assert(extractPageText("<p>a</p>".repeat(50_000)).length <= 30_000);
});

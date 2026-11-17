import { buildPrompt, type Env, handle, parseIdeas, pickOffers } from "./index.ts";
function assertEquals(a: unknown, b: unknown) {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${x} !== ${y}`);
}
function assert(c: unknown, msg = "assert") {
  if (!c) throw new Error(msg);
}

const env: Env = {
  supabaseUrl: "https://db.test",
  anonKey: "anon",
  serviceKey: "service",
  geminiKey: "AIzaTEST",
  model: "gemini-test",
  dailyLimit: 400,
};

const rows = [
  { id: "1", chain: "tesco", product: "Vepřová pečeně bez kosti", price: "79.9", regular_price: "198.9", pack_qty: "1", pack_unit: "kg", conditions: "", valid_to: "2026-11-17" },
  { id: "2", chain: "jip", product: "Kuřecí prsní řízky", price: "99.9", regular_price: null, pack_qty: "1", pack_unit: "kg", conditions: "", valid_to: "2026-11-17" },
  { id: "3", chain: "tesco", product: "Cibule", price: "24.9", regular_price: null, pack_qty: "1", pack_unit: "kg", conditions: "bez Clubcard", valid_to: "2026-11-17" },
  { id: "4", chain: "tesco", product: "Cibule", price: "12.45", regular_price: "24.9", pack_qty: "1", pack_unit: "kg", conditions: "s Clubcard", valid_to: "2026-11-17" },
];

const ideaJson = JSON.stringify({
  recipes: [
    {
      title: "Vepřová pečeně na cibulce",
      description: "Šťavnatá pečeně.",
      category: "Maso",
      minutes: 120,
      temperature_c: 170,
      ingredients: [
        { name: "Vepřová pečeně", quantity: 1, unit: "kg", offer: "A1" },
        { name: "Cibule", quantity: 3, unit: "ks", offer: "a3" },
        { name: "Kmín", unit: "", offer: "A99" },
        { name: "Sůl", offer: "" },
      ],
      steps: ["Maso osolte.", "Pečte 2 hodiny na 170 °C."],
    },
    {
      title: "Palačinky",
      category: "Dezerty",
      ingredients: [{ name: "Mouka" }, { name: "Mléko" }, { name: "Vejce" }],
      steps: ["Smíchejte.", "Smažte."],
    },
  ],
});

Deno.test("z každého produktu se bere nejlevnější akce", () => {
  const offers = pickOffers(rows);
  assertEquals(offers.length, 3);
  assertEquals(offers.find((o) => o.product === "Cibule")?.price, 12.45);
});

Deno.test("prompt obsahuje kódy akcí a přání", () => {
  const p = buildPrompt(pickOffers(rows), 3, "něco rychlého", ["Guláš"]);
  assert(p.includes("A1: Vepřová pečeně bez kosti 1 kg – 79.9 Kč (běžně 198.9 Kč), Tesco"));
  assert(p.includes("něco rychlého"));
  assert(p.includes("Guláš"));
});

Deno.test("odkaz na akci jen na skutečnou akci, recept bez akce se zahodí", () => {
  const offers = pickOffers(rows);
  const { ideas, rejected } = parseIdeas(ideaJson, offers);
  assertEquals(ideas.length, 1);
  const idea = ideas[0];
  assertEquals(idea.ingredients[0].offer?.id, "1");
  assertEquals(idea.ingredients[1].offer?.product, "Cibule");
  assertEquals(idea.ingredients[2].offer, null); // A99 neexistuje
  assertEquals(idea.ingredients[3].offer, null);
  assertEquals(idea.temperature_c, 170);
  assertEquals(idea.category, "Maso");
  assertEquals(rejected, ["Palačinky: nevyužívá žádnou akci"]);
});

Deno.test("neplatný JSON se nezobrazí", () => {
  assertEquals(parseIdeas("nesmysl", []).ideas.length, 0);
});

function fakeServer(opts: { gemini?: (body: any) => Response; usage?: number; offers?: any[] }) {
  const calls: string[] = [];
  let usageSaved: number | null = null;
  let prompt = "";
  const fetchImpl = async (url: string, init?: RequestInit): Promise<Response> => {
    calls.push(url);
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: "u1" });
    if (url.includes("/rest/v1/price_offers")) return Response.json(opts.offers ?? rows);
    if (url.includes("/rest/v1/price_ai_usage?select")) return Response.json([{ requests: opts.usage ?? 5 }]);
    if (url.includes("/rest/v1/price_ai_usage?on_conflict")) {
      usageSaved = JSON.parse(String(init?.body)).requests;
      return new Response("", { status: 201 });
    }
    if (url.includes("generativelanguage")) {
      const body = JSON.parse(String(init?.body));
      prompt = body.contents[0].parts[0].text;
      return opts.gemini ? opts.gemini(body) : Response.json({ candidates: [{ content: { parts: [{ text: ideaJson }] } }] });
    }
    return new Response("?", { status: 404 });
  };
  return { fetchImpl, calls, usageSaved: () => usageSaved, prompt: () => prompt };
}

const request = (body: unknown) =>
  new Request("https://fn.test/sale-ideas", {
    method: "POST",
    headers: { Authorization: "Bearer user-token" },
    body: JSON.stringify(body),
  });
const now = new Date("2026-11-17T10:00:00Z");

Deno.test("návrh receptů z akcí a započtení do denního limitu", async () => {
  const s = fakeServer({});
  const res = await handle(request({ action: "suggest", count: 2 }), env, s.fetchImpl, now);
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(body.ideas.length, 1);
  assertEquals(body.ideas[0].ingredients[0].offer.price, 79.9);
  assertEquals(s.usageSaved(), 6);
  assert(s.prompt().includes("Navrhni 2 různé recepty"));
});

Deno.test("bez platných akcí se Gemini nevolá", async () => {
  const s = fakeServer({ offers: [] });
  const body = await (await handle(request({ action: "suggest" }), env, s.fetchImpl, now)).json();
  assertEquals(body.ideas.length, 0);
  assert(body.error.includes("Najít akce"));
  assert(!s.calls.some((c) => c.includes("generativelanguage")));
});

Deno.test("vyčerpaný denní limit", async () => {
  const s = fakeServer({ usage: 400 });
  const body = await (await handle(request({ action: "suggest" }), env, s.fetchImpl, now)).json();
  assert(body.error.includes("limit"));
  assert(!s.calls.some((c) => c.includes("generativelanguage")));
});

Deno.test("chyba Gemini 429 se srozumitelně popíše a klíč neuteče", async () => {
  const s = fakeServer({ gemini: () => new Response(JSON.stringify({ error: { message: "quota AIzaSECRET" } }), { status: 429 }) });
  const body = await (await handle(request({ action: "suggest" }), env, s.fetchImpl, now)).json();
  assert(body.error.includes("limit Gemini"));
  assert(!JSON.stringify(body).includes("AIza"));
});

Deno.test("bez přihlášení nic", async () => {
  const s = fakeServer({});
  const res = await handle(new Request("https://fn.test", { method: "POST", body: "{}" }), env, s.fetchImpl, now);
  assertEquals(res.status, 401);
});

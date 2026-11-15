import {
  chooseProvider,
  handle,
  isOfficial,
  mentionsPrice,
  parseOffers,
  productKey,
  verifyOffer,
} from "./index.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} ${x} !== ${y}`);
}
function ok(c: unknown, msg = "assert") {
  if (!c) throw new Error(msg);
}

const NOW = new Date("2026-11-16T10:00:00Z");
const TODAY = "2026-11-16";

Deno.test("klíč produktu je stejný jako v aplikaci", () => {
  eq(productKey("Máslo Tatra 250 g"), "maslo tatra");
  eq(productKey("Kuřecí stehna"), "kurec stehn");
  eq(productKey("  "), "");
});

Deno.test("oficiální weby řetězců", () => {
  ok(isOfficial("penny", "https://www.penny.cz/nabidky/maslo"));
  ok(isOfficial("penny", "penny.cz"), "název webu z citace Gemini");
  ok(!isOfficial("penny", "https://www.kupi.cz/penny"));
  ok(!isOfficial("penny", "https://penny.cz.evil.com/"));
  ok(!isOfficial("penny", "http://www.penny.cz/"), "jen https");
  ok(!isOfficial("lidl", "https://www.penny.cz/"));
});

Deno.test("čtení JSON z odpovědi modelu a ceny v textu", () => {
  const offers = parseOffers('Tady:\n```json\n[{"product":"Máslo 250 g","price":"39,90","valid_to":"2026-11-18","source_url":"https://www.penny.cz/a"},{"product":"bez ceny","valid_to":"2026-11-18","source_url":"x"}]\n```');
  eq(offers.length, 1);
  eq(offers[0].price, 39.9);
  eq(parseOffers("nic tu není"), []);
  ok(mentionsPrice("Máslo za 39,90 Kč", 39.9));
  ok(mentionsPrice('"price": 39.9', 39.9));
  ok(!mentionsPrice("Máslo za 49,90 Kč", 39.9));
});

const offer = {
  product: "Máslo 250 g",
  price: 39.9,
  valid_to: "2026-11-18",
  source_url: "https://www.penny.cz/nabidky/maslo",
};

Deno.test("ověření: citace oficiálního webu s cenou", async () => {
  const fetchNever = () => Promise.reject(new Error("nemá se stahovat"));
  const v = await verifyOffer("penny", offer, {
    supports: [{ text: '"product": "Máslo 250 g", "price": 39.9', sources: ["penny.cz"] }],
    sources: [],
  }, TODAY, fetchNever);
  eq(v.verified, true);
  eq(v.method, "citace");
});

Deno.test("ověření: citace cizího webu nestačí, rozhodne stránka", async () => {
  const page = (html: string) => (_url: string) => Promise.resolve(new Response(html, { status: 200 }));
  const evidence = { supports: [{ text: "Máslo 39,90", sources: ["kupi.cz"] }], sources: [] };
  const yes = await verifyOffer("penny", offer, evidence, TODAY, page("<h2>Máslo</h2><b>39,90&nbsp;Kč</b>"));
  eq(yes.verified, true);
  eq(yes.method, "stránka");
  const no = await verifyOffer("penny", offer, evidence, TODAY, page("<h2>Máslo</h2><b>49,90 Kč</b>"));
  eq(no.verified, false);
});

Deno.test("ověření: neoficiální zdroj a prošlá akce", async () => {
  const f = () => Promise.reject(new Error("x"));
  eq((await verifyOffer("penny", { ...offer, source_url: "https://www.kupi.cz/x" }, null, TODAY, f)).verified, false);
  eq((await verifyOffer("penny", { ...offer, valid_to: "2026-11-01" }, null, TODAY, f)).reason, "akce už skončila");
});

Deno.test("automatický výběr: zdarma, v limitu; placený jen povolený", () => {
  const g = { id: "gemini" as const, configured: true, free: true, allowed: true, usedToday: 0, limit: 400 };
  const o = { id: "openai" as const, configured: true, free: false, allowed: false, usedToday: 0, limit: null };
  eq(chooseProvider([g, o])?.id, "gemini");
  eq(chooseProvider([{ ...g, usedToday: 400 }, o]), null, "placený bez povolení ne");
  eq(chooseProvider([{ ...g, configured: false }, { ...o, allowed: true }])?.id, "openai");
});

// ---------------------------------------------------------- celý průběh

const ENV = {
  supabaseUrl: "https://db.test",
  anonKey: "anon",
  serviceKey: "sb_secret_x",
  geminiKey: "gem",
  geminiModel: "gemini-2.5-flash-lite",
  geminiDailyLimit: 400,
  openaiKey: "sk-test",
  openaiModel: "gpt-5-mini",
  allowPaid: false,
};

function req(body: unknown, token = "tok") {
  return new Request("https://fn.test/prices", {
    method: "POST",
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      "Content-Type": "application/json",
      Origin: "https://hincep-lab.github.io",
    },
    body: JSON.stringify(body),
  });
}

function fakeServer() {
  const scans = new Set<string>();
  const offers: any[] = [];
  const calls = { gemini: 0, openai: 0, page: 0 };
  let usage = 0;
  const fetchImpl = async (url: string, init: RequestInit = {}) => {
    const h = (init.headers ?? {}) as Record<string, string>;
    if (url.endsWith("/auth/v1/user")) {
      return h.Authorization === "Bearer tok" ? Response.json({ id: "pavel" }) : new Response("{}", { status: 401 });
    }
    if (url.startsWith("https://db.test/rest/v1/")) {
      const path = decodeURIComponent(url.slice("https://db.test/rest/v1/".length));
      if (path.startsWith("price_scans?select")) {
        const chain = path.match(/chain=eq\.(\w+)/)![1];
        return Response.json([...scans].filter((s) => s.startsWith(chain + "|")).map((s) => ({ product_key: s.split("|")[1] })));
      }
      if (path.startsWith("price_scans?on_conflict")) {
        for (const r of JSON.parse(init.body as string)) scans.add(`${r.chain}|${r.product_key}`);
        return new Response("", { status: 201 });
      }
      if (path.startsWith("price_ai_usage?select")) return Response.json(usage ? [{ requests: usage }] : []);
      if (path.startsWith("price_ai_usage?on_conflict")) {
        usage = JSON.parse(init.body as string).requests;
        return new Response("", { status: 201 });
      }
      if (path === "price_offers") {
        const row = JSON.parse(init.body as string);
        if (offers.some((o) => o.chain === row.chain && o.product_key === row.product_key && o.price === row.price)) {
          return new Response("dup", { status: 409 });
        }
        offers.push(row);
        return new Response("", { status: 201 });
      }
      return new Response("neznámé " + path, { status: 500 });
    }
    if (url.includes("generativelanguage.googleapis.com")) {
      calls.gemini++;
      ok(h["x-goog-api-key"] === "gem", "klíč Gemini jen v hlavičce na serveru");
      const body = JSON.parse(init.body as string);
      const prompt: string = body.contents[0].parts[0].text;
      const isPenny = prompt.includes("Penny");
      const text = isPenny
        ? '[{"product":"Máslo 250 g","price":39.9,"pack_qty":250,"pack_unit":"g","valid_to":"2026-11-18","source_url":"https://www.penny.cz/nabidky/maslo"},' +
          '{"product":"Mléko 1 l","price":19.9,"valid_to":"2026-11-18","source_url":"https://www.penny.cz/nabidky/mleko"}]'
        : "[]";
      return Response.json({
        candidates: [{
          content: { parts: [{ text }] },
          groundingMetadata: {
            groundingChunks: [{ web: { uri: "https://vertexaisearch.cloud.google.com/x", title: "penny.cz" } }],
            groundingSupports: [{ segment: { text: '"Máslo 250 g","price":39.9' }, groundingChunkIndices: [0] }],
          },
        }],
      });
    }
    if (url.includes("api.openai.com")) {
      calls.openai++;
      return Response.json({ output: [] });
    }
    // stránky obchodů (ověření textem)
    calls.page++;
    return new Response("<p>Mléko polotučné 24,90 Kč</p>", { status: 200 });
  };
  return { fetchImpl, scans, offers, calls };
}

Deno.test("hledání: ověřené a neověřené, mezipaměť, bez placeného OpenAI", async () => {
  const s = fakeServer();
  const r1 = await (await handle(req({ action: "refresh", products: ["Máslo", "Mléko"], chains: ["penny", "lidl"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r1.provider, "gemini");
  eq(r1.scanned, 4);
  eq(r1.verified, 1, "máslo má citaci oficiálního webu");
  eq(r1.unverified, 1, "cena mléka na stránce nesedí – neověřené");
  eq(s.offers.find((o) => o.product.startsWith("Mléko")).verified, false);
  eq(s.offers.find((o) => o.product.startsWith("Máslo")).verify_method, "citace");
  eq(s.calls.gemini, 2);
  eq(s.calls.openai, 0, "OpenAI je placené a není povolené");
  // Druhé hledání stejný den: vše z mezipaměti, žádný dotaz na AI.
  const r2 = await (await handle(req({ action: "refresh", products: ["máslo", "Mléko"], chains: ["penny", "lidl"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r2.cached, 4);
  eq(r2.scanned, 0);
  eq(s.calls.gemini, 2);
});

Deno.test("bez dostupného poskytovatele zdarma se nic neplatí", async () => {
  const s = fakeServer();
  const env = { ...ENV, geminiKey: "" };
  const r = await (await handle(req({ action: "refresh", products: ["Máslo"], chains: ["penny"] }), env, s.fetchImpl, NOW)).json();
  eq(r.errors, ["no_provider"]);
  eq(s.calls.openai, 0);
});

Deno.test("nabídka z ChatGPT se ověří stránkou; bez přihlášení nic", async () => {
  const s = fakeServer();
  const bad = await handle(req({ action: "submit", chain: "penny", offer: {} }), ENV, s.fetchImpl, NOW);
  eq(bad.status, 400);
  const r = await (await handle(req({
    action: "submit",
    chain: "penny",
    provider: "chatgpt",
    offer: { product: "Mléko polotučné 1 l", price: 24.9, valid_to: "2026-11-18", source_url: "https://www.penny.cz/nabidky/mleko" },
  }), ENV, s.fetchImpl, NOW)).json();
  eq(r.saved, true);
  eq(r.verified, true);
  eq(s.offers[0].provider, "chatgpt");
  eq((await handle(req({ action: "status" }, ""), ENV, s.fetchImpl, NOW)).status, 401);
});

Deno.test("stav poskytovatelů", async () => {
  const s = fakeServer();
  const r = await (await handle(req({ action: "status" }), ENV, s.fetchImpl, NOW)).json();
  eq(r.chosen, "gemini");
  eq(r.providers.map((p: any) => [p.id, p.free, p.allowed]), [["gemini", true, true], ["openai", false, false]]);
});

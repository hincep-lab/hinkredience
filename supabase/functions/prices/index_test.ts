import {
  chooseProvider,
  czStem,
  excerptsFor,
  geminiError,
  handle,
  isOfficial,
  matchStems,
  mentionsPrice,
  offerLinks,
  pageText,
  parseOffers,
  parseOffersDetailed,
  priceNearProduct,
  productKey,
  stemsMatch,
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

Deno.test("české tvary názvů: řízky ~ řízek, vepřová ~ vepřové, máslo ~ másla", () => {
  eq(czStem("rizky"), czStem("rizek"));
  eq(czStem("veprova"), czStem("veprove"));
  eq(czStem("maslo"), czStem("masla"));
  ok(stemsMatch(czStem("stehna"), czStem("stehenni")));
  ok(!stemsMatch(czStem("maso"), czStem("maslo")), "maso není máslo");
  eq(matchStems("Máslo – 250 g"), ["masl"]);
});

Deno.test("oficiální weby řetězců", () => {
  ok(isOfficial("penny", "https://www.penny.cz/nabidky/maslo"));
  ok(isOfficial("penny", "penny.cz"), "název webu z citace Gemini");
  ok(!isOfficial("penny", "https://www.kupi.cz/penny"));
  ok(!isOfficial("penny", "https://penny.cz.evil.com/"));
  ok(!isOfficial("penny", "http://www.penny.cz/"), "jen https");
  ok(!isOfficial("lidl", "https://www.penny.cz/"));
});

Deno.test("čtení JSON z odpovědi modelu, důvody odmítnutí a ceny v textu", () => {
  const offers = parseOffers('Tady:\n```json\n[{"product":"Máslo 250 g","price":"39,90","valid_to":"2026-11-18","source_url":"https://www.penny.cz/a"},{"product":"bez ceny","valid_to":"2026-11-18","source_url":"x"}]\n```');
  eq(offers.length, 1);
  eq(offers[0].price, 39.9);
  eq(parseOffers("nic tu není"), []);
  const d = parseOffersDetailed('[{"product":"Máslo","price":"39,90 Kč"},{"product":"Mléko","valid_to":"2026-11-18"}]', "https://www.penny.cz/nabidky");
  eq(d.offers.length, 0);
  eq(d.rejected, [
    { product: "Máslo", reason: "chybí platnost" },
    { product: "Mléko", reason: "chybí cena" },
  ]);
  eq(parseOffersDetailed("Nenašel jsem nic.").note, "odpověď neobsahuje pole JSON");
  ok(mentionsPrice("Máslo za 39,90 Kč", 39.9));
  ok(mentionsPrice('"price": 39.9', 39.9));
  ok(!mentionsPrice("Máslo za 49,90 Kč", 39.9));
});

Deno.test("cena musí být na stránce u produktu, ne kdekoli", () => {
  const filler = " Lorem ipsum dolor sit amet. ".repeat(30);
  const text = `Kuřecí prsní řízek 1 kg 149,90 Kč ${filler} Milka 39,90 Kč`;
  ok(priceNearProduct(text, "Kuřecí prsní řízky", 149.9));
  ok(!priceNearProduct(text, "Kuřecí prsní řízky", 39.9), "cena patří jinému zboží");
  ok(!priceNearProduct(text, "Máslo", 149.9));
});

Deno.test("text stránky včetně dat JSON a odkazy na akce", () => {
  const html = '<h1>Akce</h1><script type="application/json">{"name":"M\\u00e1slo 250 g","price":39.9}</script><script>var x=1</script>';
  const t = pageText(html);
  ok(t.includes("Máslo 250 g") && t.includes("39.9") && !t.includes("var x"));
  eq(offerLinks([
    "https://www.lidl.cz/c/akcni-letak/s1",
    "https://www.lidl.cz/kariera",
    "https://www.lidl.cz/c/nabidka-tydne/s2",
    "https://www.lidl.cz/letak.pdf",
  ]), ["https://www.lidl.cz/c/akcni-letak/s1", "https://www.lidl.cz/c/nabidka-tydne/s2"]);
});

Deno.test("úseky stránky jen kolem hledaných produktů", () => {
  const text = "Úvod. " + "x ".repeat(500) + "Vepřová pečeně bez kosti 1 kg 129,90 Kč" + " y".repeat(500) + " Máslo 250 g 44,90 Kč";
  const { excerpt, matched } = excerptsFor(text, ["Vepřová pečeně bez kosti – 1 kg", "Máslo – 250 g", "Kuřecí prsní řízky – 1 kg"]);
  eq(matched, ["Vepřová pečeně bez kosti – 1 kg", "Máslo – 250 g"]);
  ok(excerpt.includes("129,90") && excerpt.includes("44,90") && excerpt.length < 1600);
});

Deno.test("srozumitelné chyby Gemini", () => {
  const e404 = geminiError(404, JSON.stringify({ error: { message: "This model models/gemini-2.5-flash-lite is no longer available to new users." } }), "gemini-2.5-flash-lite");
  eq(e404.code, "model_unavailable");
  ok(e404.message.includes("no longer available"));
  eq(geminiError(429, '{"error":{"message":"Quota exceeded for grounding"}}', "m").code, "search_not_free");
  eq(geminiError(400, '{"error":{"message":"API key not valid. AIzaSyABC"}}', "m").code, "bad_key");
  ok(!geminiError(400, '{"error":{"message":"API key not valid. AIzaSyABC"}}', "m").message.includes("AIza"), "klíč se nevypisuje");
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
  const page = (html: string) => (_url: string) => Promise.resolve(new Response(html, { status: 200, headers: { "content-type": "text/html" } }));
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
  geminiExtractModel: "gemini-3.5-flash-lite",
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

const PENNY_PAGE = `<html><body><h1>Akční nabídka</h1><p>Platí od st 11.11. do út 17.11.2026</p>
<div class="tile"><h3>Máslo 250 g</h3><span>39,90 Kč</span></div>
<div class="tile"><h3>Merci Together 175 g</h3><span>49,90 Kč</span></div>
<a href="/nabidky/maso">Maso v akci</a></body></html>`;

interface Opts {
  /** Co vrátí čtení stránky (model 3.5). */
  extract?: string;
  /** Status vyhledávání Google (model 2.5): 200 nebo chyba. */
  searchStatus?: number;
  /** Stránky řetězců: adresa → HTML (jinak 404). */
  pages?: Record<string, string>;
}

function fakeServer(opts: Opts = {}) {
  const scans = new Set<string>();
  const offers: any[] = [];
  const calls = { extract: 0, search: 0, openai: 0, page: 0 };
  let usage = 0;
  const pages = opts.pages ?? { "https://www.penny.cz/nabidky": PENNY_PAGE };
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
      ok(h["x-goog-api-key"] === "gem", "klíč Gemini jen v hlavičce na serveru");
      const body = JSON.parse(init.body as string);
      if (body.tools) {
        calls.search++;
        ok(url.includes("gemini-2.5-flash-lite"));
        const status = opts.searchStatus ?? 404;
        if (status !== 200) {
          return Response.json({ error: { message: "This model models/gemini-2.5-flash-lite is no longer available to new users." } }, { status });
        }
        const prompt: string = body.contents[0].parts[0].text;
        const text = prompt.includes("Lidl")
          ? '[{"product":"Kuřecí prsní řízky 1 kg","price":149.9,"valid_to":"2026-11-22","source_url":"https://www.lidl.cz/p/rizky"}]'
          : "[]";
        return Response.json({
          candidates: [{
            content: { parts: [{ text }] },
            groundingMetadata: {
              webSearchQueries: ["lidl akce kuřecí řízky"],
              groundingChunks: [{ web: { uri: "https://vertexaisearch.cloud.google.com/x", title: "lidl.cz" } }],
              groundingSupports: [{ segment: { text: '"price":149.9' }, groundingChunkIndices: [0] }],
            },
          }],
        });
      }
      calls.extract++;
      ok(url.includes("gemini-3.5-flash-lite"), "stránku čte model bez vyhledávání");
      ok(body.contents[0].parts[0].text.includes("39,90"), "AI dostane text stránky");
      const text = opts.extract ??
        '[{"product":"Máslo 250 g","price":39.9,"pack_qty":250,"pack_unit":"g","valid_from":"2026-11-11","valid_to":"2026-11-17","source_url":"https://podvod.example/x"},' +
          '{"product":"Máslo 250 g","price":29.9,"valid_to":"2026-11-17"}]';
      return Response.json({ candidates: [{ content: { parts: [{ text }] }, finishReason: "STOP" }] });
    }
    if (url.includes("api.openai.com")) {
      calls.openai++;
      return Response.json({ output: [] });
    }
    calls.page++;
    const html = pages[url];
    return html !== undefined
      ? new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } })
      : new Response("nenalezeno", { status: 404, headers: { "content-type": "text/html" } });
  };
  return { fetchImpl, scans, offers, calls };
}

const LIST = ["Kuřecí prsní řízky – 1 kg", "Vepřová pečeně bez kosti – 1 kg", "Máslo – 250 g"];

Deno.test("hledání ze stránky: AI jen čte, cenu ověří stránka, vymyšlená cena neprojde", async () => {
  const s = fakeServer();
  const r = await (await handle(req({ action: "refresh", products: LIST, chains: ["penny"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r.provider, "gemini");
  eq(r.found, 2);
  eq(r.verified, 1, "39,90 je na stránce u másla");
  eq(r.unverified, 1, "29,90 na stránce není – neověřené, mimo porovnání");
  eq(r.saved, 2);
  const butter = s.offers.find((o) => o.price === 39.9);
  eq(butter.verify_method, "stránka");
  eq(butter.source_url, "https://www.penny.cz/nabidky", "zdroj je stažená stránka, ne text modelu");
  eq(s.offers.find((o) => o.price === 29.9).verified, false);
  const d = r.diag[0];
  eq(d.pages[0].matched, ["Máslo – 250 g"]);
  eq(d.ai[0].mode, "stránka");
  eq(d.offers.map((o: any) => [o.price, o.verified, o.saved]), [[39.9, true, "uloženo"], [29.9, false, "uloženo"]]);
  eq(s.calls.search, 0, "ze stránky něco je – vyhledávání se nezkouší");
  eq(s.calls.openai, 0);
});

Deno.test("nový klíč bez modelu 2.5: chyba se pozná a neschová; mezipaměť jen po úspěchu", async () => {
  const s = fakeServer({ pages: {} }); // stránky nejdou stáhnout
  const r = await (await handle(req({ action: "refresh", products: ["Máslo"], chains: ["penny", "lidl"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r.found, 0);
  ok(r.errors.includes("search:model_unavailable"), JSON.stringify(r.errors));
  ok(r.errors.some((e: string) => e.startsWith("penny: ") && e.includes("no longer available")));
  eq(s.calls.search, 1, "po první chybě modelu se vyhledávání dál nezkouší");
  eq(r.diag[1].ai[0].error.startsWith("přeskočeno"), true);
  eq(s.scans.size, 0, "chybné hledání se neuloží do mezipaměti");
  // Opakovaný test hned znovu proběhne (nic není „dnes už prohledáno“).
  const r2 = await (await handle(req({ action: "refresh", products: ["Máslo"], chains: ["penny"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r2.cached, 0);
});

Deno.test("vyhledávání Google u starších klíčů dál funguje (citace)", async () => {
  const s = fakeServer({ searchStatus: 200, pages: {} });
  const r = await (await handle(req({ action: "refresh", products: ["Kuřecí prsní řízky"], chains: ["lidl"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r.verified, 1);
  eq(s.offers[0].verify_method, "citace");
  eq(r.diag[0].ai[0].queries, 1);
});

Deno.test("mezipaměť po úspěchu a obejití pro test (force)", async () => {
  const s = fakeServer();
  await handle(req({ action: "refresh", products: ["Máslo"], chains: ["penny"] }), ENV, s.fetchImpl, NOW);
  eq(s.calls.extract, 1);
  const cached = await (await handle(req({ action: "refresh", products: ["máslo"], chains: ["penny"] }), ENV, s.fetchImpl, NOW)).json();
  eq(cached.cached, 1);
  eq(cached.scanned, 0);
  eq(s.calls.extract, 1, "z mezipaměti se AI neptá");
  const forced = await (await handle(req({ action: "refresh", products: ["máslo"], chains: ["penny"], force: true }), ENV, s.fetchImpl, NOW)).json();
  eq(s.calls.extract, 2);
  eq(forced.duplicates, 2, "stejné nabídky se neuloží dvakrát");
  eq(forced.saved, 0);
});

Deno.test("odmítnuté nabídky mají důvod", async () => {
  const s = fakeServer({
    extract: '[{"product":"Máslo 250 g","price":39.9},{"product":"Máslo 250 g","price":39.9,"valid_to":"2027-03-01"}]',
  });
  const r = await (await handle(req({ action: "refresh", products: ["Máslo"], chains: ["penny"] }), ENV, s.fetchImpl, NOW)).json();
  eq(r.rejected, 2);
  eq(r.diag[0].rejected.map((x: any) => x.reason), ["chybí platnost", "nepravděpodobná platnost do 2027-03-01"]);
  eq(s.offers.length, 0);
});

Deno.test("bez dostupného poskytovatele zdarma se nic neplatí", async () => {
  const s = fakeServer();
  const env = { ...ENV, geminiKey: "" };
  const r = await (await handle(req({ action: "refresh", products: ["Máslo"], chains: ["penny"] }), env, s.fetchImpl, NOW)).json();
  eq(r.errors, ["no_provider"]);
  eq(s.calls.openai, 0);
  eq(s.calls.page, 0);
});

Deno.test("nabídka z ChatGPT se ověří stránkou; bez přihlášení nic", async () => {
  const s = fakeServer({ pages: { "https://www.penny.cz/nabidky/maslo": PENNY_PAGE } });
  const bad = await handle(req({ action: "submit", chain: "penny", offer: {} }), ENV, s.fetchImpl, NOW);
  eq(bad.status, 400);
  const r = await (await handle(req({
    action: "submit",
    chain: "penny",
    provider: "chatgpt",
    offer: { product: "Máslo 250 g", price: 39.9, valid_to: "2026-11-17", source_url: "https://www.penny.cz/nabidky/maslo" },
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

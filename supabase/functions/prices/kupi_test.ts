import { handle, kupiOffers, kupiPack, kupiSearchUrl, kupiValidity, normalizeOffers, productMatches } from "./index.ts";
import { KUPI_MASLO } from "./testdata/kupi_maslo.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} ${x} !== ${y}`);
}
function ok(c: unknown, msg = "assert") {
  if (!c) throw new Error(msg);
}

const TODAY = "2026-11-18";
const html = KUPI_MASLO;

Deno.test("kupi.cz: platnost akce", () => {
  eq(kupiValidity("platí do úterý 24. 11.", TODAY), { from: null, to: "2026-11-24" });
  eq(kupiValidity("čt 19. 11. – ne 22. 11.", TODAY), { from: "2026-11-19", to: "2026-11-22" });
  eq(kupiValidity("zítra končí", TODAY), { from: null, to: "2026-11-19" });
  eq(kupiValidity("dnes končí", TODAY), { from: null, to: TODAY });
  eq(kupiValidity("platí do pondělí 4. 1.", "2026-12-28"), { from: null, to: "2027-01-04" });
  eq(kupiValidity("po 28. 12. – ne 3. 1.", "2026-12-28"), { from: "2026-12-28", to: "2027-01-03" });
  eq(kupiValidity("platí od čtvrtka 26. 11.", TODAY), { from: "2026-11-26", to: null });
});

Deno.test("kupi.cz: balení", () => {
  eq(kupiPack("32,90 Kč / 250 g –34 %"), { qty: 250, unit: "g", label: "250 g" });
  eq(kupiPack("234,90 Kč / 100x 10 g"), { qty: 1000, unit: "g", label: "100× 10 g" });
  eq(kupiPack("19,90 Kč / 1,5 l"), { qty: 1.5, unit: "l", label: "1,5 l" });
  eq(kupiPack("19,90 Kč"), { qty: null, unit: "", label: "" });
});

Deno.test("kupi.cz: nabídky sušických obchodů ze stránky hledání", () => {
  const { offers, rejected } = kupiOffers(html, TODAY);
  const short = offers.map((o) => `${o.chain}|${o.product}|${o.price}|${o.pack_qty}${o.pack_unit}|${o.valid_from ?? ""}-${o.valid_to}|${o.conditions}`);
  eq(short, [
    "penny|Máslo Jihočeské Madeta|32.9|250g|-2026-11-20|",
    "lidl|Máslo Milkpol|29.9|250g|2026-11-19-2026-11-22|max 5 ks/osoba/den",
    "albert|Máslo Česká chuť|27.9|250g|-2026-11-24|Platí pro členy klubu; platí pouze s mobilní aplikací",
    "albert|Máslo Česká chuť|32.9|250g|-2026-11-24|",
    "jip|Máslo Opočenské Bohemilk|234.9|1000g|-2026-11-24|",
    "tesco|Máslo Milko|24.9|250g|-2026-11-19|Cena s Clubcard",
    "penny|Margarín máslová příchuť Perla|34.9|450g|-2026-11-20|",
  ]);
  // BILLA v Sušici nehledáme, COOP leták Tip a Tuty není sušický (ZKD Sušice).
  ok(!offers.some((o) => o.shop === "billa"), "billa");
  ok(rejected.some((r) => r.product.includes("COOP") && /není pro Sušici/.test(r.reason)), "coop odmítnut");
  eq(offers[0].source_url, "https://www.kupi.cz/letak/penny-market-letak-550?map=220451505");
  eq(offers[4].label, "100× 10 g");
  // Skript na stránce (cena v datech reklamy) se nečte.
  ok(!offers.some((o) => o.price === 99.9), "skript");
});

Deno.test("kupi.cz: shoda s položkou a věrnostní cena", () => {
  const { offers } = kupiOffers(html, TODAY);
  const forButter = offers.filter((o) => productMatches("máslo", o.product));
  ok(!forButter.some((o) => o.product.startsWith("Margarín")), "margarín není máslo");
  const albert = normalizeOffers("albert", offers.filter((o) => o.chain === "albert"));
  eq(albert.offers.map((o) => [o.price, o.loyalty]), [[27.9, "Můj Albert"], [32.9, ""]]);
});

Deno.test("kupi.cz: adresa hledání jen zboží v akci", () => {
  eq(kupiSearchUrl(" kuřecí prsa "), "https://www.kupi.cz/hledej?f=ku%C5%99ec%C3%AD%20prsa&vse=0");
});

Deno.test("kupi.cz v celém hledání: uloží ověřenou akci bez AI a leták pak Gemini nečte", async () => {
  const saved: any[] = [];
  const asked: string[] = [];
  const fetchImpl = async (url: string, init: RequestInit = {}) => {
    asked.push(url);
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: "pavel" });
    if (url.startsWith("https://db.test/rest/v1/")) {
      const path = decodeURIComponent(url.slice("https://db.test/rest/v1/".length));
      if (path === "price_offers" && init.method === "POST") {
        saved.push(JSON.parse(init.body as string));
        return new Response("", { status: 201 });
      }
      if (path.includes("select")) return Response.json([]);
      return new Response("", { status: 201 });
    }
    if (url.startsWith("https://www.kupi.cz/hledej")) {
      const r = new Response(KUPI_MASLO, { status: 200, headers: { "content-type": "text/html" } });
      Object.defineProperty(r, "url", { value: url });
      return r;
    }
    if (url.includes("generativelanguage")) throw new Error("Gemini se nemá volat");
    return new Response("<html></html>", { status: 200 });
  };
  const env = {
    supabaseUrl: "https://db.test", anonKey: "anon", serviceKey: "sb_secret_x", geminiKey: "gem",
    geminiModel: "x", geminiExtractModel: "x", geminiDailyLimit: 400, openaiKey: "", openaiModel: "", allowPaid: false,
  };
  const res = await handle(new Request("https://fn.test/prices", {
    method: "POST",
    headers: { Authorization: "Bearer tok", "Content-Type": "application/json" },
    body: JSON.stringify({ action: "refresh", products: ["máslo"], chains: ["penny", "albert"] }),
  }), env, fetchImpl, new Date("2026-11-18T10:00:00Z"));
  const body = await res.json();
  eq(res.status, 200);
  eq(asked.filter((u) => u.startsWith("https://www.kupi.cz/")).length, 1, "jedno hledání pro oba řetězce");
  eq(saved.map((o) => [o.chain, o.product, o.price, o.provider, o.verified, o.verify_method, o.kind]), [
    ["penny", "Máslo Jihočeské Madeta", 32.9, "kupi", true, "kupi", "promo"],
    ["albert", "Máslo Česká chuť", 27.9, "kupi", true, "kupi", "loyalty"],
    ["albert", "Máslo Česká chuť", 32.9, "kupi", true, "kupi", "promo"],
  ]);
  ok(!saved.some((o) => o.product.startsWith("Margarín")), "margarín");
  eq(body.verified, 3);
});

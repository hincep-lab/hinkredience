import {
  albertFlyer,
  albertLeaflets,
  chooseProvider,
  coopFlyer,
  czStem,
  dateRange,
  flyersKey,
  geminiError,
  handle,
  isOfficial,
  isSource,
  jipLeaflets,
  jsStringArray,
  lidlFlyer,
  lidlSlugs,
  matchStems,
  mentionsPrice,
  pageText,
  parseFlyerOffers,
  parseOffers,
  parseOffersDetailed,
  pennyProducts,
  pickPages,
  priceInFlyerText,
  priceNearProduct,
  productKey,
  productMatches,
  stemsMatch,
  tescoFlyers,
  unflattenNuxt,
  verifiedByText,
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
  ok(isOfficial("penny", "https://files.rewe.co.at/PennyIntLeaflet/CZ/11_11_2026_tl/7/"), "leták Penny");
  ok(isOfficial("jip", "https://www.jip-potraviny.cz/akcni-letaky/") && !isOfficial("jip", "https://www.jip.cz/"), "jip.cz je papírna");
  ok(isOfficial("coop", "https://www.zkdsusice.cz/letak_tuty"));
  ok(isSource("tesco", "https://digitalcontent.api.tesco.com/v2/media/x.jpeg") && !isOfficial("tesco", "https://digitalcontent.api.tesco.com/x"));
  ok(!isSource("lidl", "https://leaflets.schwarz.evil.com/x"));
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

Deno.test("text stránky včetně dat JSON", () => {
  const html = '<h1>Akce</h1><script type="application/json">{"name":"M\\u00e1slo 250 g","price":39.9}</script><script>var x=1</script>';
  const t = pageText(html);
  ok(t.includes("Máslo 250 g") && t.includes("39.9") && !t.includes("var x"));
});

Deno.test("srozumitelné chyby Gemini", () => {
  const e404 = geminiError(404, JSON.stringify({ error: { message: "This model models/gemini-2.5-flash-lite is no longer available to new users." } }), "gemini-2.5-flash-lite");
  eq(e404.code, "model_unavailable");
  ok(e404.message.includes("no longer available"));
  const q = geminiError(429, '{"error":{"message":"Quota exceeded","details":[{"retryDelay":"17s"}]}}', "m");
  eq([q.code, q.retryAfter], ["quota", 17]);
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

// ------------------------------------------------------------ shoda názvů

Deno.test("položka × produkt: máslo není máslový, bez kosti není s kostí", () => {
  ok(productMatches("Máslo – 250 g", "Madeta Jihočeské máslo 250 g"));
  ok(productMatches("Máslo", "MÁSLO BONI 250 g"));
  ok(!productMatches("Máslo", "Chléb toustový máslový Crip Crop"), "pečivo není máslo");
  ok(!productMatches("Máslo", "Perla máslová příchuť 450 g"));
  ok(!productMatches("Máslo", "Maso mleté"));
  ok(productMatches("Vepřová pečeně bez kosti – 1 kg", "VEPŘOVÁ PEČENĚ balená ve vakuu"), "„bez kosti“ nemusí být v názvu");
  ok(productMatches("Vepřová pečeně bez kosti", "Vepřová pečeně bez kosti s řetízkem"));
  ok(!productMatches("Vepřová pečeně bez kosti", "Vepřová pečeně s kostí"));
  ok(!productMatches("Vepřová pečeně bez kosti", "Vepřová krkovice bez kosti"));
  ok(productMatches("Kuřecí prsní řízky – 1 kg", "Kuřecí prsní řízky chlazené"));
  ok(!productMatches("Kuřecí prsní řízky", "Kuřecí stehenní řízky"));
  ok(productMatches("Jahodový jogurt", "Jogurt jahoda 150 g"), "přídavné jméno v položce smí odpovídat podstatnému");
});

// ------------------------------------------------------------ data a ceny v textu letáku

Deno.test("rozsahy dat z letáků", () => {
  eq(dateRange("Platnost: 11. 11. 2026 – 17. 11. 2026"), { from: "2026-11-11", to: "2026-11-17" });
  eq(dateRange("Tato nabídka platí od 4.11.2026 do 17.11.2026 nebo do vyprodání"), { from: "2026-11-04", to: "2026-11-17" });
  eq(dateRange("Nabídka platná od středy 11. 11. do úterý 17. 11. 2026"), { from: "2026-11-11", to: "2026-11-17" });
  eq(dateRange("16. 11. - 18. 11. 2026"), { from: "2026-11-16", to: "2026-11-18" });
  eq(dateRange("29. 12. – 4. 1. 2027"), { from: "2026-12-29", to: "2027-01-04" });
  eq(dateRange("bez data"), { from: null, to: null });
});

Deno.test("cena v textu letáku: 34,90 i 3490, „34 90“, „90 109“ a 199,-", () => {
  ok(priceInFlyerText("máslo 250 g 54,90 34 90 44 90", 34.9));
  ok(priceInFlyerText("-40 % 2390 199,-/", 23.9));
  ok(priceInFlyerText("řízky mix 189,-/ -21 % 90 109 109", 109.9));
  ok(priceInFlyerText("Kachna 199,-/ 1 kg", 199));
  ok(priceInFlyerText("bez DPH 62,41 69,90 s DPH", 69.9));
  ok(!priceInFlyerText("máslo 54,90 44 90", 34.9));
  ok(!priceInFlyerText("134,90 a 34,905", 34.9), "část jiného čísla se nepočítá");
  ok(!priceInFlyerText("1199,-", 199));
  const page = { n: 3, image: "x", link: "x", fullText: true, text: "Madeta Jihočeské máslo • 250 g • 100 g = 17,96 Kč 54,90 34 90 44 90" };
  ok(verifiedByText(page, "Madeta Jihočeské máslo", 34.9));
  ok(!verifiedByText(page, "Madeta Jihočeské máslo", 31.9), "vymyšlená cena");
  ok(!verifiedByText(page, "Kuřecí prsní řízky", 34.9), "jiný produkt");
  ok(!verifiedByText({ ...page, fullText: false }, "Madeta Jihočeské máslo", 34.9), "klíčová slova nestačí");
  const far = { ...page, text: "17,90 24,90 109,90 " + "x ".repeat(400) + " KUŘECÍ PRSNÍ ŘÍZKY chlazené | cena za 1 kg" };
  ok(!verifiedByText(far, "Kuřecí prsní řízky", 109.9), "cena daleko od názvu → rozhodne kontrolní čtení");
});

// ------------------------------------------------------------ zdroje jednotlivých řetězců

/** Data Nuxt (devalue) jako na penny.cz: hodnoty odkazují indexy do pole. */
function nuxt(products: Record<string, unknown>[]): string {
  const arr: unknown[] = [["ShallowReactive", 1], { data: 2 }, { offers: 3 }, []];
  const put = (v: unknown): number => {
    if (v && typeof v === "object") {
      const o: Record<string, number> = {};
      const at = arr.push(o) - 1;
      for (const [k, x] of Object.entries(v)) o[k] = put(x);
      return at;
    }
    return arr.push(v) - 1;
  };
  for (const p of products) (arr[3] as number[]).push(put(p));
  return `<html><body><script type="application/json" data-nuxt-data="nuxt-app" id="__NUXT_DATA__">${JSON.stringify(arr)}</script></body></html>`;
}

const PENNY_DATA = nuxt([
  {
    name: "Máslo Boni", amount: "250", volumeLabelShort: "g", category: "MÁSLO", sku: "88-1", slug: "maslo-boni-881",
    price: { regular: { value: 2990 }, validityStart: "2026-11-11", validityEnd: "2026-11-17" },
  },
  {
    name: "Bramborový snack Strašidýlka Solty", amount: "55", volumeLabelShort: "g", category: "SNACK", sku: "88-2", slug: "snack-882",
    price: { regular: { value: 1990 }, loyalty: { value: 990 }, validityStart: "2026-11-11", validityEnd: "2026-11-17" },
  },
  {
    name: "Chléb toustový máslový", amount: "500", volumeLabelShort: "g", category: "PEČIVO", sku: "88-3", slug: "chleb-883",
    price: { regular: { value: 2390 }, validityStart: "2026-11-11", validityEnd: "2026-11-17" },
  },
]);

Deno.test("Penny: akční položky z dat stránky bez AI", () => {
  eq(unflattenNuxt([["Ref", 1], { a: 2 }, "x"]), { a: "x" });
  const o = pennyProducts(PENNY_DATA);
  eq(o.map((x) => [x.product, x.price, x.conditions, x.pack_qty, x.pack_unit, x.valid_to]), [
    ["Máslo Boni", 29.9, "", 250, "g", "2026-11-17"],
    ["Bramborový snack Strašidýlka Solty", 19.9, "bez PENNY karty", 55, "g", "2026-11-17"],
    ["Bramborový snack Strašidýlka Solty", 9.9, "s PENNY kartou", 55, "g", "2026-11-17"],
    ["Chléb toustový máslový", 23.9, "", 500, "g", "2026-11-17"],
  ]);
  eq(o[0].source_url, "https://www.penny.cz/products/maslo-boni-881");
  eq(pennyProducts("<html>nic</html>"), []);
});

const TESCO_LIST = `<html><script id="__NEXT_DATA__" type="application/json">${JSON.stringify({
  props: { pageProps: { __APOLLO_STATE__: {
    "Leaflet:787": {
      __typename: "Leaflet", id: 787, slug: "tesco-letak-2026-11-11", type: "HM",
      validFrom: "2026-11-11T07:00:00.000Z", validTo: "2026-11-17T22:59:59.000Z",
      pages: [
        { __typename: "LeafletMetadataPage", pagePNG: "https://digitalcontent.api.tesco.com/v2/media/dotcom-cz/a/2026_P37_CZ_HM-CHM.2.jpeg" },
        { __typename: "LeafletMetadataPage", pagePNG: "https://digitalcontent.api.tesco.com/v2/media/dotcom-cz/b/2026_P37_CZ_HM-CHM.1.jpeg" },
        { __typename: "LeafletMetadataPage", pagePNG: "https://evil.example/x.3.jpeg" },
      ],
    },
    "Leaflet:788": { __typename: "Leaflet", id: 788, slug: "tesco-letak-2026-11-11", type: "SM", validFrom: "2026-11-11T07:00:00.000Z", validTo: "2026-11-17T22:59:59.000Z", pages: [] },
    "Leaflet:790": { __typename: "Leaflet", id: 790, slug: "tesco-letak-2026-11-18", type: "HM", validFrom: "2026-11-18T07:00:00.000Z", validTo: "2026-11-24T22:59:59.000Z", pages: [{ pagePNG: "https://digitalcontent.api.tesco.com/x.1.jpeg" }] },
  } } },
})}</script></html>`;

Deno.test("Tesco: leták hypermarketů z dat stránky (jen platný, jen oficiální obrázky)", () => {
  const f = tescoFlyers(TESCO_LIST, TODAY);
  eq(f.length, 1);
  eq([f[0].validFrom, f[0].validTo, f[0].pages.map((p) => p.n)], ["2026-11-11", "2026-11-17", [1, 2]]);
  eq(f[0].pages[0].link, "https://www.itesco.cz/akcni-nabidky/letaky-a-katalogy/hypermarkety/tesco-letak-2026-11-11/1");
  ok(f[0].pages[0].image.endsWith(".1.jpeg?w=1000"));
});

const LIDL_FLYER = {
  flyer: {
    name: "Akční leták OD PONDĚLÍ", title: "16. 11. - 18. 11. 2026", offerStartDate: "2026-11-16", offerEndDate: "2026-11-22",
    pages: [
      { number: 1, keyWords: "Ředkvičky Svazek Vepřová Krkovice Kosti", altText: "", image: "https://imgproxy.leaflets.schwarz/a/1.jpg", zoom: "https://imgproxy.leaflets.schwarz/a/1z.jpg" },
      { number: 9, keyWords: "Super Cena Kuřecí Zadní Čtvrtky Kukuřičné Prsní Řízky Krůtí", altText: "", image: "https://imgproxy.leaflets.schwarz/a/9.jpg", zoom: "https://imgproxy.leaflets.schwarz/a/9z.jpg" },
      { number: 10, keyWords: "Máslový Twister Chléb Podmáslím", altText: "", image: "https://imgproxy.leaflets.schwarz/a/10.jpg" },
    ],
  },
};

Deno.test("Lidl: odkazy na letáky, platnost z titulku a výběr stran podle klíčových slov", () => {
  eq(lidlSlugs('<a href="/l/cs/letak/akcni-letak-od-pondeli-16-11-18-11-2026/ar/0">x</a><a href="/l/cs/letak/spotrebni-zbozi-16-11/ar/0">y</a><a href="https://www.lidl.cz/l/cs/letak/akcni-letaky-od-ctvrtka-19-11-22-11-2026/view">z</a>'),
    ["akcni-letak-od-pondeli-16-11-18-11-2026", "akcni-letaky-od-ctvrtka-19-11-22-11-2026"]);
  const f = lidlFlyer(LIDL_FLYER, "akcni-letak-od-pondeli-16-11-18-11-2026", TODAY)!;
  eq([f.validFrom, f.validTo, f.pages.length], ["2026-11-16", "2026-11-18", 3]);
  eq(lidlFlyer({ flyer: { ...LIDL_FLYER.flyer, title: "19. 11. - 22. 11. 2026" } }, "x", TODAY), null, "budoucí leták");
  const picked = pickPages(f, ["Kuřecí prsní řízky", "Máslo", "Vepřová pečeně bez kosti"], 6);
  eq(picked.map((p) => [p.page.n, p.items]), [[9, ["Kuřecí prsní řízky"]]]);
});

const ALBERT_LIST = `<html><style>.a{background:url(https://letaky.albert.cz/46sm_akcni_letak/cover_page.jpg)}</style><script id="__NEXT_DATA__" type="application/json">{"x":{"Leaflet:1":{"__typename":"Leaflet","id":"1","isDefault":true,"validityStartDateFormatted":"11.11.2026","validityEndDateFormatted":"17.11.2026","title":"Albert - 46HM","locationType":"HYPERMARKET","viewUrl":"https://letaky.albert.cz/46hm_akcni_letak/","documentType":"LEAFLET","stores":[{"__typename":"LeafletStore","localizedName":"Plzeň, Rokycanská"}]},"Leaflet:2":{"__typename":"Leaflet","id":"2","validityStartDateFormatted":"11.11.2026","validityEndDateFormatted":"17.11.2026","title":"Albert - 46SM","locationType":"SUPERMARKET","viewUrl":"https://letaky.albert.cz/46sm_akcni_letak/","documentType":"LEAFLET","stores":[{"__typename":"LeafletStore","localizedName":"Sušice, Hrádecká"},{"__typename":"LeafletStore","localizedName":"Sušice, T.G.Masaryka"}]},"Leaflet:3":{"__typename":"Leaflet","id":"3","validityStartDateFormatted":"18.11.2026","validityEndDateFormatted":"24.11.2026","locationType":"SUPERMARKET","viewUrl":"https://letaky.albert.cz/47sm_akcni_letak/","documentType":"LEAFLET","stores":[{"localizedName":"Sušice, Hrádecká"}]},"Leaflet:4":{"__typename":"Leaflet","id":"4","validityStartDateFormatted":"29.10.2026","validityEndDateFormatted":"17.11.2026","locationType":"SUPERMARKET","viewUrl":"https://letaky.albert.cz/44sm_akcni_katalog_xmass/","documentType":"CATALOG","stores":[{"localizedName":"Sušice, Hrádecká"}]}}}</script></html>`;

const ALBERT_SPREADS = [
  { pages: [{ number: 1, images: { at1200: "/90263/1/pages/p1-at1200.jpg", at2000: "/90263/1/pages/p1-at2000.jpg" }, text: "Vítejte\nAlbert leták" }] },
  { pages: [
    { number: 3, images: { at1200: "/90263/1/pages/p3-at1200.jpg", at2000: "/90263/1/pages/p3-at2000.jpg" }, text: "NEPORAZITELNÉ Galbani Mozzarella Madeta Jihočeské máslo\n• 250 g • 100 g = 17,96 Kč bez Aplikace / 13,96 Kč Aplikace 54,90 34 90 44 90" },
    { number: 23, images: { at1200: "/90263/1/pages/p23-at1200.jpg" }, text: "Kuřecí prsní a stehenní řízky mix • chlazené • 1 kg 189,-/ -21 % 90 109 Vepřová pečeně na kámen – plátky • chlazená • 1 kg 149 90" },
  ] },
];

Deno.test("Albert: leták pro Sušici z dat stránky, text i obrázky stran", () => {
  const l = albertLeaflets(ALBERT_LIST);
  eq(l.map((x) => [x.slug, x.from, x.to, x.leaflet, x.supermarket, x.susice]), [
    ["46hm_akcni_letak", "2026-11-11", "2026-11-17", true, false, false],
    ["46sm_akcni_letak", "2026-11-11", "2026-11-17", true, true, true],
    ["47sm_akcni_letak", "2026-11-18", "2026-11-24", true, true, true],
    ["44sm_akcni_katalog_xmass", "2026-10-29", "2026-11-17", false, true, true],
  ]);
  const f = albertFlyer(ALBERT_SPREADS, "46sm_akcni_letak", "2026-11-11", "2026-11-17")!;
  eq(f.pages.map((p) => p.n), [1, 3, 23]);
  eq(f.pages[1].image, "https://letaky.albert.cz/90263/1/pages/p3-at1200.jpg");
  eq(f.pages[1].link, "https://letaky.albert.cz/46sm_akcni_letak/page/3");
  const picked = pickPages(f, ["Kuřecí prsní řízky", "Vepřová pečeně bez kosti", "Máslo"], 6);
  eq(picked.map((p) => [p.page.n, p.items]), [[3, ["Máslo"]], [23, ["Kuřecí prsní řízky", "Vepřová pečeně bez kosti"]]]);
});

Deno.test("JIP: leták pro Sušici a text stran ze souboru prohlížeče letáku", () => {
  const html = `<article class="i-leaflet d-flex"><a href="/wp-content/uploads/file/CC-UCD-11-11-2026" title="Akční leták Svět potravin"></a><span>Platnost:</span> <span class="u-fw-600">11. 11. 2026 &#8211; </span><span class="u-fw-600">17. 11. 2026</span><span class="i-tag__title">Brno</span></article>
  <article class="i-leaflet d-flex"><a href="/wp-content/uploads/file/CC-UCC-11-11-2026" title="Akční leták JIP potraviny"></a><span>Platnost:</span> <span class="u-fw-600">11. 11. 2026 &#8211; </span><span class="u-fw-600">17. 11. 2026</span><span class="i-tag__title">Sušice</span></article>`;
  eq(jipLeaflets(html).map((l) => [l.href, l.from, l.to, l.susice]), [
    ["/wp-content/uploads/file/CC-UCD-11-11-2026", "2026-11-11", "2026-11-17", false],
    ["/wp-content/uploads/file/CC-UCC-11-11-2026", "2026-11-11", "2026-11-17", true],
  ]);
  eq(jsStringArray('var textForPages = ["JIP \\"POTRAVINY\\"   11. 11.", "Lay\\&s\\nchips 15,90", "posl\\u00e1 strana"];'),
    ['JIP "POTRAVINY"   11. 11.', "Lay&s chips 15,90", "poslá strana"]);
  eq(jsStringArray("alert(1)"), []);
});

const COOP_PAGE = `<html><main><h2>TUTY a TIP</h2><h3>Aktuální nabídka</h3><p class='text-center'>Tato nabídka platí od <b>4.11.2026</b> do <b>17.11.2026</b> nebo do vyprodání zásob.</p>
<a class='letak' href='/obr/a_tuty_191.jpg' title='Str.1'><img src='/obr/a_tuty_191$.jpg'></a> <a class='letak' href='/obr/a_tuty_192.jpg' title='Str.2'></a>
<h3>Příští nabídka</h3><p>Tato nabídka platí od <b>18.11.2026</b> do <b>1.12.2026</b></p><a class='letak' href='/obr/a_tuty_201.jpg' title='Str.1'></a></main></html>`;

Deno.test("COOP Sušice: jen aktuální leták, strany jako obrázky", () => {
  const f = coopFlyer(COOP_PAGE, "https://www.zkdsusice.cz/letak_tuty", "tuty", "COOP leták", null)!;
  eq([f.validFrom, f.validTo, f.pages.map((p) => p.image)], ["2026-11-04", "2026-11-17", [
    "https://www.zkdsusice.cz/obr/a_tuty_191.jpg", "https://www.zkdsusice.cz/obr/a_tuty_192.jpg",
  ]]);
  eq(coopFlyer("<html>nic</html>", "https://www.zkdsusice.cz/letak_tuty", "tuty", "x", null), null);
  eq(pickPages(f, ["Máslo"], 42).map((p) => p.page.n), [1, 2], "bez textu se čtou všechny strany");
});

Deno.test("odpověď modelu: cizí položka, jiné zboží a chybějící strana se odmítnou; platnost drží leták", () => {
  const flyer = albertFlyer(ALBERT_SPREADS, "46sm_akcni_letak", "2026-11-11", "2026-11-17")!;
  const pages = flyer.pages.slice(1);
  const r = parseFlyerOffers(JSON.stringify([
    { item: "Máslo", product: "Madeta Jihočeské máslo", label: "250 g", price: "34,90", pack_qty: 250, pack_unit: "g", conditions: "s aplikací", valid_to: "2026-12-31", page: 3 },
    { item: "Máslo", product: "Mistrovská máslová makovka", price: 9.9, page: 3 },
    { item: "Rohlík", product: "Rohlík tukový", price: 2.9, page: 3 },
    { item: "Máslo", product: "Máslo", price: 39.9, page: 99 },
    { item: "Máslo", product: "Máslo" },
  ]), ["Máslo"], pages, flyer);
  eq(r.offers.map((o) => [o.product, o.price, o.valid_from, o.valid_to, o.page, o.source_url]), [
    ["Madeta Jihočeské máslo", 34.9, "2026-11-11", "2026-11-17", 3, "https://letaky.albert.cz/46sm_akcni_letak/page/3"],
  ]);
  eq(r.rejected, [
    { product: "Mistrovská máslová makovka", reason: "jiné zboží než „Máslo“" },
    { product: "Rohlík tukový", reason: "nepatří k žádné položce seznamu" },
    { product: "Máslo", reason: "AI neuvedla stranu letáku" },
    { product: "Máslo", reason: "chybí cena" },
  ]);
  eq(parseFlyerOffers("nevím", ["Máslo"], pages, flyer).note, "odpověď neobsahuje pole JSON");
});

// ------------------------------------------------------------ celé hledání (bez sítě)

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

const SITES: Record<string, string> = {
  "https://www.albert.cz/aktualni-letaky": ALBERT_LIST,
  "https://letaky.albert.cz/46sm_akcni_letak/spreads.json": JSON.stringify(ALBERT_SPREADS),
  "https://www.zkdsusice.cz/letak_tuty": COOP_PAGE,
  "https://www.penny.cz/nabidky": PENNY_DATA,
  "https://www.penny.cz/nabidky?tab=nabidky/letaky": "<html>žádný leták</html>",
  "https://www.itesco.cz/akcni-nabidky/letaky-a-katalogy": TESCO_LIST,
};

interface Opts {
  /** Co Gemini „přečte“ z letáku (text odpovědi) podle čísel stran. */
  read?: (pages: string) => string;
  /** Kontrolní čtení: cena pro id výrobku (null = nenašlo). */
  check?: (id: number, line: string) => number | null;
  /** Stav odpovědi Gemini (chyba klíče/modelu). */
  geminiStatus?: number;
  sites?: Record<string, string>;
}

function fakeServer(opts: Opts = {}) {
  const scans = new Map<string, string>();
  const offers: any[] = [];
  const calls = { read: 0, check: 0, openai: 0, site: 0, image: 0, other: [] as string[] };
  let usage = 0;
  const sites = opts.sites ?? SITES;
  const fetchImpl = async (url: string, init: RequestInit = {}) => {
    const h = (init.headers ?? {}) as Record<string, string>;
    if (url.endsWith("/auth/v1/user")) {
      return h.Authorization === "Bearer tok" ? Response.json({ id: "pavel" }) : new Response("{}", { status: 401 });
    }
    if (url.startsWith("https://db.test/rest/v1/")) {
      const path = decodeURIComponent(url.slice("https://db.test/rest/v1/".length));
      if (path.startsWith("price_scans?select")) {
        const chain = path.match(/chain=eq\.(\w+)/)![1];
        return Response.json([...scans].filter(([k]) => k.startsWith(chain + "|")).map(([k, status]) => ({ product_key: k.split("|")[1], status, scanned_on: TODAY })));
      }
      if (path.startsWith("price_scans?on_conflict")) {
        for (const r of JSON.parse(init.body as string)) scans.set(`${r.chain}|${r.product_key}`, r.status);
        return new Response("", { status: 201 });
      }
      if (path.startsWith("price_ai_usage?select")) return Response.json(usage ? [{ requests: usage }] : []);
      if (path.startsWith("price_ai_usage?on_conflict")) {
        usage = JSON.parse(init.body as string).requests;
        return new Response("", { status: 201 });
      }
      if (path === "price_offers") {
        const row = JSON.parse(init.body as string);
        if (offers.some((o) => o.chain === row.chain && o.product_key === row.product_key && o.price === row.price && o.store_id === row.store_id)) {
          return new Response("dup", { status: 409 });
        }
        offers.push(row);
        return new Response("", { status: 201 });
      }
      return new Response("neznámé " + path, { status: 500 });
    }
    if (url.startsWith("https://generativelanguage.googleapis.com/")) {
      ok(url.includes("gemini-3.5-flash-lite"), "čte se modelem pro čtení");
      eq(h["x-goog-api-key"], "gem");
      if (opts.geminiStatus && opts.geminiStatus !== 200) {
        return Response.json({ error: { message: "This model models/gemini-3.5-flash-lite is no longer available to new users." } }, { status: opts.geminiStatus });
      }
      const body = JSON.parse(init.body as string);
      const parts = body.contents[0].parts;
      const prompt: string = parts[0].text;
      ok(parts.some((p: any) => p.inline_data?.data), "k dotazu jsou přiložené obrázky stran");
      ok(!body.tools, "žádné vyhledávání Google");
      let text: string;
      if (prompt.includes("Přečti z ní přesnou akční cenu")) {
        calls.check++;
        ok(!/\d+[,.]\d{2}\s*Kč/.test(prompt.split("\n").slice(1, -2).join("\n")), "kontrola nedostává cenu jako nápovědu");
        const lines = prompt.split("\n").filter((l) => /^\d+\. /.test(l));
        text = JSON.stringify(lines.map((l) => {
          const id = Number(l.split(".")[0]);
          const price = opts.check ? opts.check(id, l) : null;
          return { id, found: price !== null, price };
        }));
      } else {
        calls.read++;
        text = opts.read ? opts.read(prompt.match(/v pořadí strany: ([\d, ]+)/)?.[1] ?? "") : "[]";
      }
      return Response.json({ candidates: [{ content: { parts: [{ text }] }, finishReason: "STOP" }] });
    }
    if (url.startsWith("https://api.openai.com/")) {
      calls.openai++;
      return new Response("{}", { status: 500 });
    }
    if (/\.jpe?g(\?|$)/.test(url)) {
      calls.image++;
      return new Response(new Uint8Array(3000).fill(7), { status: 200, headers: { "content-type": "image/jpeg" } });
    }
    calls.site++;
    const html = sites[url];
    if (html === undefined) {
      calls.other.push(url);
      return new Response("nenalezeno", { status: 404 });
    }
    return new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } });
  };
  return { fetchImpl, offers, scans, calls, usage: () => usage };
}

const LIST = ["Kuřecí prsní řízky", "Vepřová pečeně bez kosti", "Máslo"];

async function refresh(s: ReturnType<typeof fakeServer>, body: Record<string, unknown>, env = ENV) {
  const res = await handle(req({ action: "refresh", products: LIST, ...body }), env, s.fetchImpl, NOW);
  eq(res.status, 200);
  return await res.json();
}

const ALBERT_READ = (pages: string) =>
  JSON.stringify(
    pages.includes("3")
      ? [
        { item: "Máslo", product: "Madeta Jihočeské máslo", label: "250 g", price: 34.9, pack_qty: 250, pack_unit: "g", regular_price: 54.9, conditions: "s aplikací", page: 3 },
        { item: "Máslo", product: "Madeta Jihočeské máslo", label: "250 g", price: 44.9, pack_qty: 250, pack_unit: "g", conditions: "bez aplikace", page: 3 },
        { item: "Máslo", product: "Jihočeské máslo", label: "vymyšlená cena", price: 31.9, page: 3 },
        { item: "Máslo", product: "Mistrovská máslová makovka", price: 9.9, page: 3 },
        { item: "Kuřecí prsní řízky", product: "Kuřecí prsní a stehenní řízky mix", label: "chlazené", price: 109.9, pack_qty: 1, pack_unit: "kg", page: 23 },
      ]
      : [],
  );

Deno.test("leták s textem: Gemini čte obrázky, cenu ověří text strany; vymyšlená cena neprojde", async () => {
  const s = fakeServer({ read: ALBERT_READ, check: () => 34.9 });
  const r = await refresh(s, { chains: ["albert"] });
  eq([r.found, r.verified, r.unverified, r.saved, r.rejected], [4, 3, 1, 4, 1]);
  eq([r.gemini.ok, r.gemini.calls, r.provider], [true, 2, "gemini"], "1× čtení stran 3 a 23, 1× kontrola vymyšlené ceny");
  eq([s.calls.read, s.calls.check, s.calls.openai], [1, 1, 0]);
  const d = r.diag[0];
  eq(d.sources.map((x: any) => [x.kind, x.valid_to, x.size, x.text, x.picked]), [["leták", "2026-11-17", 3, true, [3, 23]]]);
  eq(d.offers.map((o: any) => [o.product, o.price, o.verified, o.method]), [
    ["Madeta Jihočeské máslo", 34.9, true, "leták-text"],
    ["Madeta Jihočeské máslo", 44.9, true, "leták-text"],
    ["Jihočeské máslo", 31.9, false, ""],
    ["Kuřecí prsní a stehenní řízky mix", 109.9, true, "leták-text"],
  ]);
  ok(d.offers[2].reason.includes("druhé čtení letáku vyšlo jinak"));
  eq(d.rejected, [{ product: "Mistrovská máslová makovka", reason: "jiné zboží než „Máslo“" }]);
  const saved = s.offers.find((o) => o.price === 34.9);
  eq([saved.chain, saved.verified, saved.verify_method, saved.valid_from, saved.valid_to, saved.source_url, saved.pack_qty, saved.conditions, saved.provider], [
    "albert", true, "leták-text", "2026-11-11", "2026-11-17", "https://letaky.albert.cz/46sm_akcni_letak/page/3", 250, "s aplikací", "gemini",
  ]);
  eq(s.offers.find((o) => o.price === 31.9).verified, false);
  eq(s.usage(), 2);
});

Deno.test("leták bez textu (COOP): cenu musí potvrdit druhé nezávislé čtení strany", async () => {
  const read = () => JSON.stringify([
    { item: "Máslo", product: "Máslo Madeta", label: "250 g", price: 39.9, pack_qty: 250, pack_unit: "g", page: 1 },
    { item: "Vepřová pečeně bez kosti", product: "Vepřová pečeně bez kosti", price: 129.9, pack_qty: 1, pack_unit: "kg", page: 2 },
  ]);
  const s = fakeServer({ read, check: (_id, line) => (line.includes("Máslo") ? 39.9 : 119.9) });
  const r = await refresh(s, { chains: ["coop"] });
  eq([r.found, r.verified, r.unverified], [2, 1, 1]);
  eq([s.calls.read, s.calls.check], [1, 2], "jedno čtení obou stran, kontrola každé strany zvlášť");
  const d = r.diag[0];
  eq(d.offers.map((o: any) => [o.product, o.verified, o.method]), [["Máslo Madeta", true, "leták-2×"], ["Vepřová pečeně bez kosti", false, ""]]);
  eq(s.offers.map((o) => [o.verified, o.valid_to, o.source_url]), [
    [true, "2026-11-17", "https://www.zkdsusice.cz/letak_tuty"],
    [false, "2026-11-17", "https://www.zkdsusice.cz/letak_tuty"],
  ]);
  ok(d.pages.some((p: any) => p.url === "https://www.zkdsusice.cz/letak_tip" && p.status === 404), "nestažená stránka je v diagnostice");
});

Deno.test("Penny: ceny z dat webu se uloží ověřené i bez klíče Gemini (a nic se neplatí)", async () => {
  const s = fakeServer();
  const r = await refresh(s, { chains: ["penny"] }, { ...ENV, geminiKey: "" });
  eq([r.found, r.verified, r.saved, r.gemini.configured, r.gemini.calls], [1, 1, 1, false, 0]);
  eq(s.offers.map((o) => [o.product, o.price, o.verified, o.verify_method, o.provider, o.source_url]), [
    ["Máslo Boni", 29.9, true, "data", "web", "https://www.penny.cz/products/maslo-boni-881"],
  ]);
  ok(r.errors.includes("no_provider"));
  eq([s.calls.read, s.calls.check, s.calls.openai], [0, 0, 0]);
});

Deno.test("mezipaměť: stejné letáky se pro stejný produkt nečtou znovu; force ji obejde", async () => {
  const s = fakeServer({ read: ALBERT_READ, check: () => null });
  const first = await refresh(s, { chains: ["albert"] });
  eq([first.scanned, first.cached], [3, 0]);
  const reads = s.calls.read;
  const again = await refresh(s, { chains: ["albert"] });
  eq([again.scanned, again.cached, again.gemini.calls, again.diag[0].cached], [0, 3, 0, true]);
  eq(s.calls.read, reads, "podruhé se Gemini nevolá");
  eq(again.diag[0].sources.length, 1, "zdroj je v diagnostice i z mezipaměti");
  const more = await refresh(s, { chains: ["albert"], products: [...LIST, "Mozzarella"] });
  eq([more.scanned, more.cached], [1, 3], "nová položka se dohledá, staré ne");
  const forced = await refresh(s, { chains: ["albert"], force: true });
  eq([forced.scanned, forced.duplicates > 0], [3, true]);
});

Deno.test("chyba Gemini (model/klíč) se ukáže, nic se neuloží do mezipaměti a dál se nezkouší", async () => {
  const s = fakeServer({ geminiStatus: 404 });
  const r = await refresh(s, { chains: ["albert", "coop"] });
  eq([r.gemini.ok, r.gemini.calls, r.found], [false, 1, 0]);
  ok(r.gemini.error.includes("není pro tento klíč dostupný"));
  ok(r.errors.some((e: string) => e.startsWith("albert: model")));
  eq(s.scans.size, 0);
  eq(r.diag[0].ai[0].status, "chyba");
});

Deno.test("nedostupný web obchodu: chyba je v diagnostice a hledání se neuloží jako hotové", async () => {
  const s = fakeServer({ sites: {} });
  const r = await refresh(s, { chains: ["tesco"] });
  eq(r.found, 0);
  ok(r.errors.some((e: string) => e.includes("aktuální leták ani data obchodu se nepodařilo stáhnout")));
  eq(r.diag[0].pages[0].status, 404);
  eq(s.scans.size, 0);
});

Deno.test("Tesco bez textu: čtou se všechny strany po dávkách", async () => {
  const s = fakeServer({ read: () => "[]" });
  const r = await refresh(s, { chains: ["tesco"] });
  eq([r.found, s.calls.read, s.calls.image], [0, 1, 2]);
  eq(r.diag[0].sources[0].picked, [1, 2]);
  eq(s.scans.size, 3, "prohledáno bez chyby → do mezipaměti");
});

Deno.test("nabídka z ChatGPT se ověří stránkou; bez přihlášení nic", async () => {
  const page = '<html><body><div class="tile"><h3>Máslo 250 g</h3><span>39,90 Kč</span></div></body></html>';
  const s = fakeServer({ sites: { "https://www.penny.cz/nabidky/maslo": page } });
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

Deno.test("otisk letáků se mění s novým letákem", () => {
  const f = albertFlyer(ALBERT_SPREADS, "46sm_akcni_letak", "2026-11-11", "2026-11-17")!;
  const a = flyersKey({ flyers: [f], offers: [], log: [] });
  ok(a === flyersKey({ flyers: [f], offers: [], log: [] }));
  ok(a !== flyersKey({ flyers: [{ ...f, id: "47sm_akcni_letak" }], offers: [], log: [] }));
});

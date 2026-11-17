// HINKredience° – ceny pro „Nejvýhodnější nákup“ (akce v obchodech v Sušici)
//
// Hledá aktuální akční nabídky pro položky nákupního seznamu a ukládá je do
// tabulky price_offers. Zásady:
// - Zdrojem jsou AKTUÁLNÍ AKČNÍ LETÁKY na oficiálních webech řetězců
//   (obrázky stran letáku + text letáku, kde ho web má) a veřejná
//   strukturovaná data (Penny). Server si je stáhne sám, zdarma.
// - Google Gemini (bezplatná úroveň) čte přímo obrázky stran letáku. AI nesmí
//   vymýšlet ceny: nabídka je „ověřená“ jen tehdy, když
//     a) pochází ze strukturovaných dat webu řetězce (bez AI), nebo
//     b) cena i název stojí i v textu téže strany letáku, nebo
//     c) cenu potvrdí druhé nezávislé čtení téže strany (bez nápovědy ceny).
//   Ostatní se uloží jako neověřené a aplikace je do porovnání nepočítá.
// - Šetří bezplatné limity: stejný řetězec + produkt + stejné letáky se
//   prohledá jen jednou (tabulka price_scans), ale jen když hledání
//   proběhlo bez chyby. Pro test lze mezipaměť obejít (force).
// - Nic placeného: OpenAI se pro hledání akcí nepoužívá vůbec.
// - Klíče AI jsou jen v Secrets serverové funkce, nikdy v aplikaci.
// - Odpověď obsahuje diagnostiku: zdroje, co se stáhlo, co AI vrátila, co a
//   proč bylo odmítnuto a co se uložilo.
//
// Bez závislostí, aby šla funkce nasadit z editoru v administraci Supabase.

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  geminiKey: string;
  /** Dříve model pro vyhledávání Google; už se nepoužívá (jen pro zpětnou kompatibilitu nastavení). */
  geminiModel: string;
  /** Model pro čtení stran letáků (obrázky), zdarma. */
  geminiExtractModel: string;
  geminiDailyLimit: number;
  openaiKey: string;
  openaiModel: string;
  allowPaid: boolean;
  /** Nejdelší doba jednoho hledání v ms (výchozí 110 s). */
  budgetMs?: number;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

// ------------------------------------------------------------ obchody

/** Řetězce a jejich oficiální weby (jen ty smí být zdrojem ceny). */
export const CHAINS: Record<string, { name: string; domains: string[] }> = {
  tesco: { name: "Tesco", domains: ["itesco.cz", "tesco.cz"] },
  penny: { name: "Penny", domains: ["penny.cz", "files.rewe.co.at"] },
  lidl: { name: "Lidl", domains: ["lidl.cz"] },
  albert: { name: "Albert", domains: ["albert.cz"] },
  jip: { name: "JIP Cash & Carry", domains: ["jip-potraviny.cz"] },
  coop: { name: "COOP (Západočeské konzumní družstvo Sušice)", domains: ["zkdsusice.cz", "coop.cz", "skupina.coop"] },
};

/** Odkud se smí stahovat data a obrázky letáků (oficiální weby + jejich úložiště letáků). */
export const SOURCE_HOSTS: Record<string, string[]> = {
  tesco: ["itesco.cz", "digitalcontent.api.tesco.com"],
  penny: ["penny.cz", "files.rewe.co.at"],
  lidl: ["lidl.cz", "leaflets.schwarz"],
  albert: ["albert.cz"],
  jip: ["jip-potraviny.cz"],
  coop: ["zkdsusice.cz"],
};

export const STORES: Record<string, string> = {
  "tesco-hradecka": "tesco",
  "penny-nadrazni": "penny",
  "lidl-hradecka": "lidl",
  "albert-hradecka": "albert",
  "albert-tgm": "albert",
  "jip-hradecka": "jip",
  "coop-namesti": "coop",
  "coop-nadrazni": "coop",
  "coop-lerchova": "coop",
  "coop-smetanova": "coop",
};

function hostIn(url: string, domains: string[]): boolean {
  try {
    const u = new URL(url);
    if (u.protocol !== "https:") return false;
    const host = u.hostname.toLowerCase();
    return domains.some((d) => host === d || host.endsWith(`.${d}`));
  } catch {
    return false;
  }
}

export function isOfficial(chain: string, url: string): boolean {
  let host = "";
  try {
    const u = new URL(url);
    if (u.protocol !== "https:") return false;
    host = u.hostname.toLowerCase();
  } catch {
    host = url.trim().toLowerCase().replace(/^www\./, "");
    if (!/^[a-z0-9.-]+$/.test(host)) return false;
  }
  return (CHAINS[chain]?.domains ?? []).some((d) => host === d || host.endsWith(`.${d}`));
}

/** Smí se z této adresy stahovat podklad pro řetězec? */
export function isSource(chain: string, url: string): boolean {
  return hostIn(url, SOURCE_HOSTS[chain] ?? []);
}

// ------------------------------------------------- klíč produktu (jako v Dart)

const IGNORE = new Set([
  "kg", "ml", "ks", "bal", "baleni", "cerstvy", "cerstva", "cerstve", "akce",
  "cena", "podle", "chuti", "trad", "tradicni",
]);

export function fold(text: string): string {
  return text.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
}

export function productKey(name: string): string {
  const stems = new Set<string>();
  for (const w of fold(name).match(/[a-z]+/g) ?? []) {
    if (w.length >= 3 && !IGNORE.has(w)) stems.add(w.slice(0, 5));
  }
  return [...stems].sort().join(" ");
}

// ------------------------------------------- shoda českých názvů (jako v Dart)

const ENDINGS = [
  "ovych", "ovymi", "ovou", "ovy", "ova", "ove", "ych", "ymi", "ami", "emi",
  "ech", "ich", "ou", "em", "om", "y", "a", "e", "i", "o", "u",
];

/** Jednoduchý český kmen: bez koncovky, „řízek“ i „řízky“ → „rizk“. */
export function czStem(word: string): string {
  let w = word;
  if (w.length <= 3) return w;
  for (const e of ENDINGS) {
    if (w.endsWith(e) && w.length - e.length >= 3) {
      w = w.slice(0, -e.length);
      break;
    }
  }
  if (w.length >= 4 && /e[kc]$/.test(w)) w = w.slice(0, -2) + w.slice(-1);
  return w;
}

export function matchStems(text: string): string[] {
  const out = new Set<string>();
  for (const w of fold(text).match(/[a-z]+/g) ?? []) {
    if (w.length >= 3 && !IGNORE.has(w)) out.add(czStem(w));
  }
  return [...out];
}

function common(a: string, b: string): number {
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  return i;
}

export function stemsMatch(a: string, b: string): boolean {
  if (a === b) return true;
  const short = a.length <= b.length ? a : b;
  const long = short === a ? b : a;
  if (short.length >= 4 && long.startsWith(short)) return true;
  return common(a, b) >= 4;
}

/** Kolik kmenů z [need] je v [have]. */
function matchedCount(need: string[], have: string[]): number {
  return need.filter((s) => have.some((h) => stemsMatch(s, h))).length;
}

// Shoda položky seznamu s produktem z letáku – stejná pravidla jako v aplikaci
// (lib/core/best_buy.dart), aby se uložená nabídka v košíku opravdu ukázala.

const ADJ_OV = /ov(?:y|a|e|ou|ych|ymi|ym|eho|emu)$/;
/** Slova, která položka nemusí mít v názvu produktu („bez kosti“). */
const SOFT = new Set(["bez", "kost"]);

interface Word {
  stem: string;
  adj: boolean;
}

function matchWords(text: string): Word[] {
  const out: Word[] = [];
  for (const w of fold(text).match(/[a-z]+/g) ?? []) {
    if (w.length < 3 || IGNORE.has(w)) continue;
    const m = w.match(ADJ_OV);
    out.push({ stem: czStem(w), adj: !!m && w.length - m[0].length >= 3 });
  }
  return out;
}

/**
 * Odpovídá produkt položce seznamu? Všechna podstatná slova položky musí
 * být v produktu; „máslo“ ale není „máslový“ (příchuť, pečivo) a „bez
 * kosti“ není „s kostí“.
 */
export function productMatches(item: string, product: string): boolean {
  const fi = fold(item), fp = fold(product);
  if (/\bbez\s+kost/.test(fi) && /\bs\s+kost/.test(fp)) return false;
  if (/\bs\s+kost/.test(fi) && /\bbez\s+kost/.test(fp)) return false;
  const need = matchWords(item).filter((w) => !SOFT.has(w.stem) && !/^\d/.test(w.stem));
  if (need.length === 0) return false;
  const have = matchWords(product);
  return need.every((n) => have.some((h) => stemsMatch(n.stem, h.stem) && (n.adj || !h.adj)));
}

export interface RawOffer {
  product: string;
  label?: string;
  price: number;
  pack_qty?: number | null;
  pack_unit?: string;
  regular_price?: number | null;
  conditions?: string;
  valid_from?: string | null;
  valid_to: string;
  source_url: string;
  store_id?: string | null;
}

export interface Evidence {
  /** Citované úseky odpovědi a jejich zdroje (název webu nebo adresa). */
  supports: { text: string; sources: string[] }[];
  /** Všechny zdroje, které poskytovatel použil. */
  sources: { url: string; title: string }[];
}

function num(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number(value.replace(/\s/g, "").replace(/kč|,-$/gi, "").replace(",", "."));
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function isoDay(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const m = value.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

export interface Rejected {
  product: string;
  reason: string;
}

/** Vytáhne pole JSON z odpovědi modelu (i v bloku ```json) a řekne, co odmítlo a proč. */
export function parseOffersDetailed(
  text: string,
  fallbackUrl = "",
): { offers: RawOffer[]; rejected: Rejected[]; note: string } {
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start < 0 || end <= start) {
    return { offers: [], rejected: [], note: text.trim() ? "odpověď neobsahuje pole JSON" : "prázdná odpověď" };
  }
  let data: unknown;
  try {
    data = JSON.parse(text.slice(start, end + 1));
  } catch {
    return { offers: [], rejected: [], note: "neplatný JSON v odpovědi" };
  }
  if (!Array.isArray(data)) return { offers: [], rejected: [], note: "odpověď není pole" };
  const offers: RawOffer[] = [];
  const rejected: Rejected[] = [];
  for (const o of data.slice(0, 60)) {
    if (!o || typeof o !== "object") continue;
    const product = typeof o.product === "string" ? o.product.trim().slice(0, 160) : "";
    const price = num(o.price);
    const validTo = isoDay(o.valid_to);
    const url = typeof o.source_url === "string" && o.source_url.trim() ? o.source_url.trim() : fallbackUrl;
    const missing = [
      !product && "název",
      price === null && "cena",
      !validTo && "platnost",
      !url && "zdroj",
    ].filter(Boolean);
    if (missing.length) {
      rejected.push({ product: product || "?", reason: `chybí ${missing.join(", ")}` });
      continue;
    }
    offers.push({
      product,
      label: typeof o.label === "string" ? o.label.slice(0, 200) : "",
      price: price!,
      pack_qty: num(o.pack_qty),
      pack_unit: typeof o.pack_unit === "string" ? o.pack_unit.slice(0, 20) : "",
      regular_price: num(o.regular_price),
      conditions: typeof o.conditions === "string" ? o.conditions.slice(0, 200) : "",
      valid_from: isoDay(o.valid_from),
      valid_to: validTo!,
      source_url: url,
      store_id: typeof o.store_id === "string" ? o.store_id : null,
    });
  }
  return { offers, rejected, note: "" };
}

export function parseOffers(text: string): RawOffer[] {
  return parseOffersDetailed(text).offers;
}


const PRICE_RE = /\d{1,5}(?:[.,]\d{1,2})?/g;

/** Je v textu uvedená cena (39,90 / 39.9 / 39,- …)? */
export function mentionsPrice(text: string, price: number): boolean {
  for (const m of text.matchAll(PRICE_RE)) {
    const n = Number(m[0].replace(",", "."));
    if (Math.abs(n - price) < 0.005) return true;
  }
  return false;
}

/** Text HTML stránky bez značek; data JSON ze stránky (Next.js, ld+json) zůstanou. */
export function pageText(html: string): string {
  const data: string[] = [];
  for (const m of html.matchAll(/<script[^>]*type=["']application\/(?:ld\+)?json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    data.push(m[1]);
  }
  const text = html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;|&#160;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(Number(d)));
  const json = data.join(" ")
    .replace(/\\u([0-9a-f]{4})/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/[{}\[\]"]/g, " ");
  return `${text} ${json}`.replace(/\s+/g, " ").trim();
}

/**
 * Je cena na stránce přímo u produktu? Hledá každý výskyt ceny a kolem něj
 * (250 znaků před, 120 za) kmeny názvu produktu; musí sedět aspoň 60 %
 * podstatných slov (a vždy aspoň jedno).
 */
export function priceNearProduct(text: string, product: string, price: number): boolean {
  const need = matchStems(product).filter((s) => !/^\d/.test(s));
  if (need.length === 0) return false;
  const want = Math.max(1, Math.ceil(need.length * 0.6));
  for (const m of text.matchAll(PRICE_RE)) {
    if (Math.abs(Number(m[0].replace(",", ".")) - price) >= 0.005) continue;
    const at = m.index ?? 0;
    const around = text.slice(Math.max(0, at - 250), at + 120);
    if (matchedCount(need, matchStems(around)) >= want) return true;
  }
  return false;
}

export type Verdict = { verified: boolean; method: string; reason: string };

/**
 * Ověření jedné nabídky. Pořadí: platnost a oficiální zdroj → citace
 * poskytovatele (úsek s cenou podložený oficiálním webem) → text stránky
 * (cena u názvu produktu). [pageTextKnown] = text už stažené stránky.
 */
export async function verifyOffer(
  chain: string,
  offer: RawOffer,
  evidence: Evidence | null,
  today: string,
  fetchImpl: FetchLike,
  pageTextKnown?: string,
): Promise<Verdict> {
  if (offer.price <= 0 || offer.price >= 100000) {
    return { verified: false, method: "", reason: "nesmyslná cena" };
  }
  if (offer.valid_to < today) return { verified: false, method: "", reason: "akce už skončila" };
  if (!isOfficial(chain, offer.source_url)) {
    return { verified: false, method: "", reason: "zdroj není oficiální web řetězce" };
  }
  if (pageTextKnown !== undefined) {
    return priceNearProduct(pageTextKnown, offer.product, offer.price)
      ? { verified: true, method: "stránka", reason: "cena je na oficiální stránce u produktu" }
      : { verified: false, method: "", reason: "cena u produktu na oficiální stránce není" };
  }
  if (evidence) {
    for (const s of evidence.supports) {
      if (!mentionsPrice(s.text, offer.price)) continue;
      if (s.sources.some((src) => isOfficial(chain, src))) {
        return { verified: true, method: "citace", reason: "cenu dokládá citace oficiálního webu" };
      }
    }
  }
  try {
    const page = await fetchPage(chain, offer.source_url, fetchImpl);
    if (page.text) {
      return priceNearProduct(page.text, offer.product, offer.price)
        ? { verified: true, method: "stránka", reason: "cena je na oficiální stránce u produktu" }
        : { verified: false, method: "", reason: "cenu u produktu se na stránce nepodařilo najít" };
    }
    return { verified: false, method: "", reason: `zdroj se nepodařilo stáhnout (${page.note})` };
  } catch {
    return { verified: false, method: "", reason: "zdroj se nepodařilo ověřit" };
  }
}

// ------------------------------------------------------------ stránky řetězců

export interface Page {
  url: string;
  status: number;
  text: string;
  links: string[];
  note: string;
}


/** Stáhne oficiální stránku (jen https a jen web řetězce, i po přesměrování). */
export async function fetchPage(chain: string, url: string, fetchImpl: FetchLike): Promise<Page> {
  if (!isOfficial(chain, url) || !/^https:\/\//.test(url)) {
    return { url, status: 0, text: "", links: [], note: "není oficiální adresa" };
  }
  let res: Response;
  try {
    res = await fetchImpl(url, {
      headers: { "User-Agent": UA, Accept: "text/html,application/xhtml+xml", "Accept-Language": "cs" },
      redirect: "follow",
      signal: AbortSignal.timeout(10000),
    });
  } catch (e) {
    return { url, status: 0, text: "", links: [], note: `nedostupná (${(e as Error).name})` };
  }
  const finalUrl = res.url || url;
  if (!isOfficial(chain, finalUrl)) {
    return { url, status: res.status, text: "", links: [], note: `přesměrováno mimo oficiální web (${hostOf(finalUrl)})` };
  }
  if (!res.ok) return { url, status: res.status, text: "", links: [], note: `HTTP ${res.status}` };
  const type = res.headers.get("content-type") ?? "";
  if (type && !/html|text|json/i.test(type)) {
    return { url, status: res.status, text: "", links: [], note: `není stránka (${type.split(";")[0]})` };
  }
  const html = (await res.text()).slice(0, 3_000_000);
  const links: string[] = [];
  for (const m of html.matchAll(/href=["']([^"'#]+)["']/gi)) {
    try {
      const abs = new URL(m[1].replace(/&amp;/g, "&"), finalUrl).toString();
      if (isOfficial(chain, abs) && !links.includes(abs)) links.push(abs);
    } catch {
      // neplatný odkaz
    }
  }
  const text = pageText(html);
  return { url: finalUrl, status: res.status, text, links, note: text.length < 200 ? "skoro prázdná (načítá se skriptem?)" : "" };
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url.slice(0, 40);
  }
}


// ------------------------------------------------------------ zdroje: letáky a data

/** Jedna strana letáku. */
export interface FlyerPage {
  n: number;
  /** Obrázek strany (pro čtení). */
  image: string;
  /** Větší obrázek pro kontrolní čtení (když ho web má). */
  zoom?: string;
  /** Text strany, kde ho web poskytuje (pro výběr stran a ověření ceny). */
  text?: string;
  /** Je text úplný text strany (true), nebo jen klíčová slova (false)? */
  fullText?: boolean;
  /** Odkaz na stranu pro člověka (oficiální web). */
  link: string;
}

export interface Flyer {
  chain: string;
  id: string;
  title: string;
  url: string;
  validFrom: string | null;
  validTo: string | null;
  /** Jen pro konkrétní prodejnu (jinak všechny sušické prodejny řetězce). */
  storeId?: string | null;
  pages: FlyerPage[];
}

/** Záznam o stažení (pro diagnostiku). */
export interface FetchLog {
  url: string;
  status: number;
  chars: number;
  note: string;
}

export interface Sources {
  flyers: Flyer[];
  /** Nabídky přímo ze strukturovaných dat webu (bez AI). */
  offers: RawOffer[];
  log: FetchLog[];
}

const UA = "Mozilla/5.0 (Linux; Android 14; HINKredience) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36";

interface Got {
  ok: boolean;
  status: number;
  text: string;
  url: string;
  note: string;
}

/** Stáhne text (HTML/JSON/JS) z povoleného zdroje řetězce a zapíše do logu. */
export async function getText(chain: string, url: string, fetchImpl: FetchLike, log: FetchLog[], accept = "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"): Promise<Got> {
  const done = (g: Got): Got => {
    log.push({ url: g.url, status: g.status, chars: g.text.length, note: g.note });
    return g;
  };
  if (!isSource(chain, url)) return done({ ok: false, status: 0, text: "", url, note: "adresa mimo oficiální zdroje" });
  let res: Response;
  try {
    res = await fetchImpl(url, {
      headers: { "User-Agent": UA, Accept: accept, "Accept-Language": "cs-CZ,cs;q=0.9" },
      redirect: "follow",
      signal: AbortSignal.timeout(15000),
    });
  } catch (e) {
    return done({ ok: false, status: 0, text: "", url, note: `nedostupná (${(e as Error).name})` });
  }
  const finalUrl = res.url || url;
  if (!isSource(chain, finalUrl)) {
    return done({ ok: false, status: res.status, text: "", url, note: `přesměrováno mimo oficiální web (${hostOf(finalUrl)})` });
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => {});
    return done({ ok: false, status: res.status, text: "", url: finalUrl, note: `HTTP ${res.status}` });
  }
  const text = (await res.text()).slice(0, 4_000_000);
  return done({ ok: true, status: res.status, text, url: finalUrl, note: "" });
}

function decodeEntities(s: string): string {
  return s
    .replace(/&nbsp;|&#160;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&([a-z]+)acute;/gi, (_, c) => ACUTE[c] ?? c)
    .replace(/&([a-z]+)caron;/gi, (_, c) => CARON[c] ?? c)
    .replace(/&uring;/g, "ů").replace(/&Uring;/g, "Ů");
}
const ACUTE: Record<string, string> = { a: "á", e: "é", i: "í", o: "ó", u: "ú", y: "ý", A: "Á", E: "É", I: "Í", O: "Ó", U: "Ú", Y: "Ý" };
const CARON: Record<string, string> = { s: "š", c: "č", r: "ř", z: "ž", e: "ě", n: "ň", d: "ď", t: "ť", S: "Š", C: "Č", R: "Ř", Z: "Ž", E: "Ě", N: "Ň", D: "Ď", T: "Ť" };

function stripTags(html: string): string {
  return decodeEntities(
    html.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " "),
  ).replace(/\s+/g, " ").trim();
}

function iso(y: number, m: number, d: number): string | null {
  if (!(y > 2000 && m >= 1 && m <= 12 && d >= 1 && d <= 31)) return null;
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/** První rozsah dat v textu: „11. 11. – 17. 11. 2026“, „od 4.11.2026 do 17.11.2026“, „11. 11. do 17. 11. 2026“. */
export function dateRange(text: string, fallbackYear?: number): { from: string | null; to: string | null } {
  const m = text.match(/(\d{1,2})\.\s*(\d{1,2})\.(?:\s*(\d{4}))?\s*(?:[-–—]|do(?:\s+[^\d\s]+)?)\s*(\d{1,2})\.\s*(\d{1,2})\.(?:\s*(\d{4}))?/i);
  if (!m) return { from: null, to: null };
  const y2 = Number(m[6] ?? m[3] ?? fallbackYear ?? 0);
  let y1 = Number(m[3] ?? y2);
  if (!m[3] && Number(m[2]) > Number(m[5])) y1 = y2 - 1; // prosinec → leden
  return { from: iso(y1, Number(m[2]), Number(m[1])), to: iso(y2, Number(m[5]), Number(m[4])) };
}

function nextData(html: string): any {
  const m = html.match(/<script[^>]*id=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/);
  if (!m) return null;
  try {
    return JSON.parse(m[1]);
  } catch {
    return null;
  }
}

/** Rozbalí data Nuxt (formát devalue: pole hodnot s odkazy přes indexy). */
export function unflattenNuxt(arr: unknown[]): unknown {
  const cache = new Map<number, unknown>();
  const WRAP = new Set(["Reactive", "ShallowReactive", "Ref", "ShallowRef"]);
  const NONE = new Set(["EmptyRef", "EmptyShallowRef", "NuxtError", "Set", "Map", "Date", "null", "undefined", "NaN"]);
  const hydrate = (i: unknown): unknown => {
    if (typeof i !== "number" || i < 0 || i >= arr.length) return null;
    if (cache.has(i)) return cache.get(i);
    const v = arr[i];
    if (v === null || typeof v !== "object") {
      cache.set(i, v);
      return v;
    }
    if (Array.isArray(v)) {
      if (typeof v[0] === "string" && v.length <= 3) {
        if (WRAP.has(v[0])) {
          const r = hydrate(v[1]);
          cache.set(i, r);
          return r;
        }
        if (NONE.has(v[0])) {
          cache.set(i, null);
          return null;
        }
      }
      const out: unknown[] = [];
      cache.set(i, out);
      for (const x of v) out.push(hydrate(x));
      return out;
    }
    const out: Record<string, unknown> = {};
    cache.set(i, out);
    for (const k of Object.keys(v)) out[k] = hydrate((v as Record<string, unknown>)[k]);
    return out;
  };
  return hydrate(0);
}

// ---- Penny: strukturovaná data webu (akční položky) + leták (FlippingBook)

/** Akční položky z dat stránky penny.cz/nabidky (bez AI). */
export function pennyProducts(html: string): RawOffer[] {
  const m = html.match(/<script[^>]*id=["']__NUXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/);
  if (!m) return [];
  let root: unknown;
  try {
    root = unflattenNuxt(JSON.parse(m[1]));
  } catch {
    return [];
  }
  const found: any[] = [];
  const seen = new Set<unknown>();
  const walk = (x: unknown, depth: number) => {
    if (!x || typeof x !== "object" || seen.has(x) || depth > 18) return;
    seen.add(x);
    const o = x as any;
    if (!Array.isArray(o) && typeof o.name === "string" && o.price && typeof o.price === "object" && o.price.regular) {
      found.push(o);
      return;
    }
    for (const k of Object.keys(o)) walk(o[k], depth + 1);
  };
  walk(root, 0);
  const out: RawOffer[] = [];
  const dedupe = new Set<string>();
  for (const p of found) {
    const end = isoDay(p.price.validityEnd);
    const start = isoDay(p.price.validityStart);
    if (!end) continue;
    const qty = num(typeof p.amount === "string" ? p.amount.replace(",", ".") : p.amount);
    const unit = typeof p.volumeLabelShort === "string" ? p.volumeLabelShort : "";
    const url = typeof p.slug === "string" ? `https://www.penny.cz/products/${p.slug}` : "https://www.penny.cz/nabidky";
    const add = (cents: unknown, conditions: string) => {
      const c = Number(cents);
      if (!Number.isFinite(c) || c <= 0) return;
      const key = `${p.sku ?? p.name}|${c}|${conditions}`;
      if (dedupe.has(key)) return;
      dedupe.add(key);
      out.push({
        product: String(p.name).slice(0, 160),
        label: [qty ? `${String(qty).replace(".", ",")} ${unit}`.trim() : "", typeof p.category === "string" ? p.category.toLowerCase() : ""].filter(Boolean).join(" · "),
        price: Math.round(c) / 100,
        pack_qty: qty,
        pack_unit: unit,
        regular_price: null,
        conditions,
        valid_from: start,
        valid_to: end,
        source_url: url,
      });
    };
    add(p.price.regular?.value, p.price.loyalty?.value ? "bez PENNY karty" : "");
    add(p.price.loyalty?.value, "s PENNY kartou");
  }
  return out;
}

async function pennySources(fetchImpl: FetchLike, today: string): Promise<Sources> {
  const log: FetchLog[] = [];
  const flyers: Flyer[] = [];
  const [data, list] = await Promise.all([
    getText("penny", "https://www.penny.cz/nabidky", fetchImpl, log),
    getText("penny", "https://www.penny.cz/nabidky?tab=nabidky/letaky", fetchImpl, log),
  ]);
  const offers = data.ok ? pennyProducts(data.text) : [];
  if (data.ok && offers.length === 0) log[log.length - 2].note = "data akčních položek na stránce nejsou";
  const bases = [...new Set([...(list.text + data.text).matchAll(/https:\/\/files\.rewe\.co\.at\/PennyIntLeaflet\/CZ\/([A-Za-z0-9_]+)/g)].map((m) => m[1]))];
  // Název začíná datem začátku (11_11_2026_tl); katalogy a budoucí letáky stranou.
  const current = bases
    .map((id) => {
      const d = id.match(/^(\d{1,2})_(\d{1,2})_(\d{4})/);
      return { id, start: d ? iso(Number(d[3]), Number(d[2]), Number(d[1])) : null };
    })
    .filter((b) => b.start && b.start <= today && !/katalog/i.test(b.id))
    .sort((a, b) => (a.start! < b.start! ? 1 : -1))
    .slice(0, 1);
  for (const b of current) {
    const base = `https://files.rewe.co.at/PennyIntLeaflet/CZ/${b.id}/`;
    const index = await getText("penny", base, fetchImpl, log);
    if (!index.ok) continue;
    const count = Math.min(60, Math.max(1, ...[...index.text.matchAll(/href="\.\/(\d+)\/"/g)].map((m) => Number(m[1]))));
    const range = dateRange(stripTags(index.text.replace(/title="([^"]*)"/g, " $1 ")), Number(b.start!.slice(0, 4)));
    const texts = new Map<number, string>();
    const quiet: FetchLog[] = [];
    const numbers = Array.from({ length: count }, (_, i) => i + 1);
    for (let i = 0; i < numbers.length; i += 12) {
      await Promise.all(numbers.slice(i, i + 12).map(async (n) => {
        const page = n === 1 ? index : await getText("penny", `${base}${n}/`, fetchImpl, quiet);
        if (page.ok) texts.set(n, stripTags(page.text.slice(page.text.indexOf("<body"))));
      }));
    }
    const failed = quiet.filter((q) => q.status !== 200).length;
    log.push({ url: `${base}2/ … ${count}/`, status: failed ? 0 : 200, chars: [...texts.values()].reduce((s, t) => s + t.length, 0), note: failed ? `text ${failed} stran se nestáhl` : `text ${texts.size} stran letáku` });
    flyers.push({
      chain: "penny",
      id: b.id,
      title: "Akční leták Penny",
      url: base,
      validFrom: range.from ?? b.start,
      validTo: range.to,
      pages: numbers.map((n) => ({
        n,
        image: `${base}files/assets/common/page-html5-substrates/page${String(n).padStart(4, "0")}_4.jpg`,
        text: texts.get(n),
        fullText: true,
        link: n === 1 ? base : `${base}${n}/`,
      })),
    });
  }
  return { flyers, offers, log };
}

// ---- Tesco: leták hypermarketů (obrázky stran v datech stránky)

export function tescoFlyers(html: string, today: string): Flyer[] {
  const state = nextData(html)?.props?.pageProps?.__APOLLO_STATE__;
  if (!state || typeof state !== "object") return [];
  const out: Flyer[] = [];
  for (const key of Object.keys(state)) {
    const l = state[key];
    if (l?.__typename !== "Leaflet" || l.type !== "HM" || typeof l.slug !== "string") continue;
    const from = pragueDay(l.validFrom), to = pragueDay(l.validTo);
    if (!to || to < today || (from && from > today)) continue;
    const base = `https://www.itesco.cz/akcni-nabidky/letaky-a-katalogy/hypermarkety/${l.slug}/`;
    const pages: FlyerPage[] = [];
    for (const ref of l.pages ?? []) {
      const p = ref?.__ref ? state[ref.__ref] : ref;
      const img = typeof p?.pagePNG === "string" ? p.pagePNG : "";
      const n = Number(p?.page ?? img.match(/\.(\d+)\.(?:jpe?g|png)$/i)?.[1]);
      if (!img || !Number.isFinite(n) || !isSource("tesco", img)) continue;
      pages.push({ n, image: `${img}?w=1000`, zoom: `${img}?w=1700`, link: `${base}${n}` });
    }
    pages.sort((a, b) => a.n - b.n);
    if (pages.length) {
      out.push({ chain: "tesco", id: `HM-${l.slug}`, title: "Tesco leták hypermarkety", url: `${base}1`, validFrom: from, validTo: to, pages });
    }
  }
  return out;
}

async function tescoSources(fetchImpl: FetchLike, today: string): Promise<Sources> {
  const log: FetchLog[] = [];
  const list = await getText("tesco", "https://www.itesco.cz/akcni-nabidky/letaky-a-katalogy", fetchImpl, log);
  const flyers = list.ok ? tescoFlyers(list.text, today) : [];
  if (list.ok && flyers.length === 0) log[0].note = "platný leták hypermarketů na stránce není";
  return { flyers: flyers.slice(0, 1), offers: [], log };
}

// ---- Lidl: letáky přes leaflets.schwarz (obrázky stran + klíčová slova)

export function lidlSlugs(html: string): string[] {
  const all = [...new Set([...html.matchAll(/\/l\/cs\/letak\/([a-z0-9-]+)/g)].map((m) => m[1]))];
  return all.filter((s) => /akcni-leta/.test(s));
}

export function lidlFlyer(json: any, slug: string, today: string): Flyer | null {
  const f = json?.flyer;
  if (!f || !Array.isArray(f.pages)) return null;
  const from = isoDay(f.offerStartDate) ?? isoDay(f.startDate);
  let to = isoDay(f.offerEndDate) ?? isoDay(f.endDate);
  // Titulek „16. 11. - 18. 11. 2026“ bývá přesnější než data zveřejnění.
  const t = dateRange(String(f.title ?? ""));
  const validFrom = t.from ?? from;
  if (t.to) to = t.to;
  if (!to || to < today || (validFrom && validFrom > today)) return null;
  const pages: FlyerPage[] = [];
  for (const p of f.pages) {
    const n = Number(p?.number);
    if (!Number.isFinite(n) || typeof p?.image !== "string" || !isSource("lidl", p.image)) continue;
    pages.push({
      n,
      image: p.image,
      zoom: typeof p.zoom === "string" && isSource("lidl", p.zoom) ? p.zoom : undefined,
      text: [p.keyWords, p.altText].filter((x) => typeof x === "string").join(" "),
      fullText: false,
      link: `https://www.lidl.cz/l/cs/letak/${slug}/view/flyer/page/${n}`,
    });
  }
  if (!pages.length) return null;
  return {
    chain: "lidl",
    id: slug,
    title: `${f.name ?? "Lidl leták"} ${f.title ?? ""}`.trim(),
    url: `https://www.lidl.cz/l/cs/letak/${slug}/view/flyer/page/1`,
    validFrom,
    validTo: to,
    pages,
  };
}

async function lidlSources(fetchImpl: FetchLike, today: string): Promise<Sources> {
  const log: FetchLog[] = [];
  const flyers: Flyer[] = [];
  const list = await getText("lidl", "https://www.lidl.cz/c/akcni-letak/s10008644", fetchImpl, log);
  if (!list.ok) return { flyers, offers: [], log };
  const slugs = lidlSlugs(list.text).slice(0, 4);
  if (slugs.length === 0) log[0].note = "odkazy na akční letáky na stránce nejsou";
  await Promise.all(slugs.map(async (slug) => {
    const r = await getText("lidl", `https://endpoints.leaflets.schwarz/v4/flyer?flyer_identifier=${encodeURIComponent(slug)}`, fetchImpl, log, "application/json");
    if (!r.ok) return;
    try {
      const f = lidlFlyer(JSON.parse(r.text), slug, today);
      if (f) flyers.push(f);
      else log[log.length - 1].note = "leták dnes neplatí";
    } catch {
      log[log.length - 1].note = "neplatná data letáku";
    }
  }));
  flyers.sort((a, b) => (a.id < b.id ? -1 : 1));
  return { flyers: flyers.slice(0, 2), offers: [], log };
}

// ---- Albert: leták supermarketů (Publitas – text i obrázky stran)

/** Letáky z dat stránky albert.cz/aktualni-letaky (platnost, typ prodejny, seznam prodejen). */
export function albertLeaflets(html: string): { slug: string; from: string | null; to: string | null; leaflet: boolean; supermarket: boolean; susice: boolean }[] {
  const out: { slug: string; from: string | null; to: string | null; leaflet: boolean; supermarket: boolean; susice: boolean }[] = [];
  const re = /"__typename":"Leaflet","id":"(\d+)"([^\[\]]{0,1500}?)"viewUrl":"https:\/\/letaky\.albert\.cz\/([a-z0-9_-]+)\/"([^\[\]]{0,1500}?)"stores":\[([^\]]*)\]/gi;
  for (const m of html.matchAll(re)) {
    const seg = m[2] + m[4];
    const get = (k: string) => seg.match(new RegExp(`"${k}":"([^"]*)"`))?.[1] ?? "";
    const day = (v: string) => {
      const d = v.match(/^(\d{1,2})\.(\d{1,2})\.(\d{4})$/);
      return d ? iso(Number(d[3]), Number(d[2]), Number(d[1])) : null;
    };
    if (out.some((o) => o.slug === m[3])) continue;
    out.push({
      slug: m[3],
      from: day(get("validityStartDateFormatted")),
      to: day(get("validityEndDateFormatted")),
      leaflet: get("documentType") === "LEAFLET",
      supermarket: get("locationType") === "SUPERMARKET",
      susice: /Su[šs]ice/.test(m[5]),
    });
  }
  return out;
}

export function albertFlyer(spreads: any, slug: string, from: string | null, to: string | null): Flyer | null {
  if (!Array.isArray(spreads)) return null;
  const base = `https://letaky.albert.cz/${slug}/`;
  const pages: FlyerPage[] = [];
  for (const s of spreads) {
    for (const p of s?.pages ?? []) {
      const n = Number(p?.number);
      const im = p?.images ?? {};
      const img = im.at1200 ?? im.at1000 ?? im.at1600 ?? im.at800;
      if (!Number.isFinite(n) || typeof img !== "string") continue;
      const abs = (u: string) => new URL(u, base).toString();
      pages.push({
        n,
        image: abs(img),
        zoom: typeof im.at2000 === "string" ? abs(im.at2000) : undefined,
        text: typeof p.text === "string" ? p.text.replace(/\s+/g, " ") : undefined,
        fullText: true,
        link: `${base}page/${n}`,
      });
    }
  }
  pages.sort((a, b) => a.n - b.n);
  if (!pages.length) return null;
  return { chain: "albert", id: slug, title: "Albert akční leták", url: `${base}page/1`, validFrom: from, validTo: to, pages };
}

async function albertSources(fetchImpl: FetchLike, today: string): Promise<Sources> {
  const log: FetchLog[] = [];
  const flyers: Flyer[] = [];
  const list = await getText("albert", "https://www.albert.cz/aktualni-letaky", fetchImpl, log);
  if (!list.ok) return { flyers, offers: [], log };
  const all = albertLeaflets(list.text).filter((l) => l.leaflet && l.to && l.to >= today && (!l.from || l.from <= today));
  // Leták, který má Sušici v seznamu prodejen; jinak leták supermarketů.
  const slugs = (all.some((l) => l.susice) ? all.filter((l) => l.susice) : all.filter((l) => l.supermarket)).slice(0, 1);
  if (slugs.length === 0) log[0].note = "platný leták pro Sušici v datech stránky není";
  for (const s of slugs) {
    const r = await getText("albert", `https://letaky.albert.cz/${s.slug}/spreads.json`, fetchImpl, log, "application/json");
    if (!r.ok) continue;
    try {
      const f = albertFlyer(JSON.parse(r.text), s.slug, s.from, s.to);
      if (f) flyers.push(f);
    } catch {
      log[log.length - 1].note = "neplatná data letáku";
    }
  }
  return { flyers, offers: [], log };
}

// ---- JIP: leták pro Sušici (Flip PDF – text i obrázky stran)

export function jipLeaflets(html: string): { href: string; title: string; from: string | null; to: string | null; susice: boolean }[] {
  const out: { href: string; title: string; from: string | null; to: string | null; susice: boolean }[] = [];
  for (const a of html.matchAll(/<article class="i-leaflet[\s\S]*?<\/article>/g)) {
    const s = a[0];
    const href = s.match(/href="([^"]+)"/)?.[1] ?? "";
    if (!href || out.some((o) => o.href === href)) continue;
    const text = stripTags(s);
    const r = dateRange(text);
    out.push({ href, title: decodeEntities(s.match(/title="([^"]+)"/)?.[1] ?? "Leták JIP"), from: r.from, to: r.to, susice: /Su[šs]ice/i.test(text) });
  }
  return out;
}

/** Pole řetězců z JS souboru (var textForPages = ["…","…"];) bez spouštění kódu. */
export function jsStringArray(js: string): string[] {
  const start = js.indexOf("[");
  if (start < 0) return [];
  const out: string[] = [];
  let i = start + 1;
  while (i < js.length) {
    while (i < js.length && /[\s,]/.test(js[i])) i++;
    const q = js[i];
    if (q !== '"' && q !== "'") break;
    let s = "";
    i++;
    while (i < js.length && js[i] !== q) {
      if (js[i] === "\\") {
        const c = js[i + 1];
        if (c === "n" || c === "r" || c === "t") s += " ";
        else if (c === "u" && /^[0-9a-fA-F]{4}$/.test(js.slice(i + 2, i + 6))) {
          s += String.fromCharCode(parseInt(js.slice(i + 2, i + 6), 16));
          i += 4;
        } else s += c ?? "";
        i += 2;
      } else s += js[i++];
    }
    i++;
    out.push(s);
  }
  return out;
}

async function jipSources(fetchImpl: FetchLike, today: string): Promise<Sources> {
  const log: FetchLog[] = [];
  const flyers: Flyer[] = [];
  const list = await getText("jip", "https://www.jip-potraviny.cz/akcni-letaky/", fetchImpl, log);
  if (!list.ok) return { flyers, offers: [], log };
  const mine = jipLeaflets(list.text).filter((l) => l.susice && (!l.to || l.to >= today) && (!l.from || l.from <= today)).slice(0, 1);
  if (mine.length === 0) log[0].note = "platný leták pro Sušici na stránce není";
  for (const l of mine) {
    const base = new URL(l.href.replace(/\/?$/, "/"), "https://www.jip-potraviny.cz/").toString();
    const r = await getText("jip", `${base}mobile/javascript/search_config.js`, fetchImpl, log, "*/*");
    if (!r.ok) continue;
    const texts = jsStringArray(r.text).map((t) => t.replace(/\s+/g, " ").trim());
    if (texts.length === 0) {
      log[log.length - 1].note = "text letáku se nepodařilo přečíst";
      continue;
    }
    flyers.push({
      chain: "jip",
      id: base.replace(/\/$/, "").split("/").pop() ?? base,
      title: l.title,
      url: base,
      validFrom: l.from,
      validTo: l.to,
      pages: texts.slice(0, 60).map((text, i) => ({ n: i + 1, image: `${base}files/mobile/${i + 1}.jpg`, text, fullText: true, link: `${base}#p=${i + 1}` })),
    });
  }
  return { flyers, offers: [], log };
}

// ---- COOP: letáky Západočeského konzumního družstva Sušice (obrázky stran)

export function coopFlyer(html: string, pageUrl: string, id: string, title: string, storeId: string | null): Flyer | null {
  const main = html.slice(Math.max(0, html.indexOf("<main")));
  const start = main.search(/Aktu[aá]ln[ií] nab[ií]dka/i);
  if (start < 0) return null;
  const rest = main.slice(start);
  const end = rest.search(/P[řr][ií][šs]t[ií] nab[ií]dka|<\/main>/i);
  const part = end > 0 ? rest.slice(0, end) : rest;
  const r = dateRange(stripTags(part));
  const pages: FlyerPage[] = [];
  for (const m of part.matchAll(/<a[^>]*class=['"]letak['"][^>]*href=['"]([^'"]+)['"]/gi)) {
    const image = new URL(m[1], pageUrl).toString();
    if (isSource("coop", image)) pages.push({ n: pages.length + 1, image, link: pageUrl });
  }
  if (!pages.length) return null;
  return { chain: "coop", id: `${id}-${r.from ?? ""}`, title, url: pageUrl, validFrom: r.from, validTo: r.to, storeId, pages };
}

async function coopSources(fetchImpl: FetchLike, today: string): Promise<Sources> {
  const log: FetchLog[] = [];
  const flyers: Flyer[] = [];
  // Leták TUTY a TIP platí pro prodejny Nádražní, náměstí Svobody i Lerchova;
  // TIP Extra jen pro prodejnu Lerchova.
  const defs: [string, string, string, string | null][] = [
    ["https://www.zkdsusice.cz/letak_tuty", "tuty", "COOP leták TUTY a TIP", null],
    ["https://www.zkdsusice.cz/letak_tip", "tip", "COOP TIP Extra (Lerchova)", "coop-lerchova"],
  ];
  await Promise.all(defs.map(async ([url, id, title, store]) => {
    const r = await getText("coop", url, fetchImpl, log);
    if (!r.ok) return;
    const f = coopFlyer(r.text, url, id, title, store);
    if (f && (!f.validTo || f.validTo >= today) && (!f.validFrom || f.validFrom <= today)) flyers.push(f);
    else log[log.length - 1].note = f ? "leták dnes neplatí" : "leták na stránce není";
  }));
  flyers.sort((a, b) => (a.id < b.id ? 1 : -1));
  return { flyers, offers: [], log };
}

const LOADERS: Record<string, (f: FetchLike, today: string) => Promise<Sources>> = {
  tesco: tescoSources,
  penny: pennySources,
  lidl: lidlSources,
  albert: albertSources,
  jip: jipSources,
  coop: coopSources,
};

/** Aktuální letáky a data řetězce (bez AI, zdarma). */
export async function loadSources(chain: string, fetchImpl: FetchLike, today: string): Promise<Sources> {
  const load = LOADERS[chain];
  if (!load) return { flyers: [], offers: [], log: [] };
  try {
    return await load(fetchImpl, today);
  } catch (e) {
    return { flyers: [], offers: [], log: [{ url: `https://${CHAINS[chain].domains[0]}/`, status: 0, chars: 0, note: `chyba čtení zdroje (${(e as Error).name})` }] };
  }
}

/** Krátký otisk sady letáků – stejné letáky se pro stejný produkt nečtou znovu. */
export function flyersKey(src: Sources): string {
  const s = src.flyers.map((f) => `${f.id}|${f.validTo}|${f.pages.length}`).sort().join(";") + `#${src.offers.length}`;
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

// ------------------------------------------------------------ výběr stran a ověření v textu

/** Je položka zmíněná v textu strany? (stejná pravidla jako shoda produktu, slova kdekoli na straně) */
export function pageMentions(text: string, item: string): boolean {
  return productMatches(item, text);
}

/**
 * Strany letáku, které stojí za přečtení: s textem jen ty, kde je některá
 * položka zmíněná (nejvíc shod napřed); bez textu všechny.
 */
export function pickPages(flyer: Flyer, items: string[], max: number): { page: FlyerPage; items: string[] }[] {
  const withText = flyer.pages.some((p) => (p.text ?? "").length > 30);
  if (!withText) return flyer.pages.slice(0, max).map((page) => ({ page, items }));
  const hits = flyer.pages
    .map((page) => ({ page, items: items.filter((it) => page.text && pageMentions(page.text, it)) }))
    .filter((h) => h.items.length > 0);
  hits.sort((a, b) => b.items.length - a.items.length || a.page.n - b.page.n);
  return hits.slice(0, max).sort((a, b) => a.page.n - b.page.n);
}

/** Stojí cena v textu letáku? Letáky píší 34,90 i „3490“, „34 90“, „90 34“ a „199,-“. */
export function priceInFlyerText(text: string, price: number): boolean {
  const cents = Math.round(price * 100);
  const kc = Math.floor(cents / 100), hal = cents % 100;
  const h = String(hal).padStart(2, "0");
  const forms = hal === 0
    ? [`${kc}(?:[,.]-|[,.]–|[,.]00)?(?![,.]\\d)`]
    : [`${kc}[,.]${h}`, `${kc}${h}`, `${kc}\\s${h}`, `${h}\\s${kc}`];
  return forms.some((f) => new RegExp(`(?<![\\d,.])${f}(?!\\d)`).test(text));
}

/**
 * Ověření v textu strany: název produktu musí být v textu a cena musí stát
 * blízko něj (do 300 znaků) – cena jiného zboží z jiného místa strany nestačí.
 */
export function verifiedByText(page: FlyerPage, product: string, price: number): boolean {
  if (!page.fullText || !page.text) return false;
  const need = matchStems(product).filter((s) => !/^\d/.test(s));
  if (need.length === 0) return false;
  const text = fold(page.text);
  const words = [...text.matchAll(/[a-z]+/g)]
    .filter((m) => m[0].length >= 3 && !IGNORE.has(m[0]))
    .map((m) => ({ at: m.index ?? 0, stem: czStem(m[0]) }));
  const want = Math.max(1, Math.ceil(need.length * 0.6));
  // Kotvy: místa, kde stojí nejdelší (nejurčitější) slovo názvu.
  const main = [...need].sort((x, y) => y.length - x.length)[0];
  for (const w of words) {
    if (!stemsMatch(main, w.stem)) continue;
    const near = words.filter((o) => Math.abs(o.at - w.at) <= 120).map((o) => o.stem);
    if (matchedCount(need, near) < want) continue;
    if (priceInFlyerText(text.slice(Math.max(0, w.at - 300), w.at + 300), price)) return true;
  }
  return false;
}

// ------------------------------------------------------------ Gemini: čtení stran letáku

export interface AiDiag {
  mode: "leták" | "kontrola" | "data";
  model: string;
  status: "ok" | "chyba";
  error?: string;
  code?: string;
  /** Které strany (a kterého letáku) se četly. */
  pages?: string;
  offers?: number;
  note?: string;
}

export class AiError extends Error {
  constructor(public code: string, message: string, public status = 0, public retryAfter = 0) {
    super(message);
  }
}

/** Srozumitelný důvod chyby Gemini (bez klíče a bez dlouhých odpovědí). */
export function geminiError(status: number, body: string, model: string): AiError {
  let msg = "";
  let retry = 0;
  try {
    const j = JSON.parse(body);
    msg = String(j?.error?.message ?? "");
    for (const d of j?.error?.details ?? []) {
      const m = String(d?.retryDelay ?? "").match(/^(\d+(?:\.\d+)?)s$/);
      if (m) retry = Math.ceil(Number(m[1]));
    }
  } catch {
    msg = body;
  }
  msg = msg.replace(/AIza[0-9A-Za-z_-]+/g, "…").slice(0, 220);
  const low = msg.toLowerCase();
  if (status === 404 || /no longer available|not found|is not supported/.test(low)) {
    return new AiError("model_unavailable", `model ${model} není pro tento klíč dostupný: ${msg}`, status);
  }
  if (status === 429) {
    return new AiError("quota", `vyčerpaný bezplatný limit Gemini (${model}): ${msg}`, status, retry);
  }
  if (status === 400 && /api key|api_key/.test(low)) return new AiError("bad_key", `klíč Gemini je neplatný: ${msg}`, status);
  if (status === 403) return new AiError("forbidden", `klíč nemá přístup (${model}): ${msg}`, status);
  if (status >= 500) return new AiError("overloaded", `Gemini je dočasně nedostupné (${status}, ${model})`, status, 3);
  return new AiError("error", `Gemini ${status} (${model}): ${msg}`, status);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Jedno volání Gemini; při krátkém omezení (429/5xx) jednou počká a zkusí znovu. */
async function callGemini(env: Env, model: string, body: unknown, fetchImpl: FetchLike, deadline: number): Promise<any> {
  for (let attempt = 0; ; attempt++) {
    let res: Response;
    try {
      res = await fetchImpl(
        `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-goog-api-key": env.geminiKey },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(60000),
        },
      );
    } catch (e) {
      throw new AiError("network", `Gemini nedostupné (${(e as Error).name})`);
    }
    if (res.ok) return await res.json();
    const err = geminiError(res.status, await res.text().catch(() => ""), model);
    const wait = Math.min(err.retryAfter, 25) * 1000;
    if (attempt === 0 && wait > 0 && Date.now() + wait + 15000 < deadline) {
      await sleep(wait);
      continue;
    }
    throw err;
  }
}

function candidateText(body: any): { text: string; finish: string } {
  const cand = body?.candidates?.[0] ?? {};
  const text = (cand?.content?.parts ?? [])
    .filter((p: any) => !p?.thought)
    .map((p: any) => p?.text ?? "")
    .join("");
  const block = body?.promptFeedback?.blockReason;
  return { text, finish: block ? `zablokováno: ${block}` : String(cand?.finishReason ?? "") };
}

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000) as unknown as number[]);
  }
  return btoa(bin);
}

export interface Img {
  mime: string;
  data: string;
}

/** Stáhne obrázek strany letáku (jen z povolených zdrojů řetězce, nejvýš 6 MB). */
export async function fetchImage(chain: string, url: string, fetchImpl: FetchLike): Promise<Img | string> {
  if (!isSource(chain, url)) return "obrázek mimo oficiální zdroje";
  try {
    const res = await fetchImpl(url, {
      headers: { "User-Agent": UA, Accept: "image/jpeg,image/png,image/webp,*/*;q=0.5" },
      redirect: "follow",
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      return `obrázek HTTP ${res.status}`;
    }
    if (!isSource(chain, res.url || url)) return "obrázek přesměrován mimo oficiální web";
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.length < 2000) return "obrázek je prázdný";
    if (bytes.length > 6_000_000) return "obrázek je příliš velký";
    const type = (res.headers.get("content-type") ?? "").split(";")[0].trim();
    const mime = /^image\/(jpeg|png|webp)$/.test(type) ? type : bytes[0] === 0x89 ? "image/png" : "image/jpeg";
    return { mime, data: toBase64(bytes) };
  } catch (e) {
    return `obrázek nedostupný (${(e as Error).name})`;
  }
}

export function readPrompt(chainName: string, items: string[], pages: number[], today: string): string {
  return [
    `Dnes je ${today}. Přiložené obrázky jsou strany aktuálního akčního letáku řetězce ${chainName}`,
    `(v pořadí strany: ${pages.join(", ")}). Najdi na nich nabídky zboží, které odpovídá těmto položkám nákupního seznamu:`,
    items.map((i) => `- ${i}`).join("\n"),
    "Pravidla:",
    "1. Používej VÝHRADNĚ to, co je na obrázcích skutečně vytištěno. Nic neodhaduj a nedoplňuj. Když položka v letáku není, vynech ji.",
    "2. Zboží musí být opravdu tou položkou: „máslo“ je máslo, ne pečivo, sušenky nebo margarín „s máslovou příchutí“; „kuřecí prsní řízky“ nejsou stehenní řízky ani šunka; „vepřová pečeně“ není krkovice, plec ani bok. Přesnější druh téhož zboží (značka, balení) vyhovuje.",
    "3. Cena přesně jako v letáku, v Kč, s DPH (u velkoobchodu ber cenu s DPH, ne „bez DPH“). Ceny v letácích mívají haléře malým písmem (109⁹⁰ = 109.90).",
    "4. Když má zboží cenu s věrnostní kartou/aplikací/kuponem a jinou bez ní, vrať DVĚ nabídky a do conditions napiš např. „s aplikací“ a „bez aplikace“. Jiné podmínky (od 2 ks, jen čtvrtek–sobota, jen pult) napiš také do conditions.",
    "5. pack_qty a pack_unit = velikost balení, ke které cena patří (250 g, 1 kg, 1 ks). U ceny za kilogram je to 1 kg. regular_price = přeškrtnutá původní cena, jinak null.",
    "6. valid_from a valid_to (YYYY-MM-DD) vyplň JEN když je u nabídky nebo na straně vytištěna vlastní platnost; jinak null.",
    "7. page = číslo strany, na které nabídka je (z výše uvedených čísel).",
    "Odpověz POUZE polem JSON (když nic, tak []):",
    '[{"item": "položka seznamu přesně jak je výše", "product": "název zboží v letáku", "label": "značka, druh, gramáž", "price": 34.9, "pack_qty": 250, "pack_unit": "g", "regular_price": 54.9, "conditions": "", "valid_from": null, "valid_to": null, "page": 3}]',
  ].join("\n");
}

export function checkPrompt(chainName: string, products: { id: number; product: string; label: string; conditions: string }[]): string {
  return [
    `Na obrázku je jedna strana akčního letáku řetězce ${chainName}. Přečti z ní přesnou akční cenu (Kč, s DPH) těchto výrobků:`,
    products.map((p) => `${p.id}. ${p.product}${p.label ? ` (${p.label})` : ""}${p.conditions ? ` – cena ${p.conditions}` : ""}`).join("\n"),
    "Čti pouze to, co je na obrázku vytištěno; haléře bývají malým písmem (109⁹⁰ = 109.90). Když výrobek na straně není nebo cenu nelze bezpečně přečíst, dej found false a price null.",
    'Odpověz POUZE polem JSON: [{"id": 1, "found": true, "price": 34.9}]',
  ].join("\n");
}

/** Nabídka přečtená z letáku (před ověřením). */
export interface FlyerOffer extends RawOffer {
  item: string;
  page: number;
}

function jsonArray(text: string): unknown[] | string {
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start < 0 || end <= start) return text.trim() ? "odpověď neobsahuje pole JSON" : "prázdná odpověď";
  try {
    const data = JSON.parse(text.slice(start, end + 1));
    return Array.isArray(data) ? data : "odpověď není pole";
  } catch {
    return "neplatný JSON v odpovědi";
  }
}

/** Odpověď modelu → nabídky; co nesedí (cizí položka, jiný produkt, chybí cena), odmítne s důvodem. */
export function parseFlyerOffers(
  text: string,
  items: string[],
  pages: FlyerPage[],
  flyer: Flyer,
): { offers: FlyerOffer[]; rejected: Rejected[]; note: string } {
  const data = jsonArray(text);
  if (typeof data === "string") return { offers: [], rejected: [], note: data };
  const offers: FlyerOffer[] = [];
  const rejected: Rejected[] = [];
  for (const raw of data.slice(0, 60)) {
    if (!raw || typeof raw !== "object") continue;
    const o = raw as Record<string, unknown>;
    const product = typeof o.product === "string" ? o.product.trim().slice(0, 160) : "";
    const label = typeof o.label === "string" ? o.label.trim().slice(0, 200) : "";
    const price = num(o.price);
    const said = typeof o.item === "string" ? o.item : "";
    const item = items.find((i) => i === said) ?? items.find((i) => productKey(i) === productKey(said)) ??
      items.find((i) => productMatches(i, `${product} ${label}`));
    const page = pages.find((p) => p.n === Number(o.page)) ?? (pages.length === 1 ? pages[0] : undefined);
    const name = product || "?";
    if (!product || price === null) {
      rejected.push({ product: name, reason: `chybí ${[!product && "název", price === null && "cena"].filter(Boolean).join(", ")}` });
      continue;
    }
    if (price <= 0 || price >= 100000) {
      rejected.push({ product: name, reason: "nesmyslná cena" });
      continue;
    }
    if (!item) {
      rejected.push({ product: name, reason: "nepatří k žádné položce seznamu" });
      continue;
    }
    if (!productMatches(item, `${product} ${label}`)) {
      rejected.push({ product: name, reason: `jiné zboží než „${item}“` });
      continue;
    }
    if (!page) {
      rejected.push({ product: name, reason: "AI neuvedla stranu letáku" });
      continue;
    }
    // Platnost: vlastní jen uvnitř platnosti letáku, jinak platnost letáku.
    let from = isoDay(o.valid_from), to = isoDay(o.valid_to);
    if (flyer.validTo && (!to || to > flyer.validTo)) to = flyer.validTo;
    if (flyer.validFrom && (!from || from < flyer.validFrom)) from = flyer.validFrom;
    if (!to) {
      rejected.push({ product: name, reason: "u letáku není známá platnost" });
      continue;
    }
    offers.push({
      item,
      page: page.n,
      product,
      label,
      price,
      pack_qty: num(o.pack_qty),
      pack_unit: typeof o.pack_unit === "string" ? o.pack_unit.slice(0, 20) : "",
      regular_price: num(o.regular_price),
      conditions: typeof o.conditions === "string" ? o.conditions.slice(0, 200) : "",
      valid_from: from,
      valid_to: to,
      source_url: page.link,
      store_id: flyer.storeId ?? null,
    });
  }
  return { offers, rejected, note: "" };
}

function imageParts(pages: FlyerPage[], images: Img[]): unknown[] {
  return pages.flatMap((p, i) => [{ text: `Strana ${p.n}:` }, { inline_data: { mime_type: images[i].mime, data: images[i].data } }]);
}

/** Přečte strany letáku (obrázky) a vrátí nabídky pro položky seznamu. */
export async function readFlyerPages(
  env: Env,
  flyer: Flyer,
  pages: FlyerPage[],
  images: Img[],
  items: string[],
  today: string,
  fetchImpl: FetchLike,
  deadline: number,
): Promise<{ offers: FlyerOffer[]; rejected: Rejected[]; diag: AiDiag }> {
  const body = await callGemini(env, env.geminiExtractModel, {
    contents: [{
      role: "user",
      parts: [{ text: readPrompt(CHAINS[flyer.chain].name, items, pages.map((p) => p.n), today) }, ...imageParts(pages, images)],
    }],
    generationConfig: { temperature: 0, responseMimeType: "application/json" },
  }, fetchImpl, deadline);
  const { text, finish } = candidateText(body);
  const parsed = parseFlyerOffers(text, items, pages, flyer);
  return {
    offers: parsed.offers,
    rejected: parsed.rejected,
    diag: {
      mode: "leták",
      model: env.geminiExtractModel,
      status: "ok",
      pages: `${flyer.title}, str. ${pages.map((p) => p.n).join(", ")}`,
      offers: parsed.offers.length,
      note: [parsed.note, finish && finish !== "STOP" ? `konec: ${finish}` : ""].filter(Boolean).join("; "),
    },
  };
}

/** Kontrolní čtení jedné strany: ceny výrobků bez nápovědy. Vrací id → cena (null = nenašlo). */
export async function checkFlyerPage(
  env: Env,
  flyer: Flyer,
  page: FlyerPage,
  image: Img,
  products: { id: number; product: string; label: string; conditions: string }[],
  fetchImpl: FetchLike,
  deadline: number,
): Promise<Map<number, number | null>> {
  const body = await callGemini(env, env.geminiExtractModel, {
    contents: [{
      role: "user",
      parts: [{ text: checkPrompt(CHAINS[flyer.chain].name, products) }, { inline_data: { mime_type: image.mime, data: image.data } }],
    }],
    generationConfig: { temperature: 0, responseMimeType: "application/json" },
  }, fetchImpl, deadline);
  const data = jsonArray(candidateText(body).text);
  const out = new Map<number, number | null>();
  if (typeof data === "string") return out;
  for (const raw of data) {
    const o = raw as Record<string, unknown>;
    const id = Number(o?.id);
    if (!Number.isFinite(id)) continue;
    out.set(id, o.found === false ? null : num(o.price));
  }
  return out;
}

class Db {
  constructor(private env: Env, private fetchImpl: FetchLike) {}

  private headers(): Record<string, string> {
    const key = this.env.serviceKey;
    return {
      apikey: key,
      ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}),
      "Content-Type": "application/json",
    };
  }

  async userId(token: string): Promise<string | null> {
    const res = await this.fetchImpl(`${this.env.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: this.env.anonKey, Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    const body = await res.json();
    return typeof body?.id === "string" ? body.id : null;
  }

  async rest(path: string, init: RequestInit = {}): Promise<any> {
    const res = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      ...init,
      headers: { ...this.headers(), ...(init.headers as Record<string, string> ?? {}) },
    });
    if (!res.ok) {
      const err = new Error(`Databáze ${res.status}: ${await res.text()}`) as Error & { status?: number };
      err.status = res.status;
      throw err;
    }
    const t = await res.text();
    return t ? JSON.parse(t) : null;
  }

  /** Co už je pro řetězec prohledané: klíč produktu → stav (poslední záznam od [since]). */
  async scanned(chain: string, keys: string[], since: string): Promise<Map<string, { status: string; day: string }>> {
    const out = new Map<string, { status: string; day: string }>();
    if (keys.length === 0) return out;
    const list = keys.map((k) => `"${k.replace(/"/g, "")}"`).join(",");
    const rows = await this.rest(
      `price_scans?select=product_key,status,scanned_on&chain=eq.${chain}&scanned_on=gte.${since}&product_key=in.(${encodeURIComponent(list)})&order=scanned_on.asc`,
    );
    for (const r of rows ?? []) out.set(r.product_key, { status: String(r.status ?? ""), day: String(r.scanned_on ?? "") });
    return out;
  }

  async markScanned(chain: string, keys: string[], today: string, provider: string, status: string, found: number) {
    if (keys.length === 0) return;
    await this.rest("price_scans?on_conflict=chain,product_key,scanned_on", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify(keys.map((k) => ({
        chain, product_key: k, scanned_on: today, provider, status, found,
      }))),
    });
  }

  async usage(provider: string, today: string): Promise<number> {
    const rows = await this.rest(`price_ai_usage?select=requests&provider=eq.${provider}&day=eq.${today}`);
    return Number(rows?.[0]?.requests ?? 0);
  }

  async setUsage(provider: string, today: string, requests: number) {
    await this.rest("price_ai_usage?on_conflict=provider,day", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({ provider, day: today, requests }),
    });
  }

  /** Uloží nabídku; duplicitní (stejný produkt, cena a konec platnosti) přeskočí. */
  async insertOffer(row: Record<string, unknown>): Promise<boolean> {
    try {
      await this.rest("price_offers", {
        method: "POST",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify(row),
      });
      return true;
    } catch (e) {
      if ((e as { status?: number }).status === 409) return false;
      throw e;
    }
  }
}

// ------------------------------------------------------------ výběr poskytovatele

export interface ProviderStatus {
  id: "gemini" | "openai";
  configured: boolean;
  free: boolean;
  allowed: boolean;
  usedToday: number;
  limit: number | null;
}

export async function providerStatus(env: Env, db: { usage(p: string, d: string): Promise<number> }, today: string) {
  const gemini: ProviderStatus = {
    id: "gemini",
    configured: !!env.geminiKey,
    free: true,
    allowed: true,
    usedToday: env.geminiKey ? await db.usage("gemini", today) : 0,
    limit: env.geminiDailyLimit,
  };
  const openai: ProviderStatus = {
    id: "openai",
    configured: !!env.openaiKey,
    free: false,
    allowed: env.allowPaid,
    usedToday: env.openaiKey ? await db.usage("openai", today) : 0,
    limit: null,
  };
  return [gemini, openai];
}

/** Automatický výběr: zdarma a dostupný; placený jen když je povolený. */
export function chooseProvider(list: ProviderStatus[]): ProviderStatus | null {
  for (const p of list) {
    if (!p.configured || !p.allowed) continue;
    if (p.limit !== null && p.usedToday >= p.limit) continue;
    if (p.free) return p;
  }
  return list.find((p) => p.configured && p.allowed && !p.free) ?? null;
}

// ------------------------------------------------------------ HTTP

const ALLOWED_ORIGINS = ["https://hincep-lab.github.io", "http://localhost"];

function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const ok = ALLOWED_ORIGINS.some((o) => origin === o || origin.startsWith(`${o}:`));
  return {
    "Access-Control-Allow-Origin": ok ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

export function pragueToday(now = new Date()): string {
  return new Intl.DateTimeFormat("sv-SE", { timeZone: "Europe/Prague" }).format(now);
}

/** Den v Praze z časového údaje ISO („2026-11-17T22:59:59Z“ → 2026-11-17). */
function pragueDay(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : pragueToday(d);
}

function addDays(day: string, days: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export interface OfferDiag {
  product: string;
  item?: string;
  price: number;
  pack?: string;
  conditions?: string;
  valid_to: string;
  source: string;
  url?: string;
  verified: boolean;
  method?: string;
  reason: string;
  saved: "uloženo" | "už uloženo";
}

export interface SourceDiag {
  kind: "leták" | "data";
  title: string;
  url: string;
  valid_from: string | null;
  valid_to: string | null;
  /** Počet stran letáku / položek v datech. */
  size: number;
  /** Má leták text stran (pro výběr stran a ověření)? */
  text: boolean;
  /** Strany vybrané ke čtení. */
  picked: number[];
}

export interface ChainDiag {
  chain: string;
  name: string;
  cached: boolean;
  sources: SourceDiag[];
  pages: { url: string; status: number; chars: number; matched: string[]; note: string }[];
  ai: AiDiag[];
  offers: OfferDiag[];
  rejected: Rejected[];
  errors: string[];
}

/** Nejvíc stran na jedno čtení a nejvíc stran z jednoho letáku. */
const BATCH = 6;
const MAX_PAGES_TEXT = 6;
const MAX_PAGES_BLIND = 42;

async function inParallel<T>(jobs: (() => Promise<T>)[], limit: number): Promise<T[]> {
  const out: T[] = new Array(jobs.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, jobs.length) }, async () => {
    while (next < jobs.length) {
      const i = next++;
      out[i] = await jobs[i]();
    }
  }));
  return out;
}

export async function handle(
  req: Request,
  env: Env,
  fetchImpl: FetchLike = fetch,
  now = new Date(),
): Promise<Response> {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply(405, { error: "Jen POST." });
  if (!env.supabaseUrl || !env.anonKey || !env.serviceKey) return reply(503, { error: "Funkce není nastavená." });

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return reply(401, { error: "Chybí přístupový token." });
  const db = new Db(env, fetchImpl);
  const userId = await db.userId(token).catch(() => null);
  if (!userId) return reply(401, { error: "Neplatný nebo vypršelý přístupový token." });

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return reply(400, { error: "Neplatný požadavek." });
  }
  const today = pragueToday(now);
  const deadline = Date.now() + (env.budgetMs ?? 110_000);

  try {
    switch (payload?.action) {
      case "status": {
        const providers = await providerStatus(env, db, today);
        return reply(200, { providers, chosen: chooseProvider(providers)?.id ?? null, version: VERSION });
      }

      case "refresh": {
        const products: string[] = Array.isArray(payload?.products)
          ? [...new Set(
            payload.products
              .filter((p: unknown) => typeof p === "string")
              .map((p: string) => p.trim().slice(0, 80))
              .filter((p: string) => productKey(p).length > 0),
          )].slice(0, 20) as string[]
          : [];
        const force = payload?.force === true;
        const summary = {
          version: VERSION,
          provider: null as string | null,
          scanned: 0,
          cached: 0,
          found: 0,
          verified: 0,
          unverified: 0,
          saved: 0,
          duplicates: 0,
          rejected: 0,
          errors: [] as string[],
          gemini: {
            configured: !!env.geminiKey,
            model: env.geminiExtractModel,
            calls: 0,
            ok: null as boolean | null,
            error: "",
          },
          diag: [] as ChainDiag[],
        };
        if (products.length === 0) return reply(200, summary);
        const chainIds: string[] = Array.isArray(payload?.chains)
          ? payload.chains.filter((c: unknown) => typeof c === "string" && CHAINS[c as string])
          : Object.keys(CHAINS);

        const providers = await providerStatus(env, db, today);
        const gemini = providers[0];
        const startUsage = gemini.usedToday;
        const canAsk = () => gemini.configured && gemini.usedToday < (gemini.limit ?? Infinity);
        // Po neodstranitelné chybě (klíč, model, limit) už Gemini v tomto běhu nezkoušet.
        let aiOff = "";
        const ask = async <T>(d: ChainDiag, mode: AiDiag["mode"], pagesLabel: string, run: () => Promise<T>): Promise<T | null> => {
          if (!gemini.configured) {
            if (!d.errors.includes(NO_KEY)) d.errors.push(NO_KEY);
            return null;
          }
          if (aiOff) return null;
          if (!canAsk()) {
            aiOff = "denní limit čtení přes Gemini je vyčerpán";
            d.errors.push(aiOff);
            return null;
          }
          if (Date.now() > deadline - 20000) {
            if (!d.errors.includes(NO_TIME)) d.errors.push(NO_TIME);
            return null;
          }
          gemini.usedToday++;
          summary.gemini.calls++;
          summary.provider = "gemini";
          try {
            const r = await run();
            summary.gemini.ok = true;
            return r;
          } catch (e) {
            const err = e as AiError;
            d.ai.push({ mode, model: env.geminiExtractModel, status: "chyba", code: err.code, error: err.message, pages: pagesLabel });
            if (!d.errors.includes(err.message)) d.errors.push(err.message);
            if (summary.gemini.ok !== true) summary.gemini.ok = false;
            summary.gemini.error = err.message;
            if (["model_unavailable", "quota", "forbidden", "bad_key"].includes(err.code)) aiOff = err.message;
            return null;
          }
        };

        const save = async (chain: string, offer: RawOffer, item: string, verdict: Verdict, provider: string, d: ChainDiag) => {
          const storeId = offer.store_id && STORES[offer.store_id] === chain ? offer.store_id : null;
          const inserted = await db.insertOffer({
            chain,
            store_id: storeId,
            product: offer.product,
            product_key: productKey(offer.product),
            label: offer.label ?? "",
            price: offer.price,
            pack_qty: offer.pack_qty ?? null,
            pack_unit: offer.pack_unit ?? "",
            regular_price: offer.regular_price ?? null,
            conditions: offer.conditions ?? "",
            valid_from: offer.valid_from && offer.valid_from <= offer.valid_to ? offer.valid_from : null,
            valid_to: offer.valid_to,
            source_url: /^https:\/\//.test(offer.source_url) ? offer.source_url : `https://${CHAINS[chain].domains[0]}/`,
            source_title: verdict.reason,
            provider,
            verified: verdict.verified,
            verify_method: verdict.method,
            verified_at: verdict.verified ? new Date().toISOString() : null,
            created_by: userId,
          });
          d.offers.push({
            product: offer.product,
            item,
            price: offer.price,
            pack: offer.pack_qty ? `${String(offer.pack_qty).replace(".", ",")} ${offer.pack_unit ?? ""}`.trim() : "",
            conditions: offer.conditions ?? "",
            valid_to: offer.valid_to,
            source: hostOf(offer.source_url),
            url: offer.source_url,
            verified: verdict.verified,
            method: verdict.method,
            reason: verdict.reason,
            saved: inserted ? "uloženo" : "už uloženo",
          });
          summary.found++;
          if (inserted) summary.saved++;
          else summary.duplicates++;
          if (verdict.verified) summary.verified++;
          else summary.unverified++;
        };

        for (const chain of chainIds) {
          const d: ChainDiag = {
            chain, name: CHAINS[chain].name, cached: false,
            sources: [], pages: [], ai: [], offers: [], rejected: [], errors: [],
          };
          summary.diag.push(d);
          const keys = new Map(products.map((p) => [productKey(p), p]));

          // 1) Zdroje řetězce: aktuální letáky a data (zdarma, bez AI).
          const src = await loadSources(chain, fetchImpl, today);
          for (const l of src.log) d.pages.push({ url: l.url, status: l.status, chars: l.chars, matched: [], note: l.note });
          const key = flyersKey(src);
          const sourceOk = src.flyers.length > 0 || src.offers.length > 0;
          if (!sourceOk) d.errors.push("aktuální leták ani data obchodu se nepodařilo stáhnout");

          // 2) Mezipaměť: stejný produkt + stejné letáky už se nečtou znovu.
          const done = force || !sourceOk
            ? new Map<string, { status: string; day: string }>()
            : await db.scanned(chain, [...keys.keys()], addDays(today, -21));
          const todo = [...keys.entries()].filter(([k]) => done.get(k)?.status !== `ok:${key}`);
          summary.cached += keys.size - todo.length;
          const names = todo.map(([, p]) => p);
          if (src.offers.length) {
            d.sources.push({ kind: "data", title: `Akční položky na webu ${CHAINS[chain].name}`, url: src.offers[0].source_url.replace(/\/products\/.*/, "/nabidky"), valid_from: null, valid_to: null, size: src.offers.length, text: true, picked: [] });
          }
          if (todo.length === 0) {
            d.cached = true;
            for (const f of src.flyers) d.sources.push({ kind: "leták", title: f.title, url: f.url, valid_from: f.validFrom, valid_to: f.validTo, size: f.pages.length, text: f.pages.some((p) => !!p.text), picked: [] });
            continue;
          }
          let complete = sourceOk;

          // 3) Strukturovaná data webu (Penny): přesné ceny bez AI.
          let fromData = 0;
          for (const offer of src.offers) {
            const item = names.find((n) => productMatches(n, `${offer.product}`));
            if (!item || offer.valid_to < today || (offer.valid_from && offer.valid_from > addDays(today, 7))) continue;
            fromData++;
            await save(chain, offer, item, { verified: true, method: "data", reason: "cena z dat oficiálního webu obchodu" }, "web", d);
          }
          if (src.offers.length) {
            d.ai.push({ mode: "data", model: "bez AI", status: "ok", offers: fromData, pages: `${src.offers.length} akčních položek na webu`, note: "" });
          }

          // 4) Letáky: Gemini čte obrázky stran; cena se ověří textem strany nebo druhým čtením.
          for (const flyer of src.flyers) {
            const blind = !flyer.pages.some((p) => (p.text ?? "").length > 30);
            const picked = pickPages(flyer, names, blind ? MAX_PAGES_BLIND : MAX_PAGES_TEXT);
            d.sources.push({
              kind: "leták", title: flyer.title, url: flyer.url, valid_from: flyer.validFrom, valid_to: flyer.validTo,
              size: flyer.pages.length, text: !blind, picked: picked.map((p) => p.page.n),
            });
            if (!flyer.validTo) {
              d.errors.push(`${flyer.title}: nepodařilo se zjistit platnost letáku`);
              complete = false;
              continue;
            }
            if (picked.length === 0) continue; // text letáku položky nezmiňuje – není co číst
            const batches: { page: FlyerPage; items: string[] }[][] = [];
            for (let i = 0; i < picked.length; i += BATCH) batches.push(picked.slice(i, i + BATCH));

            const results = await inParallel(batches.map((batch) => async () => {
              const label = `${flyer.title}, str. ${batch.map((b) => b.page.n).join(", ")}`;
              const got = await Promise.all(batch.map((b) => fetchImage(chain, b.page.image, fetchImpl)));
              const ok = batch.filter((_, i) => typeof got[i] !== "string");
              const images = got.filter((g): g is Img => typeof g !== "string");
              const bad = got.filter((g): g is string => typeof g === "string");
              if (bad.length) {
                d.errors.push(`${label}: ${bad.length}× ${bad[0]}`);
                complete = false;
              }
              if (ok.length === 0) return [] as FlyerOffer[];
              // Velké obrázky (COOP, JIP) rozdělit, aby se jedno čtení vešlo do limitu.
              const groups: number[][] = [];
              let size = 0;
              ok.forEach((_, i) => {
                const len = images[i].data.length;
                if (groups.length === 0 || size + len > 7_500_000) {
                  groups.push([]);
                  size = 0;
                }
                groups[groups.length - 1].push(i);
                size += len;
              });
              const found: FlyerOffer[] = [];
              for (const g of groups) {
                const part = g.map((i) => ok[i]);
                const partLabel = `${flyer.title}, str. ${part.map((b) => b.page.n).join(", ")}`;
                const items = [...new Set(part.flatMap((b) => b.items))];
                const r = await ask(d, "leták", partLabel, () =>
                  readFlyerPages(env, flyer, part.map((b) => b.page), g.map((i) => images[i]), items, today, fetchImpl, deadline));
                if (!r) {
                  complete = false;
                  continue;
                }
                d.ai.push(r.diag);
                d.rejected.push(...r.rejected);
                if (r.diag.note) complete = false;
                found.push(...r.offers);
              }
              return found;
            }), 2);

            // Ověření: nejdřív text téže strany, jinak kontrolní čtení strany.
            const offers = results.flat().filter((o) => {
              if (o.valid_to < today) {
                d.rejected.push({ product: o.product, reason: `akce skončila ${o.valid_to}` });
                return false;
              }
              return true;
            });
            const verdicts = new Map<FlyerOffer, Verdict>();
            const byPage = new Map<number, FlyerOffer[]>();
            for (const o of offers) {
              const page = flyer.pages.find((p) => p.n === o.page)!;
              if (verifiedByText(page, o.product, o.price)) {
                verdicts.set(o, { verified: true, method: "leták-text", reason: `cena stojí v textu letáku u názvu zboží (str. ${o.page})` });
              } else {
                byPage.set(o.page, [...(byPage.get(o.page) ?? []), o]);
              }
            }
            await inParallel([...byPage.entries()].map(([n, list]) => async () => {
              const page = flyer.pages.find((p) => p.n === n)!;
              const label = `${flyer.title}, str. ${n}`;
              const fail = (reason: string) => {
                for (const o of list) verdicts.set(o, { verified: false, method: "", reason });
              };
              const img = await fetchImage(chain, page.zoom ?? page.image, fetchImpl);
              if (typeof img === "string") return fail(`kontrolní čtení se nepovedlo (${img})`);
              const asked = list.map((o, i) => ({ id: i + 1, product: o.product, label: o.label ?? "", conditions: o.conditions ?? "" }));
              const prices = await ask(d, "kontrola", label, () => checkFlyerPage(env, flyer, page, img, asked, fetchImpl, deadline));
              if (!prices) {
                complete = false;
                return fail("kontrolní čtení letáku neproběhlo");
              }
              let agreed = 0;
              list.forEach((o, i) => {
                const p = prices.get(i + 1);
                if (typeof p === "number" && Math.abs(p - o.price) < 0.005) {
                  agreed++;
                  verdicts.set(o, { verified: true, method: "leták-2×", reason: `cenu potvrdilo druhé nezávislé čtení letáku (str. ${n})` });
                } else {
                  verdicts.set(o, {
                    verified: false, method: "",
                    reason: typeof p === "number"
                      ? `druhé čtení letáku vyšlo jinak (${String(p).replace(".", ",")} Kč)`
                      : "druhé čtení letáku cenu nenašlo",
                  });
                }
              });
              d.ai.push({ mode: "kontrola", model: env.geminiExtractModel, status: "ok", pages: label, offers: agreed, note: agreed === list.length ? "" : `shoda ${agreed} z ${list.length}` });
            }), 2);
            for (const o of offers) {
              await save(chain, o, o.item, verdicts.get(o) ?? { verified: false, method: "", reason: "neověřeno" }, "gemini", d);
            }
          }

          summary.scanned += todo.length;
          summary.rejected += d.rejected.length;
          for (const e of d.errors) summary.errors.push(`${chain}: ${e}`);
          if (complete && d.errors.length === 0) {
            await db.markScanned(chain, todo.map(([k]) => k), today, summary.provider ?? "web", `ok:${key}`, d.offers.length)
              .catch(() => {});
          }
        }

        if (gemini.usedToday !== startUsage) await db.setUsage("gemini", today, gemini.usedToday).catch(() => {});
        if (!env.geminiKey) summary.errors.push("no_provider");
        return reply(200, summary);
      }

      case "submit": {
        // Nabídka z ChatGPT (přes MCP) nebo ruční: vždy se ověří stránkou.
        const chain = String(payload?.chain ?? "");
        if (!CHAINS[chain]) return reply(400, { error: "Neznámý řetězec." });
        const offers = parseOffers(JSON.stringify([payload?.offer ?? {}]));
        if (offers.length === 0) return reply(400, { error: "Chybí produkt, cena, platnost nebo zdroj." });
        const offer = offers[0];
        const provider = payload?.provider === "chatgpt" ? "chatgpt" : "manual";
        if (offer.valid_to < today) return reply(400, { error: "Akce už skončila." });
        if (!/^https:\/\//.test(offer.source_url)) return reply(400, { error: "Zdroj musí být adresa https://." });
        const verdict = await verifyOffer(chain, offer, null, today, fetchImpl);
        const storeId = offer.store_id && STORES[offer.store_id] === chain ? offer.store_id : null;
        const inserted = await db.insertOffer({
          chain,
          store_id: storeId,
          product: offer.product,
          product_key: productKey(offer.product),
          label: offer.label ?? "",
          price: offer.price,
          pack_qty: offer.pack_qty ?? null,
          pack_unit: offer.pack_unit ?? "",
          regular_price: offer.regular_price ?? null,
          conditions: offer.conditions ?? "",
          valid_from: offer.valid_from ?? null,
          valid_to: offer.valid_to,
          source_url: offer.source_url,
          source_title: verdict.reason,
          provider,
          verified: verdict.verified,
          verify_method: verdict.method,
          verified_at: verdict.verified ? new Date().toISOString() : null,
          created_by: userId,
        });
        return reply(200, { saved: inserted, duplicate: !inserted, ...verdict });
      }

      default:
        return reply(400, { error: "Neznámá akce." });
    }
  } catch (error) {
    console.error("prices:", error);
    return reply(500, { error: "Ceny se nepodařilo zpracovat." });
  }
}

const VERSION = "letaky-2";
const NO_KEY = "chybí klíč Gemini (GEMINI_API_KEY) – leták nemá kdo přečíst";
const NO_TIME = "nestihlo se dočíst všechny strany – spusťte hledání znovu, pokračuje se tam, kde se skončilo";

export function serviceKeyFrom(get: (name: string) => string | undefined): string {
  const legacy = get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const single = get("SUPABASE_SECRET_KEY");
  if (single) return single;
  try {
    const keys = JSON.parse(get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (typeof keys?.default === "string") return keys.default;
    const first = Object.values(keys ?? {}).find((v) => typeof v === "string");
    if (typeof first === "string") return first;
  } catch {
    // není JSON
  }
  return "";
}

export function envFromDeno(get: (name: string) => string | undefined): Env {
  const limit = Number(get("GEMINI_DAILY_LIMIT") ?? "");
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: serviceKeyFrom(get),
    geminiKey: get("GEMINI_API_KEY") ?? "",
    geminiModel: get("GEMINI_MODEL") || "gemini-2.5-flash-lite",
    geminiExtractModel: get("GEMINI_EXTRACT_MODEL") || "gemini-3.5-flash-lite",
    geminiDailyLimit: Number.isFinite(limit) && limit > 0 ? limit : 400,
    openaiKey: get("OPENAI_API_KEY") ?? "",
    openaiModel: get("OPENAI_PRICES_MODEL") || "gpt-5-mini",
    allowPaid: (get("PRICES_ALLOW_PAID") ?? "").toLowerCase() === "true",
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

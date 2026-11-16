// HINKredience° – ceny pro „Nejvýhodnější nákup“ (akce v obchodech v Sušici)
//
// Hledá aktuální akční nabídky pro položky nákupního seznamu a ukládá je do
// tabulky price_offers. Zásady:
// - AI nesmí vymýšlet ceny: nabídka je „ověřená“ jen tehdy, když cenu
//   dokládá OFICIÁLNÍ web řetězce – cena musí stát v textu stažené stránky
//   řetězce hned u názvu produktu (nebo ji dokládá citace vyhledávání Google
//   z oficiálního webu). Ostatní se uloží jako neověřené a aplikace je do
//   porovnání nepočítá.
// - Hlavní zdroj zdarma: server sám stáhne stránky akcí řetězců a Gemini
//   (bezplatná úroveň, bez vyhledávání) z jejich textu jen vypíše nabídky.
//   Vyhledávání Google (grounding) zkusí jen tehdy, když ho klíč zdarma
//   umí (modely 2.5 u starších klíčů) – nové klíče ho zdarma nemají.
// - Šetří bezplatné limity: stejný řetězec + produkt se hledá nejvýš jednou
//   denně (tabulka price_scans), ale jen když hledání proběhlo bez chyby.
//   Pro test lze mezipaměť obejít (force).
// - OpenAI jen když je placené použití výslovně povolené (PRICES_ALLOW_PAID).
// - Klíče AI jsou jen v Secrets serverové funkce, nikdy v aplikaci.
// - Odpověď obsahuje diagnostiku: co se stáhlo, co AI vrátila, co a proč
//   bylo odmítnuto a co se uložilo.
//
// Bez závislostí, aby šla funkce nasadit z editoru v administraci Supabase.

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  geminiKey: string;
  /** Model pro vyhledávání Google (grounding) – zdarma jen řada 2.5. */
  geminiModel: string;
  /** Model pro čtení stažených stránek (bez vyhledávání, zdarma). */
  geminiExtractModel: string;
  geminiDailyLimit: number;
  openaiKey: string;
  openaiModel: string;
  allowPaid: boolean;
  /** Volitelně jiné stránky akcí: {"penny": ["https://…"]}. */
  pages?: Record<string, string[]>;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

// ------------------------------------------------------------ obchody

export const CHAINS: Record<string, { name: string; domains: string[] }> = {
  tesco: { name: "Tesco", domains: ["itesco.cz", "tesco.cz"] },
  penny: { name: "Penny", domains: ["penny.cz"] },
  lidl: { name: "Lidl", domains: ["lidl.cz"] },
  albert: { name: "Albert", domains: ["albert.cz"] },
  jip: { name: "JIP Cash & Carry", domains: ["jip.cz"] },
  coop: { name: "COOP (Západočeské konzumní družstvo Sušice)", domains: ["coop.cz", "skupina.coop"] },
};

/** Výchozí stránky akcí (oficiální weby). Z nich se dohledají i odkazy na akce. */
export const OFFER_PAGES: Record<string, string[]> = {
  tesco: ["https://itesco.cz/akcni-nabidky/"],
  penny: ["https://www.penny.cz/nabidky"],
  lidl: ["https://www.lidl.cz/"],
  albert: ["https://www.albert.cz/"],
  jip: ["https://www.jip.cz/"],
  coop: ["https://www.coop.cz/"],
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

export function isOfficial(chain: string, url: string): boolean {
  let host = "";
  try {
    const u = new URL(url);
    if (u.protocol !== "https:") return false;
    host = u.hostname.toLowerCase();
  } catch {
    // Gemini u citací uvádí jen název webu („penny.cz“).
    host = url.trim().toLowerCase().replace(/^www\./, "");
    if (!/^[a-z0-9.-]+$/.test(host)) return false;
  }
  return (CHAINS[chain]?.domains ?? []).some((d) => host === d || host.endsWith(`.${d}`));
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

// ------------------------------------------------------------ nabídky

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

const UA = "Mozilla/5.0 (compatible; HINKredience-ceny/1.1; kontrola akcni nabidky)";

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

/** Odkazy na akce / letáky ze stejné stránky (nejvýš [max]). */
export function offerLinks(links: string[], max = 3): string[] {
  const good = links.filter((l) => {
    let p = l;
    try {
      p = decodeURI(l);
    } catch {
      // ponechat
    }
    p = fold(p);
    return /akc|nabid|letak|sleva|vyhodn|tyden/.test(p) && !/\.(pdf|jpe?g|png|webp)(\?|$)/.test(p) &&
      !/kariera|prace|recept|kontakt|vernost|cookie|gdpr|pravidla/.test(p);
  });
  return good.slice(0, max);
}

/** Úseky textu kolem zmínek produktů (pro AI), jinak nic. */
export function excerptsFor(text: string, products: string[], maxChars = 14000): { excerpt: string; matched: string[] } {
  const folded = fold(text);
  const parts: [number, number][] = [];
  const matched: string[] = [];
  for (const p of products) {
    const need = matchStems(p).filter((s) => !/^\d/.test(s));
    if (need.length === 0) continue;
    const want = Math.max(1, Math.ceil(need.length * 0.6));
    // začátek nejdelšího slova (kmen se v textu nemusí vyskytovat doslova)
    const words = (fold(p).match(/[a-z]+/g) ?? []).filter((w) => w.length >= 3 && !IGNORE.has(w));
    const anchor = [...words].sort((a, b) => b.length - a.length)[0]?.slice(0, 3) ?? "";
    if (!anchor) continue;
    let found = false;
    let from = 0;
    while (parts.length < 80) {
      const at = folded.indexOf(anchor, from);
      if (at < 0) break;
      from = at + anchor.length;
      const a = Math.max(0, at - 300), b = Math.min(text.length, at + 300);
      if (matchedCount(need, matchStems(text.slice(a, b))) >= want) {
        parts.push([a, b]);
        found = true;
      }
    }
    if (found) matched.push(p);
  }
  parts.sort((x, y) => x[0] - y[0]);
  const merged: [number, number][] = [];
  for (const r of parts) {
    const last = merged[merged.length - 1];
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
    else merged.push([...r]);
  }
  let excerpt = merged.map(([a, b]) => text.slice(a, b)).join("\n…\n");
  if (excerpt.length > maxChars) excerpt = excerpt.slice(0, maxChars);
  return { excerpt, matched };
}

/** Zmínky o platnosti letáku („platí od … do …“) pro AI. */
export function validityHints(text: string): string {
  const out: string[] = [];
  for (const m of text.matchAll(/(?:platn|plati|od\s+\S+\s+\d{1,2}\.)[^.]{0,20}?\d{1,2}\.\s?\d{1,2}\.(?:\s?\d{4})?[^.]{0,40}?\d{1,2}\.\s?\d{1,2}\.(?:\s?\d{4})?/gi)) {
    if (!out.includes(m[0])) out.push(m[0]);
    if (out.length >= 5) break;
  }
  return out.join(" | ");
}

// ------------------------------------------------------------ poskytovatelé AI

export interface AiDiag {
  mode: "stránka" | "vyhledávání";
  model: string;
  status: "ok" | "chyba";
  error?: string;
  code?: string;
  queries?: number;
  sources?: string[];
  offers?: number;
  note?: string;
}

export interface ProviderResult {
  offers: RawOffer[];
  rejected: Rejected[];
  evidence: Evidence;
  diag: AiDiag;
}

export class AiError extends Error {
  constructor(public code: string, message: string, public status = 0) {
    super(message);
  }
}

/** Srozumitelný důvod chyby Gemini (bez klíče a bez dlouhých odpovědí). */
export function geminiError(status: number, body: string, model: string): AiError {
  let msg = "";
  try {
    msg = String(JSON.parse(body)?.error?.message ?? "");
  } catch {
    msg = body;
  }
  msg = msg.replace(/AIza[0-9A-Za-z_-]+/g, "…").slice(0, 220);
  const low = msg.toLowerCase();
  if (status === 404 || /no longer available|not found|is not supported/.test(low)) {
    return new AiError("model_unavailable", `model ${model} není pro tento klíč dostupný: ${msg}`, status);
  }
  if (status === 429) {
    return new AiError(
      /search|grounding/.test(low) ? "search_not_free" : "quota",
      `vyčerpaný bezplatný limit nebo funkce není zdarma (${model}): ${msg}`,
      status,
    );
  }
  if (status === 400 && /api key|api_key/.test(low)) return new AiError("bad_key", `klíč Gemini je neplatný: ${msg}`, status);
  if (status === 403) return new AiError("forbidden", `klíč nemá přístup (${model}): ${msg}`, status);
  if (status === 400 && /search|grounding|tool/.test(low)) {
    return new AiError("search_not_free", `vyhledávání Google není pro ${model} dostupné: ${msg}`, status);
  }
  return new AiError("error", `Gemini ${status} (${model}): ${msg}`, status);
}

export function promptFor(chain: string, products: string[], today: string): string {
  const c = CHAINS[chain];
  return [
    `Dnes je ${today}. Najdi AKTUÁLNĚ PLATNÉ akční nabídky řetězce ${c.name} v České republice`,
    `(leták platný i pro prodejny v Sušici) pro tyto produkty: ${products.join(", ")}.`,
    `Používej jen oficiální web řetězce (${c.domains.join(", ")}). Nic nevymýšlej:`,
    "když cenu ve zdroji nenajdeš, produkt vynech. Cena musí být přesně jako ve zdroji.",
    "Odpověz POUZE polem JSON, každá nabídka jako objekt:",
    '{"product": "název produktu ve zdroji", "label": "značka a gramáž", "price": 39.9,',
    '"pack_qty": 250, "pack_unit": "g", "regular_price": 54.9, "conditions": "např. s aplikací",',
    '"valid_from": "YYYY-MM-DD", "valid_to": "YYYY-MM-DD", "source_url": "https://…"}',
    "Když nic nenajdeš, odpověz [].",
  ].join(" ");
}

export function extractPrompt(chain: string, products: string[], today: string, url: string, excerpt: string, validity: string): string {
  const c = CHAINS[chain];
  return [
    `Dnes je ${today}. Níže je text z oficiální stránky řetězce ${c.name} (${url}).`,
    `Vypiš z něj akční nabídky, které odpovídají těmto položkám nákupu: ${products.join(", ")}.`,
    "Používej VÝHRADNĚ údaje doslova uvedené v textu. Nic nedoplňuj ani neodhaduj.",
    "Cena musí být přesně jako v textu (bez Kč). U cen s věrnostní kartou/aplikací vrať cenu bez karty",
    "a podmínku dej do conditions, nebo dvě nabídky. Platnost převeď na YYYY-MM-DD (rok doplň podle dneška);",
    "když platnost u produktu chybí, použij platnost letáku z textu. Když produkt v textu není, vynech ho.",
    "Odpověz POUZE polem JSON: [{\"product\": \"název v textu\", \"label\": \"značka a gramáž\", \"price\": 39.9,",
    "\"pack_qty\": 250, \"pack_unit\": \"g\", \"regular_price\": 54.9, \"conditions\": \"\",",
    "\"valid_from\": \"YYYY-MM-DD\", \"valid_to\": \"YYYY-MM-DD\"}]. Když nic, odpověz [].",
    validity ? `Platnost letáku podle stránky: ${validity}` : "",
    "TEXT STRÁNKY:",
    excerpt,
  ].filter(Boolean).join("\n");
}

async function callGemini(env: Env, model: string, body: unknown, fetchImpl: FetchLike): Promise<any> {
  let res: Response;
  try {
    res = await fetchImpl(
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": env.geminiKey },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(45000),
      },
    );
  } catch (e) {
    throw new AiError("network", `Gemini nedostupné (${(e as Error).name})`);
  }
  if (!res.ok) throw geminiError(res.status, await res.text().catch(() => ""), model);
  return await res.json();
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

/** Vyhledávání Google (grounding) – zdarma jen u modelů 2.5 a jen u starších klíčů. */
export async function askGemini(env: Env, prompt: string, fetchImpl: FetchLike): Promise<ProviderResult> {
  const body = await callGemini(env, env.geminiModel, {
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    tools: [{ google_search: {} }],
    generationConfig: { temperature: 0 },
  }, fetchImpl);
  const { text, finish } = candidateText(body);
  const meta = body?.candidates?.[0]?.groundingMetadata ?? {};
  const chunks: { url: string; title: string }[] = (meta.groundingChunks ?? []).map((c: any) => ({
    url: String(c?.web?.uri ?? ""),
    title: String(c?.web?.title ?? ""),
  }));
  const supports = (meta.groundingSupports ?? []).map((s: any) => ({
    text: String(s?.segment?.text ?? ""),
    sources: (s?.groundingChunkIndices ?? [])
      .map((i: number) => chunks[i])
      .filter(Boolean)
      .flatMap((c: { url: string; title: string }) => [c.title, c.url]),
  }));
  const parsed = parseOffersDetailed(text);
  const queries = (meta.webSearchQueries ?? []).length;
  return {
    offers: parsed.offers,
    rejected: parsed.rejected,
    evidence: { supports, sources: chunks },
    diag: {
      mode: "vyhledávání",
      model: env.geminiModel,
      status: "ok",
      queries,
      sources: [...new Set(chunks.map((c) => c.title || hostOf(c.url)))].slice(0, 10),
      offers: parsed.offers.length,
      note: [
        queries === 0 ? "Google nic nehledal (bez groundingu)" : "",
        parsed.note,
        finish && finish !== "STOP" ? `konec: ${finish}` : "",
      ].filter(Boolean).join("; "),
    },
  };
}

/** Čtení stažené stránky (bez vyhledávání): AI jen vypíše, co v textu je. */
export async function extractFromPage(
  env: Env,
  prompt: string,
  pageUrl: string,
  fetchImpl: FetchLike,
): Promise<ProviderResult> {
  const body = await callGemini(env, env.geminiExtractModel, {
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    generationConfig: { temperature: 0, responseMimeType: "application/json" },
  }, fetchImpl);
  const { text, finish } = candidateText(body);
  const parsed = parseOffersDetailed(text, pageUrl);
  // Zdrojem je vždy stažená stránka, ne to, co napíše model.
  for (const o of parsed.offers) o.source_url = pageUrl;
  return {
    offers: parsed.offers,
    rejected: parsed.rejected,
    evidence: { supports: [], sources: [] },
    diag: {
      mode: "stránka",
      model: env.geminiExtractModel,
      status: "ok",
      offers: parsed.offers.length,
      note: [parsed.note, finish && finish !== "STOP" ? `konec: ${finish}` : ""].filter(Boolean).join("; "),
    },
  };
}

export async function askOpenAI(
  env: Env,
  prompt: string,
  fetchImpl: FetchLike,
): Promise<ProviderResult> {
  const res = await fetchImpl("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.openaiKey}` },
    body: JSON.stringify({ model: env.openaiModel, tools: [{ type: "web_search" }], input: prompt }),
  });
  if (!res.ok) throw new AiError("error", `OpenAI ${res.status}`, res.status);
  const body = await res.json();
  let text = "";
  const supports: { text: string; sources: string[] }[] = [];
  const sources: { url: string; title: string }[] = [];
  for (const item of body?.output ?? []) {
    if (item?.type !== "message") continue;
    for (const part of item?.content ?? []) {
      if (part?.type !== "output_text") continue;
      const t = String(part.text ?? "");
      for (const a of part.annotations ?? []) {
        if (a?.type !== "url_citation") continue;
        const url = String(a.url ?? "");
        sources.push({ url, title: String(a.title ?? "") });
        const from = Math.max(0, Number(a.start_index ?? 0) - 200);
        const to = Math.min(t.length, Number(a.end_index ?? 0) + 50);
        supports.push({ text: t.slice(from, to), sources: [url] });
      }
      text += t;
    }
  }
  const parsed = parseOffersDetailed(text);
  return {
    offers: parsed.offers,
    rejected: parsed.rejected,
    evidence: { supports, sources },
    diag: {
      mode: "vyhledávání",
      model: env.openaiModel,
      status: "ok",
      sources: [...new Set(sources.map((s) => hostOf(s.url)))].slice(0, 10),
      offers: parsed.offers.length,
      note: parsed.note,
    },
  };
}

// ------------------------------------------------------------ databáze

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

  async scannedToday(chain: string, keys: string[], today: string): Promise<Set<string>> {
    if (keys.length === 0) return new Set();
    const list = keys.map((k) => `"${k.replace(/"/g, "")}"`).join(",");
    const rows = await this.rest(
      `price_scans?select=product_key&chain=eq.${chain}&scanned_on=eq.${today}&product_key=in.(${encodeURIComponent(list)})`,
    );
    return new Set((rows ?? []).map((r: any) => r.product_key));
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

function addDays(day: string, days: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export interface OfferDiag {
  product: string;
  price: number;
  valid_to: string;
  source: string;
  verified: boolean;
  reason: string;
  saved: "uloženo" | "už uloženo";
}

export interface ChainDiag {
  chain: string;
  name: string;
  cached: boolean;
  pages: { url: string; status: number; chars: number; matched: string[]; note: string }[];
  ai: AiDiag[];
  offers: OfferDiag[];
  rejected: Rejected[];
  errors: string[];
}

function pagesFor(env: Env, chain: string): string[] {
  const own = env.pages?.[chain];
  const list = Array.isArray(own) && own.length ? own : OFFER_PAGES[chain] ?? [];
  return list.filter((u) => typeof u === "string" && isOfficial(chain, u)).slice(0, 4);
}

/** Stáhne stránky akcí řetězce (výchozí + odkazy na akce z nich). */
async function loadPages(env: Env, chain: string, fetchImpl: FetchLike): Promise<Page[]> {
  const start = pagesFor(env, chain);
  const first = await Promise.all(start.map((u) => fetchPage(chain, u, fetchImpl)));
  const seen = new Set([...start, ...first.map((p) => p.url)]);
  const more = offerLinks(first.flatMap((p) => p.links)).filter((u) => !seen.has(u)).slice(0, 3);
  const second = await Promise.all(more.map((u) => fetchPage(chain, u, fetchImpl)));
  return [...first, ...second];
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

  try {
    switch (payload?.action) {
      case "status": {
        const providers = await providerStatus(env, db, today);
        return reply(200, { providers, chosen: chooseProvider(providers)?.id ?? null });
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
        if (products.length === 0) {
          return reply(200, { scanned: 0, cached: 0, found: 0, verified: 0, unverified: 0, saved: 0, duplicates: 0, rejected: 0, errors: [], diag: [] });
        }
        const chainIds: string[] = Array.isArray(payload?.chains)
          ? payload.chains.filter((c: unknown) => typeof c === "string" && CHAINS[c as string])
          : Object.keys(CHAINS);

        const providers = await providerStatus(env, db, today);
        const gemini = providers[0];
        const startUsage = { gemini: providers[0].usedToday, openai: providers[1].usedToday };
        const summary = {
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
          diag: [] as ChainDiag[],
        };
        // Vyhledávání Google: po první „není zdarma / model nedostupný“ už nezkoušet.
        let searchOff = "";

        const canAsk = (p: ProviderStatus) =>
          p.configured && p.allowed && (p.limit === null || p.usedToday < p.limit);

        if (!chooseProvider(providers) && !gemini.configured) {
          summary.errors.push("no_provider");
          return reply(200, summary);
        }

        // Stránky všech řetězců najednou (zdarma, bez AI).
        const todoByChain = new Map<string, [string, string][]>();
        for (const chain of chainIds) {
          const keys = new Map(products.map((p) => [productKey(p), p]));
          const done = force ? new Set<string>() : await db.scannedToday(chain, [...keys.keys()], today);
          const todo = [...keys.entries()].filter(([k]) => !done.has(k));
          summary.cached += keys.size - todo.length;
          todoByChain.set(chain, todo);
        }
        const pagesByChain = new Map<string, Page[]>();
        await Promise.all(chainIds.map(async (chain) => {
          if ((todoByChain.get(chain) ?? []).length === 0) return;
          pagesByChain.set(chain, await loadPages(env, chain, fetchImpl).catch(() => []));
        }));

        const save = async (chain: string, offer: RawOffer, verdict: Verdict, provider: string, d: ChainDiag) => {
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
            price: offer.price,
            valid_to: offer.valid_to,
            source: hostOf(offer.source_url),
            verified: verdict.verified,
            reason: verdict.reason,
            saved: inserted ? "uloženo" : "už uloženo",
          });
          if (inserted) summary.saved++;
          else summary.duplicates++;
          if (verdict.verified) summary.verified++;
          else summary.unverified++;
        };

        const accept = (offer: RawOffer, d: ChainDiag): boolean => {
          if (offer.valid_to < today) {
            d.rejected.push({ product: offer.product, reason: `akce skončila ${offer.valid_to}` });
            return false;
          }
          if (offer.valid_to > addDays(today, 31)) {
            d.rejected.push({ product: offer.product, reason: `nepravděpodobná platnost do ${offer.valid_to}` });
            return false;
          }
          return true;
        };

        for (const chain of chainIds) {
          const todo = todoByChain.get(chain) ?? [];
          const d: ChainDiag = {
            chain, name: CHAINS[chain].name, cached: todo.length === 0,
            pages: [], ai: [], offers: [], rejected: [], errors: [],
          };
          summary.diag.push(d);
          if (todo.length === 0) continue;
          const names = todo.map(([, p]) => p);
          let complete = true; // vše proběhlo bez chyby → smí do mezipaměti
          let found = 0;

          // 1) Oficiální stránky řetězce + Gemini jen čte text (zdarma).
          const pages = pagesByChain.get(chain) ?? [];
          let pageOk = false;
          for (const page of pages) {
            const { excerpt, matched } = page.text ? excerptsFor(page.text, names) : { excerpt: "", matched: [] };
            d.pages.push({ url: page.url, status: page.status, chars: page.text.length, matched, note: page.note });
            if (page.text) pageOk = true;
            if (!excerpt) continue;
            if (!gemini.configured) {
              d.errors.push("chybí klíč Gemini – stránku nemá kdo přečíst");
              complete = false;
              break;
            }
            if (!canAsk(gemini)) {
              d.errors.push("denní limit Gemini vyčerpán");
              complete = false;
              break;
            }
            gemini.usedToday++;
            summary.provider = "gemini";
            try {
              const prompt = extractPrompt(chain, matched, today, page.url, excerpt, validityHints(page.text));
              const r = await extractFromPage(env, prompt, page.url, fetchImpl);
              d.ai.push(r.diag);
              d.rejected.push(...r.rejected);
              for (const offer of r.offers) {
                found++;
                if (!accept(offer, d)) continue;
                const verdict = await verifyOffer(chain, offer, null, today, fetchImpl, page.text);
                await save(chain, offer, verdict, "gemini", d);
              }
            } catch (e) {
              const err = e as AiError;
              d.ai.push({ mode: "stránka", model: env.geminiExtractModel, status: "chyba", code: err.code, error: err.message });
              d.errors.push(err.message);
              complete = false;
            }
          }
          if (pages.length > 0 && !pageOk) d.errors.push("žádnou stránku akcí řetězce se nepodařilo stáhnout");

          // 2) Vyhledávání Google – jen když ze stránek nic není a klíč ho zdarma umí.
          if (found === 0) {
            const provider = chooseProvider(providers);
            const useSearch = provider && (provider.id === "openai" || !searchOff);
            if (!provider) {
              if (!gemini.configured) summary.errors.push("no_provider");
              complete = false;
            } else if (useSearch) {
              provider.usedToday++;
              summary.provider = summary.provider ?? provider.id;
              try {
                const prompt = promptFor(chain, names, today);
                const r = provider.id === "gemini"
                  ? await askGemini(env, prompt, fetchImpl)
                  : await askOpenAI(env, prompt, fetchImpl);
                d.ai.push(r.diag);
                d.rejected.push(...r.rejected);
                for (const offer of r.offers) {
                  found++;
                  if (!accept(offer, d)) continue;
                  const verdict = await verifyOffer(chain, offer, r.evidence, today, fetchImpl);
                  await save(chain, offer, verdict, provider.id, d);
                }
              } catch (e) {
                const err = e as AiError;
                d.ai.push({
                  mode: "vyhledávání",
                  model: provider.id === "gemini" ? env.geminiModel : env.openaiModel,
                  status: "chyba",
                  code: err.code,
                  error: err.message,
                });
                if (provider.id === "gemini" && ["model_unavailable", "search_not_free", "quota", "forbidden", "bad_key"].includes(err.code)) {
                  searchOff = err.code;
                }
                // Selhání vyhledávání nevadí, pokud stránky proběhly v pořádku.
                if (!pageOk) {
                  d.errors.push(err.message);
                  complete = false;
                }
              }
            } else {
              d.ai.push({ mode: "vyhledávání", model: env.geminiModel, status: "chyba", code: searchOff, error: "přeskočeno – vyhledávání Google není pro tento klíč zdarma dostupné" });
              if (!pageOk) complete = false;
            }
          }

          summary.found += found;
          summary.scanned += todo.length;
          summary.rejected += d.rejected.length;
          for (const e of d.errors) summary.errors.push(`${chain}: ${e}`);
          if (complete) {
            await db.markScanned(chain, todo.map(([k]) => k), today, summary.provider ?? "", "ok", found)
              .catch(() => {});
          }
        }

        if (gemini.usedToday !== startUsage.gemini) await db.setUsage("gemini", today, gemini.usedToday).catch(() => {});
        if (providers[1].usedToday !== startUsage.openai) {
          await db.setUsage("openai", today, providers[1].usedToday).catch(() => {});
        }
        if (searchOff) summary.errors.push(`search:${searchOff}`);
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
  let pages: Record<string, string[]> | undefined;
  try {
    const p = JSON.parse(get("PRICES_PAGES") ?? "");
    if (p && typeof p === "object") pages = p;
  } catch {
    // výchozí stránky
  }
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: serviceKeyFrom(get),
    geminiKey: get("GEMINI_API_KEY") ?? "",
    // Vyhledávání Google je zdarma (500 dotazů/den) jen u modelů 2.5;
    // nové klíče k nim Google nepouští – pak se použijí jen stránky.
    geminiModel: get("GEMINI_MODEL") || "gemini-2.5-flash-lite",
    geminiExtractModel: get("GEMINI_EXTRACT_MODEL") || "gemini-3.5-flash-lite",
    geminiDailyLimit: Number.isFinite(limit) && limit > 0 ? limit : 400,
    openaiKey: get("OPENAI_API_KEY") ?? "",
    openaiModel: get("OPENAI_PRICES_MODEL") || "gpt-5-mini",
    allowPaid: (get("PRICES_ALLOW_PAID") ?? "").toLowerCase() === "true",
    pages,
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

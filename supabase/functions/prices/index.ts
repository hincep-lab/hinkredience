// HINKredience° – ceny pro „Nejvýhodnější nákup“ (akce v obchodech v Sušici)
//
// Hledá aktuální akční nabídky pro položky nákupního seznamu a ukládá je do
// tabulky price_offers. Zásady:
// - AI nesmí vymýšlet ceny: nabídka je „ověřená“ jen tehdy, když cenu
//   dokládá zdroj z OFICIÁLNÍHO webu řetězce (citace vyhledávání Google
//   u Gemini / OpenAI, nebo přímo text stažené stránky). Ostatní se uloží
//   jako neověřené a aplikace je do porovnání nepočítá.
// - Šetří bezplatné limity: stejný řetězec + produkt se hledá nejvýš jednou
//   denně (tabulka price_scans), sdíleně pro všechny.
// - Poskytovatelé: Google Gemini (bezplatná úroveň, vyhledávání Google
//   zdarma do 500 dotazů denně u modelů 2.5), OpenAI jen když je placené
//   použití výslovně povolené (PRICES_ALLOW_PAID=true). Výchozí stav: zdarma.
// - Klíče AI jsou jen v Secrets serverové funkce, nikdy v aplikaci.
//
// Bez závislostí, aby šla funkce nasadit z editoru v administraci Supabase.

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  geminiKey: string;
  geminiModel: string;
  geminiDailyLimit: number;
  openaiKey: string;
  openaiModel: string;
  allowPaid: boolean;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

// ------------------------------------------------------------ obchody

export const CHAINS: Record<string, { name: string; domains: string[] }> = {
  tesco: { name: "Tesco", domains: ["itesco.cz", "tesco.cz"] },
  penny: { name: "Penny", domains: ["penny.cz"] },
  lidl: { name: "Lidl", domains: ["lidl.cz"] },
  albert: { name: "Albert", domains: ["albert.cz"] },
  jip: { name: "JIP Cash & Carry", domains: ["jip.cz"] },
  coop: { name: "COOP (Západočeské konzumní družstvo Sušice)", domains: ["coop.cz"] },
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
    const n = Number(value.replace(/\s/g, "").replace(",", "."));
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function isoDay(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const m = value.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

/** Vytáhne pole JSON z odpovědi modelu (i v bloku ```json). */
export function parseOffers(text: string): RawOffer[] {
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start < 0 || end <= start) return [];
  let data: unknown;
  try {
    data = JSON.parse(text.slice(start, end + 1));
  } catch {
    return [];
  }
  if (!Array.isArray(data)) return [];
  const out: RawOffer[] = [];
  for (const o of data.slice(0, 60)) {
    if (!o || typeof o !== "object") continue;
    const product = typeof o.product === "string" ? o.product.trim().slice(0, 160) : "";
    const price = num(o.price);
    const validTo = isoDay(o.valid_to);
    const url = typeof o.source_url === "string" ? o.source_url.trim() : "";
    if (!product || price === null || !validTo || !url) continue;
    out.push({
      product,
      label: typeof o.label === "string" ? o.label.slice(0, 200) : "",
      price,
      pack_qty: num(o.pack_qty),
      pack_unit: typeof o.pack_unit === "string" ? o.pack_unit.slice(0, 20) : "",
      regular_price: num(o.regular_price),
      conditions: typeof o.conditions === "string" ? o.conditions.slice(0, 200) : "",
      valid_from: isoDay(o.valid_from),
      valid_to: validTo,
      source_url: url,
      store_id: typeof o.store_id === "string" ? o.store_id : null,
    });
  }
  return out;
}

/** Je v textu uvedená cena (39,90 / 39.9 / 39,- …)? */
export function mentionsPrice(text: string, price: number): boolean {
  for (const m of text.matchAll(/\d{1,5}(?:[.,]\d{1,2})?/g)) {
    const n = Number(m[0].replace(",", "."));
    if (Math.abs(n - price) < 0.005) return true;
  }
  return false;
}

/** Text HTML stránky bez značek. */
export function pageText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;|&#160;/g, " ")
    .replace(/\s+/g, " ");
}

export type Verdict = { verified: boolean; method: string; reason: string };

/**
 * Ověření jedné nabídky. Pořadí: platnost a oficiální zdroj → citace
 * poskytovatele (úsek s cenou podložený oficiálním webem) → text stránky.
 */
export async function verifyOffer(
  chain: string,
  offer: RawOffer,
  evidence: Evidence | null,
  today: string,
  fetchImpl: FetchLike,
): Promise<Verdict> {
  if (offer.price <= 0 || offer.price >= 100000) {
    return { verified: false, method: "", reason: "nesmyslná cena" };
  }
  if (offer.valid_to < today) return { verified: false, method: "", reason: "akce už skončila" };
  if (!isOfficial(chain, offer.source_url)) {
    return { verified: false, method: "", reason: "zdroj není oficiální web řetězce" };
  }
  if (evidence) {
    for (const s of evidence.supports) {
      if (!mentionsPrice(s.text, offer.price)) continue;
      if (s.sources.some((src) => isOfficial(chain, src))) {
        return { verified: true, method: "citace", reason: "cenu dokládá citace oficiálního webu" };
      }
    }
  }
  // Text oficiální stránky musí obsahovat cenu i produkt.
  try {
    const res = await fetchImpl(offer.source_url, {
      headers: { "User-Agent": "HINKredience-ceny/1.0 (+kontrola akcni nabidky)" },
      redirect: "follow",
      signal: AbortSignal.timeout(8000),
    });
    if (res.ok && isOfficial(chain, res.url || offer.source_url)) {
      const html = (await res.text()).slice(0, 3_000_000);
      const text = pageText(html);
      const key = productKey(offer.product).split(" ").filter(Boolean);
      const folded = fold(text);
      const hasProduct = key.length > 0 && key.some((k) => folded.includes(k));
      if (hasProduct && mentionsPrice(text, offer.price)) {
        return { verified: true, method: "stránka", reason: "cena je na oficiální stránce" };
      }
      return { verified: false, method: "", reason: "cenu se na stránce nepodařilo najít" };
    }
  } catch {
    // stránka nejde stáhnout
  }
  return { verified: false, method: "", reason: "zdroj se nepodařilo ověřit" };
}

// ------------------------------------------------------------ poskytovatelé AI

export interface ProviderResult {
  offers: RawOffer[];
  evidence: Evidence;
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

export async function askGemini(
  env: Env,
  prompt: string,
  fetchImpl: FetchLike,
): Promise<ProviderResult> {
  const res = await fetchImpl(
    `https://generativelanguage.googleapis.com/v1beta/models/${env.geminiModel}:generateContent`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": env.geminiKey },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        tools: [{ google_search: {} }],
        generationConfig: { temperature: 0 },
      }),
    },
  );
  if (!res.ok) throw new Error(`Gemini ${res.status}`);
  const body = await res.json();
  const cand = body?.candidates?.[0] ?? {};
  const text = (cand?.content?.parts ?? []).map((p: any) => p?.text ?? "").join("");
  const meta = cand?.groundingMetadata ?? {};
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
  return { offers: parseOffers(text), evidence: { supports, sources: chunks } };
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
  if (!res.ok) throw new Error(`OpenAI ${res.status}`);
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
        // Citovaný úsek + kousek okolí (cena bývá těsně před citací).
        const from = Math.max(0, Number(a.start_index ?? 0) - 200);
        const to = Math.min(t.length, Number(a.end_index ?? 0) + 50);
        supports.push({ text: t.slice(from, to), sources: [url] });
      }
      text += t;
    }
  }
  return { offers: parseOffers(text), evidence: { supports, sources } };
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

  async addUsage(provider: string, today: string, current: number) {
    await this.rest("price_ai_usage?on_conflict=provider,day", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({ provider, day: today, requests: current + 1 }),
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
        if (products.length === 0) return reply(200, { scanned: 0, cached: 0, found: 0, verified: 0 });
        const chainIds: string[] = Array.isArray(payload?.chains)
          ? payload.chains.filter((c: unknown) => typeof c === "string" && CHAINS[c as string])
          : Object.keys(CHAINS);

        const providers = await providerStatus(env, db, today);
        const summary = {
          provider: null as string | null,
          scanned: 0,
          cached: 0,
          found: 0,
          verified: 0,
          unverified: 0,
          errors: [] as string[],
        };
        for (const chain of chainIds) {
          const keys = new Map(products.map((p) => [productKey(p), p]));
          const done = await db.scannedToday(chain, [...keys.keys()], today);
          const todo = [...keys.entries()].filter(([k]) => !done.has(k));
          summary.cached += keys.size - todo.length;
          if (todo.length === 0) continue;

          const provider = chooseProvider(providers);
          if (!provider) {
            summary.errors.push("no_provider");
            break;
          }
          summary.provider = provider.id;
          let result: ProviderResult;
          try {
            const prompt = promptFor(chain, todo.map(([, p]) => p), today);
            result = provider.id === "gemini"
              ? await askGemini(env, prompt, fetchImpl)
              : await askOpenAI(env, prompt, fetchImpl);
          } catch (e) {
            summary.errors.push(`${chain}: ${(e as Error).message}`);
            continue;
          } finally {
            await db.addUsage(provider.id, today, provider.usedToday).catch(() => {});
            provider.usedToday++;
          }
          summary.scanned += todo.length;
          let found = 0;
          for (const offer of result.offers) {
            if (offer.valid_to > addDays(today, 31)) continue; // nepravděpodobně dlouhá akce
            const verdict = await verifyOffer(chain, offer, result.evidence, today, fetchImpl);
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
              source_url: /^https:\/\//.test(offer.source_url)
                ? offer.source_url
                : `https://${CHAINS[chain].domains[0]}/`,
              source_title: verdict.reason,
              provider: provider.id,
              verified: verdict.verified,
              verify_method: verdict.method,
              verified_at: verdict.verified ? new Date().toISOString() : null,
              created_by: userId,
            });
            if (!inserted) continue;
            found++;
            if (verdict.verified) summary.verified++;
            else summary.unverified++;
          }
          summary.found += found;
          await db.markScanned(chain, todo.map(([k]) => k), today, provider.id, "ok", found);
        }
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
        const verdict = await verifyOffer(chain, offer, null, today, fetchImpl);
        if (offer.valid_to < today) return reply(400, { error: "Akce už skončila." });
        if (!/^https:\/\//.test(offer.source_url)) return reply(400, { error: "Zdroj musí být adresa https://." });
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
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: serviceKeyFrom(get),
    geminiKey: get("GEMINI_API_KEY") ?? "",
    // Vyhledávání Google je zdarma (500 dotazů/den) jen u modelů 2.5.
    geminiModel: get("GEMINI_MODEL") || "gemini-2.5-flash-lite",
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

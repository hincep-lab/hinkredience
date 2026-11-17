// „Vymyslet recept z akcí“: z ověřených akcí v Sušici (tabulka price_offers)
// nechá Gemini v bezplatném tarifu navrhnout recepty. Každá surovina, která
// se odvolává na akci, musí ukazovat na skutečnou uloženou akci – jinak se
// odkaz zahodí, takže aplikace nikdy neukáže vymyšlenou cenu.
//
// Zdarma: jen bezplatný Gemini, sdílený denní limit s hledáním v letácích
// (price_ai_usage, provider "gemini"). Placené API se nepoužívá.

export const VERSION = "napady-1";

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  geminiKey: string;
  model: string;
  dailyLimit: number;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export const CATEGORIES = [
  "Maso", "Drůbež", "Ryby", "Polévky", "Omáčky", "Přílohy", "Pečení",
  "Dezerty", "Těsta", "Pizza", "Gril", "Zavařování",
];

const CHAIN_NAMES: Record<string, string> = {
  tesco: "Tesco", penny: "Penny", lidl: "Lidl", albert: "Albert", jip: "JIP", coop: "COOP",
};

export interface Offer {
  id: string;
  chain: string;
  product: string;
  price: number;
  regular_price: number | null;
  pack_qty: number | null;
  pack_unit: string;
  conditions: string;
  valid_to: string;
}

export function pragueToday(now = new Date()): string {
  return new Intl.DateTimeFormat("sv-SE", { timeZone: "Europe/Prague" }).format(now);
}

const num = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
};
const str = (v: unknown, max: number): string => (typeof v === "string" ? v.trim().slice(0, max) : "");

/** Z každého produktu jen nejlevnější akce; nejvýš [limit] položek. */
export function pickOffers(rows: any[], limit = 80): Offer[] {
  const best = new Map<string, Offer>();
  for (const r of rows ?? []) {
    const price = num(r?.price);
    const product = str(r?.product, 120);
    if (price === null || price <= 0 || !product) continue;
    const o: Offer = {
      id: String(r.id),
      chain: str(r.chain, 20),
      product,
      price,
      regular_price: num(r.regular_price),
      pack_qty: num(r.pack_qty),
      pack_unit: str(r.pack_unit, 20),
      conditions: str(r.conditions, 120),
      valid_to: str(r.valid_to, 10),
    };
    const key = `${o.chain}|${product.toLowerCase()}`;
    const prev = best.get(key);
    if (!prev || o.price < prev.price) best.set(key, o);
  }
  return [...best.values()].slice(0, limit);
}

export function offerLine(o: Offer, index: number): string {
  const pack = o.pack_qty ? ` ${String(o.pack_qty).replace(".", ",")} ${o.pack_unit}` : "";
  const reg = o.regular_price && o.regular_price > o.price ? ` (běžně ${o.regular_price} Kč)` : "";
  const cond = o.conditions ? ` [${o.conditions}]` : "";
  return `A${index + 1}: ${o.product}${pack} – ${o.price} Kč${reg}, ${CHAIN_NAMES[o.chain] ?? o.chain}${cond}`;
}

export function buildPrompt(offers: Offer[], count: number, wish: string, avoid: string[]): string {
  return [
    "Jsi zkušený český domácí kuchař. Navrhni recepty pro 4 osoby, které využijí suroviny,",
    "které jsou tento týden v akci v obchodech v Sušici. Seznam akcí:",
    ...offers.map(offerLine),
    "",
    `Navrhni ${count} různé recepty. Pravidla:`,
    "- Každý recept musí stavět hlavně na surovinách z akcí (ideálně maso nebo hlavní surovina z akce).",
    "- U suroviny, která odpovídá akci, vyplň offer jejím kódem (např. A3). U ostatních surovin offer nech prázdné.",
    "- Nevymýšlej ceny ani obchody, ty doplní aplikace.",
    "- Běžná česká domácí kuchyně, suroviny dostupné v Sušici, realistická množství v g, ml, ks, lžíce, lžička.",
    "- Postup v krocích, česky, s časy a teplotami tam, kde jsou potřeba.",
    `- Kategorie jedna z: ${CATEGORIES.join(", ")}.`,
    ...(wish ? [`- Přání uživatele: ${wish}`] : []),
    ...(avoid.length ? [`- Tyto recepty už znám, navrhni jiné: ${avoid.join("; ")}`] : []),
  ].join("\n");
}

export const RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    recipes: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          title: { type: "STRING" },
          description: { type: "STRING" },
          category: { type: "STRING" },
          minutes: { type: "INTEGER" },
          temperature_c: { type: "INTEGER" },
          ingredients: {
            type: "ARRAY",
            items: {
              type: "OBJECT",
              properties: {
                name: { type: "STRING" },
                quantity: { type: "NUMBER" },
                unit: { type: "STRING" },
                offer: { type: "STRING" },
              },
              required: ["name"],
            },
          },
          steps: { type: "ARRAY", items: { type: "STRING" } },
        },
        required: ["title", "ingredients", "steps"],
      },
    },
  },
  required: ["recipes"],
};

export interface IdeaIngredient {
  name: string;
  quantity: number | null;
  unit: string;
  offer: Offer | null;
}

export interface Idea {
  title: string;
  description: string;
  category: string;
  servings: number;
  minutes: number;
  temperature_c: number | null;
  ingredients: IdeaIngredient[];
  steps: string[];
}

/** Ověří a očistí odpověď modelu; recept bez jediné skutečné akce se zahodí. */
export function parseIdeas(text: string, offers: Offer[]): { ideas: Idea[]; rejected: string[] } {
  const rejected: string[] = [];
  let body: any;
  try {
    body = JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, ""));
  } catch {
    return { ideas: [], rejected: ["odpověď nebyla platný JSON"] };
  }
  const ideas: Idea[] = [];
  for (const r of Array.isArray(body?.recipes) ? body.recipes.slice(0, 6) : []) {
    const title = str(r?.title, 100);
    const steps = (Array.isArray(r?.steps) ? r.steps : [])
      .map((s: unknown) => str(s, 600))
      .filter(Boolean)
      .slice(0, 20);
    const ingredients: IdeaIngredient[] = [];
    for (const i of Array.isArray(r?.ingredients) ? r.ingredients.slice(0, 25) : []) {
      const name = str(i?.name, 100);
      if (!name) continue;
      const code = str(i?.offer, 10).toUpperCase().match(/^A(\d+)$/);
      const offer = code ? offers[Number(code[1]) - 1] ?? null : null;
      const quantity = num(i?.quantity);
      ingredients.push({
        name,
        quantity: quantity !== null && quantity > 0 && quantity < 100000 ? quantity : null,
        unit: str(i?.unit, 20),
        offer,
      });
    }
    if (!title) {
      rejected.push("recept bez názvu");
      continue;
    }
    if (ingredients.length < 3 || steps.length < 2) {
      rejected.push(`${title}: málo surovin nebo kroků`);
      continue;
    }
    if (!ingredients.some((i) => i.offer)) {
      rejected.push(`${title}: nevyužívá žádnou akci`);
      continue;
    }
    const category = str(r?.category, 30);
    const minutes = num(r?.minutes);
    const temp = num(r?.temperature_c);
    ideas.push({
      title,
      description: str(r?.description, 300),
      category: CATEGORIES.includes(category) ? category : "",
      servings: 4,
      minutes: minutes !== null && minutes > 0 && minutes < 1440 ? Math.round(minutes) : 0,
      temperature_c: temp !== null && temp >= 50 && temp <= 300 ? Math.round(temp) : null,
      ingredients,
      steps,
    });
  }
  return { ideas, rejected };
}

function geminiProblem(status: number, body: string): string {
  let msg = body;
  try {
    msg = String(JSON.parse(body)?.error?.message ?? body);
  } catch { /* text */ }
  msg = msg.replace(/AIza[0-9A-Za-z_-]+/g, "…").slice(0, 200);
  if (status === 429) return "Bezplatný limit Gemini je pro dnešek vyčerpaný. Zkuste to zítra.";
  if (status === 404) return `Model Gemini není dostupný: ${msg}`;
  if (status === 400 && /api key/i.test(msg)) return "Klíč Gemini je neplatný.";
  if (status >= 500) return "Gemini je teď přetížené, zkuste to za chvíli.";
  return `Gemini ${status}: ${msg}`;
}

class Db {
  constructor(private env: Env, private fetchImpl: FetchLike) {}

  async userId(token: string): Promise<string | null> {
    const res = await this.fetchImpl(`${this.env.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: this.env.anonKey, Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    const body = await res.json();
    return typeof body?.id === "string" ? body.id : null;
  }

  async rest(path: string, init: RequestInit = {}): Promise<any> {
    const key = this.env.serviceKey;
    const res = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      ...init,
      headers: {
        apikey: key,
        ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}),
        "Content-Type": "application/json",
        ...(init.headers as Record<string, string> ?? {}),
      },
    });
    if (!res.ok) throw new Error(`Databáze ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const t = await res.text();
    return t ? JSON.parse(t) : null;
  }

  async offers(today: string): Promise<any[]> {
    return await this.rest(
      `price_offers?select=id,chain,product,price,regular_price,pack_qty,pack_unit,conditions,valid_to` +
        `&verified=is.true&valid_to=gte.${today}&order=price.asc&limit=300`,
    ) ?? [];
  }

  async usage(today: string): Promise<number> {
    const rows = await this.rest(`price_ai_usage?select=requests&provider=eq.gemini&day=eq.${today}`);
    return Number(rows?.[0]?.requests ?? 0);
  }

  async setUsage(today: string, requests: number) {
    await this.rest("price_ai_usage?on_conflict=provider,day", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({ provider: "gemini", day: today, requests }),
    });
  }
}

const ALLOWED_ORIGINS = ["https://hincep-lab.github.io", "http://localhost"];

function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const ok = ALLOWED_ORIGINS.some((o) => origin === o || origin.startsWith(`${o}:`));
  return {
    "Access-Control-Allow-Origin": ok ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
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
  const base = { version: VERSION, model: env.model, configured: !!env.geminiKey };

  try {
    const offers = pickOffers(await db.offers(today));
    if (payload?.action === "status") {
      return reply(200, { ...base, offers: offers.length, used: await db.usage(today), limit: env.dailyLimit });
    }
    if (payload?.action !== "suggest") return reply(400, { error: "Neznámá akce." });
    if (!env.geminiKey) return reply(200, { ...base, ideas: [], error: "Gemini není na serveru nastavené." });
    if (offers.length === 0) {
      return reply(200, { ...base, ideas: [], error: "Nejsou uložené žádné platné ověřené akce. Nejdřív klepněte na Najít akce." });
    }
    const used = await db.usage(today);
    if (used >= env.dailyLimit) {
      return reply(200, { ...base, ideas: [], error: `Dnešní bezplatný limit (${env.dailyLimit} dotazů) je vyčerpaný. Zkuste to zítra.` });
    }
    const count = Math.min(Math.max(Number(payload?.count) || 3, 1), 5);
    const wish = str(payload?.wish, 200);
    const avoid = (Array.isArray(payload?.avoid) ? payload.avoid : [])
      .map((t: unknown) => str(t, 100))
      .filter(Boolean)
      .slice(0, 30);

    await db.setUsage(today, used + 1);
    let res: Response;
    try {
      res = await fetchImpl(
        `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(env.model)}:generateContent`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-goog-api-key": env.geminiKey },
          body: JSON.stringify({
            contents: [{ role: "user", parts: [{ text: buildPrompt(offers, count, wish, avoid) }] }],
            generationConfig: {
              temperature: 0.9,
              responseMimeType: "application/json",
              responseSchema: RESPONSE_SCHEMA,
            },
          }),
          signal: AbortSignal.timeout(90000),
        },
      );
    } catch (e) {
      return reply(200, { ...base, ideas: [], error: `Gemini je nedostupné (${(e as Error).name}).` });
    }
    if (!res.ok) {
      return reply(200, { ...base, ideas: [], error: geminiProblem(res.status, await res.text().catch(() => "")) });
    }
    const body = await res.json();
    const text = (body?.candidates?.[0]?.content?.parts ?? [])
      .filter((p: any) => !p?.thought)
      .map((p: any) => p?.text ?? "")
      .join("");
    const { ideas, rejected } = parseIdeas(text, offers);
    return reply(200, {
      ...base,
      ideas,
      rejected,
      offers: offers.length,
      error: ideas.length ? "" : "Gemini nenavrhlo žádný použitelný recept. Zkuste to znovu.",
    });
  } catch (e) {
    return reply(500, { ...base, ideas: [], error: `Chyba serveru: ${(e as Error).message}` });
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
  } catch { /* nic */ }
  return "";
}

export function envFromDeno(get: (name: string) => string | undefined): Env {
  const limit = Number(get("GEMINI_DAILY_LIMIT") ?? "");
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: serviceKeyFrom(get),
    geminiKey: get("GEMINI_API_KEY") ?? "",
    model: get("GEMINI_IDEAS_MODEL") || get("GEMINI_EXTRACT_MODEL") || "gemini-3.5-flash-lite",
    dailyLimit: Number.isFinite(limit) && limit > 0 ? limit : 400,
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

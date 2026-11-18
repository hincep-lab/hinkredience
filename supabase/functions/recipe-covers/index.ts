// HINKredience° – automatické hlavní fotografie receptů.
//
// Recepty bez fotky dostanou realistickou fotografii hotového jídla
// (OpenAI Images API). Bezpečnost a náklady:
//  * Spustí se jen s tajným klíčem plánované úlohy (x-cron-key), který je
//    uložený v databázi a nikdy ji neopustí. Přihlášení uživatelé ani
//    veřejnost funkci nespustí.
//  * Placené generování běží, jen když je v databázi zapnuté
//    (recipe_cover_settings.enabled) A funkce má vlastní klíč
//    COVERS_OPENAI_API_KEY. Bez kteréhokoli z nich nic nezaplatí.
//  * Denní limit, měsíční rozpočet a ochranu proti dvojímu účtování hlídá
//    databáze (cover_reserve) – ne tento kód.
//  * Fotka se přiřadí jen receptu, který žádnou nemá (cover_attach_if_empty);
//    existující fotky ani soubory se nikdy nemažou ani nepřepisují
//    (nahrání s x-upsert: false, žádné DELETE).
//  * Servisní klíč projektu zůstává v Supabase (proměnné funkce); funkce
//    s ním volá jen čtyři úzké databázové funkce a nahrání souboru.

export const VERSION = "2026-11-18";
export const BUCKET = "recipe-photos";
export const MAX_PER_RUN = 5;
const MAX_IMAGE_BYTES = 8_000_000;

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface Env {
  supabaseUrl: string;
  serviceKey: string;
  openaiKey: string;
  /** Pevná adresa projektu – servisní klíč se jinam nepošle. */
  expectedHost: string;
  cronKey?: string;
}

export interface Settings {
  model: string;
  quality: string;
  size: string;
}

export interface Job {
  job_id: string | null;
  recipe_id: string;
  owner_id: string;
  photo_id: string | null;
  path: string;
  status: string;
  title: string;
  description: string;
  category: string;
  tags: string[];
  ingredients: { name: string }[];
  steps: string[];
  reason: string;
}

export interface RunResult {
  recipe_id: string;
  title: string;
  status: "attached" | "skipped" | "failed" | "dry-run";
  error?: string;
}

class HttpError extends Error {
  constructor(message: string, readonly status: number, readonly charged = false) {
    super(message);
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ------------------------------------------------------------------ zadání

const PREP_HINTS: Record<string, string> = {
  "Trouba": "oven-baked",
  "Pánev": "pan-cooked",
  "Hrnec": "simmered in a pot",
  "Gril": "grilled",
  "Sous-vide": "cooked sous-vide and seared",
  "Pomalé vaření": "slow-cooked, tender",
  "Vaflovač": "made in a waffle iron",
  "Bez vaření": "fresh, no-cook",
  "Bez pečení": "no-bake",
};

function clean(value: unknown, max: number): string {
  return String(value ?? "")
    .replace(/[\u0000-\u001f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);
}

/**
 * Zadání obrázku: jedno konkrétní hotové jídlo podle názvu, popisu,
 * hlavních surovin a způsobu přípravy. Bez textu, koláží a lidí.
 */
export function buildPrompt(job: Pick<Job, "title" | "description" | "category" | "tags" | "ingredients">): string {
  const title = clean(job.title, 160);
  const description = clean(job.description, 300);
  const ingredients = (Array.isArray(job.ingredients) ? job.ingredients : [])
    .map((i) => clean(i?.name, 50))
    .filter((n) => n && !/^(sůl|pepř|voda|olej|sůl a pepř)\b/i.test(n))
    .slice(0, 12);
  const methods = (Array.isArray(job.tags) ? job.tags : [])
    .map((t) => PREP_HINTS[String(t)])
    .filter(Boolean);
  const cuisine = (Array.isArray(job.tags) ? job.tags : [])
    .map(String)
    .find((t) => /kuchyně$/i.test(t));
  return [
    `Professional, photorealistic food photograph of one finished dish: "${title}".`,
    description ? `Dish description (Czech): ${description}` : "",
    job.category ? `Category: ${clean(job.category, 60)}.` : "",
    cuisine ? `Cuisine: ${clean(cuisine, 40)}.` : "",
    methods.length ? `Preparation: ${methods.join(", ")}.` : "",
    ingredients.length ? `Visible main ingredients must match: ${ingredients.join(", ")}.` : "",
    "Show exactly one plated serving as it really looks when cooked at home by a good cook, " +
    "realistic portion and textures, appetizing, natural soft daylight, shallow depth of field, " +
    "slightly elevated 45-degree angle, the dish centered with some space around it so it can be cropped " +
    "to a square or a wide banner. Simple neutral table and plate.",
    "Strictly: a single photo, no collage, no split image, no text, no letters, no labels, no logos, " +
    "no watermark, no people, no hands, no packaging.",
  ].filter(Boolean).join("\n");
}

// ---------------------------------------------------------------- Supabase

export class Db {
  constructor(private env: Env, private fetchImpl: FetchLike) {}

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    const key = this.env.serviceKey;
    return {
      apikey: key,
      // Starší klíč (JWT) i jako Bearer; nový sb_secret_ jen v apikey.
      ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}),
      ...extra,
    };
  }

  private async call(path: string, init: RequestInit): Promise<Response> {
    return await this.fetchImpl(`${this.env.supabaseUrl}${path}`, init);
  }

  async rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const res = await this.call(`/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: this.headers({ "Content-Type": "application/json" }),
      body: JSON.stringify(args),
    });
    if (!res.ok) throw new HttpError(`Databáze ${name}: HTTP ${res.status}`, res.status);
    const text = await res.text();
    return (text ? JSON.parse(text) : null) as T;
  }

  async cronKey(): Promise<string> {
    const res = await this.call(`/rest/v1/price_cron_key?select=key&id=eq.1`, { headers: this.headers() });
    if (!res.ok) return "";
    const rows = await res.json().catch(() => []);
    return Array.isArray(rows) && typeof rows[0]?.key === "string" ? rows[0].key : "";
  }

  async settings(): Promise<Settings> {
    const res = await this.call(`/rest/v1/recipe_cover_settings?select=model,quality,size&id=eq.1`, {
      headers: this.headers(),
    });
    if (!res.ok) throw new HttpError(`Nastavení: HTTP ${res.status}`, res.status);
    const rows = await res.json();
    const s = Array.isArray(rows) ? rows[0] : null;
    return {
      model: typeof s?.model === "string" ? s.model : "gpt-image-2",
      quality: s?.quality === "low" ? "low" : "medium",
      size: typeof s?.size === "string" ? s.size : "1536x1024",
    };
  }

  /** Nahraje soubor; existující soubor NEPŘEPÍŠE (x-upsert: false). */
  async upload(path: string, bytes: Uint8Array): Promise<"created" | "exists"> {
    const res = await this.call(`/storage/v1/object/${BUCKET}/${encodePath(path)}`, {
      method: "POST",
      headers: this.headers({
        "Content-Type": "image/jpeg",
        "x-upsert": "false",
        "cache-control": "max-age=31536000",
      }),
      body: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
    });
    if (res.ok) return "created";
    // Soubor už existuje (opakování po přerušení) – nic se nepřepisuje.
    const body = await res.text().catch(() => "");
    if (res.status === 409 || /already exists|Duplicate/i.test(body)) return "exists";
    throw new HttpError(`Úložiště: HTTP ${res.status}`, res.status);
  }

  /** Existuje soubor v úložišti a má rozumnou velikost? */
  async exists(path: string): Promise<boolean> {
    const res = await this.call(`/storage/v1/object/info/${BUCKET}/${encodePath(path)}`, {
      headers: this.headers(),
    });
    if (!res.ok) return false;
    const info = await res.json().catch(() => null);
    const size = Number(info?.size ?? info?.metadata?.size ?? 1);
    return size > 1000;
  }

  /** Ověří, že recept má opravdu uloženou právě tuto fotku jako hlavní. */
  async coverIs(recipeId: string, photoId: string): Promise<boolean> {
    const res = await this.call(
      `/rest/v1/recipes?select=photos&id=eq.${encodeURIComponent(recipeId)}&deleted_at=is.null`,
      { headers: this.headers() },
    );
    if (!res.ok) return false;
    const rows = await res.json().catch(() => []);
    const photos = Array.isArray(rows) ? rows[0]?.photos : null;
    return Array.isArray(photos) && photos[0]?.id === photoId;
  }
}

function encodePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

/** Cesta souboru musí být přesně <vlastník>/<recept>/<fotka>.jpg. */
export function validPath(job: Pick<Job, "owner_id" | "recipe_id" | "photo_id" | "path">): boolean {
  return Boolean(
    job.photo_id && UUID.test(job.owner_id) && UUID.test(job.recipe_id) && UUID.test(job.photo_id) &&
      job.path === `${job.owner_id}/${job.recipe_id}/${job.photo_id}.jpg`,
  );
}

// ------------------------------------------------------------------ OpenAI

/** Vygeneruje JPEG. Chyba s `charged` = obrázek mohl být vyúčtován. */
export async function generateImage(
  prompt: string,
  settings: Settings,
  key: string,
  fetchImpl: FetchLike,
): Promise<Uint8Array> {
  let res: Response;
  try {
    res = await fetchImpl("https://api.openai.com/v1/images/generations", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: settings.model,
        prompt,
        n: 1,
        size: settings.size,
        quality: settings.quality,
        output_format: "jpeg",
        output_compression: 82,
        moderation: "auto",
      }),
      signal: AbortSignal.timeout(170_000),
    });
  } catch (error) {
    // Přerušené spojení: požadavek mohl doběhnout a být vyúčtován.
    throw new HttpError(`OpenAI: spojení přerušeno (${(error as Error).name})`, 0, true);
  }
  if (!res.ok) {
    // Odmítnutý požadavek (4xx/5xx) OpenAI neúčtuje.
    let detail = "";
    try {
      const body = await res.json();
      detail = clean(body?.error?.code ?? body?.error?.type ?? "", 60);
    } catch {
      // bez detailu
    }
    throw new HttpError(`OpenAI: HTTP ${res.status}${detail ? ` (${detail})` : ""}`, res.status, false);
  }
  const body = await res.json().catch(() => null);
  const b64 = body?.data?.[0]?.b64_json;
  if (typeof b64 !== "string" || !b64) throw new HttpError("OpenAI: odpověď bez obrázku", 200, true);
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const jpeg = bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (!jpeg || bytes.length < 5_000 || bytes.length > MAX_IMAGE_BYTES) {
    throw new HttpError("OpenAI: obrázek není platný JPEG", 200, true);
  }
  return bytes;
}

// -------------------------------------------------------------------- běh

/**
 * Jeden běh: rezervace v databázi (limity), generování, nahrání, přiřazení
 * jen k receptu bez fotky, ověření a zápis výsledku.
 */
export async function run(
  env: Env,
  options: { limit: number; dryRun: boolean },
  fetchImpl: FetchLike,
): Promise<{ results: RunResult[]; usage: unknown }> {
  const db = new Db(env, fetchImpl);
  const limit = Math.max(1, Math.min(MAX_PER_RUN, Math.floor(options.limit) || 1));
  const results: RunResult[] = [];

  if (options.dryRun) {
    const jobs = await db.rpc<Job[]>("cover_reserve", { p_limit: limit, p_dry_run: true });
    for (const j of jobs ?? []) {
      results.push({ recipe_id: j.recipe_id, title: j.title, status: "dry-run" });
    }
    return { results, usage: await db.rpc("cover_usage", {}) };
  }

  // Bez klíče se nic nerezervuje (a tedy ani nezaplatí).
  if (!env.openaiKey) {
    return { results, usage: { error: "Chybí COVERS_OPENAI_API_KEY – generování je vypnuté." } };
  }
  const settings = await db.settings();
  const jobs = await db.rpc<Job[]>("cover_reserve", { p_limit: limit, p_dry_run: false });

  for (const job of jobs ?? []) {
    const id = job.job_id;
    if (!id || !validPath(job)) {
      results.push({ recipe_id: job.recipe_id, title: job.title, status: "failed", error: "Neplatná úloha" });
      continue;
    }
    try {
      // Dokončení přerušené úlohy: obrázek už je zaplacený.
      if (job.status === "generated" || job.status === "uploaded") {
        if (!(await db.exists(job.path))) {
          await db.rpc("cover_progress", { p_job: id, p_status: "failed", p_error: "Soubor se nenašel" });
          results.push({ recipe_id: job.recipe_id, title: job.title, status: "failed", error: "Soubor se nenašel" });
          continue;
        }
        await db.rpc("cover_progress", { p_job: id, p_status: "uploaded" });
      } else {
        const prompt = buildPrompt(job);
        let image: Uint8Array;
        try {
          image = await generateImage(prompt, settings, env.openaiKey, fetchImpl);
        } catch (error) {
          const e = error as HttpError;
          // Neúčtovaná chyba: útrata 0 a recept to zkusí jindy (nejvýš 2×).
          await db.rpc("cover_progress", {
            p_job: id,
            p_status: "failed",
            p_error: e.message,
            p_cost: e.charged ? null : 0,
          });
          results.push({ recipe_id: job.recipe_id, title: job.title, status: "failed", error: e.message });
          continue;
        }
        // Cesta se zapíše před nahráním – po přerušení se úloha dokončí.
        await db.rpc("cover_progress", { p_job: id, p_status: "generated", p_path: job.path });
        await db.upload(job.path, image);
        await db.rpc("cover_progress", { p_job: id, p_status: "uploaded" });
      }
      const attached = await db.rpc<boolean>("cover_attach_if_empty", { p_job: id });
      if (!attached) {
        results.push({
          recipe_id: job.recipe_id,
          title: job.title,
          status: "skipped",
          error: "Recept mezitím dostal fotku – nic se nepřepsalo.",
        });
        continue;
      }
      const ok = (await db.coverIs(job.recipe_id, job.photo_id!)) && (await db.exists(job.path));
      results.push(
        ok
          ? { recipe_id: job.recipe_id, title: job.title, status: "attached" }
          : { recipe_id: job.recipe_id, title: job.title, status: "failed", error: "Uložení se nepodařilo ověřit" },
      );
    } catch (error) {
      const message = (error as Error).message;
      // Stav úlohy zůstane (generated/uploaded) a další běh ji dokončí.
      await db.rpc("cover_progress", { p_job: id, p_status: "generated", p_error: message })
        .catch(() => undefined);
      results.push({ recipe_id: job.recipe_id, title: job.title, status: "failed", error: message });
    }
  }
  return { results, usage: await db.rpc("cover_usage", {}) };
}

// ------------------------------------------------------------------- HTTP

export function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length || b.length < 24) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function handle(req: Request, env: Env, fetchImpl: FetchLike = fetch): Promise<Response> {
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return reply(405, { error: "Jen POST." });
  let host = "";
  try {
    const u = new URL(env.supabaseUrl);
    host = u.protocol === "https:" && !u.port && (u.pathname === "/" || u.pathname === "") ? u.hostname : "";
  } catch {
    host = "";
  }
  if (!env.serviceKey || !host || host !== env.expectedHost) {
    return reply(503, { error: "Funkce není nastavená." });
  }
  const db = new Db(env, fetchImpl);
  const header = req.headers.get("x-cron-key") ?? "";
  const expected = env.cronKey || await db.cronKey().catch(() => "");
  if (!sameSecret(header, expected)) return reply(401, { error: "Neoprávněno." });

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return reply(400, { error: "Neplatný požadavek." });
  }
  const action = payload?.action;
  if (action !== "run" && action !== "dry-run") return reply(400, { error: "Neznámá akce." });
  try {
    const out = await run(env, { limit: Number(payload?.limit) || 1, dryRun: action === "dry-run" }, fetchImpl);
    console.log(JSON.stringify({ covers: out.results.map((r) => ({ r: r.recipe_id, s: r.status, e: r.error })) }));
    return reply(200, { version: VERSION, ...out });
  } catch (error) {
    console.error("recipe-covers:", (error as Error).message);
    return reply(500, { error: (error as Error).message });
  }
}

function serviceKeyFrom(get: (name: string) => string | undefined): string {
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
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    serviceKey: serviceKeyFrom(get),
    // Vlastní klíč jen pro fotky (s rozpočtovým limitem v OpenAI) – záměrně
    // se nepoužije obecný OPENAI_API_KEY, aby nic nezaplatilo omylem.
    openaiKey: get("COVERS_OPENAI_API_KEY") ?? "",
    expectedHost: "wjqpzoeheonjwdyyezhb.supabase.co",
    cronKey: "",
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

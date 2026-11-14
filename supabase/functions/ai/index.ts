// HINKredience° – serverová funkce „ai“ (Etapa 2)
//
// Jediná funkce obsluhuje AI kuchaře, vyhledávání receptů na internetu,
// vylepšování a import receptů. Klíč k OpenAI žije jen tady (tajemství
// funkce OPENAI_API_KEY), v mobilní aplikaci žádný tajný klíč není.
//
// Bez závislostí: Supabase i OpenAI se volají přes fetch, k databázi se
// přistupuje s tokenem přihlášeného uživatele, takže platí Row Level Security.
//
// Konfigurace (Edge Functions → Secrets):
//   OPENAI_API_KEY        povinné
//   OPENAI_MODEL          model pro chat a úpravy receptů (výchozí níže)
//   OPENAI_SEARCH_MODEL   model pro vyhledávání na internetu
//   AI_DAILY_LIMIT        max. počet požadavků na AI za den a uživatele
//   AI_SEARCH_DAILY_LIMIT max. počet vyhledávání na internetu za den

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  openaiKey: string;
  model: string;
  searchModel: string;
  dailyLimit: number;
  searchDailyLimit: number;
}

export type FetchLike = (
  input: string,
  init?: RequestInit,
) => Promise<Response>;

export const DEFAULT_MODEL = "gpt-6.1-terra";
export const DEFAULT_DAILY_LIMIT = 80;
export const DEFAULT_SEARCH_DAILY_LIMIT = 25;

const MAX_MESSAGE_CHARS = 6000;
const MAX_IMAGE_BASE64_CHARS = 6_000_000; // ~4,5 MB obrázek
const MAX_IMPORT_TEXT_CHARS = 30_000;
const MAX_PAGE_BYTES = 1_500_000;
const HISTORY_MESSAGES = 16;

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

// ------------------------------------------------------------------ schémata

const nullableNumber = { type: ["number", "null"] };
const nullableInteger = { type: ["integer", "null"] };

export const recipeSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "title",
    "description",
    "category",
    "servings",
    "prep_minutes",
    "cook_minutes",
    "temperatures",
    "equipment",
    "notes",
    "ingredients",
    "steps",
  ],
  properties: {
    title: { type: "string" },
    description: { type: "string" },
    category: {
      type: "string",
      description:
        "Jedna z: Maso, Drůbež, Ryby, Polévky, Omáčky, Přílohy, Pečení, Dezerty, Těsta, Pizza, Gril, Zavařování – nebo jiná výstižná.",
    },
    servings: { type: "number" },
    prep_minutes: { type: "integer" },
    cook_minutes: { type: "integer" },
    temperatures: {
      type: "array",
      items: { type: "string" },
      description: "Např. „Trouba 160 °C“, „Střed masa 58 °C“.",
    },
    equipment: { type: "array", items: { type: "string" } },
    notes: { type: "string" },
    ingredients: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["name", "quantity", "unit", "note"],
        properties: {
          name: { type: "string" },
          quantity: nullableNumber,
          unit: {
            type: "string",
            description: "g, kg, ml, l, ks, lžíce, lžička, špetka… nebo prázdné.",
          },
          note: { type: "string" },
        },
      },
    },
    steps: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["instruction", "duration_minutes", "temperature_c"],
        properties: {
          instruction: { type: "string" },
          duration_minutes: nullableInteger,
          temperature_c: nullableNumber,
        },
      },
    },
  },
};

const nullableRecipe = { anyOf: [recipeSchema, { type: "null" }] };

const chatSchema = {
  type: "object",
  additionalProperties: false,
  required: ["reply", "recipe", "change_summary"],
  properties: {
    reply: {
      type: "string",
      description: "Odpověď uživateli česky, prostý text bez markdownu.",
    },
    recipe: nullableRecipe,
    change_summary: {
      type: "string",
      description:
        "Když recipe upravuje přiložený recept: stručně co a proč se změnilo. Jinak prázdné.",
    },
  },
};

const searchSchema = {
  type: "object",
  additionalProperties: false,
  required: ["results", "comparison"],
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: [
          "title",
          "url",
          "site",
          "summary",
          "ingredients",
          "method",
          "temperatures",
          "total_minutes",
          "rating",
          "rating_count",
        ],
        properties: {
          title: { type: "string" },
          url: { type: "string", description: "Přesná adresa stránky s receptem." },
          site: { type: "string" },
          summary: { type: "string", description: "1–2 věty vlastními slovy." },
          ingredients: {
            type: "array",
            items: { type: "string" },
            description: "Hlavní suroviny s množstvím, pokud je stránka uvádí.",
          },
          method: {
            type: "string",
            description: "Shrnutí postupu vlastními slovy, bez doslovného opisu.",
          },
          temperatures: { type: "array", items: { type: "string" } },
          total_minutes: nullableInteger,
          rating: {
            ...nullableNumber,
            description: "Hodnocení ze stránky (0–5). Null, když ho stránka neuvádí.",
          },
          rating_count: nullableInteger,
        },
      },
    },
    comparison: {
      type: "object",
      additionalProperties: false,
      required: ["ingredients", "method", "temperatures_times", "ratings"],
      properties: {
        ingredients: { type: "string" },
        method: { type: "string" },
        temperatures_times: { type: "string" },
        ratings: { type: "string" },
      },
    },
  },
};

const improveSchema = {
  type: "object",
  additionalProperties: false,
  required: ["summary", "changes", "recipe"],
  properties: {
    summary: { type: "string" },
    changes: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["what", "why"],
        properties: { what: { type: "string" }, why: { type: "string" } },
      },
    },
    recipe: recipeSchema,
  },
};

const draftSchema = {
  type: "object",
  additionalProperties: false,
  required: ["found", "message", "recipe"],
  properties: {
    found: {
      type: "boolean",
      description: "False, když podklad žádný recept neobsahuje.",
    },
    message: { type: "string" },
    recipe: nullableRecipe,
  },
};

// ------------------------------------------------------------------ pomocné

export function clampText(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed;
}

/** Sjednotí adresu pro porovnání: bez schématu, www, parametrů a lomítka. */
export function normalizeUrl(raw: string): string {
  try {
    const url = new URL(raw.trim());
    const host = url.hostname.toLowerCase().replace(/^www\./, "");
    let path = decodeURIComponent(url.pathname).replace(/\/+$/, "");
    path = path.toLowerCase();
    return `${host}${path}`;
  } catch {
    return "";
  }
}

export function isHttpUrl(raw: string): boolean {
  try {
    const url = new URL(raw);
    return url.protocol === "https:" || url.protocol === "http:";
  } catch {
    return false;
  }
}

/** Odmítne adresy do vnitřních sítí, aby import nešel zneužít. */
export function isPublicHost(raw: string): boolean {
  let host: string;
  try {
    host = new URL(raw).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (host.startsWith("[")) return false; // IPv6 literály nepovolujeme
  if (host === "localhost" || host.endsWith(".localhost")) return false;
  if (host.endsWith(".local") || host.endsWith(".internal")) return false;
  if (!host.includes(".")) return false;
  const ip = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ip) {
    const a = Number(ip[1]);
    const b = Number(ip[2]);
    if (a === 10 || a === 127 || a === 0 || a >= 224) return false;
    if (a === 169 && b === 254) return false;
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 168) return false;
    if (a === 100 && b >= 64 && b <= 127) return false;
  }
  return true;
}

/** Vytáhne ze stránky čitelný text a strukturovaná data receptu (JSON-LD). */
export function extractPageText(html: string, max = MAX_IMPORT_TEXT_CHARS): string {
  const parts: string[] = [];
  const ldPattern =
    /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  for (const match of html.matchAll(ldPattern)) {
    const block = match[1].trim();
    if (/"@type"\s*:\s*(\[[^\]]*)?"Recipe"/i.test(block)) {
      parts.push(`STRUKTUROVANÁ DATA RECEPTU:\n${block.slice(0, 12_000)}`);
    }
  }
  const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (title) parts.push(`TITULEK: ${decodeEntities(title[1]).trim()}`);
  const text = decodeEntities(
    html
      .replace(/<(script|style|noscript|svg|nav|footer|header|form)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<!--[\s\S]*?-->/g, " ")
      .replace(/<(br|\/p|\/div|\/li|\/h[1-6]|\/tr)[^>]*>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/[ \t\r\f\v]+/g, " ")
    .replace(/\n\s*\n+/g, "\n")
    .trim();
  parts.push(`TEXT STRÁNKY:\n${text}`);
  const joined = parts.join("\n\n");
  return joined.length > max ? joined.slice(0, max) : joined;
}

function decodeEntities(text: string): string {
  const named: Record<string, string> = {
    amp: "&",
    lt: "<",
    gt: ">",
    quot: '"',
    apos: "'",
    nbsp: " ",
    deg: "°",
    frac12: "½",
    frac14: "¼",
    frac34: "¾",
  };
  return text
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&([a-z0-9]+);/gi, (whole, name) => named[name.toLowerCase()] ?? whole);
}

interface Source {
  url: string;
  title: string;
}

/** Zdroje, které vyhledávání skutečně otevřelo nebo citovalo. */
export function collectSources(response: any): Source[] {
  const found = new Map<string, Source>();
  const add = (url: unknown, title: unknown) => {
    if (typeof url !== "string" || !isHttpUrl(url)) return;
    const key = normalizeUrl(url);
    if (!key || found.has(key)) return;
    found.set(key, { url, title: typeof title === "string" ? title : "" });
  };
  for (const item of response?.output ?? []) {
    if (item?.type === "web_search_call") {
      for (const source of item.action?.sources ?? []) add(source?.url, source?.title);
      if (item.action?.url) add(item.action.url, "");
    }
    if (item?.type === "message") {
      for (const part of item.content ?? []) {
        for (const note of part?.annotations ?? []) {
          if (note?.type === "url_citation") add(note.url, note.title);
        }
      }
    }
  }
  return [...found.values()];
}

/** Text odpovědi modelu; vyhodí chybu při odmítnutí nebo useknutí. */
export function outputText(response: any): string {
  if (response?.status === "incomplete") {
    throw new ApiError(502, "ai_incomplete", "Odpověď AI byla příliš dlouhá a nedokončila se. Zkuste dotaz zúžit.");
  }
  let text = "";
  for (const item of response?.output ?? []) {
    if (item?.type !== "message") continue;
    for (const part of item.content ?? []) {
      if (part?.type === "refusal") {
        throw new ApiError(422, "ai_refused", "AI na tento požadavek odmítla odpovědět.");
      }
      if (part?.type === "output_text" && typeof part.text === "string") {
        text += part.text;
      }
    }
  }
  if (!text) throw new ApiError(502, "ai_empty", "AI nevrátila žádnou odpověď.");
  return text;
}

function parseJson(text: string): any {
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError(502, "ai_invalid", "AI vrátila odpověď v neplatném tvaru.");
  }
}

/** Ověří a očistí recept od modelu. Vrací null, když je nepoužitelný. */
export function sanitizeRecipe(raw: any): Record<string, unknown> | null {
  if (!raw || typeof raw !== "object") return null;
  const title = clampText(raw.title, 200);
  if (!title) return null;
  const number = (value: unknown, fallback: number, min: number, max: number) => {
    const n = typeof value === "number" && Number.isFinite(value) ? value : fallback;
    return Math.min(max, Math.max(min, n));
  };
  const strings = (value: unknown, max: number) =>
    Array.isArray(value)
      ? value.map((v) => clampText(v, 200)).filter((v) => v).slice(0, max)
      : [];
  const ingredients = (Array.isArray(raw.ingredients) ? raw.ingredients : [])
    .map((item: any) => ({
      name: clampText(item?.name, 200),
      quantity:
        typeof item?.quantity === "number" && Number.isFinite(item.quantity) && item.quantity > 0
          ? item.quantity
          : null,
      unit: clampText(item?.unit, 40),
      note: clampText(item?.note, 300),
    }))
    .filter((item: { name: string }) => item.name)
    .slice(0, 80);
  const steps = (Array.isArray(raw.steps) ? raw.steps : [])
    .map((step: any) => ({
      instruction: clampText(step?.instruction, 2000),
      duration_minutes:
        typeof step?.duration_minutes === "number" && step.duration_minutes > 0
          ? Math.round(step.duration_minutes)
          : null,
      temperature_c:
        typeof step?.temperature_c === "number" && step.temperature_c > -50 && step.temperature_c < 600
          ? step.temperature_c
          : null,
    }))
    .filter((step: { instruction: string }) => step.instruction)
    .slice(0, 60);
  return {
    title,
    description: clampText(raw.description, 1000),
    category: clampText(raw.category, 60),
    servings: number(raw.servings, 4, 0.5, 100),
    prep_minutes: Math.round(number(raw.prep_minutes, 0, 0, 100_000)),
    cook_minutes: Math.round(number(raw.cook_minutes, 0, 0, 100_000)),
    temperatures: strings(raw.temperatures, 20),
    equipment: strings(raw.equipment, 20),
    notes: clampText(raw.notes, 4000),
    ingredients,
    steps,
  };
}

/** Zkrácená podoba receptu z aplikace pro model (bez fotek a interních polí). */
export function compactRecipe(raw: any): Record<string, unknown> | null {
  const recipe = sanitizeRecipe(raw);
  if (!recipe) return null;
  return {
    ...recipe,
    rating: typeof raw.rating === "number" ? raw.rating : null,
  };
}

// ---------------------------------------------------------------- Supabase

class Supabase {
  constructor(
    private env: Env,
    private token: string,
    private fetchImpl: FetchLike,
  ) {}

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    return {
      apikey: this.env.anonKey,
      Authorization: `Bearer ${this.token}`,
      "Content-Type": "application/json",
      ...extra,
    };
  }

  async user(): Promise<{ id: string }> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/auth/v1/user`, {
      headers: this.headers(),
    });
    if (!response.ok) {
      throw new ApiError(401, "unauthorized", "Přihlášení vypršelo. Přihlaste se znovu.");
    }
    const body = await response.json();
    if (!body?.id) throw new ApiError(401, "unauthorized", "Přihlášení vypršelo. Přihlaste se znovu.");
    return { id: body.id };
  }

  async select(path: string): Promise<any[]> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      headers: this.headers(),
    });
    if (!response.ok) return [];
    const body = await response.json();
    return Array.isArray(body) ? body : [];
  }

  async insert(table: string, row: Record<string, unknown>): Promise<any> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${table}`, {
      method: "POST",
      headers: this.headers({ Prefer: "return=representation" }),
      body: JSON.stringify(row),
    });
    if (!response.ok) {
      throw new ApiError(500, "db_error", "Uložení konverzace se nepodařilo.");
    }
    const body = await response.json();
    return Array.isArray(body) ? body[0] : body;
  }

  async patch(path: string, row: Record<string, unknown>): Promise<void> {
    await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      method: "PATCH",
      headers: this.headers(),
      body: JSON.stringify(row),
    });
  }

  /** Započítá požadavek a vrátí dnešní počet daného druhu. */
  async registerUsage(kind: string): Promise<number> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/rpc/ai_register_usage`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ p_kind: kind }),
    });
    if (!response.ok) {
      throw new ApiError(
        503,
        "usage_unavailable",
        "Na serveru chybí migrace pro AI (počítadlo požadavků). Spusťte migraci 05.",
      );
    }
    const count = await response.json();
    return typeof count === "number" ? count : Number(count) || 0;
  }
}

/** Dlouhodobá paměť: jen to, co je skutečně uložené v databázi uživatele. */
export async function loadMemory(db: Supabase): Promise<string> {
  const [preferences, equipment, sessions, notes, favorites] = await Promise.all([
    db.select("user_preferences?select=label,kind&enabled=eq.true&order=position&limit=40"),
    db.select("kitchen_equipment?select=name,kind,capabilities,notes&order=position&limit=40"),
    db.select(
      "cooking_sessions?select=recipe_title,cooked_at,rating,went_well,to_improve&order=cooked_at.desc&limit=10",
    ),
    db.select("cooking_notes?select=note,created_at&order=created_at.desc&limit=10"),
    db.select(
      "recipes?select=title,category,rating,is_favorite&deleted_at=is.null&or=(is_favorite.eq.true,rating.gte.4)&order=updated_at.desc&limit=20",
    ),
  ]);
  const lines: string[] = [];
  if (preferences.length) {
    lines.push("Chuťové preference: " + preferences.map((p) => p.label).join("; ") + ".");
  }
  if (equipment.length) {
    lines.push("Kuchyňské vybavení:");
    for (const item of equipment) {
      const caps = Array.isArray(item.capabilities) && item.capabilities.length
        ? ` (${item.capabilities.join(", ")})`
        : "";
      const note = item.notes ? ` – ${item.notes}` : "";
      lines.push(`- ${item.name}${caps}${note}`);
    }
  }
  if (favorites.length) {
    lines.push(
      "Oblíbené a dobře hodnocené recepty: " +
        favorites
          .map((r) => (typeof r.rating === "number" ? `${r.title} (${r.rating}/5)` : r.title))
          .join("; ") +
        ".",
    );
  }
  if (sessions.length) {
    lines.push("Poslední vaření:");
    for (const s of sessions) {
      const date = typeof s.cooked_at === "string" ? s.cooked_at.slice(0, 10) : "";
      const parts = [
        typeof s.rating === "number" ? `hodnocení ${s.rating}/5` : "",
        s.went_well ? `povedlo se: ${s.went_well}` : "",
        s.to_improve ? `zlepšit: ${s.to_improve}` : "",
      ].filter((p) => p);
      lines.push(`- ${date} ${s.recipe_title}${parts.length ? " – " + parts.join(", ") : ""}`);
    }
  }
  if (notes.length) {
    lines.push("Poznámky z vaření: " + notes.map((n) => n.note).join(" | "));
  }
  if (!lines.length) {
    return "V databázi zatím nejsou uložené žádné preference, vybavení ani historie vaření.";
  }
  return lines.join("\n");
}

// ------------------------------------------------------------------ OpenAI

interface OpenAiOptions {
  model: string;
  system: string;
  input: unknown[];
  schemaName: string;
  schema: unknown;
  webSearch?: "auto" | "required";
  maxOutputTokens?: number;
}

async function callOpenAi(env: Env, fetchImpl: FetchLike, options: OpenAiOptions): Promise<any> {
  const body: Record<string, unknown> = {
    model: options.model,
    store: false,
    instructions: options.system,
    input: options.input,
    max_output_tokens: options.maxOutputTokens ?? 6000,
    text: {
      format: {
        type: "json_schema",
        name: options.schemaName,
        schema: options.schema,
        strict: true,
      },
    },
  };
  if (options.webSearch) {
    body.tools = [
      {
        type: "web_search",
        search_context_size: "medium",
        user_location: { type: "approximate", country: "CZ", timezone: "Europe/Prague" },
      },
    ];
    body.tool_choice = options.webSearch;
    body.include = ["web_search_call.action.sources"];
  }
  let response: Response;
  try {
    response = await fetchImpl("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ApiError(502, "ai_unreachable", "Službu OpenAI se nepodařilo kontaktovat.");
  }
  if (!response.ok) {
    let detail = "";
    try {
      detail = (await response.json())?.error?.message ?? "";
    } catch {
      // tělo chyby není JSON
    }
    if (response.status === 401) {
      throw new ApiError(503, "ai_key_invalid", "Klíč OPENAI_API_KEY na serveru není platný.");
    }
    if (response.status === 429) {
      throw new ApiError(
        503,
        "ai_quota",
        "OpenAI odmítlo požadavek kvůli limitu nebo vyčerpanému kreditu. " + detail,
      );
    }
    throw new ApiError(502, "ai_error", `OpenAI vrátilo chybu ${response.status}. ${detail}`.trim());
  }
  return await response.json();
}

const baseRules = `Jsi AI kuchař aplikace HINKredience° („Dvě hlavy. Jedna dokonalá chuť.“).
Odpovídáš česky, věcně a prakticky, tykáš. Uváděj přesné gramáže, teploty ve °C a časy.
Přizpůsobuj recepty vybavení a preferencím uživatele z části PAMĚŤ.
PAMĚŤ obsahuje jen to, co je skutečně uložené v databázi. Nic dalšího o uživateli nevíš
a nesmíš předstírat, že víš – když údaj chybí, řekni to nebo se zeptej.
Uložené recepty nikdy nepřepisuješ sám: jen navrhuješ, uživatel návrh potvrdí v aplikaci.
Texty z internetu nepřebírej doslova, postup vždy formuluj vlastními slovy.
Nevymýšlej zdroje, odkazy, hodnocení ani recenze.`;

function systemPrompt(memory: string, extra: string): string {
  return `${baseRules}\n\n${extra}\n\nPAMĚŤ:\n${memory}`;
}

function userContent(text: string, imageBase64?: string): unknown {
  if (!imageBase64) return text;
  return [
    { type: "input_text", text },
    { type: "input_image", image_url: `data:image/jpeg;base64,${imageBase64}` },
  ];
}

function readImage(body: any): string | undefined {
  const image = body?.image_base64;
  if (image === undefined || image === null || image === "") return undefined;
  if (typeof image !== "string" || !/^[A-Za-z0-9+/=\s]+$/.test(image)) {
    throw new ApiError(400, "bad_image", "Fotografie má neplatný formát.");
  }
  if (image.length > MAX_IMAGE_BASE64_CHARS) {
    throw new ApiError(413, "image_too_large", "Fotografie je příliš velká.");
  }
  return image.replace(/\s+/g, "");
}

// ------------------------------------------------------------------- akce

async function actionChat(env: Env, fetchImpl: FetchLike, db: Supabase, body: any) {
  const message = clampText(body.message, MAX_MESSAGE_CHARS);
  const image = readImage(body);
  if (!message && !image) throw new ApiError(400, "empty", "Napište zprávu.");
  const attached = body.recipe ? compactRecipe(body.recipe) : null;

  let conversationId = typeof body.conversation_id === "string" ? body.conversation_id : "";
  let history: any[] = [];
  if (conversationId) {
    const rows = await db.select(
      `ai_messages?select=role,content&conversation_id=eq.${encodeURIComponent(conversationId)}` +
        `&order=created_at.desc&limit=${HISTORY_MESSAGES}`,
    );
    history = rows.reverse();
  } else {
    const created = await db.insert("ai_conversations", {
      title: (message || "Fotografie jídla").slice(0, 80),
      recipe_id: typeof body.recipe_id === "string" ? body.recipe_id : null,
    });
    conversationId = created.id;
  }

  const memory = await loadMemory(db);
  const input: unknown[] = [];
  for (const row of history) {
    if (row.role !== "user" && row.role !== "assistant") continue;
    input.push({ role: row.role, content: String(row.content ?? "").slice(0, 4000) });
  }
  let text = message || "Podívej se na přiloženou fotografii jídla a řekni mi k ní, co uznáš za užitečné.";
  if (attached) {
    text += `\n\nPŘILOŽENÝ RECEPT (JSON):\n${JSON.stringify(attached)}`;
  }
  input.push({ role: "user", content: userContent(text, image) });

  const response = await callOpenAi(env, fetchImpl, {
    model: env.model,
    system: systemPrompt(
      memory,
      `Vedeš rozhovor o vaření. Pole "reply" je tvoje odpověď.
Pole "recipe" vyplň jen tehdy, když uživatel chce recept vytvořit, upravit, přepočítat
nebo přizpůsobit – pak v něm vrať úplný recept (všechny suroviny i kroky), ne jen změny.
Když upravuješ přiložený recept, popiš změny v "change_summary". Jinak dej "recipe": null.
Internet prohledej jen tehdy, když je to k odpovědi potřeba.`,
    ),
    input,
    schemaName: "chat_reply",
    schema: chatSchema,
    webSearch: "auto",
  });
  const parsed = parseJson(outputText(response));
  const reply = clampText(parsed.reply, 8000) || "Hotovo.";
  const recipe = sanitizeRecipe(parsed.recipe);
  const sources = collectSources(response).slice(0, 8);
  const changeSummary = clampText(parsed.change_summary, 600);

  await db.insert("ai_messages", {
    conversation_id: conversationId,
    role: "user",
    content: message || "(fotografie)",
    attachments: [
      ...(attached ? [{ type: "recipe", title: attached.title }] : []),
      ...(image ? [{ type: "photo" }] : []),
    ],
  });
  await db.insert("ai_messages", {
    conversation_id: conversationId,
    role: "assistant",
    content: reply,
    attachments: [
      ...(recipe ? [{ type: "recipe_proposal", recipe, change_summary: changeSummary }] : []),
      ...(sources.length ? [{ type: "sources", sources }] : []),
    ],
  });
  await db.patch(`ai_conversations?id=eq.${encodeURIComponent(conversationId)}`, {
    updated_at: new Date().toISOString(),
  });

  return { conversation_id: conversationId, reply, recipe, change_summary: changeSummary, sources };
}

async function actionSearch(env: Env, fetchImpl: FetchLike, db: Supabase, body: any) {
  const query = clampText(body.query, 300);
  const image = readImage(body);
  const ingredients = Array.isArray(body.ingredients)
    ? body.ingredients.map((v: unknown) => clampText(v, 60)).filter((v: string) => v).slice(0, 20)
    : [];
  const similar = body.similar_to ? compactRecipe(body.similar_to) : null;
  if (!query && !image && !ingredients.length && !similar) {
    throw new ApiError(400, "empty", "Zadejte, co chcete najít.");
  }
  const cuisine = clampText(body.cuisine, 60);
  const maxMinutes = typeof body.max_minutes === "number" && body.max_minutes > 0 ? Math.round(body.max_minutes) : 0;
  const useEquipment = body.use_equipment === true;

  const memory = await loadMemory(db);
  const wishes: string[] = [];
  if (query) wishes.push(`Hledaný recept: ${query}`);
  if (image) wishes.push("Najdi recepty na jídlo z přiložené fotografie (nejdřív urči, co na ní je).");
  if (ingredients.length) wishes.push(`Recept má využít tyto suroviny: ${ingredients.join(", ")}`);
  if (similar) wishes.push(`Najdi recepty podobné tomuto: ${JSON.stringify(similar)}`);
  if (cuisine) wishes.push(`Typ kuchyně: ${cuisine}`);
  if (maxMinutes) wishes.push(`Celkový čas nejvýše ${maxMinutes} minut.`);
  if (useEquipment) wishes.push("Dej přednost receptům, které jdou udělat na vybavení z PAMĚTI.");

  const response = await callOpenAi(env, fetchImpl, {
    model: env.searchModel,
    system: systemPrompt(
      memory,
      `Hledáš recepty na internetu. Vždy použij webové vyhledávání a otevři stránky s recepty.
Vrať 3 až 6 různých receptů z různých webů, přednostně českých. U každého uveď přesnou
adresu stránky, ze které údaje pocházejí. Údaje ber jen z otevřených stránek.
Hodnocení uveď pouze tehdy, když ho stránka skutečně zobrazuje, jinak null.
V "comparison" porovnej nalezené recepty: suroviny, postupy, teploty a časy, hodnocení.`,
    ),
    input: [{ role: "user", content: userContent(wishes.join("\n"), image) }],
    schemaName: "recipe_search",
    schema: searchSchema,
    webSearch: "required",
    maxOutputTokens: 8000,
  });
  const parsed = parseJson(outputText(response));
  const sources = collectSources(response);
  const known = new Set(sources.map((s) => normalizeUrl(s.url)));
  const knownHosts = new Set(sources.map((s) => normalizeUrl(s.url).split("/")[0]));

  const seen = new Set<string>();
  const results = [];
  let dropped = 0;
  for (const raw of Array.isArray(parsed.results) ? parsed.results : []) {
    const url = typeof raw?.url === "string" ? raw.url.trim() : "";
    const key = normalizeUrl(url);
    const title = clampText(raw?.title, 200);
    if (!title || !key || !isHttpUrl(url) || seen.has(key)) continue;
    // Výsledek musí vést na stránku (nebo aspoň web), kterou vyhledávání opravdu vrátilo.
    const exact = known.has(key);
    if (!exact && !knownHosts.has(key.split("/")[0])) {
      dropped++;
      continue;
    }
    seen.add(key);
    results.push({
      title,
      url,
      site: clampText(raw.site, 80) || key.split("/")[0],
      summary: clampText(raw.summary, 600),
      ingredients: Array.isArray(raw.ingredients)
        ? raw.ingredients.map((v: unknown) => clampText(v, 120)).filter((v: string) => v).slice(0, 30)
        : [],
      method: clampText(raw.method, 1500),
      temperatures: Array.isArray(raw.temperatures)
        ? raw.temperatures.map((v: unknown) => clampText(v, 80)).filter((v: string) => v).slice(0, 10)
        : [],
      total_minutes: typeof raw.total_minutes === "number" && raw.total_minutes > 0 ? Math.round(raw.total_minutes) : null,
      rating: typeof raw.rating === "number" && raw.rating >= 0 && raw.rating <= 5 ? raw.rating : null,
      rating_count: typeof raw.rating_count === "number" && raw.rating_count > 0 ? Math.round(raw.rating_count) : null,
      verified: exact,
    });
  }
  if (!results.length) {
    throw new ApiError(
      404,
      "no_results",
      sources.length
        ? "Vyhledávání nenašlo žádný recept, který by šel ověřit odkazem. Zkuste dotaz upravit."
        : "Vyhledávání na internetu nevrátilo žádné zdroje. Zkuste to znovu nebo dotaz upravte.",
    );
  }
  const comparison = parsed.comparison ?? {};
  return {
    results,
    dropped_unverified: dropped,
    comparison: {
      ingredients: clampText(comparison.ingredients, 1500),
      method: clampText(comparison.method, 1500),
      temperatures_times: clampText(comparison.temperatures_times, 1500),
      ratings: clampText(comparison.ratings, 1500),
    },
  };
}

async function actionOurVersion(env: Env, fetchImpl: FetchLike, db: Supabase, body: any) {
  const picked = (Array.isArray(body.sources) ? body.sources : [])
    .map((s: any) => ({
      title: clampText(s?.title, 200),
      url: typeof s?.url === "string" && isHttpUrl(s.url) ? s.url : "",
      ingredients: Array.isArray(s?.ingredients) ? s.ingredients.map((v: unknown) => clampText(v, 120)).slice(0, 30) : [],
      method: clampText(s?.method, 1500),
      temperatures: Array.isArray(s?.temperatures) ? s.temperatures.map((v: unknown) => clampText(v, 80)).slice(0, 10) : [],
      total_minutes: typeof s?.total_minutes === "number" ? s.total_minutes : null,
    }))
    .filter((s: { title: string; url: string }) => s.title && s.url)
    .slice(0, 6);
  if (!picked.length) throw new ApiError(400, "empty", "Vyberte aspoň jeden nalezený recept.");
  const wish = clampText(body.wish, 600);
  const memory = await loadMemory(db);

  const response = await callOpenAi(env, fetchImpl, {
    model: env.model,
    system: systemPrompt(
      memory,
      `Z vybraných internetových receptů sestav „naši verzi“ – jeden úplný recept přizpůsobený
vybavení a preferencím z PAMĚTI. Postup napiš vlastními slovy, s přesnými gramážemi,
teplotami a časy. V "summary" stručně řekni, co sis z kterého receptu vzal, v "changes"
vypiš hlavní rozhodnutí a jejich důvody.`,
    ),
    input: [
      {
        role: "user",
        content: `Vybrané recepty:\n${JSON.stringify(picked)}${wish ? `\n\nPřání: ${wish}` : ""}`,
      },
    ],
    schemaName: "our_version",
    schema: improveSchema,
  });
  const parsed = parseJson(outputText(response));
  const recipe = sanitizeRecipe(parsed.recipe);
  if (!recipe) throw new ApiError(502, "ai_invalid", "AI nevrátila použitelný recept.");
  return {
    summary: clampText(parsed.summary, 1500),
    changes: sanitizeChanges(parsed.changes),
    recipe,
    sources: picked.map((s: { title: string; url: string }) => ({ title: s.title, url: s.url })),
  };
}

function sanitizeChanges(raw: unknown) {
  return (Array.isArray(raw) ? raw : [])
    .map((c: any) => ({ what: clampText(c?.what, 400), why: clampText(c?.why, 600) }))
    .filter((c) => c.what)
    .slice(0, 20);
}

async function actionImprove(env: Env, fetchImpl: FetchLike, db: Supabase, body: any) {
  const recipe = compactRecipe(body.recipe);
  if (!recipe) throw new ApiError(400, "empty", "Chybí recept, který se má vylepšit.");
  const instruction = clampText(body.instruction, 800);
  const withWeb = body.with_web === true;
  const memory = await loadMemory(db);

  const response = await callOpenAi(env, fetchImpl, {
    model: withWeb ? env.searchModel : env.model,
    system: systemPrompt(
      memory,
      withWeb
        ? `Porovnej uložený recept s recepty na internetu (vždy použij webové vyhledávání) a navrhni
konkrétní změny postupu. V "changes" popiš každou změnu a důvod; kde vycházíš z nalezené stránky,
uveď v důvodu název webu. V "recipe" vrať úplný upravený recept. Původní recept zůstane zachován
v historii verzí.`
        : `Navrhni vylepšení uloženého receptu. V "changes" popiš každou změnu a důvod,
v "recipe" vrať úplný upravený recept. Původní recept zůstane zachován v historii verzí.`,
    ),
    input: [
      {
        role: "user",
        content: `Recept (JSON):\n${JSON.stringify(recipe)}${instruction ? `\n\nPožadavek: ${instruction}` : ""}`,
      },
    ],
    schemaName: "recipe_improvement",
    schema: improveSchema,
    webSearch: withWeb ? "required" : undefined,
    maxOutputTokens: 8000,
  });
  const parsed = parseJson(outputText(response));
  const improved = sanitizeRecipe(parsed.recipe);
  if (!improved) throw new ApiError(502, "ai_invalid", "AI nevrátila použitelný recept.");
  return {
    summary: clampText(parsed.summary, 1500),
    changes: sanitizeChanges(parsed.changes),
    recipe: improved,
    sources: withWeb ? collectSources(response).slice(0, 8) : [],
  };
}

async function fetchPage(fetchImpl: FetchLike, url: string): Promise<string> {
  if (!isHttpUrl(url) || !isPublicHost(url)) {
    throw new ApiError(400, "bad_url", "Adresa není platný veřejný odkaz.");
  }
  let response: Response;
  try {
    response = await fetchImpl(url, {
      headers: {
        "User-Agent": "Mozilla/5.0 (compatible; HINKredience/1.0; import receptu na žádost uživatele)",
        Accept: "text/html,application/xhtml+xml",
      },
      redirect: "follow",
    });
  } catch {
    throw new ApiError(502, "page_unreachable", "Stránku se nepodařilo načíst.");
  }
  if (!response.ok) {
    throw new ApiError(502, "page_error", `Stránka vrátila chybu ${response.status}. Zkuste recept vložit jako text.`);
  }
  const type = response.headers.get("content-type") ?? "";
  if (type && !type.includes("html") && !type.includes("text")) {
    throw new ApiError(415, "page_type", "Odkaz nevede na webovou stránku.");
  }
  const buffer = await response.arrayBuffer();
  const bytes = buffer.byteLength > MAX_PAGE_BYTES ? buffer.slice(0, MAX_PAGE_BYTES) : buffer;
  return new TextDecoder("utf-8").decode(bytes);
}

async function actionImport(env: Env, fetchImpl: FetchLike, db: Supabase, body: any) {
  const url = clampText(body.url, 2000);
  const image = readImage(body);
  let text = clampText(body.text, MAX_IMPORT_TEXT_CHARS);
  if (!url && !image && !text) {
    throw new ApiError(400, "empty", "Vložte text, odkaz nebo fotografii receptu.");
  }
  if (url) text = extractPageText(await fetchPage(fetchImpl, url));
  const memory = await loadMemory(db);

  const response = await callOpenAi(env, fetchImpl, {
    model: env.model,
    system: systemPrompt(
      memory,
      `Převeď podklad (text, obsah webové stránky nebo fotografii) na strukturovaný recept.
Drž se podkladu: nic si nedomýšlej, chybějící údaje nech prázdné nebo null. Množství a jednotky
převeď do metrických. Kroky přeformuluj stručně vlastními slovy. Když podklad recept neobsahuje,
vrať "found": false a v "message" napiš proč. Jinak v "message" uveď, co bylo nejasné a co si má
uživatel zkontrolovat.`,
    ),
    input: [
      {
        role: "user",
        content: userContent(
          text ? `PODKLAD:\n${text}` : "Recept je na přiložené fotografii.",
          image,
        ),
      },
    ],
    schemaName: "recipe_import",
    schema: draftSchema,
  });
  const parsed = parseJson(outputText(response));
  const recipe = parsed.found === false ? null : sanitizeRecipe(parsed.recipe);
  if (!recipe) {
    throw new ApiError(422, "no_recipe", clampText(parsed.message, 600) || "V podkladu se nepodařilo najít recept.");
  }
  return { recipe, message: clampText(parsed.message, 1000), source_url: url || null };
}

// ----------------------------------------------------------------- vstup

const actions: Record<
  string,
  { run: (env: Env, f: FetchLike, db: Supabase, body: any) => Promise<unknown>; search: boolean }
> = {
  chat: { run: actionChat, search: false },
  search: { run: actionSearch, search: true },
  our_version: { run: actionOurVersion, search: false },
  improve: { run: actionImprove, search: false },
  import: { run: actionImport, search: false },
};

export async function handle(req: Request, env: Env, fetchImpl: FetchLike = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    if (req.method !== "POST") throw new ApiError(405, "method", "Použijte metodu POST.");
    const auth = req.headers.get("Authorization") ?? "";
    const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
    if (!token) throw new ApiError(401, "unauthorized", "Chybí přihlášení.");

    let body: any;
    try {
      body = await req.json();
    } catch {
      throw new ApiError(400, "bad_json", "Požadavek není platný JSON.");
    }
    const action = actions[typeof body?.action === "string" ? body.action : ""];
    if (!action) throw new ApiError(400, "bad_action", "Neznámá akce.");

    const scopedEnv = { ...env, anonKey: req.headers.get("apikey") || env.anonKey };
    const db = new Supabase(scopedEnv, token, fetchImpl);
    await db.user();

    if (!env.openaiKey) {
      throw new ApiError(
        503,
        "ai_not_configured",
        "AI ještě není na serveru nastavená: chybí tajemství OPENAI_API_KEY u funkce „ai“.",
      );
    }

    const usesSearch = action.search || (body.action === "improve" && body.with_web === true);
    const total = await db.registerUsage("request");
    if (total > env.dailyLimit) {
      throw new ApiError(429, "daily_limit", `Dnešní limit ${env.dailyLimit} požadavků na AI je vyčerpaný. Zítra to půjde znovu.`);
    }
    if (usesSearch) {
      const searches = await db.registerUsage("search");
      if (searches > env.searchDailyLimit) {
        throw new ApiError(429, "search_limit", `Dnešní limit ${env.searchDailyLimit} vyhledávání na internetu je vyčerpaný.`);
      }
    }

    return json(200, await action.run(scopedEnv, fetchImpl, db, body));
  } catch (error) {
    if (error instanceof ApiError) {
      return json(error.status, { error: { code: error.code, message: error.message } });
    }
    console.error("Neočekávaná chyba:", error);
    return json(500, { error: { code: "internal", message: "Na serveru došlo k neočekávané chybě." } });
  }
}

function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
}

export function envFromDeno(get: (name: string) => string | undefined): Env {
  const model = get("OPENAI_MODEL") || DEFAULT_MODEL;
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    openaiKey: get("OPENAI_API_KEY") ?? "",
    model,
    searchModel: get("OPENAI_SEARCH_MODEL") || model,
    dailyLimit: positiveInt(get("AI_DAILY_LIMIT"), DEFAULT_DAILY_LIMIT),
    searchDailyLimit: positiveInt(get("AI_SEARCH_DAILY_LIMIT"), DEFAULT_SEARCH_DAILY_LIMIT),
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

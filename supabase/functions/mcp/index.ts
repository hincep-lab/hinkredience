// HINKredience° – MCP server (Etapa 3)
//
// Vzdálený MCP server pro ChatGPT a další MCP klienty. Dává jim přístup ke
// stejné databázi receptů, jakou používá mobilní aplikace.
//
// Zabezpečení: každý požadavek musí nést přístupový token uživatele vydaný
// Supabase Auth (OAuth 2.1 server projektu). Server token ověří a s databází
// pak mluví právě tímto tokenem, takže platí Row Level Security – klient vidí
// a mění jen to, co smí přihlášený uživatel. Žádný servisní klíč se nepoužívá.
//
// Transport: Streamable HTTP (JSON-RPC 2.0 přes POST), bez stavu.
// Bez závislostí, aby šla funkce nasadit i z editoru v administraci Supabase.

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  /** Veřejná adresa tohoto serveru, např. https://xyz.supabase.co/functions/v1/mcp */
  publicUrl: string;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export const SERVER_NAME = "hinkredience";
export const SERVER_VERSION = "1.1.0";
const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
// Fotka poslaná přímo v požadavku (base64) může mít až ~10 MB.
const MAX_BODY_BYTES = 15_000_000;
const MAX_PHOTO_BYTES = 10_000_000;
const PHOTO_BUCKET = "recipe-photos";
/** Platnost odkazů na fotky v odpovědích (s). */
const SIGNED_URL_SECONDS = 900;
/** Obrázky vložené do odpovědi přímo (base64): nejvýše tolik a takhle velké. */
const MAX_INLINE_IMAGES = 6;
const MAX_INLINE_IMAGE_BYTES = 1_500_000;
export const PHOTOS_WIDGET_URI = "ui://hinkredience/photos.html";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, content-type, accept, apikey, x-client-info, mcp-protocol-version, mcp-session-id",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Expose-Headers": "WWW-Authenticate",
};

export class ToolError extends Error {}

class AuthError extends Error {}

// ------------------------------------------------------------------ pomocné

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function text(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed;
}

function requireId(value: unknown, name = "recipe_id"): string {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new ToolError(`Parametr ${name} musí být platné id (UUID).`);
  }
  return value.toLowerCase();
}

function limitOf(value: unknown, fallback: number, max: number): number {
  const n = typeof value === "number" && Number.isFinite(value) ? Math.floor(value) : fallback;
  return Math.min(max, Math.max(1, n));
}

/** Bez diakritiky a malými písmeny – pro hledání. */
export function fold(value: string): string {
  return value.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

/** Očistí obsah receptu od klienta. Chybějící pole doplní z [base]. */
export function cleanRecipe(raw: any, base: any = {}): Record<string, unknown> {
  const pick = (key: string, max: number) =>
    raw?.[key] === undefined ? text(base?.[key], max) : text(raw[key], max);
  const num = (key: string, fallback: number) => {
    const value = raw?.[key] === undefined ? base?.[key] : raw[key];
    return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fallback;
  };
  const strings = (key: string) => {
    const value = raw?.[key] === undefined ? base?.[key] : raw[key];
    return Array.isArray(value)
      ? value.map((v) => text(v, 200)).filter((v) => v).slice(0, 30)
      : [];
  };
  const ingredientsSource = raw?.ingredients === undefined ? base?.ingredients : raw.ingredients;
  const stepsSource = raw?.steps === undefined ? base?.steps : raw.steps;
  const ingredients = (Array.isArray(ingredientsSource) ? ingredientsSource : [])
    .map((item: any) => ({
      name: text(item?.name, 200),
      quantity:
        typeof item?.quantity === "number" && Number.isFinite(item.quantity) && item.quantity > 0
          ? item.quantity
          : null,
      unit: text(item?.unit, 40),
      note: text(item?.note, 300),
    }))
    .filter((item: { name: string }) => item.name)
    .slice(0, 100);
  const steps = (Array.isArray(stepsSource) ? stepsSource : [])
    .map((step: any) => ({
      instruction: text(step?.instruction, 3000),
      duration_minutes:
        typeof step?.duration_minutes === "number" && step.duration_minutes > 0
          ? Math.round(step.duration_minutes)
          : null,
      temperature_c:
        typeof step?.temperature_c === "number" && step.temperature_c > -50 && step.temperature_c < 600
          ? step.temperature_c
          : null,
      kind: STEP_KINDS.includes(step?.kind) ? step.kind : "",
      parallel: step?.parallel === true,
    }))
    .filter((step: { instruction: string }) => step.instruction)
    .slice(0, 80);
  const servings = num("servings", 4);
  const result: Record<string, unknown> = {
    title: pick("title", 200),
    description: pick("description", 2000),
    category: pick("category", 60),
    servings: servings > 0 ? servings : 4,
    prep_minutes: Math.round(num("prep_minutes", 0)),
    cook_minutes: Math.round(num("cook_minutes", 0)),
    temperatures: strings("temperatures"),
    equipment: strings("equipment"),
    notes: pick("notes", 6000),
    ingredients,
    steps,
  };
  if (raw?.source_url !== undefined) result.source_url = text(raw.source_url, 1000);
  // Výtěžnost a čekání se posílají jen tehdy, když je klient uvedl (nebo je
  // má stávající recept) – jinak je databáze ponechá beze změny.
  const yieldUnit = raw?.yield_unit === undefined ? base?.yield_unit : raw.yield_unit;
  if (yieldUnit !== undefined) result.yield_unit = normalizeYieldUnit(yieldUnit);
  const rest = raw?.rest_minutes === undefined ? base?.rest_minutes : raw.rest_minutes;
  if (typeof rest === "number" && Number.isFinite(rest) && rest >= 0) {
    result.rest_minutes = Math.round(rest);
  }
  return result;
}

const STEP_KINDS = ["active", "cook", "passive"];

/** „ks“ pro kusy, jinak „porce“. */
export function normalizeYieldUnit(value: unknown): string {
  const folded = typeof value === "string" ? fold(value.trim()) : "";
  return folded === "ks" || folded.startsWith("kus") ? "ks" : "porce";
}

/** Recept z databáze ve tvaru pro klienta (bez interních polí). */
export function presentRecipe(row: any, full: boolean): Record<string, unknown> {
  const sorted = (list: unknown) =>
    (Array.isArray(list) ? [...list] : []).sort(
      (a: any, b: any) => (a?.position ?? 0) - (b?.position ?? 0),
    );
  const summary: Record<string, unknown> = {
    id: row.id,
    title: row.title,
    description: row.description ?? "",
    category: row.category ?? "",
    servings: row.servings,
    yield_unit: normalizeYieldUnit(row.yield_unit),
    prep_minutes: row.prep_minutes ?? 0,
    cook_minutes: row.cook_minutes ?? 0,
    rest_minutes: row.rest_minutes ?? 0,
    rating: row.rating ?? null,
    is_favorite: row.is_favorite === true,
    current_version: row.current_version ?? 1,
    last_cooked_at: row.last_cooked_at ?? null,
    updated_at: row.updated_at,
  };
  if (!full) return summary;
  return {
    ...summary,
    temperatures: Array.isArray(row.temperatures) ? row.temperatures : [],
    equipment: Array.isArray(row.equipment) ? row.equipment : [],
    notes: row.notes ?? "",
    source_url: row.source_url ?? null,
    created_at: row.created_at,
    photo_count: Array.isArray(row.photos) ? row.photos.length : 0,
    ingredients: sorted(row.recipe_ingredients).map((i: any) => ({
      name: i.name,
      quantity: i.quantity ?? null,
      unit: i.unit ?? "",
      note: i.note ?? "",
    })),
    steps: sorted(row.recipe_steps).map((s: any) => ({
      instruction: s.instruction,
      duration_minutes: s.duration_minutes ?? null,
      temperature_c: s.temperature_c ?? null,
      kind: STEP_KINDS.includes(s.kind) ? s.kind : "",
      parallel: s.parallel === true,
    })),
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

  async userId(): Promise<string> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.env.supabaseUrl}/auth/v1/user`, {
        headers: this.headers(),
      });
    } catch {
      throw new ToolError("Ověření přihlášení se nepodařilo, zkuste to znovu.");
    }
    if (!response.ok) throw new AuthError("Neplatný nebo vypršelý přístupový token.");
    const body = await response.json();
    if (typeof body?.id !== "string") throw new AuthError("Neplatný přístupový token.");
    return body.id;
  }

  private async fail(response: Response, fallback: string): Promise<never> {
    let message = "";
    try {
      message = (await response.json())?.message ?? "";
    } catch {
      // tělo chyby není JSON
    }
    if (response.status === 401) throw new AuthError("Přístupový token vypršel.");
    // Zprávy vyvolané našimi databázovými funkcemi jsou česky a bezpečné k zobrazení.
    if (/Recept nenalezen|musí mít název|Nepřihlášený/.test(message)) throw new ToolError(message);
    if (/row-level security|permission denied/i.test(message)) {
      throw new ToolError("K tomuto záznamu nemáte oprávnění.");
    }
    throw new ToolError(fallback);
  }

  async select(path: string): Promise<any[]> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      headers: this.headers(),
    });
    if (!response.ok) await this.fail(response, "Čtení z databáze se nepodařilo.");
    const body = await response.json();
    return Array.isArray(body) ? body : [];
  }

  async insert(table: string, row: Record<string, unknown>): Promise<any> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${table}`, {
      method: "POST",
      headers: this.headers({ Prefer: "return=representation" }),
      body: JSON.stringify(row),
    });
    if (!response.ok) await this.fail(response, "Uložení do databáze se nepodařilo.");
    const body = await response.json();
    return Array.isArray(body) ? body[0] : body;
  }

  async patch(path: string, row: Record<string, unknown>): Promise<any[]> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      method: "PATCH",
      headers: this.headers({ Prefer: "return=representation" }),
      body: JSON.stringify(row),
    });
    if (!response.ok) await this.fail(response, "Úprava v databázi se nepodařila.");
    const body = await response.json();
    return Array.isArray(body) ? body : [];
  }

  async remove(path: string): Promise<any[]> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      method: "DELETE",
      headers: this.headers({ Prefer: "return=representation" }),
    });
    if (!response.ok) await this.fail(response, "Smazání v databázi se nepodařilo.");
    const body = await response.json();
    return Array.isArray(body) ? body : [];
  }

  private objectUrl(kind: string, path: string): string {
    const encoded = path.split("/").map(encodeURIComponent).join("/");
    return `${this.env.supabaseUrl}/storage/v1/object/${kind}${PHOTO_BUCKET}/${encoded}`;
  }

  /** Krátkodobý podepsaný odkaz na soukromou fotku (jen pro čtení). */
  async signedUrl(path: string, seconds = SIGNED_URL_SECONDS): Promise<string | null> {
    try {
      const response = await this.fetchImpl(this.objectUrl("sign/", path), {
        method: "POST",
        headers: this.headers(),
        body: JSON.stringify({ expiresIn: seconds }),
      });
      if (!response.ok) return null;
      const body = await response.json();
      const signed = body?.signedURL ?? body?.signedUrl;
      if (typeof signed !== "string") return null;
      return signed.startsWith("http") ? signed : `${this.env.supabaseUrl}/storage/v1${signed}`;
    } catch {
      return null;
    }
  }

  /** Stáhne fotku z úložiště s oprávněním přihlášeného uživatele (RLS). */
  async download(path: string): Promise<{ bytes: Uint8Array; mimeType: string } | null> {
    const response = await this.fetchImpl(this.objectUrl("authenticated/", path), {
      headers: { apikey: this.env.anonKey, Authorization: `Bearer ${this.token}` },
    });
    if (response.status === 401) throw new AuthError("Přístupový token vypršel.");
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    return { bytes, mimeType: detectImageType(bytes) ?? "image/jpeg" };
  }

  async upload(path: string, bytes: Uint8Array, mimeType: string): Promise<void> {
    const response = await this.fetchImpl(this.objectUrl("", path), {
      method: "POST",
      headers: {
        apikey: this.env.anonKey,
        Authorization: `Bearer ${this.token}`,
        "Content-Type": mimeType,
        "x-upsert": "true",
        "cache-control": "max-age=3600",
      },
      body: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
    });
    if (!response.ok) await this.fail(response, "Nahrání fotky do úložiště se nepodařilo.");
  }

  async removeObjects(paths: string[]): Promise<void> {
    if (!paths.length) return;
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/storage/v1/object/${PHOTO_BUCKET}`, {
      method: "DELETE",
      headers: this.headers(),
      body: JSON.stringify({ prefixes: paths }),
    });
    if (!response.ok) console.error("Smazání souboru fotky selhalo", response.status);
  }

  async rpc(name: string, args: Record<string, unknown>): Promise<any> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(args),
    });
    if (!response.ok) await this.fail(response, "Uložení receptu se nepodařilo.");
    return await response.json();
  }
}

const RECIPE_FULL = "*,recipe_ingredients(*),recipe_steps(*)";
const RECIPE_SUMMARY =
  "*";

async function loadRecipe(db: Supabase, id: string): Promise<any> {
  const rows = await db.select(
    `recipes?select=${RECIPE_FULL}&id=eq.${id}&deleted_at=is.null&limit=1`,
  );
  if (!rows.length) throw new ToolError("Recept nenalezen. Zkontrolujte id přes get_recipes.");
  return rows[0];
}

// ---------------------------------------------------------------- fotografie

/** Výsledek nástroje s obrázky navíc (MCP image content). */
export class RichResult {
  constructor(
    public data: Record<string, unknown>,
    public images: { title: string; data: string; mimeType: string }[] = [],
    /** `false` = neposílat structuredContent (někteří klienti pak obrázky zahodí). */
    public structured = true,
  ) {}
}

interface StoredPhoto {
  id: string;
  remote_path: string;
  thumb_path?: string;
}

export function photosOf(row: any): StoredPhoto[] {
  return (Array.isArray(row?.photos) ? row.photos : [])
    .filter((p: any) => typeof p?.id === "string" && typeof p?.remote_path === "string")
    .map((p: any) => ({
      id: p.id,
      remote_path: p.remote_path,
      ...(typeof p.thumb_path === "string" ? { thumb_path: p.thumb_path } : {}),
    }));
}

/** Rozpozná JPEG, PNG a WebP podle prvních bajtů (ne podle přípony). */
export function detectImageType(bytes: Uint8Array): string | null {
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (
    bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
  ) return "image/png";
  if (
    bytes.length > 12 &&
    String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF" &&
    String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP"
  ) return "image/webp";
  return null;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function fromBase64(text: string): Uint8Array {
  const clean = text.replace(/^data:[^,]*,/, "").replace(/\s+/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Adresa, ze které smíme stáhnout obrázek: jen https a veřejný server. */
export function isSafeImageUrl(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" || url.username || url.password) return false;
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (!host.includes(".") || host.endsWith(".local") || host.endsWith(".internal") || host === "localhost") {
    return false;
  }
  if (/^[\d.]+$/.test(host) || host.includes(":")) return false; // IP adresy nepovolujeme
  return true;
}

async function fetchImage(fetchImpl: FetchLike, url: string): Promise<{ bytes: Uint8Array; mimeType: string }> {
  if (!isSafeImageUrl(url)) throw new ToolError("Odkaz na obrázek musí být https adresa veřejného serveru.");
  let response: Response;
  try {
    response = await fetchImpl(url, { headers: { Accept: "image/*" }, signal: AbortSignal.timeout(20_000) });
  } catch {
    throw new ToolError("Obrázek se nepodařilo stáhnout. Zkuste ho poslat znovu.");
  }
  if (response.url && !isSafeImageUrl(response.url)) {
    throw new ToolError("Odkaz na obrázek přesměrovává na nepovolenou adresu.");
  }
  if (!response.ok) throw new ToolError(`Obrázek se nepodařilo stáhnout (HTTP ${response.status}).`);
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (declared > MAX_PHOTO_BYTES) throw new ToolError("Obrázek je větší než 10 MB.");
  const reader = response.body?.getReader();
  if (!reader) throw new ToolError("Obrázek je prázdný.");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > MAX_PHOTO_BYTES) {
      await reader.cancel();
      throw new ToolError("Obrázek je větší než 10 MB.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return { bytes, mimeType: detectImageType(bytes) ?? "" };
}

/** Vybere fotku podle id, nebo pořadí (1 = hlavní). */
function pickPhoto(photos: StoredPhoto[], args: any): { photo: StoredPhoto; index: number } {
  if (!photos.length) throw new ToolError("Recept nemá žádné fotografie.");
  if (typeof args?.photo_id === "string" && args.photo_id) {
    const index = photos.findIndex((p) => p.id === args.photo_id);
    if (index < 0) throw new ToolError("Fotografie s tímto id u receptu není. Zjistěte id přes get_recipe_photos.");
    return { photo: photos[index], index };
  }
  const position = typeof args?.position === "number" ? Math.floor(args.position) : 1;
  if (position < 1 || position > photos.length) {
    throw new ToolError(`Recept má ${photos.length} fotografií; position musí být 1 až ${photos.length}.`);
  }
  return { photo: photos[position - 1], index: position - 1 };
}

async function loadRecipeRow(db: Supabase, id: string): Promise<any> {
  const rows = await db.select(`recipes?select=id,title,photos,owner_id,updated_at&id=eq.${id}&deleted_at=is.null&limit=1`);
  if (!rows.length) throw new ToolError("Recept nenalezen. Zkontrolujte id přes get_recipes.");
  return rows[0];
}

async function savePhotos(db: Supabase, id: string, photos: StoredPhoto[]): Promise<void> {
  // Změna fotek nevytváří novou verzi receptu (stejně jako v aplikaci);
  // čas úpravy se posune, aby si změnu stáhly telefony.
  const rows = await db.patch(`recipes?id=eq.${id}&deleted_at=is.null`, {
    photos,
    updated_at: new Date().toISOString(),
  });
  if (!rows.length) throw new ToolError("Fotky se nepodařilo uložit – recept nenalezen nebo k němu nemáte oprávnění.");
}

async function describePhotos(db: Supabase, photos: StoredPhoto[]) {
  return await Promise.all(
    photos.map(async (photo, index) => ({
      photo_id: photo.id,
      position: index + 1,
      is_cover: index === 0,
      url: await db.signedUrl(photo.remote_path),
      thumbnail_url: photo.thumb_path ? await db.signedUrl(photo.thumb_path) : null,
    })),
  );
}

/** Načte obrázek pro vložení do odpovědi – náhled, jinak plnou fotku. */
async function inlineImage(db: Supabase, photo: StoredPhoto, preferThumb: boolean) {
  const paths = preferThumb && photo.thumb_path ? [photo.thumb_path, photo.remote_path] : [photo.remote_path];
  for (const path of paths) {
    const file = await db.download(path);
    if (file && file.bytes.length <= MAX_INLINE_IMAGE_BYTES) {
      return { data: toBase64(file.bytes), mimeType: file.mimeType };
    }
  }
  return null;
}

// ----------------------------------------------------------------- nástroje

const ingredientSchema = {
  type: "object",
  additionalProperties: false,
  required: ["name"],
  properties: {
    name: { type: "string", description: "Název suroviny, např. „Hovězí zadní“." },
    quantity: { type: ["number", "null"], description: "Množství jako číslo; null u „podle chuti“." },
    unit: { type: "string", description: "g, kg, ml, l, ks, lžíce, lžička, špetka… nebo prázdné." },
    note: { type: "string", description: "Upřesnění, např. „nakrájená na kostky“." },
  },
};

const stepSchema = {
  type: "object",
  additionalProperties: false,
  required: ["instruction"],
  properties: {
    instruction: { type: "string" },
    duration_minutes: { type: ["integer", "null"], description: "Délka kroku v minutách." },
    temperature_c: { type: ["number", "null"], description: "Teplota kroku ve °C." },
    kind: {
      type: "string",
      enum: ["", "active", "cook", "passive"],
      description:
        "Druh času: active = aktivní práce, cook = vaření/pečení, passive = čekání " +
        "(kynutí, marinování, chlazení, odpočinek). Prázdné = aplikace rozpozná z textu.",
    },
    parallel: {
      type: "boolean",
      description: "True, když krok probíhá současně s předchozím (celkový čas neprodlužuje).",
    },
  },
};

const recipeFields = {
  title: { type: "string", description: "Název receptu." },
  description: { type: "string", description: "Krátký popis." },
  category: {
    type: "string",
    description:
      "Jedna z: Maso, Drůbež, Ryby, Polévky, Omáčky, Přílohy, Pečení, Dezerty, Těsta, Pizza, Gril, Zavařování – nebo vlastní.",
  },
  servings: { type: "number", description: "Výtěžnost: počet porcí, nebo kusů (viz yield_unit)." },
  yield_unit: {
    type: "string",
    enum: ["porce", "ks"],
    description: "V čem je výtěžnost: „porce“ (výchozí), nebo „ks“ u knedlíků, housek, sušenek apod.",
  },
  prep_minutes: { type: "integer", description: "Aktivní příprava v minutách (práce u linky)." },
  cook_minutes: { type: "integer", description: "Vaření, pečení, smažení v minutách." },
  rest_minutes: {
    type: "integer",
    description:
      "Pasivní čekání v minutách: kynutí, marinování, chlazení, odpočinek. " +
      "Např. těsto kynoucí 20 hodin = 1200. Nezapočítávej ho do prep_minutes ani cook_minutes.",
  },
  temperatures: {
    type: "array",
    items: { type: "string" },
    description: "Důležité teploty, např. „Trouba 160 °C“, „Střed masa 58 °C“.",
  },
  equipment: { type: "array", items: { type: "string" }, description: "Potřebné vybavení." },
  notes: { type: "string", description: "Poznámky a tipy." },
  source_url: { type: "string", description: "Odkaz na zdroj, pokud recept z nějakého vychází." },
  ingredients: { type: "array", items: ingredientSchema },
  steps: { type: "array", items: stepSchema, description: "Postup krok za krokem." },
};

const idProperty = { type: "string", description: "Id receptu (UUID) z get_recipes nebo search_recipes." };

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  readOnly: boolean;
  destructive?: boolean;
  /** Nástroj zobrazuje fotky v okénku (MCP Apps / ChatGPT). */
  widget?: boolean;
  /** Parametry, do kterých ChatGPT předá soubor od uživatele. */
  fileParams?: string[];
  run: (db: Supabase, args: any, userId: string, fetchImpl: FetchLike) => Promise<unknown>;
}

const photoSelector = {
  photo_id: { type: "string", description: "Id fotky z get_recipe_photos." },
  position: {
    type: "integer",
    description: "Pořadí fotky (1 = hlavní, 2 = druhá…). Použij, když uživatel řekne „druhá fotka“.",
  },
};

export const tools: Tool[] = [
  {
    name: "get_recipes",
    title: "Seznam receptů",
    description:
      "Vrátí přehled receptů uložených v kuchařce HINKredience (bez surovin a postupu). " +
      "Použij, když chce uživatel vědět, co v kuchařce má, nebo když potřebuješ id receptu.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        category: { type: "string", description: "Jen recepty z této kategorie." },
        favorites_only: { type: "boolean", description: "Jen oblíbené." },
        limit: { type: "integer", description: "Max. počet (výchozí 50, nejvýše 200)." },
      },
    },
    readOnly: true,
    run: async (db, args) => {
      let path = `recipes?select=${RECIPE_SUMMARY}&deleted_at=is.null&order=updated_at.desc` +
        `&limit=${limitOf(args?.limit, 50, 200)}`;
      const category = text(args?.category, 60);
      if (category) path += `&category=eq.${encodeURIComponent(category)}`;
      if (args?.favorites_only === true) path += "&is_favorite=eq.true";
      const rows = await db.select(path);
      return { count: rows.length, recipes: rows.map((r) => presentRecipe(r, false)) };
    },
  },
  {
    name: "get_recipe",
    title: "Detail receptu",
    description:
      "Vrátí úplný recept včetně surovin, postupu, teplot a poznámek. " +
      "Použij před úpravou receptu, ať pracuješ s aktuální podobou.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: { recipe_id: idProperty },
    },
    readOnly: true,
    run: async (db, args) => ({ recipe: presentRecipe(await loadRecipe(db, requireId(args?.recipe_id)), true) }),
  },
  {
    name: "search_recipes",
    title: "Hledání v receptech",
    description:
      "Hledá v uložených receptech podle názvu, popisu, kategorie, poznámek a surovin. " +
      "Nerozlišuje diakritiku ani velikost písmen. Nehledá na internetu.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["query"],
      properties: {
        query: { type: "string", description: "Hledaný text, např. „svíčková“ nebo „kuře smetana“." },
        limit: { type: "integer", description: "Max. počet (výchozí 20, nejvýše 50)." },
      },
    },
    readOnly: true,
    run: async (db, args) => {
      const words = fold(text(args?.query, 200)).split(/\s+/).filter((w) => w);
      if (!words.length) throw new ToolError("Zadejte, co hledat.");
      const rows = await db.select(
        `recipes?select=${RECIPE_SUMMARY},notes,recipe_ingredients(name)&deleted_at=is.null` +
          "&order=updated_at.desc&limit=1000",
      );
      const matches = rows.filter((row) => {
        const haystack = fold(
          [
            row.title,
            row.description,
            row.category,
            row.notes,
            ...(Array.isArray(row.recipe_ingredients) ? row.recipe_ingredients.map((i: any) => i.name) : []),
          ].join(" "),
        );
        return words.every((word) => haystack.includes(word));
      });
      const limited = matches.slice(0, limitOf(args?.limit, 20, 50));
      return { count: limited.length, recipes: limited.map((r) => presentRecipe(r, false)) };
    },
  },
  {
    name: "create_recipe",
    title: "Uložit nový recept",
    description:
      "Uloží nový recept do kuchařky HINKredience. Použij, když uživatel řekne „ulož recept do " +
      "HINKredience“. Pošli úplný recept: suroviny s gramážemi a jednotkami, kroky s časy a teplotami. " +
      "Recept se objeví v mobilní aplikaci po synchronizaci.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["title", "ingredients", "steps"],
      properties: recipeFields,
    },
    readOnly: false,
    run: async (db, args) => {
      const recipe = cleanRecipe(args);
      if (!recipe.title) throw new ToolError("Recept musí mít název.");
      const saved = await db.rpc("api_save_recipe", {
        p_recipe: recipe,
        p_meta: { change_summary: "Vytvořeno v ChatGPT" },
      });
      return {
        saved: true,
        recipe_id: saved.id,
        version: saved.version,
        message: `Recept „${recipe.title}“ je uložený v HINKredience.`,
      };
    },
  },
  {
    name: "update_recipe",
    title: "Upravit recept",
    description:
      "Upraví uložený recept. Stačí poslat jen pole, která se mění; ostatní zůstanou. " +
      "Pozor: ingredients a steps se vždy nahrazují celým seznamem. Úprava vytvoří novou verzi, " +
      "původní podoba zůstává v historii. Vždy uveď change_summary.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "change_summary"],
      properties: {
        recipe_id: idProperty,
        change_summary: { type: "string", description: "Co se změnilo, stručně." },
        change_reason: { type: "string", description: "Proč se to změnilo." },
        ...recipeFields,
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const current = presentRecipe(await loadRecipe(db, id), true);
      const recipe = cleanRecipe(args, current);
      if (!recipe.title) throw new ToolError("Recept musí mít název.");
      const saved = await db.rpc("api_save_recipe", {
        p_recipe: recipe,
        p_recipe_id: id,
        p_meta: {
          change_summary: text(args?.change_summary, 500) || "Úprava přes ChatGPT",
          change_reason: text(args?.change_reason, 1000),
        },
      });
      return {
        saved: true,
        recipe_id: saved.id,
        version: saved.version,
        message: `Recept „${recipe.title}“ je uložený jako verze ${saved.version}. Předchozí verze zůstává v historii.`,
      };
    },
  },
  {
    name: "delete_recipe",
    title: "Přesunout recept do koše",
    description:
      "Přesune recept do koše. Recept se nemaže natrvalo – uživatel ho může obnovit v mobilní " +
      "aplikaci (Více → Koš). Použij jen na výslovnou žádost uživatele.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: { recipe_id: idProperty },
    },
    readOnly: false,
    destructive: true,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const now = new Date().toISOString();
      const rows = await db.patch(`recipes?id=eq.${id}&deleted_at=is.null`, {
        deleted_at: now,
        updated_at: now,
      });
      if (!rows.length) throw new ToolError("Recept nenalezen nebo už je v koši.");
      return { deleted: true, recipe_id: id, message: `Recept „${rows[0].title}“ je v koši a jde obnovit v aplikaci.` };
    },
  },
  {
    name: "get_recipe_versions",
    title: "Historie verzí receptu",
    description:
      "Vrátí historii verzí receptu: co se změnilo, proč, kdy, s jakým výsledkem a hodnocením. " +
      "S include_content=true vrátí i úplnou podobu každé verze (pro porovnání).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: {
        recipe_id: idProperty,
        include_content: { type: "boolean", description: "Vrátit i suroviny a postup každé verze." },
      },
    },
    readOnly: true,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const rows = await db.select(
        "recipe_versions?select=version_number,change_summary,change_reason,result_note,rating,created_at,snapshot" +
          `&recipe_id=eq.${id}&order=version_number.desc&limit=100`,
      );
      if (!rows.length) await loadRecipe(db, id);
      return {
        count: rows.length,
        versions: rows.map((row) => ({
          version: row.version_number,
          change_summary: row.change_summary ?? "",
          change_reason: row.change_reason ?? "",
          result_note: row.result_note ?? "",
          rating: row.rating ?? null,
          created_at: row.created_at,
          title: row.snapshot?.title ?? "",
          ...(args?.include_content === true
            ? {
              recipe: cleanRecipe({
                ...row.snapshot,
                servings: Number(row.snapshot?.servings) || 4,
                ingredients: (row.snapshot?.ingredients ?? []).map((i: any) => ({
                  ...i,
                  quantity: i?.quantity === null || i?.quantity === undefined ? null : Number(i.quantity),
                })),
                steps: (row.snapshot?.steps ?? []).map((s: any) => ({
                  ...s,
                  temperature_c: s?.temperature_c === null || s?.temperature_c === undefined
                    ? null
                    : Number(s.temperature_c),
                })),
              }),
            }
            : {}),
        })),
      };
    },
  },
  {
    name: "create_recipe_version",
    title: "Uložit novou verzi receptu",
    description:
      "Uloží úplně novou podobu receptu jako další verzi (např. „verze 3: změna teploty a délky " +
      "pečení“). Pošli celý recept. Uveď, co a proč se změnilo, případně jak to dopadlo a hodnocení. " +
      "Starší verze zůstávají v historii.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "change_summary", "title", "ingredients", "steps"],
      properties: {
        recipe_id: idProperty,
        change_summary: { type: "string", description: "Co se změnilo." },
        change_reason: { type: "string", description: "Proč." },
        result_note: { type: "string", description: "Jaký byl výsledek, pokud už se vařilo." },
        rating: { type: ["number", "null"], description: "Hodnocení této verze 0–5." },
        ...recipeFields,
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const recipe = cleanRecipe(args);
      if (!recipe.title) throw new ToolError("Recept musí mít název.");
      const rating = typeof args?.rating === "number" && args.rating >= 0 && args.rating <= 5 ? args.rating : null;
      const saved = await db.rpc("api_save_recipe", {
        p_recipe: recipe,
        p_recipe_id: id,
        p_meta: {
          change_summary: text(args?.change_summary, 500) || "Nová verze z ChatGPT",
          change_reason: text(args?.change_reason, 1000),
          result_note: text(args?.result_note, 2000),
          rating,
        },
      });
      return {
        saved: true,
        recipe_id: saved.id,
        version: saved.version,
        message: `Uložena verze ${saved.version} receptu „${recipe.title}“.`,
      };
    },
  },
  {
    name: "add_cooking_note",
    title: "Přidat poznámku z vaření",
    description:
      "Přidá k receptu poznámku z vaření (co se povedlo, co příště jinak). Recept samotný nemění.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "note"],
      properties: {
        recipe_id: idProperty,
        note: { type: "string", description: "Text poznámky." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const note = text(args?.note, 4000);
      if (!note) throw new ToolError("Poznámka je prázdná.");
      const recipe = await loadRecipe(db, id);
      const row = await db.insert("cooking_notes", { recipe_id: id, note });
      return { saved: true, note_id: row?.id ?? null, message: `Poznámka je uložená u receptu „${recipe.title}“.` };
    },
  },
  {
    name: "get_cooking_history",
    title: "Historie vaření",
    description:
      "Vrátí kuchařský deník: záznamy vaření (datum, skutečný čas, hodnocení, co se povedlo, co " +
      "zlepšit) a poznámky. Lze omezit na jeden recept. Používej jen tato skutečně uložená data.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        recipe_id: { ...idProperty, description: "Nepovinné: jen historie tohoto receptu." },
        limit: { type: "integer", description: "Max. počet záznamů (výchozí 20, nejvýše 100)." },
      },
    },
    readOnly: true,
    run: async (db, args) => {
      const limit = limitOf(args?.limit, 20, 100);
      const filter = args?.recipe_id === undefined || args?.recipe_id === null || args?.recipe_id === ""
        ? ""
        : `&recipe_id=eq.${requireId(args.recipe_id)}`;
      const [sessions, notes] = await Promise.all([
        db.select(
          "cooking_sessions?select=recipe_id,recipe_title,status,cooked_at,actual_minutes,actual_temperatures,rating,went_well,to_improve" +
            `${filter}&order=cooked_at.desc&limit=${limit}`,
        ),
        db.select(
          `cooking_notes?select=recipe_id,note,created_at${filter}&order=created_at.desc&limit=${limit}`,
        ),
      ]);
      return { sessions, notes };
    },
  },
  {
    name: "get_kitchen_equipment",
    title: "Kuchyňské vybavení a chutě",
    description:
      "Vrátí uložené kuchyňské vybavení (trouba, hrnce, spotřebiče a co umí) a chuťové preference " +
      "uživatele. Použij před návrhem receptu, ať ho přizpůsobíš tomu, co doma opravdu má.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    readOnly: true,
    run: async (db) => {
      const [equipment, preferences] = await Promise.all([
        db.select("kitchen_equipment?select=id,name,kind,capabilities,notes&order=position,created_at&limit=100"),
        db.select("user_preferences?select=label&enabled=eq.true&order=position,created_at&limit=100"),
      ]);
      return { equipment, taste_preferences: preferences.map((p) => p.label) };
    },
  },
  {
    name: "update_kitchen_equipment",
    title: "Upravit kuchyňské vybavení",
    description:
      "Přidá, upraví nebo odebere položku kuchyňského vybavení. action=add vyžaduje name; " +
      "action=update a action=remove vyžadují equipment_id z get_kitchen_equipment.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["add", "update", "remove"] },
        equipment_id: { type: "string", description: "Id položky (pro update a remove)." },
        name: { type: "string", description: "Název zařízení, např. „Tesla EliteCook K70“." },
        kind: { type: "string", description: "Druh, např. trouba, hrnec, pánev." },
        capabilities: { type: "array", items: { type: "string" }, description: "Co zařízení umí." },
        notes: { type: "string" },
      },
    },
    readOnly: false,
    destructive: true,
    run: async (db, args) => {
      const action = args?.action;
      const fields: Record<string, unknown> = {};
      if (args?.name !== undefined) fields.name = text(args.name, 200);
      if (args?.kind !== undefined) fields.kind = text(args.kind, 60);
      if (args?.notes !== undefined) fields.notes = text(args.notes, 1000);
      if (Array.isArray(args?.capabilities)) {
        fields.capabilities = args.capabilities.map((v: unknown) => text(v, 120)).filter((v: string) => v).slice(0, 30);
      }
      if (action === "add") {
        if (!fields.name) throw new ToolError("U nového vybavení uveďte name.");
        const row = await db.insert("kitchen_equipment", { ...fields, position: 1000 });
        return { saved: true, equipment_id: row?.id ?? null, message: `Vybavení „${fields.name}“ je přidané.` };
      }
      const id = requireId(args?.equipment_id, "equipment_id");
      if (action === "update") {
        if (fields.name === "") throw new ToolError("Název nesmí být prázdný.");
        if (!Object.keys(fields).length) throw new ToolError("Neuvedli jste, co změnit.");
        const rows = await db.patch(`kitchen_equipment?id=eq.${id}`, { ...fields, updated_at: new Date().toISOString() });
        if (!rows.length) throw new ToolError("Vybavení nenalezeno.");
        return { saved: true, equipment_id: id, message: `Vybavení „${rows[0].name}“ je upravené.` };
      }
      if (action === "remove") {
        const rows = await db.remove(`kitchen_equipment?id=eq.${id}`);
        if (!rows.length) throw new ToolError("Vybavení nenalezeno.");
        return { removed: true, equipment_id: id, message: `Vybavení „${rows[0].name}“ je odebrané.` };
      }
      throw new ToolError("Parametr action musí být add, update nebo remove.");
    },
  },
  {
    name: "list_recipes_with_photos",
    title: "Recepty s fotografiemi",
    description:
      "Ukáže recepty z kuchařky, které mají fotografie, včetně hlavní fotky. Fotky se zobrazí " +
      "uživateli v okénku a jako obrázky. Použij např. na „podívej se na fotky v mé kuchařce“.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        query: { type: "string", description: "Jen recepty, jejichž název obsahuje tento text." },
        limit: { type: "integer", description: "Max. počet receptů (výchozí 12, nejvýše 50)." },
        include_images: { type: "boolean", description: "Přiložit náhledy jako obrázky (výchozí ano)." },
      },
    },
    readOnly: true,
    widget: true,
    run: async (db, args) => {
      const rows = await db.select(
        "recipes?select=id,title,category,photos,updated_at&deleted_at=is.null&order=updated_at.desc&limit=300",
      );
      const query = fold(text(args?.query, 80));
      const limit = limitOf(args?.limit, 12, 50);
      const withPhotos = rows
        .filter((r) => photosOf(r).length > 0)
        .filter((r) => !query || fold(r.title ?? "").includes(query))
        .slice(0, limit);
      const recipes = await Promise.all(
        withPhotos.map(async (r) => {
          const photos = photosOf(r);
          const cover = photos[0];
          return {
            recipe_id: r.id,
            title: r.title,
            category: r.category ?? "",
            photo_count: photos.length,
            cover: {
              photo_id: cover.id,
              url: await db.signedUrl(cover.remote_path),
              thumbnail_url: cover.thumb_path ? await db.signedUrl(cover.thumb_path) : null,
            },
          };
        }),
      );
      const images = [];
      if (args?.include_images !== false) {
        for (const r of withPhotos.slice(0, MAX_INLINE_IMAGES)) {
          const image = await inlineImage(db, photosOf(r)[0], true);
          if (image) images.push({ title: `Hlavní fotka receptu „${r.title}“`, ...image });
        }
      }
      return new RichResult(
        {
          view: "recipes",
          count: recipes.length,
          recipes,
          note: "Odkazy na fotky platí 15 minut. Detail fotek receptu: get_recipe_photos.",
        },
        images,
      );
    },
  },
  {
    name: "get_recipe_photos",
    title: "Fotografie receptu",
    description:
      "Načte všechny fotografie jednoho receptu (pořadí, hlavní fotka) a ukáže je. " +
      "Použij např. na „vidíš novou fotku lososa?“ – nejdřív najdi id receptu přes search_recipes.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: {
        recipe_id: idProperty,
        include_images: { type: "boolean", description: "Přiložit fotky jako obrázky (výchozí ano)." },
      },
    },
    readOnly: true,
    widget: true,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const row = await loadRecipeRow(db, id);
      const photos = photosOf(row);
      const images = [];
      if (args?.include_images !== false) {
        for (const [index, photo] of photos.slice(0, MAX_INLINE_IMAGES).entries()) {
          const image = await inlineImage(db, photo, photos.length > 2);
          if (image) {
            images.push({
              title: `Fotka ${index + 1}${index === 0 ? " (hlavní)" : ""} receptu „${row.title}“`,
              ...image,
            });
          }
        }
      }
      return new RichResult(
        {
          view: "photos",
          recipe_id: id,
          title: row.title,
          photo_count: photos.length,
          photos: await describePhotos(db, photos),
          note: photos.length
            ? "Fotka 1 je hlavní. Odkazy platí 15 minut."
            : "Recept zatím nemá žádné fotky. Přidat je jde přes upload_recipe_photo nebo v aplikaci.",
        },
        images,
      );
    },
  },
  {
    name: "get_recipe_photo",
    title: "Jedna fotografie receptu",
    description:
      "Načte jednu fotografii receptu v plné kvalitě, abys ji mohl prohlédnout a posoudit " +
      "(např. propečení, barvu, servírování). Vyber ji podle photo_id nebo pořadí.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: { recipe_id: idProperty, ...photoSelector },
    },
    readOnly: true,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const row = await loadRecipeRow(db, id);
      const { photo, index } = pickPhoto(photosOf(row), args);
      const file = await db.download(photo.remote_path);
      if (!file) throw new ToolError("Soubor fotky v úložišti nebyl nalezen.");
      let image = file;
      if (file.bytes.length > MAX_INLINE_IMAGE_BYTES * 3 && photo.thumb_path) {
        image = (await db.download(photo.thumb_path)) ?? file;
      }
      return new RichResult(
        {
          recipe_id: id,
          title: row.title,
          photo_id: photo.id,
          position: index + 1,
          is_cover: index === 0,
          url: await db.signedUrl(photo.remote_path),
        },
        [{
          title: `Fotka ${index + 1}${index === 0 ? " (hlavní)" : ""} receptu „${row.title}“`,
          data: toBase64(image.bytes),
          mimeType: image.mimeType,
        }],
        false,
      );
    },
  },
  {
    name: "upload_recipe_photo",
    title: "Přidat fotografii k receptu",
    description:
      "Uloží fotografii, kterou uživatel poslal do konverzace, k receptu v kuchařce. " +
      "Předej obrázek v parametru photo (soubor z konverzace). Jiní klienti mohou poslat " +
      "image_base64 nebo veřejný https odkaz image_url. Ukládej jen na výslovnou žádost " +
      "(např. „vlož ji ke králíkovi“) a jen ke správnému receptu – při nejistotě se zeptej.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: {
        recipe_id: idProperty,
        photo: {
          type: "object",
          description: "Obrázek nahraný uživatelem do konverzace.",
          properties: {
            download_url: { type: "string" },
            file_id: { type: "string" },
            mime_type: { type: "string" },
            file_name: { type: "string" },
          },
        },
        image_url: { type: "string", description: "Veřejný https odkaz na obrázek (alternativa k photo)." },
        image_base64: { type: "string", description: "Obrázek v base64 (JPEG, PNG nebo WebP, max. 10 MB)." },
        set_as_cover: { type: "boolean", description: "Nastavit jako hlavní fotku (výchozí ne)." },
      },
    },
    readOnly: false,
    fileParams: ["photo"],
    run: async (db, args, userId, fetchImpl) => {
      const id = requireId(args?.recipe_id);
      const row = await loadRecipeRow(db, id);
      let file: { bytes: Uint8Array; mimeType: string };
      const downloadUrl = typeof args?.photo === "object" ? args.photo?.download_url : null;
      if (typeof downloadUrl === "string" && downloadUrl) {
        file = await fetchImage(fetchImpl, downloadUrl);
      } else if (typeof args?.image_url === "string" && args.image_url) {
        file = await fetchImage(fetchImpl, args.image_url);
      } else if (typeof args?.image_base64 === "string" && args.image_base64) {
        let bytes: Uint8Array;
        try {
          bytes = fromBase64(args.image_base64);
        } catch {
          throw new ToolError("image_base64 není platný base64.");
        }
        if (bytes.length > MAX_PHOTO_BYTES) throw new ToolError("Obrázek je větší než 10 MB.");
        file = { bytes, mimeType: detectImageType(bytes) ?? "" };
      } else {
        throw new ToolError("Chybí obrázek. Pošlete fotku do konverzace a zopakujte žádost.");
      }
      if (!file.mimeType) {
        throw new ToolError("Podporované jsou fotky JPEG, PNG a WebP (HEIC z iPhonu převeďte na JPEG).");
      }
      const photoId = crypto.randomUUID();
      const extension = file.mimeType === "image/png" ? "png" : file.mimeType === "image/webp" ? "webp" : "jpg";
      const path = `${userId}/${id}/${photoId}.${extension}`;
      await db.upload(path, file.bytes, file.mimeType);
      const photo: StoredPhoto = { id: photoId, remote_path: path };
      const current = photosOf(row);
      const photos = args?.set_as_cover === true ? [photo, ...current] : [...current, photo];
      try {
        await savePhotos(db, id, photos);
      } catch (error) {
        await db.removeObjects([path]);
        throw error;
      }
      const position = photos.findIndex((p) => p.id === photoId) + 1;
      return {
        saved: true,
        recipe_id: id,
        title: row.title,
        photo_id: photoId,
        position,
        is_cover: position === 1,
        size_kb: Math.round(file.bytes.length / 1024),
        message: `Fotka je uložená u receptu „${row.title}“ jako ${position}. fotka` +
          `${position === 1 ? " (hlavní)" : ""}. V aplikaci se objeví po synchronizaci (obvykle hned).`,
      };
    },
  },
  {
    name: "set_recipe_cover_photo",
    title: "Nastavit hlavní fotografii",
    description:
      "Nastaví vybranou fotku receptu jako hlavní (zobrazuje se v seznamu a nahoře v detailu). " +
      "Např. „nastav druhou fotku palačinek jako hlavní“ = position 2.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: { recipe_id: idProperty, ...photoSelector },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const row = await loadRecipeRow(db, id);
      const photos = photosOf(row);
      const { photo, index } = pickPhoto(photos, args);
      if (index > 0) {
        photos.splice(index, 1);
        photos.unshift(photo);
        await savePhotos(db, id, photos);
      }
      return {
        saved: index > 0,
        recipe_id: id,
        title: row.title,
        cover_photo_id: photo.id,
        message: index > 0
          ? `Hlavní fotka receptu „${row.title}“ je teď ta, která byla ${index + 1}. v pořadí.`
          : `Tato fotka už je u receptu „${row.title}“ hlavní.`,
      };
    },
  },
  {
    name: "reorder_recipe_photos",
    title: "Změnit pořadí fotografií",
    description:
      "Změní pořadí fotek receptu. photo_ids = id v novém pořadí (první bude hlavní); " +
      "neuvedené fotky zůstanou za nimi v původním pořadí.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "photo_ids"],
      properties: {
        recipe_id: idProperty,
        photo_ids: { type: "array", items: { type: "string" }, description: "Id fotek v novém pořadí." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const row = await loadRecipeRow(db, id);
      const photos = photosOf(row);
      const wanted: string[] = Array.isArray(args?.photo_ids) ? args.photo_ids.filter((v: unknown) => typeof v === "string") : [];
      const unknown = wanted.filter((pid) => !photos.some((p) => p.id === pid));
      if (unknown.length) throw new ToolError(`Neznámá id fotek: ${unknown.join(", ")}.`);
      const ordered = [
        ...[...new Set(wanted)].map((pid) => photos.find((p) => p.id === pid)!),
        ...photos.filter((p) => !wanted.includes(p.id)),
      ];
      await savePhotos(db, id, ordered);
      return {
        saved: true,
        recipe_id: id,
        order: ordered.map((p, i) => ({ position: i + 1, photo_id: p.id })),
        message: `Pořadí fotek receptu „${row.title}“ je uložené.`,
      };
    },
  },
  {
    name: "delete_recipe_photo",
    title: "Odebrat fotografii z receptu",
    description:
      "Odebere fotku z receptu. Soubor se smaže z úložiště jen tehdy, když ho nepoužívá žádná " +
      "uložená verze receptu. Použij jen na výslovnou žádost uživatele.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: { recipe_id: idProperty, ...photoSelector },
    },
    readOnly: false,
    destructive: true,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const row = await loadRecipeRow(db, id);
      const photos = photosOf(row);
      const { photo, index } = pickPhoto(photos, args);
      photos.splice(index, 1);
      await savePhotos(db, id, photos);
      // Fotku, kterou zná historie verzí, necháme v úložišti (obnova verze).
      const inHistory = await db.select(
        `recipe_versions?select=id&recipe_id=eq.${id}&snapshot=cs.${
          encodeURIComponent(JSON.stringify({ photos: [{ remote_path: photo.remote_path }] }))
        }&limit=1`,
      );
      if (!inHistory.length && photo.remote_path.startsWith(`${row.owner_id}/`)) {
        await db.removeObjects([photo.remote_path, ...(photo.thumb_path ? [photo.thumb_path] : [])]);
      }
      return {
        deleted: true,
        recipe_id: id,
        photo_id: photo.id,
        remaining: photos.length,
        file_kept_for_history: inHistory.length > 0,
        message: `Fotka ${index + 1} je z receptu „${row.title}“ odebraná.`,
      };
    },
  },
];

const instructions =
  "HINKredience° je osobní kuchařka Pavla Hinka sdílená s mobilní aplikací. " +
  "Recepty ukládej česky, s přesnými gramážemi, teplotami ve °C a časy. " +
  "Před návrhem receptu si přes get_kitchen_equipment zjisti vybavení a chutě. " +
  "Než recept upravíš, načti ho přes get_recipe. Úpravy vždy vytvářejí novou verzi, nic se nepřepisuje. " +
  "Nevymýšlej si uložené recepty ani historii – používej jen data z nástrojů. " +
  "Ukládej a maž jen na výslovnou žádost uživatele. " +
  "Fotky receptů: přehled list_recipes_with_photos, fotky jednoho receptu get_recipe_photos, " +
  "prohlédnutí jedné fotky get_recipe_photo, nahrání fotky z konverzace upload_recipe_photo, " +
  "hlavní fotka set_recipe_cover_photo (první fotka = hlavní).";

function toolList() {
  return tools.map((tool) => ({
    name: tool.name,
    title: tool.title,
    description: tool.description,
    inputSchema: tool.inputSchema,
    annotations: {
      title: tool.title,
      readOnlyHint: tool.readOnly,
      destructiveHint: tool.readOnly ? false : tool.destructive === true,
      idempotentHint: tool.readOnly,
      openWorldHint: false,
    },
    securitySchemes: [{ type: "oauth2", scopes: [] }],
    ...(tool.widget || tool.fileParams
      ? {
        _meta: {
          ...(tool.widget
            ? {
              ui: { resourceUri: PHOTOS_WIDGET_URI },
              "openai/outputTemplate": PHOTOS_WIDGET_URI,
              "openai/toolInvocation/invoking": "Načítám fotky…",
              "openai/toolInvocation/invoked": "Fotky načtené",
            }
            : {}),
          ...(tool.fileParams ? { "openai/fileParams": tool.fileParams } : {}),
        },
      }
      : {}),
  }));
}

/** Okénko s fotkami (MCP Apps). Obrázky načítá jen z úložiště projektu. */
export function photosWidgetHtml(env: Env): string {
  const origin = new URL(env.supabaseUrl).origin;
  return `<!doctype html>
<html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
  body { margin: 0; padding: 12px; background: transparent; }
  h2 { font-size: 15px; margin: 0 0 10px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; }
  figure { margin: 0; border-radius: 12px; overflow: hidden; background: rgba(127,127,127,.12); }
  img { display: block; width: 100%; aspect-ratio: 4 / 3; object-fit: cover; }
  figcaption { font-size: 12.5px; padding: 6px 8px; line-height: 1.3; }
  .cover { color: #c98a4b; font-weight: 600; }
  .empty { opacity: .7; font-size: 13px; }
</style></head>
<body><div id="root"><p class="empty">Načítám fotky…</p></div>
<script>
  const ORIGIN = ${JSON.stringify(origin)};
  const root = document.getElementById("root");
  const safe = (url) => typeof url === "string" && url.startsWith(ORIGIN + "/") ? url : null;
  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }
  function render(data) {
    if (!data || typeof data !== "object") return;
    root.replaceChildren();
    const items = data.view === "photos"
      ? (data.photos || []).map((p) => ({ url: p.thumbnail_url || p.url, full: p.url, label: p.is_cover ? "Hlavní fotka" : "Fotka " + p.position, cover: p.is_cover }))
      : (data.recipes || []).map((r) => ({ url: r.cover && (r.cover.thumbnail_url || r.cover.url), full: r.cover && r.cover.url, label: r.title + " · " + r.photo_count + " fot.", cover: false }));
    if (data.view === "photos") root.append(el("h2", "", data.title || "Fotky receptu"));
    if (!items.length) { root.append(el("p", "empty", "Žádné fotky.")); return; }
    const grid = el("div", "grid");
    for (const item of items) {
      const src = safe(item.url) || safe(item.full);
      if (!src) continue;
      const figure = el("figure");
      const img = el("img"); img.src = src; img.alt = item.label; img.loading = "lazy";
      figure.append(img, el("figcaption", item.cover ? "cover" : "", item.label));
      grid.append(figure);
    }
    root.append(grid);
  }
  // ChatGPT (window.openai) i standard MCP Apps (postMessage).
  if (window.openai && window.openai.toolOutput) render(window.openai.toolOutput);
  window.addEventListener("openai:set_globals", () => window.openai && render(window.openai.toolOutput));
  window.addEventListener("message", (event) => {
    if (event.source !== window.parent) return;
    const msg = event.data;
    if (!msg || msg.jsonrpc !== "2.0") return;
    if (msg.method === "ui/notifications/tool-result") render(msg.params && msg.params.structuredContent);
    if (msg.id === 1 && msg.result) window.parent.postMessage({ jsonrpc: "2.0", method: "ui/notifications/initialized" }, "*");
  });
  window.parent.postMessage({ jsonrpc: "2.0", id: 1, method: "ui/initialize", params: {
    protocolVersion: "2026-01-26",
    appInfo: { name: "hinkredience-photos", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline"] },
  } }, "*");
</script></body></html>`;
}

function widgetResource(env: Env) {
  const origin = new URL(env.supabaseUrl).origin;
  return {
    uri: PHOTOS_WIDGET_URI,
    name: "Fotky receptů",
    mimeType: "text/html;profile=mcp-app",
    _meta: {
      ui: { csp: { resourceDomains: [origin] }, prefersBorder: true },
      "openai/widgetCSP": { resource_domains: [origin], connect_domains: [] },
      "openai/widgetDescription": "Mřížka fotografií receptů z kuchařky HINKredience.",
    },
  };
}

// ---------------------------------------------------------------- protokol

function rpcResult(id: unknown, result: unknown) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: unknown, code: number, message: string) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}

function jsonResponse(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8", ...extra },
  });
}

export function resourceMetadata(env: Env) {
  return {
    resource: env.publicUrl,
    authorization_servers: [`${env.supabaseUrl}/auth/v1`],
    bearer_methods_supported: ["header"],
    resource_name: "HINKredience°",
  };
}

function metadataUrl(env: Env): string {
  return `${env.publicUrl}/.well-known/oauth-protected-resource`;
}

function unauthorized(env: Env, description: string): Response {
  return jsonResponse(
    401,
    { error: "unauthorized", error_description: description },
    {
      "WWW-Authenticate":
        `Bearer resource_metadata="${metadataUrl(env)}", error="invalid_token", error_description="${description}"`,
    },
  );
}

async function handleMessage(
  message: any,
  db: Supabase,
  userId: string,
  env: Env,
  fetchImpl: FetchLike,
): Promise<unknown | null> {
  const id = message?.id;
  const isNotification = id === undefined || id === null;
  if (message?.jsonrpc !== "2.0" || typeof message?.method !== "string") {
    return isNotification ? null : rpcError(id, -32600, "Neplatný požadavek JSON-RPC.");
  }
  switch (message.method) {
    case "initialize": {
      const requested = message.params?.protocolVersion;
      return rpcResult(id, {
        protocolVersion: PROTOCOL_VERSIONS.includes(requested) ? requested : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false }, resources: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, title: "HINKredience°", version: SERVER_VERSION },
        instructions,
      });
    }
    case "ping":
      return rpcResult(id, {});
    case "tools/list":
      return rpcResult(id, { tools: toolList() });
    case "tools/call": {
      const tool = tools.find((t) => t.name === message.params?.name);
      if (!tool) return rpcError(id, -32602, `Neznámý nástroj: ${message.params?.name}`);
      try {
        const result = await tool.run(db, message.params?.arguments ?? {}, userId, fetchImpl);
        if (result instanceof RichResult) {
          const content: unknown[] = [{ type: "text", text: JSON.stringify(result.data) }];
          for (const image of result.images) {
            content.push({ type: "text", text: image.title });
            content.push({ type: "image", data: image.data, mimeType: image.mimeType });
          }
          return rpcResult(id, {
            content,
            ...(result.structured ? { structuredContent: result.data } : {}),
            isError: false,
          });
        }
        return rpcResult(id, {
          content: [{ type: "text", text: JSON.stringify(result) }],
          structuredContent: result,
          isError: false,
        });
      } catch (error) {
        if (error instanceof AuthError) throw error;
        const text = error instanceof ToolError
          ? error.message
          : "Na serveru HINKredience došlo k neočekávané chybě.";
        if (!(error instanceof ToolError)) console.error("Chyba nástroje", tool.name, error);
        return rpcResult(id, { content: [{ type: "text", text }], isError: true });
      }
    }
    case "resources/list":
      return rpcResult(id, { resources: [widgetResource(env)] });
    case "resources/templates/list":
      return rpcResult(id, { resourceTemplates: [] });
    case "resources/read": {
      if (message.params?.uri !== PHOTOS_WIDGET_URI) {
        return rpcError(id, -32002, "Zdroj nenalezen.");
      }
      const resource = widgetResource(env);
      return rpcResult(id, {
        contents: [{
          uri: resource.uri,
          mimeType: resource.mimeType,
          text: photosWidgetHtml(env),
          _meta: resource._meta,
        }],
      });
    }
    default:
      if (isNotification) return null; // notifications/initialized apod.
      if (message.method.startsWith("resources/") || message.method.startsWith("prompts/")) {
        const key = message.method.startsWith("resources/") ? "resources" : "prompts";
        if (message.method.endsWith("/list")) return rpcResult(id, { [key]: [] });
      }
      return rpcError(id, -32601, `Metoda ${message.method} není podporována.`);
  }
}

export async function handle(req: Request, env: Env, fetchImpl: FetchLike = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });

  const path = new URL(req.url).pathname;
  if (req.method === "GET" && path.includes("/.well-known/oauth-protected-resource")) {
    return jsonResponse(200, resourceMetadata(env), { "Cache-Control": "public, max-age=300" });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" }, { Allow: "POST, OPTIONS" });
  }

  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!token) return unauthorized(env, "Chybi pristupovy token.");

  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) {
    return jsonResponse(413, rpcError(null, -32600, "Požadavek je příliš velký."));
  }
  let payload: any;
  try {
    payload = JSON.parse(raw);
  } catch {
    return jsonResponse(400, rpcError(null, -32700, "Neplatný JSON."));
  }

  const scopedEnv = { ...env, anonKey: env.anonKey || (req.headers.get("apikey") ?? "") };
  const db = new Supabase(scopedEnv, token, fetchImpl);
  try {
    const userId = await db.userId();
    if (Array.isArray(payload)) {
      const results = [];
      for (const message of payload.slice(0, 20)) {
        const result = await handleMessage(message, db, userId, scopedEnv, fetchImpl);
        if (result !== null) results.push(result);
      }
      return results.length ? jsonResponse(200, results) : new Response(null, { status: 202, headers: corsHeaders });
    }
    const result = await handleMessage(payload, db, userId, scopedEnv, fetchImpl);
    return result === null
      ? new Response(null, { status: 202, headers: corsHeaders })
      : jsonResponse(200, result);
  } catch (error) {
    if (error instanceof AuthError) return unauthorized(env, "Pristupovy token je neplatny nebo vyprsel.");
    if (error instanceof ToolError) return jsonResponse(503, rpcError(payload?.id, -32000, error.message));
    console.error("Neočekávaná chyba:", error);
    return jsonResponse(500, rpcError(payload?.id, -32603, "Vnitřní chyba serveru."));
  }
}

export function envFromDeno(get: (name: string) => string | undefined): Env {
  const supabaseUrl = (get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  return {
    supabaseUrl,
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    publicUrl: (get("MCP_PUBLIC_URL") || `${supabaseUrl}/functions/v1/mcp`).replace(/\/+$/, ""),
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

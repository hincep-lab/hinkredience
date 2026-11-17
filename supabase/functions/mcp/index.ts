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
export const SERVER_VERSION = "1.4.0";
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
  // Štítky se posílají jen tehdy, když je klient uvedl – jinak je databáze
  // ponechá beze změny (starší klienti o nich nevědí).
  if (Array.isArray(raw?.tags)) result.tags = cleanTags(raw.tags);
  return result;
}

/** Způsoby přípravy, podle kterých filtruje aplikace. */
export const PREP_TAGS = ["Trouba", "Pánev", "Sous-vide", "Gril", "Pomalé vaření"];

/** Příležitosti, podle kterých filtruje aplikace. */
export const OCCASION_TAGS = [
  "Rychlá večeře",
  "Rodinný oběd",
  "Pro děti",
  "Nedělní oběd",
  "Slavnostní jídlo",
  "Na více dní",
  "Sladká snídaně",
];

/** Štítky: oříznuté, bez duplicit, nejvýš 30. Známé štítky v přesném tvaru. */
export function cleanTags(value: unknown): string[] {
  const known = [...PREP_TAGS, ...OCCASION_TAGS];
  const out: string[] = [];
  for (const item of Array.isArray(value) ? value : []) {
    let tag = text(item, 40);
    if (!tag) continue;
    const canonical = known.find((k) => fold(k) === fold(tag));
    if (canonical) tag = canonical;
    if (!out.some((t) => fold(t) === fold(tag))) out.push(tag);
    if (out.length >= 30) break;
  }
  return out;
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
    tags: Array.isArray(row.tags) ? row.tags : [],
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
    if (/(deleted_at|synced_at|note).*(does not exist|could not find)|could not find the '.*' column/i.test(message)) {
      throw new ToolError(
        "Na serveru ještě chybí migrace pro nákupní seznamy (09 a 10). Spusťte je v Supabase.",
      );
    }
    if (/Vlastníka nákupního seznamu/.test(message)) throw new ToolError(message);
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

  /** Zavolá jinou serverovou funkci projektu s tokenem uživatele. */
  async callFunction(name: string, body: Record<string, unknown>): Promise<any> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/functions/v1/${name}`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(body),
    });
    if (response.status === 401) throw new AuthError("Přístupový token vypršel.");
    let data: any = null;
    try {
      data = await response.json();
    } catch {
      // odpověď není JSON
    }
    if (!response.ok) {
      throw new ToolError(typeof data?.error === "string" ? data.error : "Služba cen teď neodpovídá.");
    }
    return data;
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


// --------------------------------------------------------- nákupní seznamy

export const SHOPPING_CATEGORIES = ["maso", "zelenina", "mlecne", "koreni", "ostatni"];
const CATEGORY_LABELS: Record<string, string> = {
  maso: "Maso a ryby",
  zelenina: "Zelenina a ovoce",
  mlecne: "Mléčné výrobky a vejce",
  koreni: "Koření",
  ostatni: "Ostatní",
};
const MAX_ITEMS_PER_CALL = 100;

const OTHER_FIRST = [
  "olej", "vyvar", "bujon", "demi", "glace", "mouk", "cukr", "ocet", "testovin", "rizot", "ryze",
  "chleb", "pecivo", "rohlik", "knedl", "kecup", "horcic", "vino", "pivo", "drozd", "prasek", "skrob",
  "cokolad", "kakao", "konzerv", "pyre", "protlak", "omack", "drobk", "strouhank",
];
const SPICES = [
  "paprika mleta", "mleta paprika", "mlety pepr", "sul", "pepr", "koreni", "bobkov", "kmin", "majorank",
  "oregano", "tymian", "rozmar", "bazalk", "skoric", "hrebicek", "muskat", "chilli", "kari", "curry",
  "zazvor mlet", "vanilk", "badyan", "jalovec", "kurkum", "paprika sladka", "sladka paprika",
  "uzena paprika", "feferonk susen",
];
const DAIRY = [
  "mlek", "mleko", "smetan", "maslo", "masla", "syr", "jogurt", "tvaroh", "vejce", "vajec", "vajic",
  "zloutk", "bilk", "mascarpone", "ricott", "mozzarell", "parmazan", "eidam", "cottage", "kefir",
  "podmasl", "zakys",
];
const MEAT = [
  "maso", "masa", "kure", "kurec", "kurat", "krut", "kachn", "husa", "husi", "hovez", "veprov", "teleci",
  "jehne", "kralik", "zverin", "srnci", "divoc", "slanin", "sunk", "klobas", "parek", "parky", "salam",
  "mlete", "steh", "prsa", "prsni", "kridl", "zebr", "krkovic", "panenk", "svickov", "rostenc", "ryba",
  "ryby", "losos", "pstruh", "kapr", "tunak", "treska", "krevet", "jatra", "jater", "anglick",
];
const VEGETABLES = [
  "cibul", "cesnek", "paprik", "mrkev", "mrkv", "brambor", "rajc", "okurk", "zeli", "kapust", "celer",
  "petrzel", "porek", "salat", "spenat", "rukol", "cuket", "lilek", "dyne", "brokolic", "kvetak",
  "hrasek", "fazol", "cocka", "kukuric", "houb", "zampion", "zazvor", "chilli paprick", "jablk",
  "hrusk", "citron", "limet", "pomeranc", "banan", "jahod", "boruvk", "malin", "svestk", "merunk",
  "hrozn", "avokad", "pazitk", "kopr", "redkvick", "repa", "salotk", "ovoce", "zelenin",
];

/** Kategorie podle názvu suroviny (stejná pravidla jako v aplikaci). */
export function guessCategory(name: string): string {
  const text = ` ${fold(name).replace(/[^a-z0-9% ]/g, " ")} `;
  const any = (stems: string[]) => stems.some((s) => text.includes(s));
  if (any(OTHER_FIRST)) return "ostatni";
  if (any(SPICES)) return "koreni";
  if (any(DAIRY)) return "mlecne";
  if (any(MEAT)) return "maso";
  if (any(VEGETABLES)) return "zelenina";
  return "ostatni";
}

const MASS: Record<string, number> = { g: 1, dkg: 10, dag: 10, kg: 1000 };
const VOLUME: Record<string, number> = { ml: 1, cl: 10, dl: 100, l: 1000 };

/** Sjednotí zápis jednotky: „litry“ → l, „gramů“ → g, „ks.“ → ks. */
export function normalizeUnit(unit: unknown): string {
  const raw = typeof unit === "string" ? unit.trim() : "";
  const folded = fold(raw).replace(/\.$/, "");
  if (/^(l|litr|litru|litry|litrů|litrech)$/.test(folded) || folded.startsWith("litr")) return "l";
  if (folded.startsWith("mililitr")) return "ml";
  if (folded.startsWith("decilitr")) return "dl";
  if (folded.startsWith("kilogram") || folded === "kila" || folded === "kilo") return "kg";
  if (folded.startsWith("gram")) return "g";
  if (folded.startsWith("dekagram") || folded === "deka") return "dkg";
  if (folded === "kus" || folded === "kusy" || folded === "kusu" || folded === "kusů") return "ks";
  return raw.slice(0, 40);
}

/** Převod na gramy / mililitry, aby šla množství sčítat. */
export function toBaseUnit(quantity: number, unit: string): { quantity: number; unit: string } {
  const key = fold(unit.trim()).replace(/\.$/, "");
  if (key in MASS) return { quantity: quantity * MASS[key], unit: "g" };
  if (key in VOLUME) return { quantity: quantity * VOLUME[key], unit: "ml" };
  return { quantity, unit: unit.trim() };
}

function formatNumber(value: number): string {
  const rounded = Math.round(value * 100) / 100;
  return String(rounded).replace(".", ",");
}

/** „1,5 kg“, „500 g“, „2,5 l“, „5 kuliček“, „“ (bez množství). */
export function formatShoppingAmount(quantity: number | null, unit: string): string {
  if (quantity === null || quantity === undefined || !(quantity > 0)) return unit.trim();
  const key = fold(unit.trim());
  if (key === "g" && quantity >= 1000) return `${formatNumber(quantity / 1000)} kg`;
  if (key === "ml" && quantity >= 1000) return `${formatNumber(quantity / 1000)} l`;
  return unit.trim() ? `${formatNumber(quantity)} ${unit.trim()}` : formatNumber(quantity);
}

interface ShoppingDraft {
  name: string;
  quantity: number | null;
  unit: string;
  category: string;
  note: string;
  source: string;
}

/** Ověří a očistí položky od klienta. */
export function cleanShoppingItems(raw: unknown, source = ""): ShoppingDraft[] {
  if (!Array.isArray(raw)) throw new ToolError("Parametr items musí být seznam položek.");
  if (raw.length > MAX_ITEMS_PER_CALL) throw new ToolError(`Najednou lze přidat nejvýše ${MAX_ITEMS_PER_CALL} položek.`);
  return raw.map((item: any) => {
    const name = text(item?.name, 200);
    if (!name) throw new ToolError("Každá položka musí mít name.");
    const q = item?.quantity;
    if (q !== undefined && q !== null && !(typeof q === "number" && Number.isFinite(q) && q >= 0 && q <= 1_000_000)) {
      throw new ToolError(`Množství u „${name}“ musí být číslo od 0 do 1 000 000.`);
    }
    const category = typeof item?.category === "string" && SHOPPING_CATEGORIES.includes(item.category)
      ? item.category
      : guessCategory(name);
    return {
      name,
      quantity: typeof q === "number" && q > 0 ? q : null,
      unit: normalizeUnit(item?.unit),
      category,
      note: text(item?.note, 500),
      source,
    };
  });
}

function nameKey(name: string): string {
  return fold(name.trim()).replace(/\s+/g, " ");
}

/**
 * Sloučí suroviny s nenakoupenými položkami seznamu: stejný název a
 * sčitatelná jednotka (g + kg, ml + l) se sečte, jinak vznikne nová položka.
 */
export function planShoppingMerge(existing: any[], drafts: ShoppingDraft[], merge = true) {
  const open = existing
    .filter((i) => !i.is_checked && !i.deleted_at)
    .map((i) => ({ ...i, sources: Array.isArray(i.sources) ? [...i.sources] : [] }));
  const inserts: any[] = [];
  const updates = new Map<string, any>();
  const merged: string[] = [];
  for (const draft of drafts) {
    const base = draft.quantity === null ? null : toBaseUnit(draft.quantity, draft.unit);
    let target: any = null;
    if (merge) {
      for (const item of [...open, ...inserts]) {
        if (nameKey(item.name) !== nameKey(draft.name)) continue;
        if (base === null || item.quantity === null || item.quantity === undefined) {
          target = item;
          break;
        }
        const itemBase = toBaseUnit(Number(item.quantity), item.unit ?? "");
        if (fold(itemBase.unit) === fold(base.unit)) {
          target = item;
          break;
        }
      }
    }
    if (!target) {
      inserts.push({
        name: draft.name,
        quantity: base?.quantity ?? null,
        unit: base?.unit ?? draft.unit,
        category: draft.category,
        note: draft.note,
        sources: draft.source ? [draft.source] : [],
      });
      continue;
    }
    if (base !== null) {
      if (target.quantity === null || target.quantity === undefined) {
        target.quantity = base.quantity;
        target.unit = base.unit;
      } else {
        const targetBase = toBaseUnit(Number(target.quantity), target.unit ?? "");
        target.quantity = targetBase.quantity + base.quantity;
        target.unit = targetBase.unit;
      }
    }
    if (draft.source && !target.sources.includes(draft.source)) target.sources.push(draft.source);
    if (target.id) {
      updates.set(target.id, target);
      merged.push(target.name);
    }
  }
  return { inserts, updates: [...updates.values()], merged };
}

function presentItem(row: any) {
  const quantity = row.quantity === null || row.quantity === undefined ? null : Number(row.quantity);
  return {
    item_id: row.id,
    name: row.name,
    quantity,
    unit: row.unit ?? "",
    amount: formatShoppingAmount(quantity, row.unit ?? ""),
    category: SHOPPING_CATEGORIES.includes(row.category) ? row.category : guessCategory(row.name ?? ""),
    note: row.note ?? "",
    checked: row.is_checked === true,
    from_recipes: Array.isArray(row.sources) ? row.sources : [],
  };
}

async function shoppingItems(db: Supabase, listId: string): Promise<any[]> {
  return await db.select(
    `shopping_items?select=id,name,quantity,unit,category,note,is_checked,sources,created_at,deleted_at` +
      `&list_id=eq.${listId}&deleted_at=is.null&order=created_at.asc&limit=1000`,
  );
}

/** Seznam podle id, názvu, jinak naposledy upravený. */
async function resolveList(db: Supabase, args: any, required = true): Promise<any | null> {
  if (typeof args?.list_id === "string" && args.list_id) {
    const id = requireId(args.list_id, "list_id");
    const rows = await db.select(`shopping_lists?select=id,name,household_id,updated_at&id=eq.${id}&deleted_at=is.null&limit=1`);
    if (!rows.length) throw new ToolError("Nákupní seznam nenalezen. Zjistěte id přes get_shopping_lists.");
    return rows[0];
  }
  const lists = await db.select(
    "shopping_lists?select=id,name,household_id,updated_at&deleted_at=is.null&order=updated_at.desc&limit=200",
  );
  const wanted = text(args?.list_name, 120);
  if (wanted) {
    const key = nameKey(wanted);
    const found = lists.find((l) => nameKey(l.name) === key) ?? lists.find((l) => nameKey(l.name).includes(key));
    if (found) return found;
    if (required) throw new ToolError(`Seznam „${wanted}“ nenalezen. Seznamy: ${lists.map((l) => l.name).join(", ") || "žádné"}.`);
    return null;
  }
  if (!lists.length) {
    if (required) throw new ToolError("Zatím nemáte žádný nákupní seznam. Vytvořte ho přes create_shopping_list.");
    return null;
  }
  return lists[0];
}

async function touchList(db: Supabase, listId: string) {
  await db.patch(`shopping_lists?id=eq.${listId}`, { updated_at: new Date().toISOString() });
}

/** Uloží výsledek sloučení a vrátí přehled. */
async function applyShoppingMerge(db: Supabase, list: any, drafts: ShoppingDraft[], merge: boolean) {
  const existing = await shoppingItems(db, list.id);
  const plan = planShoppingMerge(existing, drafts, merge);
  const now = new Date().toISOString();
  for (const item of plan.updates) {
    await db.patch(`shopping_items?id=eq.${item.id}&list_id=eq.${list.id}`, {
      quantity: item.quantity,
      unit: item.unit ?? "",
      sources: item.sources,
      updated_at: now,
    });
  }
  if (plan.inserts.length) {
    const position = existing.length;
    for (const [index, item] of plan.inserts.entries()) {
      await db.insert("shopping_items", {
        list_id: list.id,
        ...item,
        is_checked: false,
        position: position + index,
        created_at: now,
        updated_at: now,
      });
    }
  }
  await touchList(db, list.id);
  if (plan.inserts.length && list.household_id) {
    // Oznámení rodině (web push). Chyba oznámení nesmí zastavit nákup.
    await announce(db, plan.inserts.map((i: any) => ({ kind: "shopping", title: String(i.name ?? "") })));
  }
  return { added: plan.inserts.length, merged: plan.merged };
}

/** Dá vědět ostatním v rodině (serverová funkce push); chyby ignoruje. */
async function announce(db: Supabase, items: { kind: string; title: string }[]): Promise<void> {
  const clean = items.filter((i) => i.title.trim()).slice(0, 50);
  if (!clean.length) return;
  try {
    await db.callFunction("push", { action: "notify", items: clean });
  } catch {
    // oznámení jsou bonus
  }
}

async function presentList(db: Supabase, list: any) {
  const rows = await shoppingItems(db, list.id);
  const items = rows.map(presentItem);
  const order = (c: string) => SHOPPING_CATEGORIES.indexOf(c);
  items.sort((a, b) => order(a.category) - order(b.category));
  const remaining = items.filter((i) => !i.checked);
  return {
    list_id: list.id,
    name: list.name,
    shared_with_family: list.household_id !== null && list.household_id !== undefined,
    remaining_count: remaining.length,
    total_count: items.length,
    to_buy: remaining.map((i) => `${i.name}${i.amount ? ` – ${i.amount}` : ""}${i.note ? ` (${i.note})` : ""}`),
    categories: SHOPPING_CATEGORIES
      .map((c) => ({ category: c, label: CATEGORY_LABELS[c], items: items.filter((i) => i.category === c) }))
      .filter((g) => g.items.length),
  };
}

/** Položka podle id, nebo podle názvu v seznamu (nenakoupené mají přednost). */
async function resolveItem(db: Supabase, args: any) {
  if (typeof args?.item_id === "string" && args.item_id) {
    const id = requireId(args.item_id, "item_id");
    const rows = await db.select(
      `shopping_items?select=id,list_id,name,quantity,unit,category,note,is_checked,sources&id=eq.${id}&deleted_at=is.null&limit=1`,
    );
    if (!rows.length) throw new ToolError("Položka nenalezena. Zjistěte item_id přes get_shopping_list.");
    return rows[0];
  }
  const name = text(args?.name ?? args?.item_name, 200);
  if (!name) throw new ToolError("Uveďte item_id, nebo název položky (name).");
  const list = await resolveList(db, args);
  const rows = await shoppingItems(db, list.id);
  const key = nameKey(name);
  const candidates = rows.filter((r) => nameKey(r.name) === key);
  const loose = candidates.length ? candidates : rows.filter((r) => nameKey(r.name).includes(key));
  if (!loose.length) throw new ToolError(`Položka „${name}“ v seznamu „${list.name}“ není.`);
  const open = loose.filter((r) => !r.is_checked);
  const pool = open.length ? open : loose;
  if (pool.length > 1 && !candidates.length) {
    throw new ToolError(`Název „${name}“ odpovídá více položkám: ${pool.map((r) => r.name).join(", ")}. Upřesněte.`);
  }
  return { ...pool[0], list_id: list.id };
}

const listSelector = {
  list_id: { type: "string", description: "Id seznamu z get_shopping_lists." },
  list_name: { type: "string", description: "Název seznamu (když neznáš id). Bez obou = naposledy upravený seznam." },
};

const shoppingItemSchema = {
  type: "object",
  additionalProperties: false,
  required: ["name"],
  properties: {
    name: { type: "string", description: "Název, např. „Mléko“, „Kuřecí stehna s kostí“." },
    quantity: { type: ["number", "null"], description: "Množství jako číslo; null u „podle chuti“." },
    unit: { type: "string", description: "g, kg, ml, l, ks, kuliček, lžíce… nebo prázdné." },
    category: {
      type: "string",
      enum: SHOPPING_CATEGORIES,
      description: "maso, zelenina, mlecne, koreni, ostatni. Vynech = zařadí se podle názvu.",
    },
    note: { type: "string", description: "Upřesnění, např. „podle chuti“, „31 %“." },
  },
};


// ------------------------------------------------- import receptu z odkazu

const MAX_PAGE_BYTES = 3 * 1024 * 1024;

/** Odkaz na veřejnou stránku: http(s), žádné IP adresy ani vnitřní servery. */
export function isSafePageUrl(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") || url.username || url.password) return false;
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (!host.includes(".") || host.endsWith(".local") || host.endsWith(".internal") || host === "localhost") {
    return false;
  }
  if (/^[\d.]+$/.test(host) || host.includes(":")) return false;
  return true;
}

async function fetchPage(fetchImpl: FetchLike, url: string): Promise<{ html: string; url: string }> {
  let current = url;
  for (let hop = 0; hop < 4; hop++) {
    if (!isSafePageUrl(current)) throw new ToolError("Odkaz musí vést na veřejnou webovou stránku (http/https).");
    let response: Response;
    try {
      response = await fetchImpl(current, {
        redirect: "manual",
        headers: {
          Accept: "text/html,application/xhtml+xml",
          "Accept-Language": "cs,en;q=0.8",
          "User-Agent": "Mozilla/5.0 (compatible; HINKredience/1.3; +https://hincep-lab.github.io/hinkredience-login/)",
        },
        signal: AbortSignal.timeout(20_000),
      });
    } catch {
      throw new ToolError("Stránku se nepodařilo načíst. Zkontrolujte odkaz.");
    }
    if (response.status >= 300 && response.status < 400) {
      const next = response.headers.get("location");
      if (!next) break;
      current = new URL(next, current).toString();
      continue;
    }
    if (!response.ok) throw new ToolError(`Stránku se nepodařilo načíst (HTTP ${response.status}).`);
    const reader = response.body?.getReader();
    if (!reader) throw new ToolError("Stránka je prázdná.");
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > MAX_PAGE_BYTES) {
        await reader.cancel();
        break;
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return { html: new TextDecoder("utf-8").decode(bytes), url: current };
  }
  throw new ToolError("Odkaz přesměrovává příliš mnohokrát.");
}

export function decodeEntities(value: string): string {
  return value
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");
}

function stripTags(value: string): string {
  return decodeEntities(value.replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, " ")).replace(/[ \t]+/g, " ").trim();
}

/** ISO 8601 doba („PT1H30M“) na minuty. */
export function isoMinutes(value: unknown): number {
  if (typeof value !== "string") return 0;
  const m = value.match(/^P(?:(\d+)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+)S)?)?$/i);
  if (!m) return 0;
  const minutes = Number(m[1] ?? 0) * 1440 + Number(m[2] ?? 0) * 60 + Number(m[3] ?? 0) + Number(m[4] ?? 0) / 60;
  return Math.round(minutes);
}

const UNIT_WORDS: Record<string, string> = {
  g: "g", gr: "g", gram: "g", gramy: "g", gramu: "g", "gramů": "g",
  kg: "kg", dkg: "dkg", dag: "dkg", deka: "dkg",
  ml: "ml", cl: "cl", dl: "dl", l: "l", litr: "l", litry: "l", "litrů": "l", litru: "l",
  ks: "ks", kus: "ks", kusy: "ks", "kusů": "ks", kusu: "ks",
  "lžíce": "lžíce", "lžic": "lžíce", "lžíci": "lžíce", "lž": "lžíce", pl: "lžíce", "polévková": "lžíce",
  "lžička": "lžička", "lžičky": "lžička", "lžiček": "lžička", "lžičku": "lžička", kl: "lžička", "čl": "lžička",
  "hrnek": "hrnek", "hrnky": "hrnek", "hrnku": "hrnek", "hrnků": "hrnek", "šálek": "hrnek",
  "špetka": "špetka", "špetku": "špetka", "špetky": "špetka",
  "stroužek": "stroužek", "stroužky": "stroužek", "stroužků": "stroužek",
  "plátek": "plátek", "plátky": "plátek", "plátků": "plátek",
  "balení": "balení", "bal": "balení", "plechovka": "plechovka", "plechovky": "plechovka",
  "svazek": "svazek", "hrst": "hrst", "hrsti": "hrst", "snítka": "snítka", "snítky": "snítka",
  cup: "hrnek", cups: "hrnek", tbsp: "lžíce", tsp: "lžička", oz: "oz", lb: "lb",
};

const FRACTIONS: Record<string, number> = { "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1 / 3, "⅔": 2 / 3, "⅛": 0.125 };

function parseAmount(value: string): number | null {
  let text = value.trim();
  let total = 0;
  for (const [ch, n] of Object.entries(FRACTIONS)) {
    if (text.includes(ch)) {
      total += n;
      text = text.replace(ch, "").trim();
    }
  }
  if (!text) return total || null;
  const frac = text.match(/^(\d+)\s*\/\s*(\d+)$/);
  if (frac) return total + Number(frac[1]) / Number(frac[2]);
  const range = text.match(/^(\d+(?:[.,]\d+)?)\s*[-–]\s*(\d+(?:[.,]\d+)?)$/);
  if (range) return total + Number(range[2].replace(",", "."));
  const n = Number(text.replace(",", "."));
  return Number.isFinite(n) ? total + n : total || null;
}

/** „500 g hladké mouky (prosáté)“ → název, množství, jednotka, poznámka. */
export function parseIngredientLine(line: string): { name: string; quantity: number | null; unit: string; note: string } {
  let text = stripTags(line).replace(/^[-–•*·▪●○]\s*/, "").trim();
  let note = "";
  const paren = text.match(/\(([^)]*)\)/);
  if (paren) {
    note = paren[1].trim();
    text = text.replace(paren[0], " ").replace(/\s+/g, " ").trim();
  }
  const amount = "((?:\\d+(?:[.,]\\d+)?\\s*(?:[-–/]\\s*\\d+(?:[.,]\\d+)?)?)?\\s*[½¼¾⅓⅔⅛]?)";
  const lead = text.match(new RegExp(`^${amount}\\s*([A-Za-zÀ-ž.]+)?\\s+(.+)$`));
  if (lead && lead[1].trim()) {
    const quantity = parseAmount(lead[1]);
    const word = (lead[2] ?? "").replace(/\.$/, "");
    const unit = UNIT_WORDS[word.toLowerCase()] ?? UNIT_WORDS[fold(word)];
    if (unit) return { name: lead[3].trim(), quantity, unit, note };
    return { name: `${lead[2] ?? ""} ${lead[3]}`.trim(), quantity, unit: quantity ? "ks" : "", note };
  }
  const trail = text.match(new RegExp(`^(.+?)[,:]?\\s+${amount}\\s*([A-Za-zÀ-ž.]+)?$`));
  if (trail && trail[2].trim()) {
    const word = (trail[3] ?? "").replace(/\.$/, "");
    const unit = UNIT_WORDS[word.toLowerCase()] ?? UNIT_WORDS[fold(word)] ?? "";
    if (unit || !word) {
      return { name: trail[1].trim(), quantity: parseAmount(trail[2]), unit: unit || "ks", note };
    }
  }
  return { name: text, quantity: null, unit: "", note };
}

function asArray(value: unknown): any[] {
  return Array.isArray(value) ? value : value === undefined || value === null ? [] : [value];
}

function isRecipeNode(node: any): boolean {
  return asArray(node?.["@type"]).some((t) => typeof t === "string" && t.toLowerCase() === "recipe");
}

function findRecipeNode(data: any): any | null {
  for (const node of asArray(data)) {
    if (!node || typeof node !== "object") continue;
    if (isRecipeNode(node)) return node;
    const nested = findRecipeNode(node["@graph"]) ?? findRecipeNode(node.mainEntity);
    if (nested) return nested;
  }
  return null;
}

function instructionsOf(value: unknown): string[] {
  const out: string[] = [];
  for (const item of asArray(value)) {
    if (typeof item === "string") {
      out.push(...stripTags(item).split(/\n+|(?<=\.)\s+(?=\d+\.\s)/).map((t) => t.trim()).filter(Boolean));
    } else if (item && typeof item === "object") {
      if (item.itemListElement) out.push(...instructionsOf(item.itemListElement));
      else if (typeof item.text === "string") out.push(stripTags(item.text));
      else if (typeof item.name === "string") out.push(stripTags(item.name));
    }
  }
  return out.map((t) => t.replace(/^\d+[.)]\s*/, "").trim()).filter((t) => t.length > 1);
}

function yieldOf(value: unknown): { servings: number; yield_unit: string } {
  for (const item of asArray(value)) {
    const text = String(item ?? "");
    const n = text.match(/(\d+(?:[.,]\d+)?)/);
    if (n) {
      const servings = Number(n[1].replace(",", "."));
      if (servings > 0) return { servings, yield_unit: /\b(ks|kus|kusů|pieces?)\b/i.test(text) ? "ks" : "porce" };
    }
  }
  return { servings: 4, yield_unit: "porce" };
}

/** Recept ze strukturovaných dat stránky (schema.org/Recipe v JSON-LD). */
export function recipeFromJsonLd(html: string, url: string): Record<string, unknown> | null {
  const blocks = html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi);
  for (const block of blocks) {
    let data: unknown;
    try {
      data = JSON.parse(block[1].trim());
    } catch {
      try {
        data = JSON.parse(decodeEntities(block[1].trim()));
      } catch {
        continue;
      }
    }
    const node = findRecipeNode(data);
    if (!node) continue;
    const title = stripTags(String(node.name ?? ""));
    if (!title) continue;
    const { servings, yield_unit } = yieldOf(node.recipeYield);
    const prep = isoMinutes(node.prepTime);
    let cook = isoMinutes(node.cookTime);
    const total = isoMinutes(node.totalTime);
    if (!prep && !cook && total) cook = total;
    return {
      title,
      description: stripTags(String(node.description ?? "")).slice(0, 2000),
      category: stripTags(String(asArray(node.recipeCategory)[0] ?? "")).slice(0, 60),
      servings,
      yield_unit,
      prep_minutes: prep,
      cook_minutes: cook,
      ingredients: asArray(node.recipeIngredient ?? node.ingredients)
        .map((line) => parseIngredientLine(String(line)))
        .filter((i) => i.name),
      steps: instructionsOf(node.recipeInstructions).map((instruction) => ({ instruction })),
      source_url: url,
      notes: "",
    };
  }
  return null;
}

/** Recept z volného textu (popis videa, vložený text): suroviny a postup. */
export function recipeFromText(raw: string, title: string, url: string): Record<string, unknown> | null {
  const lines = raw.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const ingredients: any[] = [];
  const steps: { instruction: string }[] = [];
  let section: "unknown" | "ingredients" | "steps" = "unknown";
  for (const line of lines) {
    const head = fold(line).replace(/[:\s]+$/, "");
    if (/^(suroviny|ingredience|potrebujeme|potrebujete|na .* potrebujeme)$/.test(head)) {
      section = "ingredients";
      continue;
    }
    if (/^(postup|priprava|navod|jak na to)$/.test(head)) {
      section = "steps";
      continue;
    }
    if (/^(https?:|#|@)/.test(line)) continue;
    const looksLikeIngredient = /^[-–•*·]?\s*[\d½¼¾⅓⅔]/.test(line) && line.length < 80;
    if (section === "ingredients" || (section === "unknown" && looksLikeIngredient)) {
      if (section === "ingredients" && line.length > 120) {
        section = "steps";
      } else {
        const item = parseIngredientLine(line);
        if (item.name) ingredients.push(item);
        continue;
      }
    }
    if (section === "steps" || /^\d+[.)]\s/.test(line)) {
      steps.push({ instruction: line.replace(/^\d+[.)]\s*/, "") });
    }
  }
  if (!ingredients.length && !steps.length) return null;
  return {
    title: title || "Recept",
    description: "",
    servings: 4,
    ingredients,
    steps,
    source_url: url,
    notes: "Načteno z popisu bez AI – zkontrolujte suroviny a postup.",
  };
}

function metaContent(html: string, name: string): string {
  const re = new RegExp(
    `<meta[^>]+(?:property|name)=["']${name}["'][^>]*content=["']([^"']*)["']|<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']${name}["']`,
    "i",
  );
  const m = html.match(re);
  return decodeEntities((m?.[1] ?? m?.[2] ?? "").trim());
}

/** YouTube: celý popis videa je ve stránce jako „shortDescription“. */
function youtubeDescription(html: string): string {
  const m = html.match(/"shortDescription":"((?:[^"\\]|\\.)*)"/);
  if (!m) return "";
  try {
    return JSON.parse(`"${m[1]}"`);
  } catch {
    return "";
  }
}

/** Recept z odkazu bez AI: strukturovaná data, jinak popis stránky / videa. */
export async function importRecipeFromUrl(fetchImpl: FetchLike, url: string) {
  const page = await fetchPage(fetchImpl, url);
  const structured = recipeFromJsonLd(page.html, page.url);
  if (structured) return { recipe: structured, method: "structured" };
  const title = metaContent(page.html, "og:title") || stripTags(page.html.match(/<title>([\s\S]*?)<\/title>/i)?.[1] ?? "");
  const description = youtubeDescription(page.html) || metaContent(page.html, "og:description") ||
    metaContent(page.html, "description");
  const fromText = recipeFromText(description, title, page.url);
  if (fromText) return { recipe: fromText, method: "description" };
  throw new ToolError(
    "Na stránce jsem nenašel recept ve strojově čitelné podobě ani v popisu. " +
      "Zkopírujte text receptu a vložte ho jako text.",
  );
}

// -------------------------------------------- plán vaření, deník, rodina

const MEAL_TYPES = ["breakfast", "lunch", "dinner"];
const MEAL_LABELS: Record<string, string> = { breakfast: "snídaně", lunch: "oběd", dinner: "večeře" };

function isoDay(value: unknown, name: string): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(value))) {
    throw new ToolError(`Parametr ${name} musí být datum ve tvaru RRRR-MM-DD.`);
  }
  return value;
}

function mealType(value: unknown): string {
  const v = typeof value === "string" ? fold(value.trim()) : "";
  const map: Record<string, string> = {
    breakfast: "breakfast", snidane: "breakfast", lunch: "lunch", obed: "lunch", dinner: "dinner", vecere: "dinner",
  };
  const t = map[v];
  if (!t) throw new ToolError("meal_type musí být breakfast (snídaně), lunch (oběd) nebo dinner (večeře).");
  return t;
}

function weekRange(args: any): { from: string; to: string } {
  const today = new Date();
  const monday = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()));
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7));
  const sunday = new Date(monday);
  sunday.setUTCDate(monday.getUTCDate() + 6);
  const from = args?.from === undefined ? monday.toISOString().slice(0, 10) : isoDay(args.from, "from");
  const to = args?.to === undefined ? sunday.toISOString().slice(0, 10) : isoDay(args.to, "to");
  if (to < from) throw new ToolError("Datum to musí být stejné nebo pozdější než from.");
  return { from, to };
}

async function myHousehold(db: Supabase): Promise<string | null> {
  try {
    const id = await db.rpc("my_household", {});
    return typeof id === "string" ? id : null;
  } catch {
    return null;
  }
}

function presentMeal(row: any) {
  return {
    entry_id: row.id,
    date: row.plan_date,
    meal_type: row.meal_type,
    meal: MEAL_LABELS[row.meal_type] ?? row.meal_type,
    recipe_id: row.recipe_id,
    title: row.title || row.recipes?.title || "",
    servings: row.servings === null || row.servings === undefined ? null : Number(row.servings),
    note: row.note ?? "",
    shared_with_family: row.household_id !== null && row.household_id !== undefined,
  };
}

const MEAL_SELECT = "id,plan_date,meal_type,recipe_id,title,note,servings,household_id,recipes(title)";

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
  tags: {
    type: "array",
    items: { type: "string" },
    description:
      "Štítky pro filtry v aplikaci. Způsob přípravy (jeden nebo víc): " + PREP_TAGS.join(", ") +
      ". Příležitost: " + OCCASION_TAGS.join(", ") + ". Lze přidat i vlastní štítky. " +
      "Při úpravě pošli celý seznam; když pole vynecháš, štítky zůstanou beze změny.",
  },
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
        tag: {
          type: "string",
          description: "Jen recepty s tímto štítkem, např. „Sous-vide“ nebo „Pro děti“.",
        },
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
      const tag = text(args?.tag, 40);
      if (tag) {
        const [canonical] = cleanTags([tag]);
        path += `&tags=cs.${encodeURIComponent(JSON.stringify([canonical]))}`;
      }
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
      "Hledá v uložených receptech podle názvu, popisu, kategorie, štítků, poznámek a surovin. " +
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
            ...(Array.isArray(row.tags) ? row.tags : []),
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
  {
    name: "create_shopping_list",
    title: "Vytvořit nákupní seznam",
    description:
      "Vytvoří nový nákupní seznam v HINKredience (objeví se i v aplikaci) a volitelně do něj rovnou " +
      "přidá položky. Např. „Vytvoř nákupní seznam na kuře na paprice“. Suroviny z uloženého receptu " +
      "přidáš přes add_recipe_to_shopping_list.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["name"],
      properties: {
        name: { type: "string", description: "Název seznamu." },
        items: { type: "array", items: shoppingItemSchema, description: "Počáteční položky." },
        share_with_family: { type: "boolean", description: "Sdílet s rodinou (výchozí ne)." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const name = text(args?.name, 120);
      if (!name) throw new ToolError("Seznam musí mít název.");
      const drafts = args?.items === undefined ? [] : cleanShoppingItems(args.items);
      let household: string | null = null;
      if (args?.share_with_family === true) {
        household = await db.rpc("my_household", {}).catch(() => null);
        if (!household) throw new ToolError("Nejste v žádné rodině – seznam nejde sdílet. Vytvořte ho bez sdílení.");
      }
      const now = new Date().toISOString();
      const list = await db.insert("shopping_lists", {
        name,
        ...(household ? { household_id: household } : {}),
        created_at: now,
        updated_at: now,
      });
      const result = drafts.length ? await applyShoppingMerge(db, list, drafts, true) : { added: 0, merged: [] };
      return {
        saved: true,
        ...(await presentList(db, list)),
        message: `Seznam „${name}“ je vytvořený${result.added ? ` s ${result.added} položkami` : ""}. V aplikaci se objeví hned po synchronizaci.`,
      };
    },
  },
  {
    name: "get_shopping_lists",
    title: "Přehled nákupních seznamů",
    description: "Vrátí všechny nákupní seznamy uživatele s počtem zbývajících položek.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    readOnly: true,
    run: async (db) => {
      const lists = await db.select(
        "shopping_lists?select=id,name,household_id,updated_at,shopping_items(is_checked,deleted_at)" +
          "&deleted_at=is.null&order=updated_at.desc&limit=200",
      );
      return {
        count: lists.length,
        lists: lists.map((l) => {
          const items = (Array.isArray(l.shopping_items) ? l.shopping_items : []).filter((i: any) => !i.deleted_at);
          return {
            list_id: l.id,
            name: l.name,
            remaining_count: items.filter((i: any) => !i.is_checked).length,
            total_count: items.length,
            shared_with_family: l.household_id !== null && l.household_id !== undefined,
            updated_at: l.updated_at,
          };
        }),
      };
    },
  },
  {
    name: "get_shopping_list",
    title: "Nákupní seznam",
    description:
      "Načte položky nákupního seznamu podle kategorií, včetně toho, co je už koupené. " +
      "Použij na „Co ještě musím koupit?“ (pole to_buy). Bez list_id a list_name vrátí naposledy upravený seznam.",
    inputSchema: { type: "object", additionalProperties: false, properties: { ...listSelector } },
    readOnly: true,
    run: async (db, args) => presentList(db, await resolveList(db, args)),
  },
  {
    name: "add_shopping_items",
    title: "Přidat položky do nákupu",
    description:
      "Přidá jednu nebo víc položek do nákupního seznamu (např. „Přidej do nákupu 2 litry mléka“ = " +
      "{name: \"Mléko\", quantity: 2, unit: \"l\"}). Stejné položky se sečtou (200 g + 300 g = 500 g), " +
      "pokud merge není false.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["items"],
      properties: {
        ...listSelector,
        items: { type: "array", items: shoppingItemSchema },
        merge: { type: "boolean", description: "Sečíst se stejnými nenakoupenými položkami (výchozí ano)." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const list = await resolveList(db, args);
      const drafts = cleanShoppingItems(args?.items);
      if (!drafts.length) throw new ToolError("Neuvedli jste žádné položky.");
      const result = await applyShoppingMerge(db, list, drafts, args?.merge !== false);
      return {
        saved: true,
        added: result.added,
        merged_with_existing: result.merged,
        ...(await presentList(db, list)),
      };
    },
  },
  {
    name: "update_shopping_item",
    title: "Upravit položku nákupu",
    description:
      "Upraví položku: odškrtnutí (checked=true, např. „Označ máslo jako koupené“), množství, jednotku, " +
      "název, kategorii nebo poznámku. Položku urči item_id, nebo názvem (name) v seznamu.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        item_id: { type: "string" },
        name: { type: "string", description: "Název položky, pokud neznáš item_id." },
        ...listSelector,
        checked: { type: "boolean", description: "true = koupeno, false = vrátit do nákupu." },
        new_name: { type: "string" },
        quantity: { type: ["number", "null"] },
        unit: { type: "string" },
        category: { type: "string", enum: SHOPPING_CATEGORIES },
        note: { type: "string" },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const item = await resolveItem(db, args);
      const fields: Record<string, unknown> = {};
      if (typeof args?.checked === "boolean") fields.is_checked = args.checked;
      if (args?.new_name !== undefined) {
        const name = text(args.new_name, 200);
        if (!name) throw new ToolError("Název nesmí být prázdný.");
        fields.name = name;
      }
      if (args?.quantity !== undefined) {
        const q = args.quantity;
        if (q !== null && !(typeof q === "number" && Number.isFinite(q) && q >= 0 && q <= 1_000_000)) {
          throw new ToolError("Množství musí být číslo od 0 do 1 000 000, nebo null.");
        }
        fields.quantity = q === null || q === 0 ? null : q;
      }
      if (args?.unit !== undefined) fields.unit = normalizeUnit(args.unit);
      if (args?.category !== undefined) {
        if (!SHOPPING_CATEGORIES.includes(args.category)) throw new ToolError("Neznámá kategorie.");
        fields.category = args.category;
      }
      if (args?.note !== undefined) fields.note = text(args.note, 500);
      if (!Object.keys(fields).length) throw new ToolError("Neuvedli jste, co změnit.");
      fields.updated_at = new Date().toISOString();
      const rows = await db.patch(`shopping_items?id=eq.${item.id}&deleted_at=is.null`, fields);
      if (!rows.length) throw new ToolError("Položku se nepodařilo upravit.");
      await touchList(db, item.list_id ?? rows[0].list_id);
      const updated = presentItem(rows[0]);
      return {
        saved: true,
        item: updated,
        message: typeof args?.checked === "boolean"
          ? `„${updated.name}“ ${args.checked ? "je označené jako koupené" : "je zpět v nákupu"}.`
          : `Položka „${updated.name}“ je upravená.`,
      };
    },
  },
  {
    name: "remove_shopping_item",
    title: "Odstranit položku z nákupu",
    description: "Odstraní položku z nákupního seznamu (podle item_id, nebo názvu v seznamu).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        item_id: { type: "string" },
        name: { type: "string", description: "Název položky, pokud neznáš item_id." },
        ...listSelector,
      },
    },
    readOnly: false,
    destructive: true,
    run: async (db, args) => {
      const item = await resolveItem(db, args);
      const now = new Date().toISOString();
      const rows = await db.patch(`shopping_items?id=eq.${item.id}&deleted_at=is.null`, {
        deleted_at: now,
        updated_at: now,
      });
      if (!rows.length) throw new ToolError("Položku se nepodařilo odstranit.");
      await touchList(db, item.list_id ?? rows[0].list_id);
      return { removed: true, item_id: item.id, message: `„${item.name}“ je odstraněné ze seznamu.` };
    },
  },
  {
    name: "clear_checked_items",
    title: "Odstranit nakoupené položky",
    description: "Odstraní ze seznamu všechny už koupené (odškrtnuté) položky.",
    inputSchema: { type: "object", additionalProperties: false, properties: { ...listSelector } },
    readOnly: false,
    destructive: true,
    run: async (db, args) => {
      const list = await resolveList(db, args);
      const now = new Date().toISOString();
      const rows = await db.patch(
        `shopping_items?list_id=eq.${list.id}&is_checked=eq.true&deleted_at=is.null`,
        { deleted_at: now, updated_at: now },
      );
      if (rows.length) await touchList(db, list.id);
      return {
        removed_count: rows.length,
        ...(await presentList(db, list)),
        message: rows.length
          ? `Ze seznamu „${list.name}“ je odstraněno ${rows.length} nakoupených položek.`
          : `V seznamu „${list.name}“ nejsou žádné nakoupené položky.`,
      };
    },
  },
  {
    name: "add_recipe_to_shopping_list",
    title: "Přidat suroviny receptu do nákupu",
    description:
      "Přidá suroviny uloženého receptu do nákupního seznamu, přepočtené na zvolený počet porcí/kusů. " +
      "Stejné suroviny se sečtou s tím, co už na seznamu je. Pro víc receptů volej opakovaně se stejným " +
      "seznamem. Když seznam neexistuje, založí ho podle new_list_name.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: {
        recipe_id: idProperty,
        ...listSelector,
        new_list_name: { type: "string", description: "Založit nový seznam s tímto názvem." },
        servings: { type: "number", description: "Na kolik porcí/kusů nakoupit (výchozí podle receptu)." },
        exclude: {
          type: "array",
          items: { type: "string" },
          description: "Suroviny, které uživatel už má doma (nepřidávat).",
        },
        merge: { type: "boolean", description: "Sečíst se stejnými položkami (výchozí ano)." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const recipe = await loadRecipe(db, requireId(args?.recipe_id));
      const newName = text(args?.new_list_name, 120);
      let list = newName && !args?.list_id && !args?.list_name ? null : await resolveList(db, args, !newName);
      if (!list) {
        const now = new Date().toISOString();
        list = await db.insert("shopping_lists", {
          name: newName || recipe.title,
          created_at: now,
          updated_at: now,
        });
      }
      const baseServings = Number(recipe.servings) > 0 ? Number(recipe.servings) : 4;
      const servings = typeof args?.servings === "number" && args.servings > 0 && args.servings <= 1000
        ? args.servings
        : baseServings;
      const factor = servings / baseServings;
      const excluded = new Set(
        (Array.isArray(args?.exclude) ? args.exclude : []).map((v: unknown) => nameKey(String(v))),
      );
      const ingredients = (Array.isArray(recipe.recipe_ingredients) ? [...recipe.recipe_ingredients] : [])
        .sort((a: any, b: any) => (a?.position ?? 0) - (b?.position ?? 0));
      const drafts = cleanShoppingItems(
        ingredients
          .filter((i: any) => !excluded.has(nameKey(i.name ?? "")))
          .map((i: any) => ({
            name: i.name,
            quantity: i.quantity === null || i.quantity === undefined ? null : Number(i.quantity) * factor,
            unit: i.unit ?? "",
            note: i.note ?? "",
          })),
        recipe.title,
      );
      const result = await applyShoppingMerge(db, list, drafts, args?.merge !== false);
      return {
        saved: true,
        recipe: recipe.title,
        servings,
        yield_unit: normalizeYieldUnit(recipe.yield_unit),
        added: result.added,
        merged_with_existing: result.merged,
        skipped: [...excluded].length,
        ...(await presentList(db, list)),
      };
    },
  },
  {
    name: "import_recipe_from_url",
    title: "Načíst recept z odkazu (bez AI)",
    description:
      "Načte recept z webové stránky nebo popisu videa (YouTube) bez AI: použije strukturovaná data " +
      "stránky (schema.org Recipe), jinak rozdělí popis na suroviny a postup. S save=true ho rovnou " +
      "uloží do HINKredience, jinak vrátí návrh ke kontrole.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["url"],
      properties: {
        url: { type: "string", description: "Adresa stránky s receptem nebo videa." },
        save: { type: "boolean", description: "Rovnou uložit jako nový recept (výchozí ne)." },
      },
    },
    readOnly: false,
    run: async (db, args, _userId, fetchImpl) => {
      const url = text(args?.url, 2000);
      if (!url) throw new ToolError("Zadejte odkaz.");
      const result = await importRecipeFromUrl(fetchImpl, url);
      const recipe = cleanRecipe(result.recipe);
      if (args?.save !== true) {
        return {
          saved: false,
          method: result.method,
          recipe,
          message: result.method === "structured"
            ? `Načteno: „${recipe.title}“ (${(recipe.ingredients as any[]).length} surovin, ${(recipe.steps as any[]).length} kroků).`
            : `Načteno z popisu: „${recipe.title}“ – zkontrolujte suroviny a postup.`,
        };
      }
      const saved = await db.rpc("api_save_recipe", {
        p_recipe: recipe,
        p_meta: { change_summary: "Importováno z odkazu" },
      });
      return {
        saved: true,
        method: result.method,
        recipe_id: saved.id,
        version: saved.version,
        message: `Recept „${recipe.title}“ je uložený v HINKredience.`,
      };
    },
  },
  {
    name: "add_meal_wish",
    title: "Mám chuť na…",
    description:
      "Přidá do rodinného jídelníčku přání „mám chuť na…“ (recept z kuchařky podle recipe_id, nebo jen " +
      "název jídla). Ostatní v rodině ho uvidí v plánu vaření a dostanou oznámení.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["title"],
      properties: {
        title: { type: "string", description: "Na co má chuť, např. „Svíčková“." },
        recipe_id: { type: "string", description: "Recept z kuchařky, když existuje." },
        note: { type: "string", description: "Např. „ideálně v sobotu“." },
      },
    },
    readOnly: false,
    run: async (db, args, userId) => {
      const title = text(args?.title, 160);
      if (!title) throw new ToolError("Napište, na co máte chuť.");
      const household = await db.rpc("my_household", {}).catch(() => null);
      const profile = (await db.select(`profiles?select=greeting_name,display_name&id=eq.${userId}&limit=1`))[0] ?? {};
      const recipeId = typeof args?.recipe_id === "string" && /^[0-9a-f-]{36}$/i.test(args.recipe_id)
        ? args.recipe_id
        : null;
      const row = await db.insert("meal_wishes", {
        household_id: typeof household === "string" ? household : null,
        recipe_id: recipeId,
        title,
        note: text(args?.note, 300),
        author_name: String(profile.greeting_name || profile.display_name || ""),
      });
      if (typeof household === "string") await announce(db, [{ kind: "wish", title }]);
      return {
        saved: true,
        wish_id: row?.id ?? null,
        message: `Přání „${title}“ je v plánu vaření${typeof household === "string" ? " a rodina dostane oznámení" : ""}.`,
      };
    },
  },
  {
    name: "get_meal_wishes",
    title: "Na co má rodina chuť",
    description: "Vrátí čekající i naplánovaná přání „mám chuť na…“ celé rodiny (kdo, co, poznámka, naplánovaný den).",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    readOnly: true,
    run: async (db) => {
      const today = new Date().toISOString().slice(0, 10);
      const rows = await db.select(
        "meal_wishes?select=id,title,recipe_id,note,author_name,planned_day,created_at" +
          "&deleted_at=is.null&order=created_at.desc&limit=100",
      );
      const wishes = rows.filter((w: any) => !w.planned_day || w.planned_day >= today);
      return { count: wishes.length, wishes };
    },
  },
  {
    name: "save_price_offer",
    title: "Uložit akci z letáku (Sušice)",
    description:
      "Uloží akční nabídku obchodu v Sušici do HINKredience pro porovnání cen v nákupním košíku. " +
      "Použij JEN cenu, kterou vidíš na oficiálním webu nebo v letáku řetězce (penny.cz, lidl.cz, " +
      "albert.cz, itesco.cz, jip-potraviny.cz, zkdsusice.cz) – nikdy ji neodhaduj. Server cenu ověří na zdrojové " +
      "stránce; neověřené nabídky se uloží s označením a do přesného porovnání se nepočítají.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["chain", "product", "price", "valid_to", "source_url"],
      properties: {
        chain: { type: "string", enum: ["tesco", "penny", "lidl", "albert", "jip", "coop"] },
        store_id: {
          type: "string",
          description: "Jen když akce platí v jediné prodejně.",
          enum: [
            "tesco-hradecka", "penny-nadrazni", "lidl-hradecka", "albert-hradecka", "albert-tgm",
            "jip-hradecka", "coop-namesti", "coop-nadrazni", "coop-lerchova", "coop-smetanova",
          ],
        },
        product: { type: "string", description: "Název produktu jako ve zdroji." },
        label: { type: "string", description: "Značka, gramáž." },
        price: { type: "number", description: "Akční cena v Kč za balení." },
        pack_qty: { type: "number" },
        pack_unit: { type: "string", description: "g, kg, ml, l, ks" },
        regular_price: { type: "number" },
        conditions: { type: "string", description: "Např. jen s aplikací, od 2 ks." },
        valid_from: { type: "string", description: "RRRR-MM-DD" },
        valid_to: { type: "string", description: "RRRR-MM-DD (poslední den platnosti)" },
        source_url: { type: "string", description: "https adresa oficiální stránky s akcí." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const offer: Record<string, unknown> = {};
      for (const k of ["product", "label", "pack_unit", "conditions", "valid_from", "valid_to", "source_url", "store_id"]) {
        if (typeof args?.[k] === "string") offer[k] = text(args[k], 300);
      }
      for (const k of ["price", "pack_qty", "regular_price"]) {
        if (typeof args?.[k] === "number") offer[k] = args[k];
      }
      const r = await db.callFunction("prices", {
        action: "submit",
        provider: "chatgpt",
        chain: String(args?.chain ?? ""),
        offer,
      });
      return {
        saved: r?.saved === true,
        duplicate: r?.duplicate === true,
        verified: r?.verified === true,
        reason: r?.reason ?? "",
        message: r?.verified
          ? `Uloženo a ověřeno: ${offer.product} za ${offer.price} Kč.`
          : `Uloženo jako NEOVĚŘENÉ (${r?.reason ?? "zdroj nejde ověřit"}) – do porovnání se nepočítá.`,
      };
    },
  },
  {
    name: "get_price_offers",
    title: "Akce v obchodech v Sušici",
    description:
      "Vrátí platné akční nabídky uložené v HINKredience (Tesco, Penny, Lidl, Albert, JIP, COOP v Sušici), " +
      "volitelně jen pro řetězec nebo produkt. U každé je zdroj, platnost a zda je ověřená.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        chain: { type: "string", enum: ["tesco", "penny", "lidl", "albert", "jip", "coop"] },
        product: { type: "string", description: "Část názvu produktu." },
      },
    },
    readOnly: true,
    run: async (db, args) => {
      const today = new Date().toISOString().slice(0, 10);
      let path =
        "price_offers?select=chain,store_id,product,label,price,pack_qty,pack_unit,regular_price,conditions," +
        `valid_from,valid_to,source_url,provider,verified&valid_to=gte.${today}&order=price.asc&limit=200`;
      if (typeof args?.chain === "string") path += `&chain=eq.${encodeURIComponent(args.chain)}`;
      if (typeof args?.product === "string" && args.product.trim()) {
        path += `&product=ilike.${encodeURIComponent(`*${text(args.product, 60).replace(/[*,()]/g, " ")}*`)}`;
      }
      const offers = await db.select(path);
      return { count: offers.length, offers };
    },
  },
  {
    name: "save_receipt_prices",
    title: "Uložit ceny z účtenky",
    description:
      "Uloží skutečné ceny z účtenky (např. z fotky, kterou uživatel poslal) k prodejně v Sušici. " +
      "Sdílí se s rodinou a nákupní košík je použije pro porovnání. Opiš jen ceny, které na účtence jsou.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["store_id", "items"],
      properties: {
        store_id: {
          type: "string",
          enum: [
            "tesco-hradecka", "penny-nadrazni", "lidl-hradecka", "albert-hradecka", "albert-tgm",
            "jip-hradecka", "coop-namesti", "coop-nadrazni", "coop-lerchova", "coop-smetanova",
          ],
        },
        bought_on: { type: "string", description: "RRRR-MM-DD (výchozí dnes)" },
        items: {
          type: "array",
          maxItems: 100,
          items: {
            type: "object",
            additionalProperties: false,
            required: ["product", "price"],
            properties: {
              product: { type: "string" },
              price: { type: "number", description: "Cena za kus/balení v Kč." },
              pack_qty: { type: "number" },
              pack_unit: { type: "string" },
            },
          },
        },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const household = await db.rpc("my_household", {}).catch(() => null);
      const day = typeof args?.bought_on === "string" && /^\d{4}-\d{2}-\d{2}$/.test(args.bought_on)
        ? args.bought_on
        : new Date().toISOString().slice(0, 10);
      let saved = 0;
      for (const item of Array.isArray(args?.items) ? args.items.slice(0, 100) : []) {
        const product = text(item?.product, 160);
        const price = Number(item?.price);
        if (!product || !(price > 0 && price < 100000)) continue;
        await db.insert("price_receipts", {
          store_id: String(args?.store_id ?? ""),
          household_id: typeof household === "string" ? household : null,
          product,
          price,
          pack_qty: typeof item?.pack_qty === "number" && item.pack_qty > 0 ? item.pack_qty : null,
          pack_unit: text(item?.pack_unit, 20),
          bought_on: day,
          note: "účtenka (ChatGPT)",
        });
        saved++;
      }
      if (saved === 0) throw new ToolError("Žádná položka s platnou cenou.");
      return { saved, message: `Uloženo cen z účtenky: ${saved}.` };
    },
  },
  {
    name: "get_meal_plan",
    title: "Plán vaření",
    description: "Vrátí plán vaření (snídaně, obědy, večeře) pro zadané dny; bez dat aktuální týden (po–ne).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        from: { type: "string", description: "Od (RRRR-MM-DD)." },
        to: { type: "string", description: "Do (RRRR-MM-DD)." },
      },
    },
    readOnly: true,
    run: async (db, args) => {
      const { from, to } = weekRange(args);
      const rows = await db.select(
        `meal_plans?select=${MEAL_SELECT}&deleted_at=is.null&plan_date=gte.${from}&plan_date=lte.${to}` +
          `&order=plan_date.asc,meal_type.asc&limit=200`,
      );
      return { from, to, count: rows.length, entries: rows.map(presentMeal) };
    },
  },
  {
    name: "plan_meal",
    title: "Naplánovat jídlo",
    description:
      "Přidá jídlo do plánu vaření (v rodině společný). Použij recipe_id uloženého receptu, nebo jen title " +
      "(např. „Pizza z venku“). Pro celý týden volej opakovaně.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["date", "meal_type"],
      properties: {
        date: { type: "string", description: "Den (RRRR-MM-DD)." },
        meal_type: { type: "string", enum: MEAL_TYPES, description: "breakfast, lunch nebo dinner." },
        recipe_id: { type: "string", description: "Id receptu (nepovinné)." },
        title: { type: "string", description: "Název jídla, pokud není recept." },
        servings: { type: "number", description: "Počet porcí (nepovinné)." },
        note: { type: "string" },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const date = isoDay(args?.date, "date");
      const type = mealType(args?.meal_type);
      let recipeId: string | null = null;
      let title = text(args?.title, 200);
      if (args?.recipe_id) {
        const recipe = await loadRecipeRow(db, requireId(args.recipe_id));
        recipeId = recipe.id;
        if (!title) title = recipe.title;
      }
      if (!recipeId && !title) throw new ToolError("Uveďte recipe_id nebo title.");
      const servings = typeof args?.servings === "number" && args.servings > 0 && args.servings <= 100
        ? args.servings
        : null;
      const household = await myHousehold(db);
      const now = new Date().toISOString();
      const row = await db.insert("meal_plans", {
        plan_date: date,
        meal_type: type,
        recipe_id: recipeId,
        title,
        note: text(args?.note, 500),
        servings,
        ...(household ? { household_id: household } : {}),
        created_at: now,
        updated_at: now,
      });
      return { saved: true, entry: presentMeal(row), message: `${MEAL_LABELS[type]} ${date}: ${title}.` };
    },
  },
  {
    name: "update_meal_plan_entry",
    title: "Upravit jídlo v plánu",
    description: "Přesune nebo upraví naplánované jídlo (den, druh, recept, název, porce, poznámka).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["entry_id"],
      properties: {
        entry_id: { type: "string" },
        date: { type: "string" },
        meal_type: { type: "string", enum: MEAL_TYPES },
        recipe_id: { type: ["string", "null"] },
        title: { type: "string" },
        servings: { type: ["number", "null"] },
        note: { type: "string" },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.entry_id, "entry_id");
      const fields: Record<string, unknown> = {};
      if (args?.date !== undefined) fields.plan_date = isoDay(args.date, "date");
      if (args?.meal_type !== undefined) fields.meal_type = mealType(args.meal_type);
      if (args?.recipe_id !== undefined) {
        if (args.recipe_id === null) fields.recipe_id = null;
        else {
          const recipe = await loadRecipeRow(db, requireId(args.recipe_id));
          fields.recipe_id = recipe.id;
          if (args?.title === undefined) fields.title = recipe.title;
        }
      }
      if (args?.title !== undefined) fields.title = text(args.title, 200);
      if (args?.servings !== undefined) {
        fields.servings = typeof args.servings === "number" && args.servings > 0 && args.servings <= 100
          ? args.servings
          : null;
      }
      if (args?.note !== undefined) fields.note = text(args.note, 500);
      if (!Object.keys(fields).length) throw new ToolError("Neuvedli jste, co změnit.");
      fields.updated_at = new Date().toISOString();
      const rows = await db.patch(`meal_plans?id=eq.${id}&deleted_at=is.null&select=${MEAL_SELECT}`, fields);
      if (!rows.length) throw new ToolError("Jídlo v plánu nenalezeno. Zjistěte entry_id přes get_meal_plan.");
      return { saved: true, entry: presentMeal(rows[0]) };
    },
  },
  {
    name: "remove_meal_plan_entry",
    title: "Odebrat jídlo z plánu",
    description: "Odebere naplánované jídlo z plánu vaření (entry_id z get_meal_plan).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["entry_id"],
      properties: { entry_id: { type: "string" } },
    },
    readOnly: false,
    destructive: true,
    run: async (db, args) => {
      const id = requireId(args?.entry_id, "entry_id");
      const now = new Date().toISOString();
      const rows = await db.patch(`meal_plans?id=eq.${id}&deleted_at=is.null`, { deleted_at: now, updated_at: now });
      if (!rows.length) throw new ToolError("Jídlo v plánu nenalezeno.");
      return { removed: true, entry_id: id };
    },
  },
  {
    name: "shop_for_meal_plan",
    title: "Nakoupit na plán",
    description:
      "Přidá suroviny všech naplánovaných receptů v zadaných dnech (bez dat aktuální týden) do nákupního " +
      "seznamu, přepočtené na naplánované porce a sečtené. Bez seznamu založí nový.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        from: { type: "string" },
        to: { type: "string" },
        ...listSelector,
        new_list_name: { type: "string" },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const { from, to } = weekRange(args);
      const entries = await db.select(
        `meal_plans?select=recipe_id,servings&deleted_at=is.null&recipe_id=not.is.null` +
          `&plan_date=gte.${from}&plan_date=lte.${to}&limit=200`,
      );
      if (!entries.length) throw new ToolError(`V plánu ${from} – ${to} nejsou žádné recepty.`);
      const drafts: ShoppingDraft[] = [];
      for (const entry of entries) {
        const recipe = await loadRecipe(db, entry.recipe_id).catch(() => null);
        if (!recipe) continue;
        const base = Number(recipe.servings) > 0 ? Number(recipe.servings) : 4;
        const factor = Number(entry.servings) > 0 ? Number(entry.servings) / base : 1;
        drafts.push(
          ...cleanShoppingItems(
            (recipe.recipe_ingredients ?? []).map((i: any) => ({
              name: i.name,
              quantity: i.quantity === null || i.quantity === undefined ? null : Number(i.quantity) * factor,
              unit: i.unit ?? "",
              note: i.note ?? "",
            })).slice(0, 100),
            recipe.title,
          ),
        );
      }
      const newName = text(args?.new_list_name, 120);
      let list = newName && !args?.list_id && !args?.list_name ? null : await resolveList(db, args, false);
      if (!list) {
        const now = new Date().toISOString();
        list = await db.insert("shopping_lists", {
          name: newName || `Nákup ${from} – ${to}`,
          created_at: now,
          updated_at: now,
        });
      }
      const result = await applyShoppingMerge(db, list, drafts, true);
      return {
        saved: true,
        recipes: entries.length,
        added: result.added,
        merged_with_existing: result.merged,
        ...(await presentList(db, list)),
      };
    },
  },
  {
    name: "log_cooking",
    title: "Zapsat vaření do deníku",
    description:
      "Zapíše do kuchařského deníku, že se recept vařil: hodnocení, co se povedlo, co příště zlepšit, " +
      "skutečný čas. Aplikace pak „co zlepšit“ připomene při příštím vaření.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: {
        recipe_id: idProperty,
        cooked_at: { type: "string", description: "Kdy (ISO datum/čas), výchozí teď." },
        servings: { type: "number" },
        rating: { type: "number", description: "0–5." },
        actual_minutes: { type: "integer" },
        went_well: { type: "string" },
        to_improve: { type: "string" },
        notes: { type: "string" },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const recipe = await loadRecipeRow(db, requireId(args?.recipe_id));
      const cookedAt = typeof args?.cooked_at === "string" && !Number.isNaN(Date.parse(args.cooked_at))
        ? new Date(args.cooked_at).toISOString()
        : new Date().toISOString();
      const rating = typeof args?.rating === "number" && args.rating >= 0 && args.rating <= 5
        ? Math.round(args.rating * 2) / 2
        : null;
      const now = new Date().toISOString();
      const row = await db.insert("cooking_sessions", {
        recipe_id: recipe.id,
        recipe_title: recipe.title,
        status: "finished",
        cooked_at: cookedAt,
        servings: typeof args?.servings === "number" && args.servings > 0 ? args.servings : null,
        rating,
        actual_minutes: typeof args?.actual_minutes === "number" && args.actual_minutes >= 0
          ? Math.round(args.actual_minutes)
          : null,
        went_well: text(args?.went_well, 2000),
        to_improve: text(args?.to_improve, 2000),
        notes: text(args?.notes, 4000),
        updated_at: now,
      });
      await db.patch(`recipes?id=eq.${recipe.id}`, { last_cooked_at: cookedAt }).catch(() => []);
      return { saved: true, session_id: row.id, message: `Vaření „${recipe.title}“ je zapsané v deníku.` };
    },
  },
  {
    name: "set_recipe_favorite",
    title: "Oblíbený recept",
    description: "Přidá recept mezi oblíbené (favorite=true), nebo ho z nich odebere.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "favorite"],
      properties: { recipe_id: idProperty, favorite: { type: "boolean" } },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const rows = await db.patch(`recipes?id=eq.${id}&deleted_at=is.null`, {
        is_favorite: args?.favorite === true,
        updated_at: new Date().toISOString(),
      });
      if (!rows.length) throw new ToolError("Recept nenalezen.");
      return { saved: true, recipe_id: id, favorite: rows[0].is_favorite };
    },
  },
  {
    name: "rate_recipe",
    title: "Ohodnotit recept",
    description: "Nastaví hodnocení receptu 0–5 hvězdiček (po půlkách), null hodnocení smaže.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "rating"],
      properties: { recipe_id: idProperty, rating: { type: ["number", "null"] } },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const rating = args?.rating;
      if (rating !== null && !(typeof rating === "number" && rating >= 0 && rating <= 5)) {
        throw new ToolError("Hodnocení musí být číslo 0–5, nebo null.");
      }
      const rows = await db.patch(`recipes?id=eq.${id}&deleted_at=is.null`, {
        rating: rating === null ? null : Math.round(rating * 2) / 2,
        updated_at: new Date().toISOString(),
      });
      if (!rows.length) throw new ToolError("Recept nenalezen.");
      return { saved: true, recipe_id: id, rating: rows[0].rating };
    },
  },
  {
    name: "get_trash",
    title: "Koš receptů",
    description: "Recepty přesunuté do koše (jdou obnovit přes restore_recipe).",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    readOnly: true,
    run: async (db) => {
      const rows = await db.select(
        "recipes?select=id,title,category,deleted_at&deleted_at=not.is.null&order=deleted_at.desc&limit=100",
      );
      return { count: rows.length, recipes: rows.map((r) => ({ recipe_id: r.id, title: r.title, deleted_at: r.deleted_at })) };
    },
  },
  {
    name: "restore_recipe",
    title: "Obnovit recept z koše",
    description: "Vrátí recept z koše zpět do kuchařky.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id"],
      properties: { recipe_id: idProperty },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const rows = await db.patch(`recipes?id=eq.${id}&deleted_at=not.is.null`, {
        deleted_at: null,
        updated_at: new Date().toISOString(),
      });
      if (!rows.length) throw new ToolError("V koši takový recept není.");
      return { restored: true, recipe_id: id, title: rows[0].title };
    },
  },
  {
    name: "get_family",
    title: "Rodina",
    description: "Rodina uživatele: členové a zda se jeho recepty sdílejí automaticky.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    readOnly: true,
    run: async (db, _args, userId) => {
      const household = await myHousehold(db);
      const profile = (await db.select(
        `profiles?select=greeting_name,share_recipes_with_family&id=eq.${userId}&limit=1`,
      ).catch(() => []))[0] ?? {};
      if (!household) {
        return { in_family: false, greeting_name: profile.greeting_name ?? "", auto_share_recipes: false };
      }
      const [house] = await db.select(`households?select=id,name&id=eq.${household}&limit=1`);
      const members = await db.select(`household_members?select=user_id,role&household_id=eq.${household}`);
      const ids = members.map((m) => m.user_id).join(",");
      const names = ids ? await db.select(`profiles?select=id,display_name,greeting_name&id=in.(${ids})`) : [];
      return {
        in_family: true,
        family_name: house?.name ?? "Rodina",
        greeting_name: profile.greeting_name ?? "",
        auto_share_recipes: profile.share_recipes_with_family === true,
        members: members.map((m) => {
          const p = names.find((n) => n.id === m.user_id) ?? {};
          return {
            name: p.greeting_name || p.display_name || "Člen rodiny",
            role: m.role === "owner" ? "zakladatel" : "člen",
            is_me: m.user_id === userId,
          };
        }),
      };
    },
  },
  {
    name: "set_recipe_sharing",
    title: "Sdílet recept s rodinou",
    description: "Nasdílí jeden recept rodině (shared=true), nebo ho udělá soukromým.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipe_id", "shared"],
      properties: { recipe_id: idProperty, shared: { type: "boolean" } },
    },
    readOnly: false,
    run: async (db, args) => {
      const id = requireId(args?.recipe_id);
      const household = args?.shared === true ? await myHousehold(db) : null;
      if (args?.shared === true && !household) throw new ToolError("Nejste v žádné rodině.");
      const rows = await db.patch(`recipes?id=eq.${id}&deleted_at=is.null`, {
        household_id: household,
        visibility: household ? "household" : "private",
        updated_at: new Date().toISOString(),
      });
      if (!rows.length) throw new ToolError("Recept nenalezen.");
      const shared = rows[0].visibility === "household";
      return {
        saved: true,
        recipe_id: id,
        shared,
        message: shared
          ? "Recept vidí celá rodina."
          : "Recept je soukromý.",
        ...(args?.shared === false && shared
          ? { note: "Máte zapnuté automatické sdílení všech receptů, proto zůstal sdílený." }
          : {}),
      };
    },
  },
  {
    name: "share_all_recipes",
    title: "Sdílet všechny recepty s rodinou",
    description:
      "Nasdílí rodině všechny recepty uživatele. S automatic=true se navíc budou automaticky sdílet i všechny " +
      "nové; automatic=false automatiku vypne (sdílené zůstanou sdílené).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { automatic: { type: "boolean" } },
    },
    readOnly: false,
    run: async (db, args) => {
      if (typeof args?.automatic === "boolean") {
        const count = await db.rpc("set_share_recipes_with_family", { p_enabled: args.automatic });
        return {
          saved: true,
          automatic: args.automatic,
          newly_shared: Number(count) || 0,
          message: args.automatic
            ? "Všechny recepty se teď sdílejí s rodinou automaticky."
            : "Automatické sdílení je vypnuté.",
        };
      }
      const count = await db.rpc("share_all_my_recipes", {});
      return { saved: true, newly_shared: Number(count) || 0 };
    },
  },
  {
    name: "update_taste_preferences",
    title: "Upravit chutě",
    description:
      "Upraví chuťové preference (Kuchyně a chutě): add přidá, remove smaže, enable/disable zapne či vypne. " +
      "Aplikace podle nich doporučuje recepty.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["add", "remove", "enable", "disable"] },
        preference_id: { type: "string" },
        label: { type: "string", description: "Text preference, např. „Bez koriandru“." },
      },
    },
    readOnly: false,
    run: async (db, args) => {
      const action = args?.action;
      if (action === "add") {
        const label = text(args?.label, 200);
        if (!label) throw new ToolError("Uveďte label.");
        const row = await db.insert("user_preferences", { label, position: 1000 });
        return { saved: true, preference_id: row.id, label };
      }
      let id = typeof args?.preference_id === "string" && args.preference_id ? requireId(args.preference_id, "preference_id") : "";
      if (!id) {
        const label = text(args?.label, 200);
        if (!label) throw new ToolError("Uveďte preference_id nebo label.");
        const all = await db.select("user_preferences?select=id,label&limit=200");
        const found = all.find((p) => fold(p.label) === fold(label)) ?? all.find((p) => fold(p.label).includes(fold(label)));
        if (!found) throw new ToolError(`Preference „${label}“ nenalezena.`);
        id = found.id;
      }
      if (action === "remove") {
        const rows = await db.remove(`user_preferences?id=eq.${id}`);
        if (!rows.length) throw new ToolError("Preference nenalezena.");
        return { removed: true, preference_id: id };
      }
      if (action === "enable" || action === "disable") {
        const rows = await db.patch(`user_preferences?id=eq.${id}`, { enabled: action === "enable" });
        if (!rows.length) throw new ToolError("Preference nenalezena.");
        return { saved: true, preference_id: id, enabled: action === "enable" };
      }
      throw new ToolError("action musí být add, remove, enable nebo disable.");
    },
  },
  {
    name: "set_greeting_name",
    title: "Oslovení v aplikaci",
    description: "Změní přezdívku, kterou aplikace používá v oslovení („Ahoj Pájo“).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["name"],
      properties: { name: { type: "string" } },
    },
    readOnly: false,
    run: async (db, args, userId) => {
      const name = text(args?.name, 30);
      if (!name) throw new ToolError("Přezdívka nesmí být prázdná.");
      const rows = await db.patch(`profiles?id=eq.${userId}`, { greeting_name: name, updated_at: new Date().toISOString() });
      if (!rows.length) throw new ToolError("Profil nenalezen.");
      return { saved: true, greeting_name: name, message: `Aplikace vás bude oslovovat „${name}“ (po dalším přihlášení).` };
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
  "hlavní fotka set_recipe_cover_photo (první fotka = hlavní). " +
  "Nákupní seznamy: get_shopping_lists, get_shopping_list (co zbývá koupit), create_shopping_list, " +
  "add_shopping_items, update_shopping_item (odškrtnutí), remove_shopping_item, clear_checked_items, " +
  "add_recipe_to_shopping_list (suroviny receptu s přepočtem porcí). " +
  "Plán vaření: get_meal_plan, plan_meal, update_meal_plan_entry, remove_meal_plan_entry, " +
  "shop_for_meal_plan (nákup na celý plán). Deník: log_cooking, get_cooking_history. " +
  "Oblíbené a hodnocení: set_recipe_favorite, rate_recipe. Koš: get_trash, restore_recipe. " +
  "Rodina a sdílení: get_family, set_recipe_sharing, share_all_recipes. Chutě: " +
  "update_taste_preferences; oslovení: set_greeting_name. Recept z odkazu bez AI: " +
  "import_recipe_from_url. Vždy zapisuj do databáze přes tyto nástroje, ne jen do odpovědi.";

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

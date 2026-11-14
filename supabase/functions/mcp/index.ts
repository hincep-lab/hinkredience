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
export const SERVER_VERSION = "1.0.0";
const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_BODY_BYTES = 400_000;

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
  return result;
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
    prep_minutes: row.prep_minutes ?? 0,
    cook_minutes: row.cook_minutes ?? 0,
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
  "id,title,description,category,servings,prep_minutes,cook_minutes,rating,is_favorite,current_version,last_cooked_at,updated_at";

async function loadRecipe(db: Supabase, id: string): Promise<any> {
  const rows = await db.select(
    `recipes?select=${RECIPE_FULL}&id=eq.${id}&deleted_at=is.null&limit=1`,
  );
  if (!rows.length) throw new ToolError("Recept nenalezen. Zkontrolujte id přes get_recipes.");
  return rows[0];
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
  servings: { type: "number", description: "Počet porcí." },
  prep_minutes: { type: "integer", description: "Čas přípravy v minutách." },
  cook_minutes: { type: "integer", description: "Čas vaření/pečení v minutách." },
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
  run: (db: Supabase, args: any, userId: string) => Promise<unknown>;
}

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
];

const instructions =
  "HINKredience° je osobní kuchařka Pavla Hinka sdílená s mobilní aplikací. " +
  "Recepty ukládej česky, s přesnými gramážemi, teplotami ve °C a časy. " +
  "Před návrhem receptu si přes get_kitchen_equipment zjisti vybavení a chutě. " +
  "Než recept upravíš, načti ho přes get_recipe. Úpravy vždy vytvářejí novou verzi, nic se nepřepisuje. " +
  "Nevymýšlej si uložené recepty ani historii – používej jen data z nástrojů. " +
  "Ukládej a maž jen na výslovnou žádost uživatele.";

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
  }));
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
        capabilities: { tools: { listChanged: false } },
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
        const result = await tool.run(db, message.params?.arguments ?? {}, userId);
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
        const result = await handleMessage(message, db, userId);
        if (result !== null) results.push(result);
      }
      return results.length ? jsonResponse(200, results) : new Response(null, { status: 202, headers: corsHeaders });
    }
    const result = await handleMessage(payload, db, userId);
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

// HINKredience° – oznámení pro rodinu (web push)
//
// Když někdo přidá přání „mám chuť na…“ nebo položku na nákup, aplikace
// zavolá tuhle funkci a ta pošle oznámení ostatním členům domácnosti na
// zařízení, která si je zapnula (prohlížeč, aplikace na ploše iPhonu).
//
// Zabezpečení:
// - každý požadavek musí nést přístupový token přihlášeného uživatele;
// - funkce posílá jen členům domácnosti volajícího, nikdy nikomu jinému;
// - klíč pro podepisování (VAPID) vznikne při prvním použití a uloží se do
//   tabulky, ke které nemají uživatelé přístup. Čte se servisním klíčem,
//   který existuje jen na serveru (proměnná prostředí funkce), nikdy
//   v aplikaci.
//
// Bez závislostí (jen Web Crypto), aby šla funkce nasadit z editoru
// v administraci Supabase.

export interface Env {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  subject: string;
}

type Bytes = Uint8Array<ArrayBuffer>;

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface Subscription {
  id?: string;
  user_id?: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}

export interface NewsItem {
  kind: "wish" | "shopping";
  title: string;
}

const ALLOWED_ORIGINS = [
  "https://hincep-lab.github.io",
  "http://localhost",
];

// ------------------------------------------------------------ base64url

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(text: string): Bytes {
  const s = text.replace(/-/g, "+").replace(/_/g, "/");
  const padded = s + "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

const text = new TextEncoder();

// ------------------------------------------------------------ VAPID klíče

export interface VapidKeys {
  publicKey: string; // 65 bajtů (nekomprimovaný bod P-256), base64url
  privateJwk: JsonWebKey;
}

export async function generateVapidKeys(): Promise<VapidKeys> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return { publicKey: b64url(raw), privateJwk: jwk };
}

/// Podepsaný token VAPID (JWT ES256) pro push službu daného endpointu.
export async function vapidJwt(
  endpoint: string,
  keys: VapidKeys,
  subject: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const aud = new URL(endpoint).origin;
  const header = b64url(text.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64url(text.encode(JSON.stringify({
    aud,
    exp: nowSeconds + 12 * 3600,
    sub: subject,
  })));
  const key = await crypto.subtle.importKey(
    "jwk",
    { ...keys.privateJwk, key_ops: ["sign"] },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      text.encode(`${header}.${claims}`),
    ),
  );
  return `${header}.${claims}.${b64url(signature)}`;
}

// ------------------------------------------------- šifrování (RFC 8291)

async function hkdf(
  salt: Bytes,
  ikm: Bytes,
  info: Bytes,
  length: number,
): Promise<Bytes> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt, info },
      key,
      length * 8,
    ),
  );
}

/// Zašifruje obsah oznámení pro jedno zařízení (Content-Encoding: aes128gcm).
export async function encryptPayload(
  payload: Uint8Array,
  subscription: { p256dh: string; auth: string },
  fixed?: { salt: Bytes; serverKeys: CryptoKeyPair },
): Promise<Bytes> {
  const uaPublic = fromB64url(subscription.p256dh);
  const authSecret = fromB64url(subscription.auth);
  const serverKeys = fixed?.serverKeys ?? await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  ) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", serverKeys.publicKey));
  const uaKey = await crypto.subtle.importKey(
    "raw",
    uaPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, serverKeys.privateKey, 256),
  );
  const ikm = await hkdf(
    authSecret,
    shared,
    concat(text.encode("WebPush: info\0"), uaPublic, asPublic),
    32,
  );
  const salt: Bytes = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, text.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, text.encode("Content-Encoding: nonce\0"), 12);
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce },
      aes,
      concat(payload, new Uint8Array([2])),
    ),
  );
  const rs = new Uint8Array([0, 0, 16, 0]); // 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}

/// Odešle jedno oznámení. Vrací HTTP stav push služby (404/410 = zařízení
/// se odhlásilo).
export async function sendPush(
  subscription: Subscription,
  message: { title: string; body: string; tag?: string },
  keys: VapidKeys,
  subject: string,
  fetchImpl: FetchLike,
): Promise<number> {
  const body = await encryptPayload(
    text.encode(JSON.stringify(message)),
    subscription,
  );
  const jwt = await vapidJwt(subscription.endpoint, keys, subject);
  const response = await fetchImpl(subscription.endpoint, {
    method: "POST",
    headers: {
      Authorization: `vapid t=${jwt}, k=${keys.publicKey}`,
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "86400",
      Urgency: "high",
    },
    body,
  });
  try {
    await response.body?.cancel();
  } catch {
    // tělo odpovědi nás nezajímá
  }
  return response.status;
}

// ------------------------------------------------------------ texty

export function notificationsFor(author: string, items: NewsItem[]): {
  title: string;
  body: string;
  tag: string;
}[] {
  const who = author.trim() || "Někdo z rodiny";
  const out: { title: string; body: string; tag: string }[] = [];
  for (const wish of items.filter((i) => i.kind === "wish")) {
    out.push({ title: `${who} má chuť na…`, body: wish.title, tag: "wish" });
  }
  const shopping = items.filter((i) => i.kind === "shopping").map((i) => i.title);
  if (shopping.length > 0) {
    const shown = shopping.slice(0, 3).join(", ");
    const rest = shopping.length - 3;
    const n = shopping.length;
    out.push({
      title: n === 1
        ? `${who} přidal(a) na nákup`
        : n < 5
        ? `${who} přidal(a) na nákup ${n} položky`
        : `${who} přidal(a) na nákup ${n} položek`,
      body: rest > 0 ? `${shown} a ${rest} další` : shown,
      tag: "shopping",
    });
  }
  return out;
}

export function cleanItems(value: unknown): NewsItem[] {
  if (!Array.isArray(value)) return [];
  const out: NewsItem[] = [];
  for (const item of value.slice(0, 50)) {
    const kind = item?.kind;
    const title = typeof item?.title === "string" ? item.title.trim().slice(0, 120) : "";
    if ((kind === "wish" || kind === "shopping") && title) out.push({ kind, title });
  }
  return out;
}

// ------------------------------------------------------------ Supabase

class Db {
  constructor(private env: Env, private fetchImpl: FetchLike) {}

  private serviceHeaders(): Record<string, string> {
    const key = this.env.serviceKey;
    return {
      apikey: key,
      // Nové tajné klíče (sb_secret_…) se posílají jen jako apikey.
      ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}),
      "Content-Type": "application/json",
    };
  }

  async userId(token: string): Promise<string | null> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: this.env.anonKey, Authorization: `Bearer ${token}` },
    });
    if (!response.ok) return null;
    const body = await response.json();
    return typeof body?.id === "string" ? body.id : null;
  }

  async rest(path: string, init: RequestInit = {}): Promise<any> {
    const response = await this.fetchImpl(`${this.env.supabaseUrl}/rest/v1/${path}`, {
      ...init,
      headers: { ...this.serviceHeaders(), ...(init.headers as Record<string, string> ?? {}) },
    });
    if (!response.ok) {
      throw new Error(`Databáze odpověděla ${response.status}: ${await response.text()}`);
    }
    const body = await response.text();
    return body ? JSON.parse(body) : null;
  }

  async keys(): Promise<VapidKeys> {
    const rows = await this.rest("push_server_keys?id=eq.1&select=public_key,private_jwk");
    if (Array.isArray(rows) && rows.length > 0) {
      return { publicKey: rows[0].public_key, privateJwk: rows[0].private_jwk };
    }
    const fresh = await generateVapidKeys();
    // Když dva požadavky založí klíč současně, vyhraje první a druhý ho načte.
    await this.rest("push_server_keys?on_conflict=id", {
      method: "POST",
      headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
      body: JSON.stringify({ id: 1, public_key: fresh.publicKey, private_jwk: fresh.privateJwk }),
    });
    const again = await this.rest("push_server_keys?id=eq.1&select=public_key,private_jwk");
    return { publicKey: again[0].public_key, privateJwk: again[0].private_jwk };
  }

  /// Ostatní členové domácnosti volajícího (bez něj).
  async familyOf(userId: string): Promise<string[]> {
    const mine = await this.rest(
      `household_members?user_id=eq.${userId}&select=household_id&order=joined_at.asc&limit=1`,
    );
    if (!Array.isArray(mine) || mine.length === 0) return [];
    const members = await this.rest(
      `household_members?household_id=eq.${mine[0].household_id}&select=user_id`,
    );
    return members.map((m: any) => m.user_id).filter((id: string) => id !== userId);
  }

  async nameOf(userId: string): Promise<string> {
    const rows = await this.rest(`profiles?id=eq.${userId}&select=greeting_name,display_name`);
    const p = rows?.[0] ?? {};
    return (p.greeting_name || p.display_name || "").trim();
  }

  async subscriptionsOf(userIds: string[]): Promise<Subscription[]> {
    if (userIds.length === 0) return [];
    return await this.rest(
      `push_subscriptions?user_id=in.(${userIds.join(",")})&select=id,user_id,endpoint,p256dh,auth`,
    );
  }

  async markResult(subscription: Subscription, status: number): Promise<void> {
    if (!subscription.id) return;
    if (status === 404 || status === 410) {
      await this.rest(`push_subscriptions?id=eq.${subscription.id}`, { method: "DELETE" });
    } else if (status >= 200 && status < 300) {
      await this.rest(`push_subscriptions?id=eq.${subscription.id}`, {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ last_ok_at: new Date().toISOString() }),
      });
    }
  }
}

// ------------------------------------------------------------ HTTP

function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const allowed = ALLOWED_ORIGINS.some((o) => origin === o || origin.startsWith(`${o}:`));
  return {
    "Access-Control-Allow-Origin": allowed ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

export async function handle(
  req: Request,
  env: Env,
  fetchImpl: FetchLike = fetch,
): Promise<Response> {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply(405, { error: "Jen POST." });
  if (!env.supabaseUrl || !env.anonKey || !env.serviceKey) {
    return reply(503, { error: "Funkce není nastavená." });
  }

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

  try {
    switch (payload?.action) {
      case "key": {
        const keys = await db.keys();
        return reply(200, { publicKey: keys.publicKey });
      }
      case "test": {
        const keys = await db.keys();
        const subs = await db.subscriptionsOf([userId]);
        let sent = 0;
        for (const s of subs) {
          const status = await sendPush(
            s,
            { title: "HINKredience°", body: "Oznámení fungují 👍", tag: "test" },
            keys,
            env.subject,
            fetchImpl,
          ).catch(() => 0);
          await db.markResult(s, status).catch(() => {});
          if (status >= 200 && status < 300) sent++;
        }
        return reply(200, { devices: subs.length, sent });
      }
      case "notify": {
        const items = cleanItems(payload?.items);
        if (items.length === 0) return reply(200, { sent: 0 });
        const family = await db.familyOf(userId);
        if (family.length === 0) return reply(200, { sent: 0 });
        const subs = await db.subscriptionsOf(family);
        if (subs.length === 0) return reply(200, { sent: 0 });
        const keys = await db.keys();
        const messages = notificationsFor(await db.nameOf(userId), items);
        let sent = 0;
        for (const s of subs) {
          for (const m of messages) {
            const status = await sendPush(s, m, keys, env.subject, fetchImpl).catch(() => 0);
            await db.markResult(s, status).catch(() => {});
            if (status >= 200 && status < 300) sent++;
            if (status === 404 || status === 410) break;
          }
        }
        return reply(200, { sent });
      }
      default:
        return reply(400, { error: "Neznámá akce." });
    }
  } catch (error) {
    console.error("push:", error);
    return reply(500, { error: "Oznámení se nepodařilo odeslat." });
  }
}

/// Servisní klíč, který Supabase dává serverovým funkcím: starý
/// (SUPABASE_SERVICE_ROLE_KEY) nebo nový (SUPABASE_SECRET_KEYS = JSON).
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
  return {
    supabaseUrl: (get("SUPABASE_URL") ?? "").replace(/\/+$/, ""),
    anonKey: get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: serviceKeyFrom(get),
    subject: get("PUSH_SUBJECT") || "https://hincep-lab.github.io/hinkredience-login/",
  };
}

if (import.meta.main) {
  // deno-lint-ignore no-explicit-any
  const deno = (globalThis as any).Deno;
  deno.serve((req: Request) => handle(req, envFromDeno((name) => deno.env.get(name))));
}

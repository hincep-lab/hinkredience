import {
  b64url,
  cleanItems,
  encryptPayload,
  fromB64url,
  generateVapidKeys,
  handle,
  notificationsFor,
  vapidJwt,
} from "./index.ts";

function assert(cond: unknown, msg = "assert"): asserts cond {
  if (!cond) throw new Error(msg);
}
function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} ${x} !== ${y}`);
}

const enc = new TextEncoder();

async function hkdf(
  salt: Uint8Array<ArrayBuffer>,
  ikm: Uint8Array<ArrayBuffer>,
  info: Uint8Array<ArrayBuffer>,
  len: number,
) {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(
    await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, len * 8),
  );
}

/// Dešifrování tak, jak to dělá prohlížeč (RFC 8291 / 8188).
async function decrypt(
  body: Uint8Array<ArrayBuffer>,
  ua: CryptoKeyPair,
  authSecret: Uint8Array<ArrayBuffer>,
): Promise<string> {
  const salt = body.slice(0, 16);
  const idlen = body[20];
  const asPublic = body.slice(21, 21 + idlen);
  const cipher = body.slice(21 + idlen);
  const uaPublic = new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey));
  const asKey = await crypto.subtle.importKey(
    "raw", asPublic, { name: "ECDH", namedCurve: "P-256" }, false, [],
  );
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: asKey }, ua.privateKey, 256),
  );
  const info = new Uint8Array([...enc.encode("WebPush: info\0"), ...uaPublic, ...asPublic]);
  const ikm = await hkdf(authSecret, shared, info, 32);
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]);
  const plain = new Uint8Array(
    await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, aes, cipher),
  );
  eq(plain[plain.length - 1], 2, "oddělovač posledního záznamu");
  eq([...body.slice(16, 20)], [0, 0, 16, 0], "velikost záznamu 4096");
  return new TextDecoder().decode(plain.slice(0, -1));
}

async function device() {
  const ua = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"],
  ) as CryptoKeyPair;
  const auth = crypto.getRandomValues(new Uint8Array(16));
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey));
  return { ua, auth, sub: { p256dh: b64url(raw), auth: b64url(auth) } };
}

Deno.test("šifrování oznámení jde v zařízení rozšifrovat", async () => {
  const d = await device();
  const body = await encryptPayload(enc.encode('{"title":"Ahoj ěščř"}'), d.sub);
  eq(await decrypt(body, d.ua, d.auth), '{"title":"Ahoj ěščř"}');
});

Deno.test("VAPID token je platně podepsaný a míří na push službu", async () => {
  const keys = await generateVapidKeys();
  eq(fromB64url(keys.publicKey).length, 65);
  const jwt = await vapidJwt("https://web.push.apple.com/abc", keys, "https://x.test/", 1000);
  const [h, c, s] = jwt.split(".");
  const claims = JSON.parse(new TextDecoder().decode(fromB64url(c)));
  eq(claims, { aud: "https://web.push.apple.com", exp: 1000 + 43200, sub: "https://x.test/" });
  const pub = await crypto.subtle.importKey(
    "raw", fromB64url(keys.publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
  );
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, pub, fromB64url(s), enc.encode(`${h}.${c}`),
    ),
    "podpis",
  );
});

Deno.test("texty oznámení a čištění vstupu", () => {
  eq(notificationsFor("Martinka", [
    { kind: "wish", title: "Svíčková" },
    { kind: "shopping", title: "Mléko" },
    { kind: "shopping", title: "Chléb" },
  ]).map((n) => [n.title, n.body]), [
    ["Martinka má chuť na…", "Svíčková"],
    ["Martinka přidal(a) na nákup 2 položky", "Mléko, Chléb"],
  ]);
  eq(
    notificationsFor("", ["A", "B", "C", "D", "E"].map((t) => ({ kind: "shopping" as const, title: t })))[0],
    { title: "Někdo z rodiny přidal(a) na nákup 5 položek", body: "A, B, C a 2 další", tag: "shopping" },
  );
  eq(cleanItems([{ kind: "x", title: "a" }, { kind: "wish", title: "  " }, { kind: "wish", title: " Guláš " }]), [
    { kind: "wish", title: "Guláš" },
  ]);
  eq(cleanItems("nic"), []);
});

// ------------------------------------------------------- celý průběh

const ENV = {
  supabaseUrl: "https://db.test",
  anonKey: "anon",
  serviceKey: "sb_secret_test",
  subject: "https://x.test/",
};

function req(body: unknown, token = "tok") {
  return new Request("https://fn.test/push", {
    method: "POST",
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      "Content-Type": "application/json",
      Origin: "https://hincep-lab.github.io",
    },
    body: JSON.stringify(body),
  });
}

async function fakeServer() {
  const martinka = await device();
  const pavelPhone = await device();
  let stored: any = null;
  const subs = [
    { id: "s1", user_id: "martinka", endpoint: "https://web.push.apple.com/m1", ...martinka.sub },
    { id: "s2", user_id: "martinka", endpoint: "https://fcm.googleapis.com/gone", ...martinka.sub },
    { id: "s3", user_id: "pavel", endpoint: "https://fcm.googleapis.com/p1", ...pavelPhone.sub },
  ];
  const pushed: { endpoint: string; body: Uint8Array<ArrayBuffer>; auth: string }[] = [];
  const deleted: string[] = [];
  const restCalls: { url: string; headers: Record<string, string> }[] = [];
  const fetchImpl = async (url: string, init: RequestInit = {}) => {
    const headers = (init.headers ?? {}) as Record<string, string>;
    if (url.endsWith("/auth/v1/user")) {
      const t = headers.Authorization;
      if (t === "Bearer tok") return Response.json({ id: "pavel" });
      if (t === "Bearer cizi") return Response.json({ id: "cizi" });
      return new Response("{}", { status: 401 });
    }
    if (url.startsWith("https://db.test/rest/v1/")) {
      restCalls.push({ url, headers });
      const path = url.slice("https://db.test/rest/v1/".length);
      if (path.startsWith("push_server_keys")) {
        if (init.method === "POST") {
          stored ??= JSON.parse(init.body as string);
          return new Response("", { status: 201 });
        }
        return Response.json(stored ? [stored] : []);
      }
      if (path.startsWith("household_members?user_id=eq.pavel")) {
        return Response.json([{ household_id: "h1" }]);
      }
      if (path.startsWith("household_members?user_id=eq.cizi")) return Response.json([]);
      if (path.startsWith("household_members?household_id=eq.h1")) {
        return Response.json([{ user_id: "pavel" }, { user_id: "martinka" }]);
      }
      if (path.startsWith("profiles?id=eq.pavel")) {
        return Response.json([{ greeting_name: "Pájo", display_name: "pavel" }]);
      }
      if (path.startsWith("push_subscriptions?user_id=in.")) {
        const ids = decodeURIComponent(path).match(/in\.\(([^)]*)\)/)![1].split(",");
        return Response.json(subs.filter((s) => ids.includes(s.user_id)));
      }
      if (path.startsWith("push_subscriptions?id=eq.") && init.method === "DELETE") {
        deleted.push(path.split("eq.")[1]);
        return new Response("", { status: 204 });
      }
      if (path.startsWith("push_subscriptions?id=eq.")) return new Response("", { status: 204 });
      return new Response("neznámé " + path, { status: 500 });
    }
    // push služby
    const auth = headers.Authorization ?? "";
    pushed.push({ endpoint: url, body: init.body as Uint8Array<ArrayBuffer>, auth });
    if (url.endsWith("/gone")) return new Response("", { status: 410 });
    return new Response("", { status: 201 });
  };
  return { fetchImpl, pushed, deleted, restCalls, martinka, getStored: () => stored };
}

Deno.test("bez platného tokenu nic", async () => {
  const s = await fakeServer();
  eq((await handle(req({ action: "key" }, ""), ENV, s.fetchImpl)).status, 401);
  eq((await handle(req({ action: "key" }, "spatny"), ENV, s.fetchImpl)).status, 401);
  eq(s.pushed.length, 0);
});

Deno.test("klíč vznikne jednou a dál se používá stejný", async () => {
  const s = await fakeServer();
  const a = await (await handle(req({ action: "key" }), ENV, s.fetchImpl)).json();
  const b = await (await handle(req({ action: "key" }), ENV, s.fetchImpl)).json();
  eq(a.publicKey, b.publicKey);
  eq(fromB64url(a.publicKey).length, 65);
  // Servisní klíč nového typu jde jen jako apikey, ne jako Bearer.
  assert(s.restCalls.every((c) => c.headers.apikey === "sb_secret_test" && !c.headers.Authorization));
});

Deno.test("oznámení dostane jen zbytek rodiny; odhlášené zařízení se smaže", async () => {
  const s = await fakeServer();
  const res = await handle(
    req({ action: "notify", items: [{ kind: "wish", title: "Svíčková" }] }),
    ENV,
    s.fetchImpl,
  );
  eq(res.status, 200);
  eq((await res.json()).sent, 1);
  eq(s.pushed.map((p) => p.endpoint), [
    "https://web.push.apple.com/m1",
    "https://fcm.googleapis.com/gone",
  ]);
  eq(s.deleted, ["s2"]);
  const msg = JSON.parse(await decrypt(s.pushed[0].body, s.martinka.ua, s.martinka.auth));
  eq(msg, { title: "Pájo má chuť na…", body: "Svíčková", tag: "wish" });
  assert(s.pushed[0].auth.startsWith("vapid t="), "VAPID hlavička");
  assert(s.pushed[0].auth.includes(`k=${s.getStored().public_key}`));
});

Deno.test("uživatel bez rodiny nikomu nic nepošle", async () => {
  const s = await fakeServer();
  const res = await handle(
    req({ action: "notify", items: [{ kind: "shopping", title: "Mléko" }] }, "cizi"),
    ENV,
    s.fetchImpl,
  );
  eq((await res.json()).sent, 0);
  eq(s.pushed.length, 0);
});

Deno.test("zkušební oznámení jde jen na vlastní zařízení", async () => {
  const s = await fakeServer();
  const res = await handle(req({ action: "test" }), ENV, s.fetchImpl);
  eq(await res.json(), { devices: 1, sent: 1 });
  eq(s.pushed.map((p) => p.endpoint), ["https://fcm.googleapis.com/p1"]);
});

Deno.test("CORS a metody", async () => {
  const s = await fakeServer();
  const opt = await handle(
    new Request("https://fn.test/push", { method: "OPTIONS", headers: { Origin: "https://hincep-lab.github.io" } }),
    ENV,
    s.fetchImpl,
  );
  eq(opt.status, 204);
  eq(opt.headers.get("Access-Control-Allow-Origin"), "https://hincep-lab.github.io");
  eq((await handle(new Request("https://fn.test/push"), ENV, s.fetchImpl)).status, 405);
});

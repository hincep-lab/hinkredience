// Bez externích knihoven (CI i lokální běh bez přístupu k registrům).
function assert(c: unknown, msg = "assert"): asserts c {
  if (!c) throw new Error(msg);
}
function assertFalse(c: unknown, msg = "assertFalse") {
  if (c) throw new Error(msg);
}
function assertEquals(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a);
  const y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} očekáváno ${y}, je ${x}`);
}
function assertStringIncludes(s: string, part: string) {
  if (!s.includes(part)) throw new Error(`„${part}“ chybí v: ${s}`);
}
import { buildPrompt, type Env, handle, type Job, run, validPath } from "./index.ts";

const OWNER = "db9e200c-4beb-4559-b9ab-ed8b71dee597";
const RECIPE = "4a5a092e-91e6-4a15-8b1c-5558293ebc83";
const PHOTO = "4f5037f4-9139-414e-8a79-dc271edb124d";
const JOB = "aaaaaaaa-0000-4000-8000-000000000001";
const CRON = "k".repeat(64);
const HOST = "wjqpzoeheonjwdyyezhb.supabase.co";

const env: Env = {
  supabaseUrl: `https://${HOST}`,
  serviceKey: "sb_secret_test",
  cfAccountId: "0123456789abcdef0123456789abcdef",
  cfToken: "cf-test-token",
  expectedHost: HOST,
};

/** Malý platný JPEG (hlavička + výplň) jako base64. */
function jpegB64(size = 6000): string {
  const bytes = new Uint8Array(size);
  bytes.set([0xff, 0xd8, 0xff, 0xe0]);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function job(over: Partial<Job> = {}): Job {
  return {
    job_id: JOB,
    recipe_id: RECIPE,
    owner_id: OWNER,
    photo_id: PHOTO,
    path: `${OWNER}/${RECIPE}/${PHOTO}.jpg`,
    status: "reserved",
    title: "Kung pao – čínské kuře s arašídy (nepálivé)",
    description: "Kuřecí stehna v husté omáčce s arašídy.",
    category: "Drůbež a králík",
    tags: ["Čínská kuchyně", "Pánev", "Rychlé jídlo"],
    ingredients: [{ name: "Kuřecí stehenní řízky" }, { name: "Sůl" }, { name: "Pražené arašídy" }],
    steps: ["Opečte kuře na pánvi."],
    reason: "nový",
    ...over,
  };
}

interface Call {
  method: string;
  url: string;
  body: string;
  headers: Record<string, string>;
}

/** Falešný Supabase + Cloudflare. `world` drží stav receptu a úloh. */
function fake(opts: {
  jobs?: Job[];
  photos?: unknown[];
  ai?: (n: number) => Response | Promise<Response>;
  attachResult?: boolean;
  uploadStatus?: number;
  objectExists?: boolean;
}) {
  const calls: Call[] = [];
  const world = {
    photos: opts.photos ?? [] as unknown[],
    progress: [] as Record<string, unknown>[],
    uploaded: [] as string[],
    aiCalls: 0,
  };
  const fetchImpl = async (url: string, init: RequestInit = {}): Promise<Response> => {
    const method = init.method ?? "GET";
    const body = typeof init.body === "string" ? init.body : "";
    calls.push({ method, url, body, headers: (init.headers ?? {}) as Record<string, string> });
    const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status });
    if (url.startsWith("https://api.cloudflare.com/")) {
      world.aiCalls++;
      return opts.ai ? await opts.ai(world.aiCalls) : json({ success: true, result: { image: jpegB64() } });
    }
    assert(url.startsWith(`https://${HOST}/`), `jen na projekt: ${url}`);
    if (url.includes("/rest/v1/price_cron_key")) return json([{ key: CRON }]);
    if (url.includes("/rest/v1/recipe_cover_settings")) {
      return json([{ model: "@cf/black-forest-labs/flux-1-schnell", steps: 8 }]);
    }
    if (url.endsWith("/rpc/cover_reserve")) return json(opts.jobs ?? [job()]);
    if (url.endsWith("/rpc/cover_usage")) return json([{ today_count: 1, month_usd: 0.041 }]);
    if (url.endsWith("/rpc/cover_progress")) {
      world.progress.push(JSON.parse(body));
      return new Response(null, { status: 204 });
    }
    if (url.endsWith("/rpc/cover_attach_if_empty")) {
      const ok = opts.attachResult ?? world.photos.length === 0;
      if (ok) world.photos = [{ id: PHOTO, remote_path: `${OWNER}/${RECIPE}/${PHOTO}.jpg` }];
      return json(ok);
    }
    if (url.includes("/storage/v1/object/info/")) {
      return (opts.objectExists ?? world.uploaded.length > 0) ? json({ size: 250_000 }) : json({}, 404);
    }
    if (url.includes("/storage/v1/object/") && method === "POST") {
      world.uploaded.push(url);
      return opts.uploadStatus ? json({ error: "x" }, opts.uploadStatus) : json({ Key: "x" });
    }
    if (url.includes("/rest/v1/recipes?")) return json([{ photos: world.photos }]);
    throw new Error(`Neočekávané volání ${method} ${url}`);
  };
  return { fetchImpl, calls, world };
}

Deno.test("zadání: jedno jídlo, suroviny a způsob přípravy, bez textu a koláží", () => {
  const p = buildPrompt(job());
  assertStringIncludes(p, "one finished dish");
  assertStringIncludes(p, "Kung pao");
  assertStringIncludes(p, "Pražené arašídy");
  assertStringIncludes(p, "pan-cooked");
  assertStringIncludes(p, "Čínská kuchyně");
  assertStringIncludes(p, "no collage");
  assertStringIncludes(p, "no text");
  assertStringIncludes(p, "no watermark");
  assertFalse(p.includes("Sůl"), "sůl se do zadání nedává");
});

Deno.test("cesta souboru jen <vlastník>/<recept>/<fotka>.jpg", () => {
  assert(validPath(job()));
  assertFalse(validPath(job({ path: `${OWNER}/${RECIPE}/../x.jpg` })));
  assertFalse(validPath(job({ path: `jiny/${RECIPE}/${PHOTO}.jpg` })));
  assertFalse(validPath(job({ photo_id: null })));
});

Deno.test("úspěch: vygeneruje JPEG, nahraje bez přepisu, přiřadí a ověří", async () => {
  const f = fake({});
  const out = await run(env, { limit: 1, dryRun: false }, f.fetchImpl);
  assertEquals(out.results.map((r) => r.status), ["attached"]);
  assertEquals(f.world.aiCalls, 1);
  const ai = f.calls.find((c) => c.url.startsWith("https://api.cloudflare.com/"))!;
  assertEquals(
    ai.url,
    "https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/ai/run/@cf/black-forest-labs/flux-1-schnell",
  );
  const req = JSON.parse(ai.body);
  assertEquals(req.steps, 8);
  assert(req.prompt.length <= 2048);
  assertStringIncludes(req.prompt, "Kung pao");
  const upload = f.calls.find((c) => c.url.includes("/storage/v1/object/recipe-photos/"))!;
  assertEquals(upload.headers["x-upsert"], "false");
  assertEquals(upload.headers["Content-Type"], "image/jpeg");
  assertStringIncludes(upload.url, `${OWNER}/${RECIPE}/${PHOTO}.jpg`);
  assertEquals(f.world.progress.map((p) => p.p_status), ["generated", "uploaded"]);
  // Servisní klíč šel jen na projekt, Cloudflare dostal jen svůj token.
  assertEquals(ai.headers.Authorization, "Bearer cf-test-token");
  assertFalse(JSON.stringify(ai.headers).includes("sb_secret"));
  // Nikde žádné mazání ani PATCH receptu.
  assertFalse(f.calls.some((c) => c.method === "DELETE" || c.method === "PATCH"));
});

Deno.test("PNG z modelu se uloží jako .png", async () => {
  const png = new Uint8Array(6000);
  png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  let b = "";
  for (const x of png) b += String.fromCharCode(x);
  const f = fake({ ai: () => new Response(JSON.stringify({ success: true, result: { image: btoa(b) } })) });
  const out = await run(env, { limit: 1, dryRun: false }, f.fetchImpl);
  assertEquals(out.results[0].status, "attached");
  const upload = f.calls.find((c) => c.url.includes("/storage/v1/object/recipe-photos/"))!;
  assertStringIncludes(upload.url, `${PHOTO}.png`);
  assertEquals(upload.headers["Content-Type"], "image/png");
  assertEquals(f.world.progress[0].p_path, `${OWNER}/${RECIPE}/${PHOTO}.png`);
});

Deno.test("vyčerpaný bezplatný příděl (429): odložit, další recepty už nezkoušet", async () => {
  const second = job({ job_id: "aaaaaaaa-0000-4000-8000-000000000002" });
  const f = fake({
    jobs: [job(), second],
    ai: () =>
      new Response(JSON.stringify({ success: false, errors: [{ code: 4006, message: "daily free allocation of 10,000 neurons used" }] }), {
        status: 429,
      }),
  });
  const out = await run(env, { limit: 2, dryRun: false }, f.fetchImpl);
  assertEquals(out.results.length, 2);
  assertEquals(f.world.aiCalls, 1, "po vyčerpání se další požadavek neposílá");
  assertEquals(f.world.progress.map((p) => p.p_status), ["postponed", "postponed"]);
});

Deno.test("recept mezitím dostal fotku: nic se nepřepíše ani nesmaže", async () => {
  const existing = [{ id: "jina-fotka", remote_path: "x/y/z.jpg" }];
  const f = fake({ photos: existing, attachResult: false });
  const out = await run(env, { limit: 1, dryRun: false }, f.fetchImpl);
  assertEquals(out.results[0].status, "skipped");
  assertEquals(f.world.photos, existing);
  assertFalse(f.calls.some((c) => c.method === "DELETE"));
});

Deno.test("odmítnuté generování (HTTP 400): pokus selže, žádné nahrání", async () => {
  const f = fake({
    ai: () => new Response(JSON.stringify({ success: false, errors: [{ code: 3030, message: "NSFW" }] }), { status: 400 }),
  });
  const out = await run(env, { limit: 1, dryRun: false }, f.fetchImpl);
  assertEquals(out.results[0].status, "failed");
  assertStringIncludes(out.results[0].error!, "3030");
  assertEquals(f.world.progress.map((p) => p.p_status), ["failed"]);
  assertEquals(f.world.uploaded.length, 0);
});

Deno.test("přerušené spojení: pokus selže, nic se nenahraje", async () => {
  const f = fake({ ai: () => Promise.reject(new TypeError("network")) });
  const out = await run(env, { limit: 1, dryRun: false }, f.fetchImpl);
  assertEquals(out.results[0].status, "failed");
  assertEquals(f.world.progress[0].p_status, "failed");
  assertEquals(f.world.uploaded.length, 0);
});

Deno.test("neplatný obrázek se nenahraje", async () => {
  const f = fake({ ai: () => new Response(JSON.stringify({ success: true, result: { image: btoa("PNG?") } })) });
  const out = await run(env, { limit: 1, dryRun: false }, f.fetchImpl);
  assertEquals(out.results[0].status, "failed");
  assertEquals(f.world.uploaded.length, 0);
});

Deno.test("chyba nahrání: úloha zůstane rozpracovaná, další běh ji dokončí bez generování", async () => {
  const first = fake({ uploadStatus: 500 });
  const out = await run(env, { limit: 1, dryRun: false }, first.fetchImpl);
  assertEquals(out.results[0].status, "failed");
  assertEquals(first.world.progress.at(-1)?.p_status, "generated");
  // Další běh: databáze vrátí rozpracovanou úlohu se souborem.
  const second = fake({ jobs: [job({ status: "generated", reason: "dokončení" })], objectExists: true });
  const out2 = await run(env, { limit: 1, dryRun: false }, second.fetchImpl);
  assertEquals(out2.results[0].status, "attached");
  assertEquals(second.world.aiCalls, 0, "znovu se negeneruje");
});

Deno.test("dry-run: nic negeneruje, nenahrává ani nezapisuje", async () => {
  const f = fake({ jobs: [job({ job_id: null, status: "dry-run", photo_id: null, path: "" })] });
  const out = await run(env, { limit: 5, dryRun: true }, f.fetchImpl);
  assertEquals(out.results.map((r) => r.status), ["dry-run"]);
  assertEquals(f.world.aiCalls, 0);
  assertEquals(f.world.uploaded.length, 0);
  assertEquals(f.world.progress.length, 0);
  const reserve = f.calls.find((c) => c.url.endsWith("/rpc/cover_reserve"))!;
  assertEquals(JSON.parse(reserve.body), { p_limit: 5, p_dry_run: true });
});

Deno.test("bez Cloudflare tokenu se nic nerezervuje", async () => {
  const f = fake({});
  const out = await run({ ...env, cfToken: "" }, { limit: 5, dryRun: false }, f.fetchImpl);
  assertEquals(out.results.length, 0);
  assertFalse(f.calls.some((c) => c.url.endsWith("/rpc/cover_reserve")));
  assertEquals(f.world.aiCalls, 0);
});

Deno.test("limit za běh nejvýš 5", async () => {
  const f = fake({ jobs: [] });
  await run(env, { limit: 50, dryRun: false }, f.fetchImpl);
  const reserve = f.calls.find((c) => c.url.endsWith("/rpc/cover_reserve"))!;
  assertEquals(JSON.parse(reserve.body).p_limit, 5);
});

Deno.test("HTTP: bez klíče plánované úlohy 401, cizí adresa projektu 503", async () => {
  const f = fake({});
  const post = (headers: Record<string, string>, body: unknown) =>
    new Request("https://x/functions/v1/recipe-covers", {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
  assertEquals((await handle(post({}, { action: "run" }), env, f.fetchImpl)).status, 401);
  assertEquals((await handle(post({ "x-cron-key": "spatny".repeat(11) }, { action: "run" }), env, f.fetchImpl)).status, 401);
  const evil = await handle(
    post({ "x-cron-key": CRON }, { action: "run" }),
    { ...env, supabaseUrl: "https://evil.example.com" },
    f.fetchImpl,
  );
  assertEquals(evil.status, 503);
  assertFalse(f.calls.some((c) => c.url.includes("evil")), "klíč se na cizí adresu nepošle");
  const ok = await handle(post({ "x-cron-key": CRON }, { action: "dry-run", limit: 2 }), env, fake({}).fetchImpl);
  assertEquals(ok.status, 200);
  assertEquals((await handle(post({ "x-cron-key": CRON }, { action: "smazat" }), env, f.fetchImpl)).status, 400);
});

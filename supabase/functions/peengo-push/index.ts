// Peengo günlük hatırlatıcılar: sabah 07:00 günaydın, akşam 20:00 gece alarmı.
// İstekler:
//   {kind:"key"}               -> bildirim açık anahtarı (ilk çağrıda anahtarlar üretilir)
//   {kind:"selftest"}          -> şifreleme ve imza testi (bildirim göndermez)
//   {kind:"test", token}       -> sadece o oyuncunun cihazlarına deneme bildirimi
//   {kind:"morning"|"evening"} -> herkese; sadece zamanlayıcı (x-peengo-cron başlığı) çağırabilir
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Sunucu anahtarı Supabase tarafından fonksiyona otomatik verilir (koda yazılmaz)
function serverKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  try {
    const v = JSON.parse(raw);
    if (typeof v === "string") return v;
    const first = Object.values(v || {})[0];
    if (typeof first === "string") return first;
  } catch { /* düz metin */ }
  return raw;
}
const sb = createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), {
  auth: { persistSession: false },
});

const SITE = "https://gekall.github.io/peengo/";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const b64u = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const pad = (n: number) => String(n).padStart(2, "0");
const pick = <T>(a: T[]) => a[Math.floor(Math.random() * a.length)];

type Cfg = { vapid_public: string; vapid_private: string; cron_secret: string; anon_key: string | null };

async function config(): Promise<Cfg> {
  let { data, error } = await sb.from("push_config").select("*").eq("id", 1).single();
  if (error) throw error;
  if (!data.vapid_public || !data.vapid_private) {
    const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const pub = b64u(await crypto.subtle.exportKey("raw", kp.publicKey));
    const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
    await sb.from("push_config").update({ vapid_public: pub, vapid_private: jwk.d }).eq("id", 1).is("vapid_public", null);
    ({ data, error } = await sb.from("push_config").select("*").eq("id", 1).single());
    if (error) throw error;
  }
  webpush.setVapidDetails(SITE, data.vapid_public, data.vapid_private);
  return data as Cfg;
}

// Zamanlayıcının bu fonksiyonu doğrulanmış çağırabilmesi için herkese açık (anon) anahtarı kilitli tabloya kaydet.
// Kaynak: ortam değişkeni, yoksa sitenin isteğiyle gelen ve Supabase'in imzasını zaten doğruladığı anon anahtar.
async function rememberAnon(cfg: Cfg, req: Request) {
  let anon = Deno.env.get("SUPABASE_ANON_KEY") || "";
  if (!anon.startsWith("eyJ")) {
    const m = /^Bearer\s+(eyJ[\w-]+\.[\w-]+\.[\w-]+)$/.exec(req.headers.get("authorization") || "");
    if (m) {
      try {
        const p = JSON.parse(atob(m[1].split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
        if (p.role === "anon") anon = m[1];
      } catch { /* geçersiz */ }
    }
  }
  if (anon.startsWith("eyJ") && cfg.anon_key !== anon) {
    await sb.from("push_config").update({ anon_key: anon }).eq("id", 1);
    cfg.anon_key = anon;
  }
}

const MORNING_TITLES = [
  "Günaydın pisuvar canavarı 🚽",
  "Günaydın mesane şampiyonu 💧",
  "Kalk bakalım klozet kralı 👑",
  "Günaydın sifon savaşçısı ⚔️",
  "Uyan, duvar seni bekliyor 🧱",
];
const EVENING_TITLES = [
  "Gece alarmları kuruldu mu?? ⏰",
  "Bu gece nöbet var mı? 🌙",
  "Alarm kur, dakika kap ⏰",
];

function emptyIn(mine: Set<number>, h: number) {
  let e = 0;
  for (let m = 0; m < 60; m++) if (!mine.has(h * 60 + m)) e++;
  return e;
}

function morning(name: string, mine: Set<number>) {
  let best = 7, bestE = -1;
  for (let h = 7; h <= 22; h++) {
    const e = emptyIn(mine, h);
    if (e > bestE) { bestE = e; best = h; }
  }
  const body = bestE <= 0
    ? `${name}, gündüz duvarın full! Artık gece nöbeti zamanı 🌙`
    : `${name}, bugünün hedefi ${pad(best)}:00–${pad(best)}:59. Orada ${bestE} dakikan boş. Duvarın: ${mine.size}/1440.`;
  return { title: pick(MORNING_TITLES), body, tag: "peengo-sabah" };
}

function evening(name: string, mine: Set<number>) {
  let total = 0, best = 0, bestE = -1;
  for (let h = 0; h < 7; h++) {
    const e = emptyIn(mine, h);
    total += e;
    if (e > bestE) { bestE = e; best = h; }
  }
  const body = total === 0
    ? `${name}, gece duvarın tamamen dolu. Rahat uyu, efsanesin 👑`
    : `${name}, gecede ${total} boş dakikan var. En boş saat ${pad(best)}:00 (${bestE} boş). Bir alarm, bir dakika!`;
  return { title: pick(EVENING_TITLES), body, tag: "peengo-aksam" };
}

async function sendTo(ids: string[] | null, kind: string) {
  let q = sb.from("push_subs").select("id,player_id,endpoint,p256dh,auth");
  if (ids) q = q.in("player_id", ids);
  const { data: subs, error } = await q;
  if (error) throw error;
  if (!subs || !subs.length) return { sent: 0, subs: 0, removed: 0 };

  const pids = [...new Set(subs.map((s) => s.player_id))];
  const { data: players } = await sb.from("players").select("id,name").in("id", pids);
  const names: Record<string, string> = Object.fromEntries((players || []).map((p) => [p.id, p.name]));
  const marks: Record<string, Set<number>> = {};
  for (let from = 0; ; from += 1000) {
    const { data, error: e } = await sb.from("marks").select("player_id,minute")
      .in("player_id", pids).order("player_id").order("minute").range(from, from + 999);
    if (e) throw e;
    (data || []).forEach((r) => (marks[r.player_id] ||= new Set()).add(r.minute));
    if (!data || data.length < 1000) break;
  }

  let sent = 0, removed = 0, failed = 0;
  await Promise.all(subs.map(async (s) => {
    const name = names[s.player_id] || "Peengo";
    const mine = marks[s.player_id] || new Set<number>();
    const msg = kind === "morning" ? morning(name, mine)
      : kind === "evening" ? evening(name, mine)
      : { title: "Peengo bildirimleri açık ✅", body: `${name}, hatırlatıcılar sabah 07:00 ve akşam 20:00'de gelecek.`, tag: "peengo-test" };
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ ...msg, url: SITE }),
        { TTL: 6 * 3600, urgency: "normal" },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        await sb.from("push_subs").delete().eq("id", s.id);
        removed++;
      } else failed++;
    }
  }));
  return { sent, subs: subs.length, removed, failed };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Sadece POST" }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* boş gövde */ }
  const kind = String(body.kind || "");
  try {
    const cfg = await config();
    await rememberAnon(cfg, req);
    if (kind === "key") return json({ publicKey: cfg.vapid_public });

    if (kind === "selftest") {
      const kp = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
      const p256dh = b64u(await crypto.subtle.exportKey("raw", kp.publicKey));
      const auth = b64u(crypto.getRandomValues(new Uint8Array(16)));
      const d = webpush.generateRequestDetails(
        { endpoint: "https://fcm.googleapis.com/fcm/send/peengo-selftest", keys: { p256dh, auth } },
        JSON.stringify({ title: "test", body: "test" }),
      );
      return json({ ok: true, signed: String(d.headers.Authorization || "").startsWith("vapid"), bytes: d.body.length });
    }

    if (kind === "test") {
      const token = String(body.token || "");
      if (!/^[0-9a-f-]{36}$/.test(token)) return json({ error: "Oturumun kapanmış. Tekrar giriş yap." }, 401);
      const { data: s } = await sb.from("sessions").select("player_id").eq("token", token).maybeSingle();
      if (!s) return json({ error: "Oturumun kapanmış. Tekrar giriş yap." }, 401);
      return json(await sendTo([s.player_id], "test"));
    }

    if (kind === "morning" || kind === "evening") {
      if (req.headers.get("x-peengo-cron") !== cfg.cron_secret) return json({ error: "yetkisiz" }, 403);
      return json(await sendTo(null, kind));
    }

    return json({ error: "Bilinmeyen istek" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});

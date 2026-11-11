// Niet Café: отправка Web Push (версия 2). Вызывается из базы (push_send в 7_push.sql / 33_push_all.sql).
// Развернуть БЕЗ проверки JWT (Verify JWT = off): защита — секрет в заголовке x-push-secret.
//
// Событие: { kind, title, body, tag, url?, delay? (сек, до 25), и ОДИН из адресатов:
//            to_user: uuid | to_role: 'waiter' | to_roles: ['store','boss'] | to_guest: <номер заявки гостя> }
// Уведомление уходит с высоким приоритетом (urgency: high) — телефон показывает его и на заблокированном экране.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@niet.cafe",
  Deno.env.get("VAPID_PUBLIC")!,
  Deno.env.get("VAPID_PRIVATE")!,
);

// сколько живёт уведомление, если телефон без сети (потом становится неактуальным)
const TTL: Record<string, number> = { test: 120, guest: 1800, low: 21600, stop: 3600, unstop: 3600 };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Sub = { id: number; endpoint: string; p256dh: string; auth_key: string; guest?: boolean };

async function staffSubs(e: any): Promise<Sub[]> {
  let ids: string[] = [];
  if (e.to_user) ids = [e.to_user];
  else {
    const roles: string[] = e.to_roles ?? (e.to_role ? [e.to_role] : []);
    if (!roles.length) return [];
    const { data } = await sb.from("profiles").select("id").in("role", roles);
    ids = (data ?? []).map((p: any) => p.id);
  }
  if (!ids.length) return [];
  const { data } = await sb.from("push_subs").select("id,endpoint,p256dh,auth_key").in("user_id", ids);
  return (data ?? []) as Sub[];
}

async function guestSubs(gid: number): Promise<Sub[]> {
  const { data } = await sb.from("guest_push_subs").select("id,endpoint,p256dh,auth_key").eq("gorder_id", gid);
  return (data ?? []).map((s: any) => ({ ...s, guest: true }));
}

async function sendOne(s: Sub, payload: string, ttl: number) {
  const table = s.guest ? "guest_push_subs" : "push_subs";
  try {
    await webpush.sendNotification(
      { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
      payload, { TTL: ttl, urgency: "high" },
    );
    if (!s.guest) await sb.from(table).update({ last_ok: new Date().toISOString(), fails: 0, last_err: null }).eq("id", s.id);
    return 1;
  } catch (err: any) {
    const code = err?.statusCode;
    if (code === 404 || code === 410) { await sb.from(table).delete().eq("id", s.id); return -1; }  // подписка умерла
    console.error("push error", code, err?.body ?? err?.message);
    if (!s.guest) {
      const { data } = await sb.from(table).select("fails").eq("id", s.id).maybeSingle();
      await sb.from(table).update({ fails: (data?.fails ?? 0) + 1, last_err: (String(code ?? "") + " " + String(err?.body ?? err?.message ?? "")).trim().slice(0, 200) }).eq("id", s.id);
    }
    return 0;
  }
}

async function handle(e: any) {
  const subs = e.to_guest != null ? await guestSubs(+e.to_guest) : await staffSubs(e);
  if (!subs.length) return { sent: 0, dead: 0 };
  const payload = JSON.stringify({ title: e.title, body: e.body ?? "", tag: e.tag, kind: e.kind, url: e.url });
  const ttl = TTL[e.kind] ?? 900;
  const seen = new Set<string>();
  let sent = 0, dead = 0;
  await Promise.all(subs.filter((s) => !seen.has(s.endpoint) && seen.add(s.endpoint)).map(async (s) => {
    const r = await sendOne(s, payload, ttl);
    if (r > 0) sent++; else if (r < 0) dead++;
  }));
  return { sent, dead };
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_SECRET");
  if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("forbidden", { status: 403 });

  let events: any[] = [];
  try { const b = await req.json(); events = Array.isArray(b) ? b : [b]; } catch { return new Response("bad json", { status: 400 }); }

  const now = events.filter((e) => !(+e.delay > 0));
  const later = events.filter((e) => +e.delay > 0);

  // отложенные (проверка «заблокируйте телефон»): отвечаем базе сразу, отправляем в фоне
  if (later.length) {
    const job = (async () => {
      for (const e of later) { await sleep(Math.min(+e.delay, 25) * 1000); await handle(e); }
    })();
    // @ts-ignore EdgeRuntime есть в Supabase Edge Functions
    if (typeof EdgeRuntime !== "undefined" && EdgeRuntime.waitUntil) EdgeRuntime.waitUntil(job); else await job;
  }

  let sent = 0, dead = 0;
  for (const e of now) { const r = await handle(e); sent += r.sent; dead += r.dead; }
  return new Response(JSON.stringify({ sent, dead, queued: later.length }), { headers: { "Content-Type": "application/json" } });
});

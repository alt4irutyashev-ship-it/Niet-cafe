// Niet Café: отправка Web Push. Вызывается из базы (7_push.sql -> push_send).
// Развернуть БЕЗ проверки JWT (Verify JWT = off): защита — секрет в заголовке x-push-secret.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@niet.cafe",
  Deno.env.get("VAPID_PUBLIC")!,
  Deno.env.get("VAPID_PRIVATE")!,
);

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_SECRET");
  if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("forbidden", { status: 403 });

  let events: any[] = [];
  try { const b = await req.json(); events = Array.isArray(b) ? b : [b]; } catch { return new Response("bad json", { status: 400 }); }

  let sent = 0, dead = 0;
  for (const e of events) {
    // кому: конкретному сотруднику или всем с ролью (роль берётся из profiles — всегда актуальная)
    let ids: string[] = [];
    if (e.to_user) ids = [e.to_user];
    else if (e.to_role) {
      const { data } = await sb.from("profiles").select("id").eq("role", e.to_role);
      ids = (data ?? []).map((p: any) => p.id);
    }
    if (!ids.length) continue;
    const { data: subs } = await sb.from("push_subs").select("id,endpoint,p256dh,auth_key").in("user_id", ids);
    const payload = JSON.stringify({ title: e.title, body: e.body, tag: e.tag, kind: e.kind });
    await Promise.all((subs ?? []).map(async (s: any) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
          payload, { TTL: 600, urgency: "high" },
        );
        sent++;
      } catch (err: any) {
        if (err?.statusCode === 404 || err?.statusCode === 410) { dead++; await sb.from("push_subs").delete().eq("id", s.id); }
        else console.error("push error", err?.statusCode, err?.body ?? err?.message);
      }
    }));
  }
  return new Response(JSON.stringify({ sent, dead }), { headers: { "Content-Type": "application/json" } });
});

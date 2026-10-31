// Approvals on the phone. The Mac sends the approvals that wait for the user; new ones are stored
// and pushed to their phones. The phone web app answers them straight in the database (its row
// rules only allow answering your own pending approvals); the Mac picks up the answers.
//
// GET  /phone/vapid → the public key phones subscribe with.
// POST /phone {"pending": [...], "gone": ["id", …]} → store new approvals and notify; mark finished ones.
import webpush from "npm:web-push@3.6.7";
import { admin, cors, currentUser, fail, json } from "../_shared/common.ts";

interface Pending {
  id: string; bot_name: string; bot_color?: string; title: string; action: string; reason?: string;
  fields?: Array<{ key: string; label: string; value: string; multiline?: boolean; list?: boolean }>;
}

const publicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const privateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
if (publicKey && privateKey) {
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "https://github.com/vgawor/orbit-releases", publicKey, privateKey);
}

async function notify(uid: string, a: Pending): Promise<void> {
  if (!publicKey || !privateKey) return;
  const { data: phones } = await admin.from("push_subscriptions").select("*").eq("user_id", uid);
  const payload = JSON.stringify({ title: `${a.bot_name} needs your OK`, body: a.title, id: a.id });
  for (const p of phones ?? []) {
    try {
      await webpush.sendNotification({ endpoint: p.endpoint, keys: { p256dh: p.p256dh, auth: p.auth } }, payload, { TTL: 3600 });
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      // The phone unsubscribed or the subscription expired.
      if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("endpoint", p.endpoint);
    }
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  if (req.method === "GET" && url.pathname.endsWith("/vapid")) return json({ publicKey });

  const user = await currentUser(req);
  if (!user) return fail(401, "Sign in to Orbit again.");
  if (req.method !== "POST") return fail(405, "Use POST.");
  const body = await req.json().catch(() => ({})) as { pending?: Pending[]; gone?: string[] };

  const pending = (body.pending ?? []).slice(0, 50);
  if (pending.length) {
    const ids = pending.map((a) => a.id);
    const { data: known } = await admin.from("approvals").select("id").eq("user_id", user.id).in("id", ids);
    const seen = new Set((known ?? []).map((r) => r.id));
    const fresh = pending.filter((a) => !seen.has(a.id));
    if (fresh.length) {
      await admin.from("approvals").insert(fresh.map((a) => ({
        user_id: user.id, id: a.id, bot_name: a.bot_name, bot_color: a.bot_color ?? null, title: a.title.slice(0, 300),
        action: a.action.slice(0, 40), reason: a.reason?.slice(0, 600) ?? null, fields: a.fields ?? [],
      })));
      for (const a of fresh) await notify(user.id, a);
    }
  }
  const gone = (body.gone ?? []).slice(0, 200);
  if (gone.length) {
    await admin.from("approvals").update({ status: "gone" }).eq("user_id", user.id).in("id", gone);
  }
  // Old rows don't need to stay around.
  await admin.from("approvals").delete().eq("user_id", user.id).neq("status", "pending")
    .lt("created_at", new Date(Date.now() - 7 * 86400_000).toISOString());
  return json({ ok: true });
});

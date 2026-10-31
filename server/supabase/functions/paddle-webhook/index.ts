// Paddle tells Orbit when a subscription starts, renews, fails or ends. Every notification is
// checked against Paddle's signature (HMAC-SHA256 of "ts:body" with the endpoint's secret)
// before anything changes. Deployed without JWT checks: Paddle signs instead of signing in.
import { admin } from "../_shared/common.ts";

const TOLERANCE_SECONDS = 300;

async function hmacHex(key: string, message: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** True when the Paddle-Signature header matches the raw body and is recent. */
export async function verify(header: string | null, raw: string, secret: string, now = Date.now() / 1000): Promise<boolean> {
  if (!header || !secret) return false;
  let ts = "";
  const h1s: string[] = [];
  for (const part of header.split(";")) {
    const [k, v] = part.split("=");
    if (k === "ts") ts = v;
    if (k === "h1" && v) h1s.push(v);
  }
  if (!ts || h1s.length === 0 || Math.abs(now - Number(ts)) > TOLERANCE_SECONDS) return false;
  const expected = await hmacHex(secret, `${ts}:${raw}`);
  return h1s.some((h) => safeEqual(h, expected));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const raw = await req.text();
  if (!(await verify(req.headers.get("Paddle-Signature"), raw, Deno.env.get("PADDLE_WEBHOOK_SECRET") ?? ""))) {
    return new Response("Bad signature", { status: 401 });
  }
  const event = JSON.parse(raw) as { event_type?: string; data?: Record<string, unknown> };
  const type = event.event_type ?? "";
  const d = event.data ?? {};
  if (!type.startsWith("subscription.")) return new Response("ignored", { status: 200 });

  const status = String(d.status ?? "");
  const customer = d.customer_id as string | undefined;
  let uid = (d.custom_data as { orbit_user_id?: string } | undefined)?.orbit_user_id;
  if (!uid && customer) {
    const { data } = await admin.from("profiles").select("id").eq("paddle_customer_id", customer).maybeSingle();
    uid = data?.id;
  }
  if (!uid) return new Response("No matching Orbit account", { status: 200 });

  const pro = ["active", "trialing", "past_due"].includes(status);
  const { error } = await admin.from("profiles").update({
    plan: pro ? "pro" : "free",
    subscription_status: status,
    paddle_customer_id: customer ?? null,
    paddle_subscription_id: (d.id as string | undefined) ?? null,
    current_period_end: (d.current_billing_period as { ends_at?: string } | undefined)?.ends_at ?? null,
    updated_at: new Date().toISOString(),
  }).eq("id", uid);
  // A failure here makes Paddle retry later.
  return new Response(error ? "Couldn't save" : "ok", { status: error ? 500 : 200 });
});

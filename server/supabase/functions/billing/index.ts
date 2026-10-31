// Orbit Pro billing through Paddle (merchant of record: Paddle handles VAT, receipts, refunds).
// POST {"action": "checkout"} → a Paddle checkout link for $12/month, tied to this account.
// POST {"action": "portal"}   → Paddle's page where the subscriber changes card or cancels.
// POST {"action": "status"}   → plan, status and this month's AI use, for the Mac app.
import { cors, currentUser, fail, fairUseCents, isPro, json, profile, spent } from "../_shared/common.ts";

const PADDLE = Deno.env.get("PADDLE_API_URL") ?? "https://sandbox-api.paddle.com";

async function paddle(method: string, path: string, body?: unknown): Promise<Record<string, unknown>> {
  const res = await fetch(PADDLE + path, {
    method,
    headers: { "Authorization": `Bearer ${Deno.env.get("PADDLE_API_KEY") ?? ""}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((data as { error?: { detail?: string } }).error?.detail ?? `Paddle ${res.status}`);
  return (data as { data: Record<string, unknown> }).data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail(405, "Use POST.");
  const user = await currentUser(req);
  if (!user) return fail(401, "Sign in to Orbit again (Settings → Account).");
  const p = await profile(user.id);
  const { action } = await req.json().catch(() => ({ action: "" }));

  try {
    switch (action) {
      case "status":
        return json({
          email: p?.email ?? user.email, pro: isPro(p), plan: p?.plan ?? "free", status: p?.subscription_status ?? null,
          renews: p?.current_period_end ?? null, spent_cents: await spent(user.id), limit_cents: fairUseCents,
        });
      case "checkout": {
        if (isPro(p)) return fail(409, "Orbit Pro is already active on this account.");
        const price = Deno.env.get("PADDLE_PRICE_ID");
        if (!price) return fail(503, "Orbit Pro isn't on sale yet.");
        const tx = await paddle("POST", "/transactions", {
          items: [{ price_id: price, quantity: 1 }],
          custom_data: { orbit_user_id: user.id },
          ...(p?.paddle_customer_id ? { customer_id: p.paddle_customer_id } : {}),
        });
        const url = (tx.checkout as { url?: string } | undefined)?.url;
        if (!url) return fail(502, "Paddle didn't return a checkout link. Is the default payment link set?");
        return json({ url });
      }
      case "portal": {
        if (!p?.paddle_customer_id) return fail(404, "No subscription on this account yet.");
        const session = await paddle("POST", `/customers/${p.paddle_customer_id}/portal-sessions`,
          p.paddle_subscription_id ? { subscription_ids: [p.paddle_subscription_id] } : {});
        const url = (session.urls as { general?: { overview?: string } } | undefined)?.general?.overview;
        return url ? json({ url }) : fail(502, "Paddle didn't return a link.");
      }
      default:
        return fail(400, "Unknown action.");
    }
  } catch (e) {
    return fail(502, (e as Error).message);
  }
});

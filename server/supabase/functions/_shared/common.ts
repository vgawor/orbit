// Shared by Orbit's Edge Functions: who's calling, whether they have Orbit Pro, what they own,
// and what they've spent. Uses the service role, so it can see every row; each function only
// ever acts for the user whose sign-in token came with the request.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

export const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

export const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

/** An error in the shape the Mac app already reads: {"error": {"message": "…"}}. */
export function fail(status: number, message: string): Response {
  return json({ error: { type: "orbit_error", message } }, status);
}

export interface User { id: string; email?: string }

/** The signed-in user behind the request's Authorization header, or null. */
export async function currentUser(req: Request): Promise<User | null> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  return { id: data.user.id, email: data.user.email ?? undefined };
}

export interface Profile {
  id: string; email: string | null; plan: string; subscription_status: string | null;
  paddle_customer_id: string | null; paddle_subscription_id: string | null; current_period_end: string | null;
}

export async function profile(uid: string): Promise<Profile | null> {
  const { data } = await admin.from("profiles").select("*").eq("id", uid).maybeSingle();
  return data as Profile | null;
}

/** Pro while the subscription is active, in trial, or a payment is being retried. */
export function isPro(p: Profile | null): boolean {
  return !!p && p.plan === "pro" && ["active", "trialing", "past_due"].includes(p.subscription_status ?? "");
}

/** AI use included in Orbit Pro each month, in US cents ($12 plan → about $8 of AI). */
export const fairUseCents = Number(Deno.env.get("FAIR_USE_CENTS") ?? "800");
/** No single run may cost more than this (cents). */
export const maxRunCents = Number(Deno.env.get("MAX_RUN_CENTS") ?? "200");

export async function spent(uid: string): Promise<number> {
  const { data } = await admin.rpc("month_spend", { uid });
  return Number(data ?? 0);
}

export async function owns(uid: string, kind: string, id: string | undefined | null): Promise<boolean> {
  if (!id) return false;
  const { data } = await admin.from("resources").select("user_id").eq("remote_id", id).eq("kind", kind).maybeSingle();
  return data?.user_id === uid;
}

export async function record(uid: string, kind: string, id: string | undefined | null): Promise<void> {
  if (!id) return;
  await admin.from("resources").upsert({ remote_id: id, user_id: uid, kind }, { onConflict: "remote_id", ignoreDuplicates: true });
}

export async function recordUsage(uid: string, runId: string, provider: "claude" | "chatgpt", cents: number): Promise<void> {
  if (!runId || !Number.isFinite(cents)) return;
  await admin.from("usage").upsert(
    { run_id: runId, user_id: uid, provider, cost_cents: Math.max(0, Math.round(cents)), updated_at: new Date().toISOString() },
    { onConflict: "run_id" },
  );
}

export async function getConfig(key: string): Promise<string | null> {
  const { data } = await admin.from("config").select("value").eq("key", key).maybeSingle();
  return data?.value ?? null;
}

export async function setConfig(key: string, value: string): Promise<void> {
  await admin.from("config").upsert({ key, value });
}

/** The cap that applies to one run: never above the per-run maximum. */
export function clampBudget(budget: unknown): Record<string, unknown> {
  const asked = Number((budget as { max_list_cost?: { amount?: string } } | undefined)?.max_list_cost?.amount ?? NaN);
  const cents = Number.isFinite(asked) && asked > 0 ? Math.min(asked, maxRunCents) : maxRunCents;
  return { type: "limit", max_list_cost: { amount: String(cents), currency: "USD" } };
}

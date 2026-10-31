// Orbit Pro's door to ChatGPT (OpenAI Responses API) for bots that run on the Mac. Same rules as
// the Claude door: Pro only, the fair-use limit, each conversation tied to its account, Orbit's
// key added here, and the cost recorded (estimated from OpenAI's list prices).
import { cors, currentUser, fail, fairUseCents, isPro, owns, profile, record, recordUsage, spent } from "../_shared/common.ts";

/** US cents per million tokens (input, output). */
const PRICES: Record<string, [number, number]> = {
  "gpt-6-astra": [1000, 5000],
  "gpt-6.1-sol": [200, 1000],
  "gpt-6.1-terra": [100, 500],
};
const SEARCH_CENTS = 2.5;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST" || !new URL(req.url).pathname.endsWith("/responses")) return fail(404, "Only /responses is available.");
  const user = await currentUser(req);
  if (!user) return fail(401, "Sign in to Orbit again (Settings → Account).");
  if (!isPro(await profile(user.id))) return fail(402, "Orbit Pro isn't active on this account.");

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return fail(400, "Expected JSON.");
  const model = String(body.model ?? "");
  if (!PRICES[model]) return fail(400, `Orbit Pro supports ${Object.keys(PRICES).join(", ")}.`);
  const previous = body.previous_response_id as string | undefined;
  if (previous && !(await owns(user.id, "response", previous))) return fail(403, "That conversation isn't yours.");
  // A new run (not a continuation) stops at the fair-use limit.
  if (!previous && await spent(user.id) >= fairUseCents) {
    return fail(402, "You've used this month's AI included in Orbit Pro. It resets on the 1st.");
  }
  body.store = true;
  delete body.background;

  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Authorization": `Bearer ${Deno.env.get("OPENAI_API_KEY") ?? ""}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (res.ok) {
    try {
      const data = JSON.parse(text);
      await record(user.id, "response", data.id);
      const [inPrice, outPrice] = PRICES[model];
      const usage = data.usage ?? {};
      const searches = (data.output ?? []).filter((o: { type?: string }) => o.type === "web_search_call").length;
      const c = ((usage.input_tokens ?? 0) * inPrice + (usage.output_tokens ?? 0) * outPrice) / 1_000_000 + searches * SEARCH_CENTS;
      await recordUsage(user.id, `openai:${data.id}`, "chatgpt", Math.ceil(c));
    } catch { /* the call worked; bookkeeping is best effort */ }
  }
  return new Response(text, { status: res.status, headers: { ...cors, "Content-Type": "application/json" } });
});

// Orbit Pro's door to Claude Managed Agents. The Mac app sends the same requests it would send
// to api.anthropic.com/v1, here instead, with the user's Orbit sign-in. This function:
// - lets only Orbit Pro accounts through, and stops new work at the monthly fair-use limit;
// - keeps every agent, deployment and session tied to the account that made it, so nobody can
//   reach anyone else's bots;
// - allows only the calls Orbit's bots use, with Orbit's own sandboxes and a cap on every run;
// - adds Orbit's Anthropic key (a secret here, never in the app) and records what each run cost.
import {
  admin, clampBudget, cors, currentUser, fail, fairUseCents, getConfig, isPro, json, owns, profile, record,
  recordUsage, setConfig, spent,
} from "../_shared/common.ts";

const ANTHROPIC = "https://api.anthropic.com/v1/";
const BETA = "managed-agents-2026-04-01";
const VERSION = "2026-10-21";

async function anthropic(method: string, path: string, body?: unknown): Promise<Response> {
  return await fetch(ANTHROPIC + path, {
    method,
    headers: {
      "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "",
      "anthropic-version": VERSION,
      "anthropic-beta": BETA,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

/** Orbit's two shared sandboxes (plain, and with web access), made once. */
async function environment(web: boolean): Promise<string> {
  const key = web ? "environment.web" : "environment";
  const saved = await getConfig(key);
  if (saved) return saved;
  const res = await anthropic("POST", "environments", {
    name: web ? "Orbit Pro Bots · web" : "Orbit Pro Bots",
    config: { type: "cloud", networking: web ? { type: "unrestricted" } : { type: "limited", allow_package_managers: false, allow_mcp_servers: false } },
  });
  const created = await res.json();
  if (!res.ok || !created.id) throw new Error(created?.error?.message ?? "Couldn't make the sandbox.");
  await setConfig(key, created.id);
  return created.id;
}

async function isOrbitEnvironment(id: unknown): Promise<boolean> {
  if (typeof id !== "string") return false;
  return id === await getConfig("environment") || id === await getConfig("environment.web");
}

function agentID(agent: unknown): string | undefined {
  if (typeof agent === "string") return agent;
  return (agent as { id?: string } | undefined)?.id;
}

/** "1234" or 1234 → cents. */
function cents(cost: unknown): number | undefined {
  const amount = (cost as { amount?: unknown } | undefined)?.amount;
  const n = Number(amount);
  return Number.isFinite(n) ? n : undefined;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const user = await currentUser(req);
  if (!user) return fail(401, "Sign in to Orbit again (Settings → Account).");
  if (!isPro(await profile(user.id))) return fail(402, "Orbit Pro isn't active on this account.");

  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/claude\/?/, "");
  const parts = path.split("/").filter(Boolean);
  const method = req.method;
  let body: Record<string, unknown> | undefined;
  if (method === "POST") body = await req.json().catch(() => ({}));

  // Orbit's own routes.
  if (parts[0] === "orbit") {
    if (parts[1] === "environment") {
      try { return json({ id: await environment(url.searchParams.get("web") === "1") }); }
      catch (e) { return fail(502, (e as Error).message); }
    }
    if (parts[1] === "usage") return json({ spent_cents: await spent(user.id), limit_cents: fairUseCents });
    return fail(404, "Unknown Orbit route.");
  }

  // New work stops at the fair-use limit; reading results and answering bots still works.
  const startsWork = method === "POST" && (
    path === "sessions" || path === "deployments" || /^deployments\/[^/]+\/(run|unpause)$/.test(path) ||
    (/^sessions\/[^/]+\/events$/.test(path) && JSON.stringify(body ?? {}).includes("\"user.message\""))
  );
  if (startsWork && await spent(user.id) >= fairUseCents) {
    return fail(402, "You've used this month's AI included in Orbit Pro. It resets on the 1st.");
  }

  // What each call may do.
  const [kind, id, action] = parts;
  let after: ((data: Record<string, unknown>) => Promise<void>) | undefined;

  if (kind === "agents") {
    if (!id && method === "POST") {
      body!.metadata = { ...(body!.metadata as object ?? {}), orbit_user: user.id };
      after = async (d) => { await record(user.id, "agent", d.id as string); };
    } else if (!(await owns(user.id, "agent", id)) || (action && action !== "archive") || (method !== "POST" && method !== "GET")) {
      return fail(403, "That isn't one of your bots.");
    }
  } else if (kind === "deployments") {
    if (!id && method === "POST" || id && !action && method === "POST") {
      if (id && !(await owns(user.id, "deployment", id))) return fail(403, "That isn't one of your schedules.");
      if (body!.agent !== undefined && !(await owns(user.id, "agent", agentID(body!.agent)))) return fail(403, "That isn't one of your bots.");
      if (body!.environment_id !== undefined && !(await isOrbitEnvironment(body!.environment_id))) return fail(403, "Use Orbit's sandbox.");
      if (body!.vault_ids !== undefined || body!.resources !== undefined) return fail(403, "Not available in Orbit Pro.");
      body!.budget = clampBudget(body!.budget);
      if (!id) after = async (d) => { await record(user.id, "deployment", d.id as string); };
    } else if (id && ["pause", "unpause", "archive", "run"].includes(action ?? "") && method === "POST") {
      if (!(await owns(user.id, "deployment", id))) return fail(403, "That isn't one of your schedules.");
    } else {
      return fail(403, "Not available in Orbit Pro.");
    }
  } else if (kind === "deployment_runs" && method === "GET" && !id) {
    const depl = url.searchParams.get("deployment_id");
    if (!(await owns(user.id, "deployment", depl))) return fail(403, "That isn't one of your schedules.");
    // Runs the schedule started become this user's sessions.
    after = async (d) => {
      for (const run of (d.data as Array<{ session_id?: string }> ?? [])) await record(user.id, "session", run.session_id);
    };
  } else if (kind === "sessions") {
    if (!id && method === "POST") {
      if (!(await owns(user.id, "agent", agentID(body!.agent)))) return fail(403, "That isn't one of your bots.");
      if (!(await isOrbitEnvironment(body!.environment_id))) return fail(403, "Use Orbit's sandbox.");
      if (body!.vault_ids !== undefined || body!.resources !== undefined) return fail(403, "Not available in Orbit Pro.");
      body!.budget = clampBudget(body!.budget);
      body!.metadata = { ...(body!.metadata as object ?? {}), orbit_user: user.id };
      after = async (d) => { await record(user.id, "session", d.id as string); };
    } else if (id && await owns(user.id, "session", id)) {
      if (!action && method === "GET") {
        after = async (d) => {
          const c = cents((d.usage as { list_cost?: unknown } | undefined)?.list_cost);
          if (c !== undefined) await recordUsage(user.id, id, "claude", c);
        };
      } else if (action === "events" && (method === "GET" || method === "POST")) {
        // Answers, confirmations and interrupts only; never new instructions from outside Orbit's own flow.
      } else {
        return fail(403, "Not available in Orbit Pro.");
      }
    } else {
      return fail(403, "That isn't one of your runs.");
    }
  } else {
    return fail(403, "Not available in Orbit Pro.");
  }

  const res = await anthropic(method, path + url.search, body);
  const text = await res.text();
  if (res.ok && after) {
    try { await after(JSON.parse(text)); } catch { /* the call worked; bookkeeping is best effort */ }
  }
  return new Response(text, { status: res.status, headers: { ...cors, "Content-Type": "application/json" } });
});

// Keep the admin client referenced so the bundler doesn't drop the shared module's setup.
void admin;

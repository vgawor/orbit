// Orbit on the phone. Lists the approvals your bots are waiting on (copied here by Orbit on
// your Mac), lets you Send, Edit or Skip, and turns on push notifications. Answers go to your
// Mac, which carries them out exactly like the buttons in the notch.
const { supabaseUrl, publishableKey } = window.ORBIT;
const db = window.supabase.createClient(supabaseUrl, publishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: "orbit-phone" },
});

const COLORS = { dot: "#FFFFFF", original: "#FBAE72", ink: "#77748A", bluey: "#5C9EFF", coral: "#FF7A6B", mint: "#6FE3B0", sunny: "#FFD34D" };
const $ = (id) => document.getElementById(id);
let email = "";
let editing = null;      // id of the approval being edited
let busy = new Set();    // approvals being answered

function show(el, on) { el.hidden = !on; }
function error(where, message) { $(where).textContent = message || ""; show($(where), !!message); }

// MARK: Signing in

$("send").onclick = async () => {
  email = $("email").value.trim().toLowerCase();
  if (!email.includes("@")) return error("signin-error", "Enter your email address.");
  $("send").disabled = true;
  const { error: e } = await db.auth.signInWithOtp({ email, options: { shouldCreateUser: true } });
  $("send").disabled = false;
  if (e) return error("signin-error", e.message);
  error("signin-error", "");
  show($("step-email"), false);
  show($("step-code"), true);
  $("code").focus();
};

$("verify").onclick = async () => {
  const token = $("code").value.replace(/\D/g, "");
  $("verify").disabled = true;
  const { error: e } = await db.auth.verifyOtp({ email, token, type: "email" });
  $("verify").disabled = false;
  if (e) return error("signin-error", "That code didn't work. Check it, or send a new one.");
  render();
};

$("sign-out").onclick = async () => { await db.auth.signOut(); render(); };

// MARK: Approvals

async function load() {
  const { data, error: e } = await db.from("approvals").select("*").eq("status", "pending").order("created_at", { ascending: false });
  if (e) return error("home-error", e.message);
  error("home-error", "");
  draw(data || []);
}

function draw(items) {
  const list = $("list");
  list.replaceChildren();
  if (!items.length) {
    const empty = document.createElement("div");
    empty.className = "card empty";
    empty.innerHTML = `<div class="big">🪐</div><h2>Nothing waiting</h2><p class="muted small" style="margin:0">When a bot needs your OK, it shows up here.</p>`;
    list.append(empty);
    return;
  }
  for (const a of items) list.append(card(a));
}

function card(a) {
  const el = document.createElement("article");
  el.className = "card ask";
  const who = document.createElement("div");
  who.className = "who";
  const dot = document.createElement("span");
  dot.className = "dot";
  dot.style.background = COLORS[a.bot_color] || "#fff";
  who.append(dot, `${a.bot_name} needs your OK`);
  const title = document.createElement("h2");
  title.textContent = a.title;
  el.append(who, title);
  if (a.reason) {
    const r = document.createElement("div");
    r.className = "reason";
    r.textContent = a.reason;
    el.append(r);
  }
  const fields = (a.fields || []).filter((f) => editing === a.id || (f.value || "").trim());
  for (const f of fields) {
    const box = document.createElement("div");
    box.className = "field";
    const label = document.createElement("label");
    label.textContent = f.label;
    box.append(label);
    if (editing === a.id) {
      const input = document.createElement(f.multiline ? "textarea" : "input");
      input.value = f.value || "";
      input.dataset.key = f.key;
      label.htmlFor = input.id = `${a.id}-${f.key}`;
      box.append(input);
    } else {
      const v = document.createElement("div");
      v.className = "value" + (f.multiline ? " long" : "");
      v.textContent = f.value;
      box.append(v);
    }
    el.append(box);
  }
  const row = document.createElement("div");
  row.className = "row";
  const go = button(a.action || "Approve", "primary", () => answer(a, true, el));
  const edit = button(editing === a.id ? "Done" : "Edit", "", () => { editing = editing === a.id ? null : a.id; load(); });
  const skip = button("Skip", "quiet", () => answer(a, false, el));
  if (busy.has(a.id)) [go, edit, skip].forEach((b) => (b.disabled = true));
  row.append(go);
  if ((a.fields || []).length) row.append(edit);
  row.append(skip);
  el.append(row);
  return el;
}

function button(text, kind, onClick) {
  const b = document.createElement("button");
  b.textContent = text;
  if (kind) b.className = kind;
  b.onclick = onClick;
  return b;
}

async function answer(a, approve, el) {
  busy.add(a.id);
  const fields = {};
  if (approve && editing === a.id) {
    for (const input of el.querySelectorAll("[data-key]")) fields[input.dataset.key] = input.value;
  }
  const { error: e } = await db.from("approvals")
    .update({ status: "decided", decision: { approve, fields }, decided_at: new Date().toISOString() })
    .eq("id", a.id).eq("status", "pending");
  busy.delete(a.id);
  if (e) return error("home-error", e.message);
  editing = null;
  load();
}

// MARK: Notifications

const standalone = window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone;

async function setUpNotifications() {
  const note = $("notify");
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    if (!standalone && /iPhone|iPad/.test(navigator.userAgent)) {
      $("notify-text").textContent = "To get notifications on iPhone: tap Share → Add to Home Screen, then open Orbit from your Home Screen.";
      show($("enable-push"), false);
      show(note, true);
    }
    return;
  }
  const reg = await navigator.serviceWorker.register("sw.js");
  const sub = await reg.pushManager.getSubscription();
  show(note, !sub || Notification.permission !== "granted");
}

$("enable-push").onclick = async () => {
  try {
    if ((await Notification.requestPermission()) !== "granted") throw new Error("Notifications are off for Orbit. Turn them on in Settings → Notifications.");
    const { data: session } = await db.auth.getSession();
    const res = await fetch(`${supabaseUrl}/functions/v1/phone/vapid`, {
      headers: { apikey: publishableKey, Authorization: `Bearer ${session.session?.access_token}` },
    });
    const { publicKey } = await res.json();
    if (!publicKey) throw new Error("Notifications aren't set up on Orbit's server yet.");
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(publicKey) });
    const json = sub.toJSON();
    const { data: user } = await db.auth.getUser();
    const { error: e } = await db.from("push_subscriptions").upsert({
      endpoint: json.endpoint, user_id: user.user.id, p256dh: json.keys.p256dh, auth: json.keys.auth,
    }, { onConflict: "endpoint", ignoreDuplicates: true });
    if (e) throw e;
    show($("notify"), false);
  } catch (e) {
    error("home-error", e.message);
  }
};

function urlBase64ToUint8Array(base64) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const raw = atob((base64 + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

// MARK: Screens

async function render() {
  const { data } = await db.auth.getSession();
  const signedIn = !!data.session;
  show($("signin"), !signedIn);
  show($("home"), signedIn);
  show($("sign-out"), signedIn);
  if (signedIn) {
    await load();
    setUpNotifications().catch(() => {});
  } else {
    show($("step-email"), true);
    show($("step-code"), false);
  }
}

navigator.serviceWorker?.addEventListener("message", (e) => { if (e.data?.type === "refresh") load(); });
document.addEventListener("visibilitychange", () => { if (!document.hidden) render(); });
setInterval(() => { if (!document.hidden && !editing) load(); }, 15000);
render();

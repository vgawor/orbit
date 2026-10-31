// Orbit on the phone: shows a notification when a bot needs your OK, and opens the app when
// you tap it.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { title: "Orbit", body: event.data?.text() }; }
  event.waitUntil(self.registration.showNotification(data.title || "A bot needs your OK", {
    body: data.body || "",
    icon: "icon-192.png",
    badge: "icon-192.png",
    tag: data.id || "orbit",
    data: { id: data.id },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) { if ("focus" in c) { c.postMessage({ type: "refresh" }); return c.focus(); } }
    return self.clients.openWindow("./");
  })());
});

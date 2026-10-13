// Raphael Web service worker: the app shell works offline; API calls always go to the network.
const SHELL = "raphael-shell-v1";
const FILES = ["/", "/app.css", "/app.js", "/icon.svg", "/icon-192.png", "/manifest.webmanifest"];
self.addEventListener("install", (e) => { e.waitUntil(caches.open(SHELL).then((c) => c.addAll(FILES)).then(() => self.skipWaiting())); });
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== SHELL).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/")) return;
  // Network first (a deploy shows up at once), cached shell when offline.
  e.respondWith(fetch(e.request).then((r) => {
    if (r.ok) { const copy = r.clone(); caches.open(SHELL).then((c) => c.put(url.pathname === "/" || url.pathname === "/index.html" ? "/" : url.pathname, copy)); }
    return r;
  }).catch(() => caches.match(url.pathname === "/index.html" ? "/" : url.pathname).then((m) => m || caches.match("/"))));
});

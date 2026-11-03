// Byte web: keeps the app shell for offline start; always fresh when online.
// © 2026 Apurba Laskar
const CACHE = 'byte-shell-v1';
self.addEventListener('install', (e) => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));
self.addEventListener('fetch', (e) => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  const immutable = u.hostname === 'www.gstatic.com' || u.hostname === 'fonts.gstatic.com';
  const shell = u.origin === self.location.origin;
  if (!immutable && !shell) return; // music, covers, the web server: straight to the network
  if (r.headers.has('range')) return;
  e.respondWith((async () => {
    const c = await caches.open(CACHE);
    if (immutable) {
      const hit = await c.match(r);
      if (hit) return hit;
    }
    try {
      const res = await fetch(r);
      if (res.ok && (res.type === 'basic' || res.type === 'cors')) c.put(r, res.clone());
      return res;
    } catch (err) {
      const hit = await c.match(r, { ignoreSearch: shell });
      if (hit) return hit;
      throw err;
    }
  })());
});

/* Niet Café: работа без интернета. При изменении файлов сайта увеличьте номер версии. */
const V = 'niet-v14';
const SHELL = ['./index.html', './guest.html', './order.html', './manifest.json', './guest.webmanifest', './icon-192.png', './icon-512.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {})))));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

const put = (req, res) => { if (res && res.ok) { const c = res.clone(); caches.open(V).then(x => x.put(req, c)); } return res; };
const netFirst = req => fetch(req).then(r => put(req, r)).catch(() => caches.match(req, { ignoreSearch: req.mode === 'navigate' }));
const cacheFirst = req => caches.match(req).then(r => r || fetch(req).then(x => put(req, x)));

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (u.pathname.includes('/auth/') || u.pathname.includes('/realtime/')) return;
  // фото блюд — из кэша
  if (u.pathname.includes('/storage/v1/object/public/')) return e.respondWith(cacheFirst(req));
  // фото блюд из папки menu/ сайта — из кэша (имя файла меняется только при замене фото)
  if (u.origin === location.origin && /\/menu\/(t\/)?d\d+\.jpg$/.test(u.pathname)) return e.respondWith(cacheFirst(req));
  // меню для гостей можно смотреть без сети
  if (/\/rest\/v1\/(cats|dishes|links|settings)\b/.test(u.pathname)) return e.respondWith(netFirst(req));
  if (u.pathname.includes('/rest/v1/') || u.pathname.includes('/rpc/')) return; // рабочие данные — только из сети
  // страницы, иконки, шрифты, библиотека
  if (u.origin === location.origin || /cdn\.jsdelivr|fonts\.(googleapis|gstatic)/.test(u.host)) e.respondWith(netFirst(req));
});

// ---- Push-уведомления ----
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) {}
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // если приложение открыто на экране — оно само покажет окно; на iPhone уведомление нужно показывать всегда
    wins.forEach(w => { try { w.postMessage({ push: d }); } catch (_) {} });
    if (d.kind !== 'test' && wins.some(w => w.visibilityState === 'visible') && !/iPhone|iPad|iPod/.test(self.navigator.userAgent)) return;
    await self.registration.showNotification(d.title || 'Niet Café', {
      body: d.body || '', tag: d.tag || undefined, renotify: !!d.tag,
      icon: 'icon-192.png', badge: 'icon-192.png', vibrate: ({ call: [500, 150, 500], bill: [80, 60, 80, 60, 80, 60, 300], gorder: [150, 80, 150, 80, 400], delivery: [250, 100, 250, 100, 250], take: [250, 100, 250], cancel: [700], ready: [120, 60, 120, 60, 120], stop: [400, 120, 400], low: [200, 200, 200], test: [200, 100, 200, 100, 600], guest: [150, 80, 300] })[d.kind] || [300, 120, 300], silent: false, requireInteraction: ['new', 'ready', 'cancel', 'call', 'bill', 'gorder', 'delivery', 'take', 'stop', 'test'].includes(d.kind), data: { kind: d.kind || '', url: d.url || '' },
    });
  })());
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  const page = new URL(url).pathname;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // сначала — уже открытая вкладка той же страницы (гость → guest.html, сотрудник → приложение)
    const same = wins.find(w => new URL(w.url).pathname === page) || (page.endsWith('/') || page.endsWith('index.html') ? wins.find(w => !/guest\.html|order\.html/.test(w.url)) : null);
    if (same && 'focus' in same) return same.focus();
    return self.clients.openWindow(url);
  })());
});

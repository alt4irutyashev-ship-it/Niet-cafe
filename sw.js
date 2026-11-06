/* Niet Café: service worker — установка как приложение и Web Push (уведомления при закрытом приложении). Страницы не кэширует. */
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));

self.addEventListener('push',e=>{
  let d={};
  try{d=e.data?e.data.json():{}}catch(_){d={title:'Niet Café',body:e.data?e.data.text():''}}
  e.waitUntil((async()=>{
    const cl=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const vis=cl.some(c=>c.visibilityState==='visible');
    const apple=/iPhone|iPad|iPod/.test(self.navigator.userAgent);
    // Приложение открыто на экране — оно само покажет окно и звук. Safari на iPhone требует показывать уведомление на каждый push, поэтому там показываем тихо и сразу убираем.
    if(vis&&!apple)return;
    await self.registration.showNotification(d.title||'Niet Café',{
      body:d.body||'',tag:d.tag||undefined,renotify:!!d.tag,
      requireInteraction:d.kind!=='accepted',
      vibrate:[400,150,400],silent:vis,
      icon:'icon-192.png',badge:'icon-192.png',data:{url:'./'}
    });
    if(vis){await new Promise(r=>setTimeout(r,1500));const n=await self.registration.getNotifications({tag:d.tag});n.forEach(x=>x.close())}
  })());
});

self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>{for(const c of l)if('focus'in c)return c.focus();return self.clients.openWindow('./')}))});

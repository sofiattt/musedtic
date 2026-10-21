/* musedtic service worker: network first, so updates always reach you; the cache is only a fallback when you are offline. */
const CACHE = 'musedtic-shell-v2';
self.addEventListener('install', function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(['./index.html']); }).catch(function(){}));
  self.skipWaiting();
});
self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(ks){ return Promise.all(ks.filter(function(k){ return k !== CACHE; }).map(function(k){ return caches.delete(k); })); }).then(function(){ return self.clients.claim(); }));
});
self.addEventListener('fetch', function(e){
  var u = new URL(e.request.url);
  if(e.request.method !== 'GET' || u.origin !== location.origin) return;       // never touch calls to other servers
  e.respondWith(
    fetch(e.request).then(function(r){
      if(r.ok && (u.pathname.endsWith('/') || u.pathname.endsWith('index.html'))){ var copy = r.clone(); caches.open(CACHE).then(function(c){ c.put('./index.html', copy); }); }
      return r;
    }).catch(function(){ return caches.match(e.request).then(function(r){ return r || caches.match('./index.html'); }); })
  );
});

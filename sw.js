const CACHE_NAME = 'qualisight-v1';
const ASSETS = [
  '/',
  '/login.html',
  '/dashboard.html',
  '/test.html',
  '/camera.html',
  '/manifest.json'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS))
  );
});

self.addEventListener('fetch', (event) => {
  event.respondWith(
    caches.match(event.request).then((response) => {
      return response || fetch(event.request);
    })
  );
});

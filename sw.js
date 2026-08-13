const CACHE_VERSION = 'remember-v23-click-to-list';
const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.json',
  '/manifest.webmanifest',
  '/favicon.ico',
  '/app-icon.svg',
  '/brand-mark.svg',
  '/app-icon-180.png',
  '/app-icon-192.png',
  '/app-icon-512.png',
  '/js/config.js',
  '/js/billing-config.js',
  '/js/supabase-service.js',
  '/js/billing.js'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_VERSION)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys
          .filter(key => key !== CACHE_VERSION)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const { request } = event;
  if (request.method !== 'GET') return;

  event.respondWith(
    caches.match(request).then(cached => {
      const fetched = fetch(request).then(response => {
        if (!response || response.status !== 200 || response.type !== 'basic') {
          return response;
        }
        const copy = response.clone();
        caches.open(CACHE_VERSION).then(cache => cache.put(request, copy));
        return response;
      }).catch(() => cached);

      return cached || fetched;
    })
  );
});

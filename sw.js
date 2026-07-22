const CACHE_VERSION = 'sweat-manager-v10-toss-stripe';
const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.json',
  '/manifest.webmanifest',
  '/app-icon.svg',
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
  const request = event.request;

  if (request.method !== 'GET') return;

  // Always network-first for app shell and config so auth settings update quickly.
  event.respondWith(
    fetch(request)
      .then(response => {
        const copy = response.clone();
        caches.open(CACHE_VERSION).then(cache => cache.put(request, copy));
        return response;
      })
      .catch(() => caches.match(request).then(cached => cached || caches.match('/index.html')))
  );
});

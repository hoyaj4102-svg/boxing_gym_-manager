// CACHE_VERSION is the content hash of APP_SHELL.
// scripts/sw-cache-version.test.mjs fails CI when those files change
// and this constant is left unchanged, so a deploy cannot keep the old shell.
const CACHE_VERSION = 'remember-4e90389021655658';

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

const APP_ROUTES = new Set(['/', '/index.html', '/signup', '/login', '/reset-password']);
const SENSITIVE_QUERY_KEYS = ['code', 'access_token', 'refresh_token', 'token', 'provider_token', 'id_token'];
const reloadingClients = new Set();

function isSensitiveRequest(url, request) {
  const host = url.hostname.toLowerCase();
  if (host === 'supabase.co' || host.endsWith('.supabase.co')) return true;
  if (host === 'tosspayments.com' || host.endsWith('.tosspayments.com')) return true;
  if (request && request.headers) {
    if (request.headers.has('authorization') || request.headers.has('range')) return true;
  }
  const path = url.pathname.toLowerCase();
  if (path === '/sw.js') return true;
  if (path.startsWith('/api/') || path.startsWith('/auth/') || path.includes('/auth/v1/') || path.includes('/rest/v1/') || path.includes('/functions/')) return true;
  if (/(^|\/)(payments?|billing-auth|checkout|confirm-toss|charge-subscriptions?)(\/|$)/.test(path)) return true;
  for (let i = 0; i < SENSITIVE_QUERY_KEYS.length; i += 1) {
    if (url.searchParams.has(SENSITIVE_QUERY_KEYS[i])) return true;
  }
  return false;
}

function isNetworkFirstRequest(request, url) {
  if (request.mode === 'navigate') return true;
  const destination = request.destination;
  if (destination === 'document' || destination === 'script' || destination === 'style') return true;
  const path = url.pathname.toLowerCase();
  if (APP_ROUTES.has(path) || path.startsWith('/js/')) return true;
  return /\.(html|js|mjs|css)$/.test(path);
}

function canStore(response) {
  return !!response && response.ok === true && response.type === 'basic' && response.redirected !== true;
}

function fetchStrategy(request) {
  if (!request || request.method !== 'GET') return 'bypass';
  let url;
  try {
    url = new URL(request.url);
  } catch (error) {
    return 'bypass';
  }
  if (url.origin !== self.location.origin) return 'bypass';
  if (isSensitiveRequest(url, request)) return 'bypass';
  if (isNetworkFirstRequest(request, url)) return 'network-first';
  return 'stale-while-revalidate';
}

function fetchFresh(request) {
  // A navigation Request cannot be rebuilt with a new cache mode.
  if (request.mode === 'navigate' || request.destination === 'document') {
    return fetch(request.url, {
      cache: 'no-cache',
      credentials: 'same-origin',
      redirect: 'follow'
    });
  }
  try {
    return fetch(new Request(request, { cache: 'no-cache' }));
  } catch (error) {
    return fetch(request);
  }
}

function cacheKey(request) {
  // Cache.put rejects navigation requests. Store a normal GET for the same URL.
  if (request.mode === 'navigate' || request.destination === 'document') {
    return new Request(request.url, { credentials: 'same-origin' });
  }
  return request;
}

async function storeResponse(request, response) {
  if (!canStore(response)) return;
  try {
    const cache = await caches.open(CACHE_VERSION);
    await cache.put(cacheKey(request), response.clone());
  } catch (error) {
    // A fresh network response is still returned when Cache Storage rejects the write.
  }
}

async function networkFirst(request) {
  const cache = await caches.open(CACHE_VERSION);
  try {
    const response = await fetchFresh(request);
    await storeResponse(request, response);
    return response;
  } catch (error) {
    const cached = await cache.match(request) || await cache.match(request.url);
    if (cached) return cached;
    if (request.mode === 'navigate' || request.destination === 'document') {
      const shell = await cache.match('/index.html') || await cache.match('/');
      if (shell) return shell;
    }
    throw error;
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(CACHE_VERSION);
  const cached = await cache.match(request);
  const fetched = fetchFresh(request).then(async (response) => {
    await storeResponse(request, response);
    return response;
  }).catch(() => cached);
  return cached || fetched;
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_VERSION);
    const stored = new Set();
    for (let i = 0; i < APP_SHELL.length; i += 1) {
      const path = APP_SHELL[i];
      try {
        const response = await fetch(path, { cache: 'reload' });
        if (!response || !response.ok) throw new Error('shell response was not ok');
        await cache.put(path, response);
        stored.add(path);
      } catch (error) {
        // One optional asset must not pin clients to the previous worker.
      }
    }
    if (!stored.has('/') && !stored.has('/index.html')) {
      throw new Error('app shell precache failed');
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || !data.type) return;
  if (data.type === 'SKIP_WAITING') {
    self.skipWaiting();
    return;
  }
  if (data.type === 'REMEMBER_SW_RELOADING' && event.source && event.source.id) {
    reloadingClients.add(event.source.id);
  }
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const hadPreviousCache = keys.some((key) => key !== CACHE_VERSION);
    await Promise.all(keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key)));
    await self.clients.claim();
    if (!hadPreviousCache) return;

    try {
      const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const existingIds = new Set();
      for (let i = 0; i < clients.length; i += 1) {
        existingIds.add(clients[i].id);
        try {
          clients[i].postMessage({ type: 'REMEMBER_SW_ACTIVATED', version: CACHE_VERSION });
        } catch (error) {
          // A closing window cannot accept the message.
        }
      }
      // Pages that already listen reload themselves and acknowledge.
      // An already-installed PWA does not have that listener yet, so navigate once.
      await delay(800);
      const stillOpen = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (let i = 0; i < stillOpen.length; i += 1) {
        const client = stillOpen[i];
        if (!existingIds.has(client.id) || reloadingClients.has(client.id)) continue;
        if (!client.url || client.url.indexOf(self.location.origin) !== 0) continue;
        if (typeof client.navigate !== 'function') continue;
        try {
          await client.navigate(client.url);
        } catch (error) {
          // Browsers without WindowClient.navigate need the page to be opened again.
        }
      }
    } catch (error) {
      // Cache cleanup and clients.claim already ran. A refresh failure must not
      // roll back the new worker.
    }
  })());
});

self.addEventListener('fetch', (event) => {
  const strategy = fetchStrategy(event.request);
  if (strategy === 'bypass') return;
  event.respondWith(strategy === 'network-first' ? networkFirst(event.request) : staleWhileRevalidate(event.request));
});

self.__rememberSw = {
  CACHE_VERSION,
  APP_SHELL,
  fetchStrategy,
  canStore
};

/**
 * First-visit signup attribution.
 * Kept briefly in sessionStorage, then sent once when signup completes.
 * Stores UTM tokens, the referrer domain, and the landing path.
 * Does not store the raw query, a full referrer URL, an IP, a fingerprint, or an email.
 * Display language is unrelated. utm_source=threads does not change language.
 */
(function (global) {
  const STORAGE_KEY = 'remember_signup_acquisition';
  const TTL_MS = 30 * 60 * 1000;
  const TOKEN_MAX = 64;
  const PATH_MAX = 128;
  const DOMAIN_MAX = 253;
  const FIELDS = [
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'utm_content',
    'utm_term',
    'referrer_domain',
    'landing_path'
  ];
  const UTM_FIELDS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];
  const STORED_KEYS = new Set(FIELDS.concat(['captured_at', 'expires_at']));
  const TOKEN_PATTERN = /^[A-Za-z0-9._~-]+$/;
  const DOMAIN_PATTERN = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;
  const PATH_PATTERN = /^\/[A-Za-z0-9/_.~-]*$/;
  const CAPTURED_AT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

  function sanitizeToken(value) {
    if (typeof value !== 'string') return null;
    const cleaned = value.trim();
    if (!cleaned || cleaned.length > TOKEN_MAX) return null;
    if (!TOKEN_PATTERN.test(cleaned)) return null;
    return cleaned;
  }

  function sanitizeDomain(value) {
    if (typeof value !== 'string') return null;
    const cleaned = value.trim().toLowerCase().replace(/\.$/, '');
    if (!cleaned || cleaned.length > DOMAIN_MAX) return null;
    if (/[:/?#%@\s]/.test(cleaned)) return null;
    if (cleaned === 'localhost') return cleaned;
    if (/^[0-9.]+$/.test(cleaned)) return null;
    if (!/[a-z]/.test(cleaned)) return null;
    if (!DOMAIN_PATTERN.test(cleaned)) return null;
    return cleaned;
  }

  function sanitizePath(value) {
    if (typeof value !== 'string') return null;
    const cleaned = value.trim();
    if (!cleaned || cleaned.length > PATH_MAX || !cleaned.startsWith('/')) return null;
    if (cleaned.includes('..') || cleaned.includes('//')) return null;
    if (!PATH_PATTERN.test(cleaned)) return null;
    return cleaned;
  }

  function domainFromReferrer(referrer, pageHost) {
    const raw = String(referrer || '').trim();
    if (!raw) return null;
    let hostname = null;
    if (/^[a-z0-9.-]+$/i.test(raw)) {
      hostname = raw;
    } else {
      try {
        hostname = new URL(raw).hostname;
      } catch (error) {
        return null;
      }
    }
    const domain = sanitizeDomain(hostname);
    const ownDomain = sanitizeDomain(pageHost || '');
    if (domain && ownDomain && domain === ownDomain) return null;
    return domain;
  }

  function tokensFromSearch(search) {
    const params = new URLSearchParams(String(search || '').replace(/^\?/, ''));
    const record = {};
    for (let i = 0; i < UTM_FIELDS.length; i += 1) {
      const key = UTM_FIELDS[i];
      record[key] = sanitizeToken(params.get(key) || '');
    }
    return record;
  }

  function hasAttribution(record) {
    return FIELDS.some((key) => Boolean(record[key]));
  }

  function normalizeCapturedAt(value, now) {
    if (typeof value !== 'string' || !CAPTURED_AT_PATTERN.test(value)) return null;
    const parsed = Date.parse(value);
    const current = Number.isFinite(now) ? now : Date.now();
    if (!Number.isFinite(parsed)) return null;
    if (parsed < current - (2 * 60 * 60 * 1000)) return null;
    if (parsed > current + (5 * 60 * 1000)) return null;
    return new Date(parsed).toISOString();
  }

  function forSignup(record, now) {
    if (!record || typeof record !== 'object') return null;
    const clean = {
      utm_source: sanitizeToken(record.utm_source),
      utm_medium: sanitizeToken(record.utm_medium),
      utm_campaign: sanitizeToken(record.utm_campaign),
      utm_content: sanitizeToken(record.utm_content),
      utm_term: sanitizeToken(record.utm_term),
      referrer_domain: sanitizeDomain(record.referrer_domain),
      landing_path: sanitizePath(record.landing_path)
    };
    if (!hasAttribution(clean)) return null;
    const payload = {};
    for (let i = 0; i < FIELDS.length; i += 1) {
      const key = FIELDS[i];
      if (clean[key]) payload[key] = clean[key];
    }
    const capturedAt = normalizeCapturedAt(record.captured_at, now);
    if (capturedAt) payload.captured_at = capturedAt;
    return payload;
  }

  function safeGet(storage) {
    try {
      return storage.getItem(STORAGE_KEY);
    } catch (error) {
      return null;
    }
  }

  function safeRemove(storage) {
    try {
      storage.removeItem(STORAGE_KEY);
    } catch (error) {
      // Storage can be blocked. Signup still proceeds without attribution.
    }
  }

  function readStored(storage, now) {
    if (!storage || typeof storage.getItem !== 'function') return null;
    const raw = safeGet(storage);
    if (!raw) return null;
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      safeRemove(storage);
      return null;
    }
    if (!parsed || typeof parsed !== 'object' || typeof parsed.expires_at !== 'number') {
      safeRemove(storage);
      return null;
    }
    if (parsed.expires_at <= now) {
      safeRemove(storage);
      return null;
    }
    const keys = Object.keys(parsed);
    for (let i = 0; i < keys.length; i += 1) {
      if (!STORED_KEYS.has(keys[i])) {
        safeRemove(storage);
        return null;
      }
    }
    return parsed;
  }

  function captureFirstVisit(input) {
    const settings = input || {};
    const now = Number.isFinite(settings.now) ? settings.now : Date.now();
    const storage = settings.storage;
    if (!storage || typeof storage.setItem !== 'function') {
      return { stored: false, record: null };
    }
    const existing = readStored(storage, now);
    if (existing) {
      return { stored: false, record: forSignup(existing, now) };
    }
    const fromQuery = tokensFromSearch(settings.search);
    const draft = {
      utm_source: fromQuery.utm_source,
      utm_medium: fromQuery.utm_medium,
      utm_campaign: fromQuery.utm_campaign,
      utm_content: fromQuery.utm_content,
      utm_term: fromQuery.utm_term,
      referrer_domain: domainFromReferrer(settings.referrer, settings.pageHost),
      landing_path: sanitizePath(settings.pathname),
      captured_at: new Date(now).toISOString()
    };
    const payload = forSignup(draft, now);
    if (!payload) return { stored: false, record: null };
    const body = {
      captured_at: payload.captured_at,
      expires_at: now + TTL_MS
    };
    for (let i = 0; i < FIELDS.length; i += 1) {
      const key = FIELDS[i];
      if (payload[key]) body[key] = payload[key];
    }
    try {
      storage.setItem(STORAGE_KEY, JSON.stringify(body));
    } catch (error) {
      return { stored: false, record: payload };
    }
    return { stored: true, record: payload };
  }

  function readForSignup(input) {
    const settings = input || {};
    const now = Number.isFinite(settings.now) ? settings.now : Date.now();
    const existing = readStored(settings.storage, now);
    if (!existing) return null;
    return forSignup(existing, now);
  }

  function clear(storage) {
    if (!storage) return;
    safeRemove(storage);
  }

  const api = {
    STORAGE_KEY,
    TTL_MS,
    sanitizeToken,
    sanitizeDomain,
    sanitizePath,
    domainFromReferrer,
    forSignup,
    captureFirstVisit,
    readForSignup,
    clear
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }
  global.RememberAcquisition = api;
})(typeof window !== 'undefined' ? window : globalThis);

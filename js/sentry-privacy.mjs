// Shared Sentry privacy filter for the static frontend and Supabase Edge Functions.
// This module never reads a DSN and never sends an event.

export const FILTERED = "[Filtered]";
export const TRACES_SAMPLE_RATE = 0.1;

// Custom production host. *.vercel.app is classified as preview, including the
// current canonical alias boxing-gym-manager.vercel.app. See the PR notes.
export const PRODUCTION_HOSTS = ["app.re-member.kr"];

const SENSITIVE_OBJECT_KEYS = new Set([
  "password",
  "passwd",
  "pwd",
  "billingkey",
  "authkey",
  "customerkey",
  "authorization",
  "apikey",
  "cookie",
  "cookies",
  "secret",
  "secretkey",
  "cardnumber",
  "cardno",
  "pan",
  "email",
  "phone",
  "mobile",
  "tel",
]);

const IP_HEADERS = new Set([
  "forwarded",
  "xforwardedfor",
  "xrealip",
  "cfconnectingip",
  "trueclientip",
]);

const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;
const EMAIL_PATTERN = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g;
const PHONE_PATTERN = /(?:\+82[-\s]?)?0?1[016789][-\s]?\d{3,4}[-\s]?\d{4}\b/g;
const E164_PATTERN = /\+\d{1,3}(?:[-\s]\d{2,4}){2,3}\b/g;
const CARD_PATTERN = /(?:\d[ -]?){13,19}/g;
const LABELED_SECRET_PATTERN = /\b(password|passwd|billing[_-]?key|auth[_-]?key|customer[_-]?key|api[_-]?key)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,}&]+)/gi;
const RAW_KEY_PATTERN = /\b(?:billing|auth|customer)[_-]?key[_-][A-Za-z0-9_-]{4,}\b/gi;
const BEARER_PATTERN = /\bBearer\s+\S+/gi;
const BASIC_PATTERN = /\bBasic\s+\S+/gi;
const PASSWORD_TOKEN_PATTERN = /\S*password\S*/gi;

function normalizeKey(key) {
  return String(key).replace(/[_\-\s]/g, "").toLowerCase();
}

function isSensitiveObjectKey(key) {
  const normalized = normalizeKey(key);
  if (SENSITIVE_OBJECT_KEYS.has(normalized)) return true;
  if (normalized === "token" || normalized.endsWith("token")) return true;
  if (normalized.endsWith("secret") || normalized.endsWith("password") || normalized.endsWith("apikey")) return true;
  if (normalized.includes("billingkey") || normalized.includes("authkey") || normalized.includes("customerkey")) return true;
  return false;
}

export function isSensitiveQueryParam(key) {
  const normalized = normalizeKey(key);
  if (normalized === "token" || normalized === "code" || normalized === "key") return true;
  return isSensitiveObjectKey(key);
}

export function isSensitiveHeader(name) {
  const normalized = normalizeKey(name);
  if (normalized === "authorization" || normalized === "cookie" || normalized === "setcookie" || normalized === "apikey") {
    return true;
  }
  if (IP_HEADERS.has(normalized)) return true;
  if (normalized.startsWith("x") && /token|key|secret|auth|password|credential|signature/.test(normalized)) {
    return true;
  }
  return isSensitiveObjectKey(name);
}

function luhnOk(digits) {
  let sum = 0;
  let alternate = false;
  for (let index = digits.length - 1; index >= 0; index -= 1) {
    let digit = digits.charCodeAt(index) - 48;
    if (digit < 0 || digit > 9) return false;
    if (alternate) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    alternate = !alternate;
  }
  return sum % 10 === 0;
}

function maskCardNumbers(value) {
  return value.replace(CARD_PATTERN, (match) => {
    const digits = match.replace(/\D/g, "");
    if (digits.length < 13 || digits.length > 19) return match;
    if (!luhnOk(digits)) return match;
    return FILTERED;
  });
}

function scrubEmbeddedQuery(value) {
  return value.replace(/([?&])([^=&#\s]+)=([^&#\s]*)/g, (match, separator, key, rawValue) => {
    let decoded = key;
    try {
      decoded = decodeURIComponent(key);
    } catch {
      decoded = key;
    }
    if (!isSensitiveQueryParam(decoded)) return match;
    return `${separator}${key}=${FILTERED}`;
  });
}

export function scrubString(value) {
  if (typeof value !== "string" || value.length === 0) return value;
  let text = scrubEmbeddedQuery(value);
  text = text.replace(JWT_PATTERN, FILTERED);
  text = text.replace(BEARER_PATTERN, `Bearer ${FILTERED}`);
  text = text.replace(BASIC_PATTERN, `Basic ${FILTERED}`);
  text = text.replace(LABELED_SECRET_PATTERN, `$1=${FILTERED}`);
  text = text.replace(RAW_KEY_PATTERN, FILTERED);
  text = text.replace(PASSWORD_TOKEN_PATTERN, FILTERED);
  text = text.replace(EMAIL_PATTERN, FILTERED);
  text = text.replace(PHONE_PATTERN, FILTERED);
  text = text.replace(E164_PATTERN, FILTERED);
  text = maskCardNumbers(text);
  return text;
}

function scrubUrl(value) {
  if (typeof value !== "string" || value.length === 0) return value;
  const hashIndex = value.indexOf("#");
  const hash = hashIndex >= 0 ? value.slice(hashIndex) : "";
  const withoutHash = hashIndex >= 0 ? value.slice(0, hashIndex) : value;
  const queryIndex = withoutHash.indexOf("?");
  if (queryIndex < 0) return scrubString(value);
  const path = withoutHash.slice(0, queryIndex);
  const params = new URLSearchParams(withoutHash.slice(queryIndex + 1));
  for (const key of [...params.keys()]) {
    if (isSensitiveQueryParam(key)) params.set(key, FILTERED);
  }
  const query = params.toString();
  return scrubString(query ? `${path}?${query}${hash}` : `${path}${hash}`);
}

function headerEntries(headers) {
  if (!headers) return [];
  if (Array.isArray(headers)) {
    return headers.map((entry) => {
      if (Array.isArray(entry)) return [String(entry[0]), entry[1]];
      return [String(entry.name || ""), entry.value];
    });
  }
  if (typeof headers === "object") return Object.entries(headers);
  return [];
}

function scrubHeaders(headers) {
  const entries = headerEntries(headers);
  if (entries.length === 0) return headers;
  const next = {};
  for (const [name, value] of entries) {
    next[name] = isSensitiveHeader(name) ? FILTERED : scrubString(String(value ?? ""));
  }
  return next;
}

function scrubQuery(query) {
  if (typeof query === "string") {
    const params = new URLSearchParams(query.replace(/^\?/, ""));
    for (const key of [...params.keys()]) {
      if (isSensitiveQueryParam(key)) params.set(key, FILTERED);
    }
    return scrubString(params.toString());
  }
  if (!query || typeof query !== "object" || Array.isArray(query)) return query;
  const next = {};
  for (const [key, value] of Object.entries(query)) {
    next[key] = isSensitiveQueryParam(key) ? FILTERED : scrubString(String(value ?? ""));
  }
  return next;
}

function scrubRequest(request) {
  if (!request || typeof request !== "object") return request;
  delete request.data;
  delete request.body;
  delete request.cookies;
  delete request.env;
  if (request.headers) request.headers = scrubHeaders(request.headers);
  if (typeof request.url === "string") request.url = scrubUrl(request.url);
  if (request.query_string !== undefined) request.query_string = scrubQuery(request.query_string);
  return request;
}

function scrubUser(user) {
  if (!user || typeof user !== "object") return undefined;
  const id = typeof user.id === "string" ? scrubString(user.id) : undefined;
  if (!id) return undefined;
  return { id };
}

function deepScrub(value, depth) {
  if (typeof value === "string") return scrubString(value);
  if (!value || typeof value !== "object") return value;
  if (depth > 12) return FILTERED;
  if (Array.isArray(value)) return value.map((entry) => deepScrub(entry, depth + 1));
  const next = {};
  for (const [key, entry] of Object.entries(value)) {
    next[key] = isSensitiveObjectKey(key) ? FILTERED : deepScrub(entry, depth + 1);
  }
  return next;
}

function scrubBreadcrumbList(list) {
  const kept = [];
  for (const breadcrumb of list) {
    const next = beforeBreadcrumb(breadcrumb);
    if (next) kept.push(next);
  }
  return kept;
}

function scrubEvent(event) {
  delete event.sdkProcessingMetadata;
  if (event.user) event.user = scrubUser(event.user);
  for (const field of ["message", "logentry", "extra", "contexts", "tags", "fingerprint", "exception", "threads", "spans"]) {
    if (event[field] !== undefined) event[field] = deepScrub(event[field], 0);
  }
  if (Array.isArray(event.breadcrumbs)) {
    event.breadcrumbs = scrubBreadcrumbList(event.breadcrumbs);
  } else if (event.breadcrumbs && Array.isArray(event.breadcrumbs.values)) {
    event.breadcrumbs.values = scrubBreadcrumbList(event.breadcrumbs.values);
  }
  if (event.request) scrubRequest(event.request);
  return event;
}

function copyEvent(event) {
  return JSON.parse(JSON.stringify(event));
}

export function beforeSend(event) {
  try {
    if (!event || typeof event !== "object") return null;
    return scrubEvent(copyEvent(event));
  } catch {
    return null;
  }
}

export function beforeSendTransaction(event) {
  return beforeSend(event);
}

export function beforeBreadcrumb(breadcrumb) {
  try {
    if (!breadcrumb || typeof breadcrumb !== "object") return null;
    if (breadcrumb.category === "console") {
      const level = String(breadcrumb.level || "");
      if (level !== "error" && level !== "fatal") return null;
    }
    return deepScrub(copyEvent(breadcrumb), 0);
  } catch {
    return null;
  }
}

export function hostnameFrom(value) {
  if (typeof value !== "string" || value.length === 0) return "";
  try {
    return new URL(value).hostname.toLowerCase();
  } catch {
    return "";
  }
}

function classifyHost(host) {
  if (!host) return "unknown";
  if (PRODUCTION_HOSTS.includes(host)) return "production";
  if (host === "vercel.app" || host.endsWith(".vercel.app")) return "preview";
  return "unknown";
}

// Origin wins when it is present. Referer is only a fallback because browsers
// may omit it. Neither header isolates data: Preview and Production call the
// same Supabase project.
export function environmentFromOrigin(origin, referer) {
  const originHost = hostnameFrom(origin);
  if (originHost) return classifyHost(originHost);
  return classifyHost(hostnameFrom(referer));
}

export function createSentryOptions(config) {
  const source = config || {};
  const dsn = typeof source.dsn === "string" ? source.dsn : "";
  const environment = typeof source.environment === "string" && source.environment ? source.environment : undefined;
  const release = typeof source.release === "string" && source.release ? source.release : undefined;
  return {
    dsn,
    environment,
    release,
    sendDefaultPii: false,
    tracesSampleRate: TRACES_SAMPLE_RATE,
    beforeSend,
    beforeSendTransaction,
    beforeBreadcrumb,
  };
}

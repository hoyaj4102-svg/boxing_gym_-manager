import { createSentryOptions } from "./sentry-privacy.mjs";

// Tracing bundle only. The replay bundle is intentionally not loaded.
export const SENTRY_BROWSER_SDK_URL = "https://browser.sentry-cdn.com/11.16.0/bundle.tracing.min.js";

const INTERNAL_ID_KEY = "remember_sentry_iid";

export function readInternalId(storage, randomUUID) {
  try {
    const existing = storage && storage.getItem(INTERNAL_ID_KEY);
    if (existing && /^[0-9a-f-]{36}$/i.test(existing)) return existing;
    const id = randomUUID();
    if (storage) storage.setItem(INTERNAL_ID_KEY, id);
    return id;
  } catch {
    return randomUUID();
  }
}

export function installSentry(Sentry, config, hooks) {
  const options = createSentryOptions(config);
  if (!options.dsn) return { enabled: false };
  Sentry.init(options);
  const randomUUID = hooks && hooks.randomUUID ? hooks.randomUUID : () => crypto.randomUUID();
  const storage = hooks && Object.prototype.hasOwnProperty.call(hooks, "storage") ? hooks.storage : null;
  Sentry.setUser({ id: readInternalId(storage, randomUUID) });
  return { enabled: true, options };
}

function loadBrowserSdk() {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = SENTRY_BROWSER_SDK_URL;
    script.crossOrigin = "anonymous";
    script.onload = () => resolve(globalThis.Sentry);
    script.onerror = () => reject(new Error("sentry-sdk-load-failed"));
    document.head.appendChild(script);
  });
}

if (typeof document !== "undefined") {
  const config = globalThis.REMEMBER_SENTRY;
  if (config && typeof config.dsn === "string" && config.dsn.length > 0) {
    loadBrowserSdk()
      .then((Sentry) => {
        if (!Sentry) return;
        let storage = null;
        try {
          storage = sessionStorage;
        } catch {
          storage = null;
        }
        installSentry(Sentry, config, { storage, randomUUID: () => crypto.randomUUID() });
      })
      .catch(() => {
        // A missing SDK or DSN leaves the app running with reporting disabled.
      });
  }
}

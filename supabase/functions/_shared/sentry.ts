import { AsyncLocalStorage } from "node:async_hooks";
import {
  beforeBreadcrumb,
  beforeSend as scrubSentryEvent,
  beforeSendTransaction as scrubSentryTransaction,
  environmentFromOrigin,
  TRACES_SAMPLE_RATE,
} from "../../../js/sentry-privacy.mjs";

// @sentry/deno 11 requires Deno >= 2.8.3. Hosted Supabase Edge Runtime is still
// the Deno 2.1 line (edge-runtime 1.79.x, November 2026, no Deno upgrade in
// that release), so this pin stays on the newest 10.x release.
// Keep this specifier as a string literal so the Supabase bundler can see it.

type EdgeContext = {
  environment: string;
  id: string;
};

type SentryModule = {
  init: (options: Record<string, unknown>) => void;
  captureException: (error: unknown) => void;
  flush: (timeout?: number) => Promise<boolean>;
};

const edgeContext = new AsyncLocalStorage<EdgeContext>();
let loadPromise: Promise<SentryModule | null> | null = null;
let initialized = false;

function dsn() {
  return Deno.env.get("SENTRY_DSN") || "";
}

function release() {
  return Deno.env.get("VERCEL_GIT_COMMIT_SHA") || "";
}

function loadSentry(): Promise<SentryModule | null> {
  if (!dsn()) return Promise.resolve(null);
  if (!loadPromise) {
    loadPromise = import("npm:@sentry/deno@10.78.0")
      .then((mod) => mod as SentryModule)
      .catch(() => null);
  }
  return loadPromise;
}

function applyEdgeContext(event: Record<string, unknown>) {
  const current = edgeContext.getStore();
  if (current) {
    event.environment = current.environment;
    event.user = { id: current.id };
  }
  const releaseId = release();
  if (releaseId) event.release = releaseId;
  return event;
}

async function ensureClient(): Promise<SentryModule | null> {
  const sentry = await loadSentry();
  if (!sentry || initialized) return sentry;
  const releaseId = release();
  sentry.init({
    dsn: dsn(),
    release: releaseId || undefined,
    sendDefaultPii: false,
    tracesSampleRate: TRACES_SAMPLE_RATE,
    // Supabase reuses isolates and the Deno SDK does not separate Deno.serve
    // scopes. Leave automatic integrations off and attach context per request.
    defaultIntegrations: false,
    beforeSend(event: Record<string, unknown>) {
      return scrubSentryEvent(applyEdgeContext(event));
    },
    beforeSendTransaction(event: Record<string, unknown>) {
      return scrubSentryTransaction(applyEdgeContext(event));
    },
    beforeBreadcrumb,
  });
  initialized = true;
  return sentry;
}

export async function reportEdgeException(error: unknown): Promise<void> {
  if (!dsn()) return;
  try {
    const sentry = await ensureClient();
    if (!sentry) return;
    sentry.captureException(error);
    await sentry.flush(2000);
  } catch {
    // Reporting must not change the caller's response.
  }
}

export function serveWithSentry(
  handler: (req: Request) => Response | Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (!dsn()) return await handler(req);
    await ensureClient();
    const context = {
      environment: environmentFromOrigin(
        req.headers.get("origin"),
        req.headers.get("referer"),
      ),
      id: crypto.randomUUID(),
    };
    return await edgeContext.run(context, async () => {
      try {
        return await handler(req);
      } catch (error) {
        await reportEdgeException(error);
        throw error;
      }
    });
  };
}

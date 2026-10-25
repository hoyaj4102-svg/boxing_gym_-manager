import { corsHeaders, jsonResponse, textResponse } from "../_shared/cors.ts";
import { getAdminClient } from "../_shared/supabase.ts";
import {
  type AdminClientLike,
  processReconciliationAttempt,
  type ReconciliationAttempt,
} from "./reconciliation.ts";

const DEFAULT_STALE_MINUTES = 10;
const MAX_BATCH_SIZE = 50;

function isAuthorizedCron(req: Request, cronSecret: string) {
  if (!cronSecret) return false;
  const auth = req.headers.get("Authorization") || "";
  const headerSecret = req.headers.get("x-cron-secret") || "";
  return auth === `Bearer ${cronSecret}` || headerSecret === cronSecret;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return textResponse("Method not allowed", 405);
  }

  try {
    const cronSecret = Deno.env.get("CRON_SECRET") || "";
    if (!isAuthorizedCron(req, cronSecret)) {
      return textResponse("Unauthorized", 401);
    }

    const admin = getAdminClient();
    const staleBefore = new Date(Date.now() - DEFAULT_STALE_MINUTES * 60 * 1000)
      .toISOString();

    const { data: claimedAttempts, error: claimError } = await admin.rpc(
      "claim_stale_auto_renewal_reconciliation_attempts",
      {
        p_stale_before: staleBefore,
        p_limit: MAX_BATCH_SIZE,
      },
    );

    if (claimError) {
      return jsonResponse({ ok: false, error: claimError.message }, 400);
    }

    const results: Array<Record<string, unknown>> = [];
    const tossSecret = Deno.env.get("TOSS_SECRET_KEY") || "";

    for (const attempt of (claimedAttempts || []) as ReconciliationAttempt[]) {
      const result = await processReconciliationAttempt(
        admin as unknown as AdminClientLike,
        attempt,
        {
          tossSecret,
          fetchImpl: fetch,
        },
      );
      results.push(result);
    }

    return jsonResponse({
      ok: true,
      checkedAt: new Date().toISOString(),
      staleBefore,
      count: results.length,
      results,
    });
  } catch (error) {
    const message = errorMessage(error);
    return jsonResponse({ ok: false, error: message || "Unknown error" }, 400);
  }
});

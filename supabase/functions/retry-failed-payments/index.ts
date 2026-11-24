import { corsHeaders, jsonResponse, textResponse } from "../_shared/cors.ts";
import { getAdminClient } from "../_shared/supabase.ts";
import { retryDispatchDecision } from "../_shared/toss_test_guard.ts";
import {
  executeFailureRetryCharge,
  failureRetryAttemptUpdate,
} from "./handler.ts";

function isAuthorizedCron(req: Request, cronSecret: string) {
  if (!cronSecret) return false;
  const auth = req.headers.get("Authorization") || "";
  const headerSecret = req.headers.get("x-cron-secret") || "";
  return auth === `Bearer ${cronSecret}` || headerSecret === cronSecret;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return textResponse("Method not allowed", 405);

  const cronSecret = Deno.env.get("CRON_SECRET") || "";
  if (!isAuthorizedCron(req, cronSecret)) return textResponse("Unauthorized", 401);

  const decision = retryDispatchDecision({
    mode: Deno.env.get("BILLING_FAILURE_RETRY_MODE"),
    secretKey: Deno.env.get("TOSS_SECRET_KEY") || "",
  });
  if (decision !== "proceed") {
    return jsonResponse({
      ok: decision === "dry_run",
      dryRun: true,
      providerCalls: 0,
      code: decision === "dry_run" ? "RETRY_MODE_NOT_TEST" : "TOSS_SECRET_NOT_TEST",
    }, decision === "dry_run" ? 200 : 403);
  }

  // Reached only when BILLING_FAILURE_RETRY_MODE=test and the secret is a test key.
  // There is no schedule. This function is not called by the dry-run workflow.
  const admin = getAdminClient();
  const secret = Deno.env.get("TOSS_SECRET_KEY") || "";
  const authorization = `Basic ${btoa(`${secret}:`)}`;
  const claimed = await admin.rpc("claim_due_payment_failure_retries", {
    p_now: new Date().toISOString(),
    p_limit: 10,
  });
  if (claimed.error) {
    return jsonResponse({ ok: false, providerCalls: 0, code: "RETRY_CLAIM_FAILED" }, 400);
  }

  const claims = Array.isArray(claimed.data) ? claimed.data : [];
  let providerCalls = 0;
  const results: Array<Record<string, unknown>> = [];
  for (const claim of claims) {
    if (!claim || typeof claim !== "object") continue;
    const row = claim as Record<string, unknown>;
    const gymId = String(row.gym_id || "");
    const attemptId = String(row.payment_attempt_id || "");
    const orderId = String(row.order_id || "");
    const credential = await admin.rpc("read_gym_billing_credential", { p_gym_id: gymId });
    const billingKey = typeof credential.data === "string" ? credential.data.trim() : "";
    if (!billingKey || credential.error) continue;
    const settled = await executeFailureRetryCharge({
      orderId,
      amountKrw: Number(row.amount_krw || 0),
      customerKey: String(row.customer_key || ""),
      billingKey,
      authorization,
      tossSecret: secret,
    });
    providerCalls += settled.providerPosts;
    const settlement = settled.settlement;
    if (attemptId) {
      await admin.from("payment_attempts").update(failureRetryAttemptUpdate(settlement)).eq(
        "id",
        attemptId,
      );
      if (settlement.kind === "paid") {
        await admin.rpc("activate_payment_attempt", { p_attempt_id: attemptId });
      }
    }
    results.push({
      orderId,
      paymentAttemptId: attemptId,
      chargeResult: settlement.kind,
      providerPosts: settled.providerPosts,
    });
  }

  return jsonResponse({
    ok: true,
    dryRun: false,
    providerCalls,
    count: claims.length,
    results,
  });
});

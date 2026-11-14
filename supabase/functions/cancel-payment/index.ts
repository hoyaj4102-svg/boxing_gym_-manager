import { corsHeaders, jsonResponse, textResponse } from "../_shared/cors.ts";
import { evaluateDraftRefund } from "../_shared/refund_policy.ts";
import { getAdminClient, getGymIdForUser, requireUser } from "../_shared/supabase.ts";
import { assessTossTestCall } from "../_shared/toss_test_guard.ts";
import { executeRefund } from "./handler.ts";

function normallyUsed(value: unknown): boolean | null {
  if (value === true) return true;
  if (value === false) return false;
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return textResponse("Method not allowed", 405);

  try {
    const { user } = await requireUser(req);
    const admin = getAdminClient();
    const gymId = await getGymIdForUser(admin, user.id);
    const body = await req.json();
    const refundRequestId = String(body.refundRequestId || "").trim();
    if (!refundRequestId) return textResponse("refundRequestId is required", 400);

    const loaded = await admin.rpc("load_billing_refund_for_cancel", {
      p_gym_id: gymId,
      p_user_id: user.id,
      p_refund_request_id: refundRequestId,
    });
    if (loaded.error || !loaded.data || typeof loaded.data !== "object") {
      return jsonResponse({ ok: false, providerCalls: 0, code: "REFUND_NOT_FOUND" }, 404);
    }

    const row = loaded.data as Record<string, unknown>;
    const decision = evaluateDraftRefund({
      paidAt: String(row.paid_at || ""),
      now: new Date().toISOString(),
      amountKrw: Number(row.amount_krw),
      requestedAmountKrw: Number(row.requested_amount_krw),
      reason: String(row.reason || ""),
      normallyUsed: normallyUsed(row.normally_used),
    });
    const secret = Deno.env.get("TOSS_SECRET_KEY") || "";
    const guard = assessTossTestCall({
      mode: Deno.env.get("BILLING_CANCEL_MODE"),
      secretKey: secret,
    });
    const result = await executeRefund({
      decision,
      guard,
      paymentKey: String(row.payment_key || ""),
      refundRequestId,
      cancelReason: String(row.reason || "customer_request"),
      authorization: guard.allow ? `Basic ${btoa(`${secret}:`)}` : "",
    });

    await admin.rpc("record_billing_refund_result", {
      p_refund_request_id: refundRequestId,
      p_status: result.status,
      p_code: result.code,
      p_provider_called: result.providerCalls > 0,
    });

    return jsonResponse({
      ok: result.status === "succeeded",
      providerCalls: result.providerCalls,
      status: result.status,
      code: result.code,
    }, result.status === "succeeded" ? 200 : 409);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "UNAUTHORIZED" ? 401 : 400;
    return textResponse(status === 401 ? "Unauthorized" : "Refund request failed", status);
  }
});

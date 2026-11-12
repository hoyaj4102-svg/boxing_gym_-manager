import { corsHeaders, jsonResponse, textResponse } from "../_shared/cors.ts";
import { getAdminClient, getGymIdForUser, requireUser } from "../_shared/supabase.ts";
import { assessTossTestCall } from "../_shared/toss_test_guard.ts";
import { executeReceiptLookup } from "./handler.ts";

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
    const paymentAttemptId = String(body.paymentAttemptId || "").trim();
    if (!paymentAttemptId) return textResponse("paymentAttemptId is required", 400);

    const owned = await admin
      .from("payment_attempts")
      .select("id")
      .eq("id", paymentAttemptId)
      .eq("gym_id", gymId)
      .maybeSingle();
    if (owned.error || !owned.data) {
      return jsonResponse({ ok: false, providerCalls: 0, code: "PAYMENT_NOT_FOUND" }, 404);
    }

    const resolved = await admin.rpc("resolve_attempt_payment_key", {
      p_attempt_id: paymentAttemptId,
    });
    const paymentKey = typeof resolved.data === "string" ? resolved.data.trim() : "";
    if (resolved.error || !paymentKey) {
      return jsonResponse({ ok: false, providerCalls: 0, code: "PAYMENT_KEY_MISSING" }, 404);
    }

    const secret = Deno.env.get("TOSS_SECRET_KEY") || "";
    const guard = assessTossTestCall({
      mode: Deno.env.get("BILLING_RECEIPT_MODE"),
      secretKey: secret,
    });
    const result = await executeReceiptLookup({
      guard,
      paymentKey,
      authorization: guard.allow ? `Basic ${btoa(`${secret}:`)}` : "",
    });

    return jsonResponse({
      ok: result.status === "found",
      providerCalls: result.providerCalls,
      status: result.status,
      code: result.code,
      receiptUrl: result.receiptUrl,
    }, result.status === "found" ? 200 : 409);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "UNAUTHORIZED" ? 401 : 400;
    return textResponse(status === 401 ? "Unauthorized" : "Receipt lookup failed", status);
  }
});
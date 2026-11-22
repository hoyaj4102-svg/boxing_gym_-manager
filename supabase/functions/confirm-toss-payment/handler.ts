import { corsHeaders, jsonResponse, textResponse } from "../_shared/cors.ts";

export const LEGACY_TOSS_CONFIRM_DISABLED = "LEGACY_TOSS_CONFIRM_DISABLED";

export type RequireUser = (req: Request) => Promise<unknown>;
export type ReportError = (error: unknown) => Promise<void> | void;

export async function handleConfirmTossPaymentRequest(
  req: Request,
  deps: { requireUser: RequireUser; reportError?: ReportError },
) {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  if (req.method !== "POST") {
    return textResponse("Method not allowed", 405);
  }

  try {
    await deps.requireUser(req);
    return jsonResponse(
      {
        ok: false,
        error: LEGACY_TOSS_CONFIRM_DISABLED,
        message:
          "Legacy Toss payment confirmation is disabled. Use the billing-auth subscription flow.",
      },
      410,
    );
  } catch (error) {
    if (deps.reportError) {
      try {
        await deps.reportError(error);
      } catch {
        // Reporting must not change the response.
      }
    }
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "UNAUTHORIZED" ? 401 : 400;
    return textResponse(message, status);
  }
}

import { corsHeaders, jsonResponse, textResponse } from "../_shared/cors.ts";

export const LEGACY_CHECKOUT_DISABLED = "LEGACY_CHECKOUT_DISABLED";

export type RequireUser = (req: Request) => Promise<unknown>;

export async function handleCreateCheckoutRequest(
  req: Request,
  deps: { requireUser: RequireUser },
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
        error: LEGACY_CHECKOUT_DISABLED,
        message:
          "Legacy checkout is disabled. Use the billing-auth subscription flow.",
      },
      410,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "UNAUTHORIZED" ? 401 : 400;
    return textResponse(message, status);
  }
}

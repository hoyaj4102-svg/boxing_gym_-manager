import { requireUser } from "../_shared/supabase.ts";
import { reportEdgeException, serveWithSentry } from "../_shared/sentry.ts";
import { handleConfirmTossPaymentRequest } from "./handler.ts";

Deno.serve(serveWithSentry(async (req) => {
  return handleConfirmTossPaymentRequest(req, {
    requireUser,
    reportError: reportEdgeException,
  });
}));

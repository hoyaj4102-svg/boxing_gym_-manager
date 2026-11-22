import { requireUser } from "../_shared/supabase.ts";
import { reportEdgeException, serveWithSentry } from "../_shared/sentry.ts";
import { handleCreateCheckoutRequest } from "./handler.ts";

Deno.serve(serveWithSentry(async (req) => {
  return handleCreateCheckoutRequest(req, {
    requireUser,
    reportError: reportEdgeException,
  });
}));

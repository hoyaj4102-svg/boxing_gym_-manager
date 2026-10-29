import { requireUser } from "../_shared/supabase.ts";
import { handleCreateCheckoutRequest } from "./handler.ts";

Deno.serve(async (req) => {
  return handleCreateCheckoutRequest(req, { requireUser });
});

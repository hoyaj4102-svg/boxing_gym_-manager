import { requireUser } from "../_shared/supabase.ts";
import { handleConfirmTossPaymentRequest } from "./handler.ts";

Deno.serve(async (req) => {
  return handleConfirmTossPaymentRequest(req, { requireUser });
});

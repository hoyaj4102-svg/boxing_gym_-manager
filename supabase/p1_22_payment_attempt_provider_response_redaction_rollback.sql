-- =============================================================================
-- Rollback for payment attempt provider_response redaction.
--
-- Masked provider_response values cannot be restored. This file does not
-- rewrite payment_attempts, checkout_sessions, or subscriptions, and it does
-- not read private.billing_credentials.
--
-- The migration does not replace private.redact_sensitive_payload or
-- private.redact_payment_row. payment_attempts_redact_payload stays in place
-- so later inserts and updates remain masked. Re-applying this file only
-- drops the one-time apply function.
-- =============================================================================

drop function if exists private.apply_payment_attempt_provider_response_redaction();

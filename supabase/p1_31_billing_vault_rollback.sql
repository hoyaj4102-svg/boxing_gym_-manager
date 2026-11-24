-- Undo supabase/p1_31_billing_vault.sql.
-- requires Founder approval before applying to production
--
-- Restores plaintext from Vault, then deletes only the secrets this migration
-- recorded. If a secret cannot be decrypted, the function raises
-- BILLING_VAULT_ROLLBACK_INCOMPLETE and leaves the database unchanged.
-- Do not apply this file to production until that approval is recorded.

select private.rollback_billing_keys_from_vault();

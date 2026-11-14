-- =============================================================================
-- Rollback for p1_25 column drop.
--
-- Recreates private.billing_credentials.billing_key and fills it from Vault.
-- The gyms fallback stays off (p1_24 state).
--
-- Irreversible when a Vault secret is missing or no longer decrypts. This
-- file then raises BILLING_VAULT_ROLLBACK_INCOMPLETE. Dropping the column
-- destroyed the only plaintext copy; Vault is the only way back. Do not
-- delete Vault secrets before you are sure this rollback is unnecessary.
-- =============================================================================

select private.rollback_billing_vault_drop();

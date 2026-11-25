-- =============================================================================
-- Rollback for p1_24 plaintext clear.
--
-- Writes Vault-confirmed values back into the columns p1_24 nulled and turns
-- the gyms billing fallback back on. It does not delete Vault secrets.
--
-- Irreversible for a row whose Vault secret no longer decrypts: the nulled
-- plaintext cannot be reconstructed. Run this before p1_25. After p1_25 the
-- billing_key column is gone; run p1_25's rollback first or this file raises
-- BILLING_VAULT_ROLLBACK_NEEDS_COLUMN.
-- =============================================================================

select private.rollback_billing_vault_clear();

-- =============================================================================
-- Rollback for p1_23 Billing Vault copy.
--
-- Deletes the Vault secrets recorded by p1_23 and the secret-id rows.
-- Plaintext columns are not modified.
--
-- Irreversible if this is run after p1_24 has nulled plaintext. The function
-- raises BILLING_VAULT_ROLLBACK_UNSAFE and deletes nothing when a recorded
-- secret no longer matches plaintext. Run p1_24's rollback first, and only
-- then this file, if you still need to remove the Vault copies.
-- Do not run this after p1_25 unless the plaintext column has been restored
-- and still matches Vault.
-- =============================================================================

select private.rollback_billing_vault_copy();

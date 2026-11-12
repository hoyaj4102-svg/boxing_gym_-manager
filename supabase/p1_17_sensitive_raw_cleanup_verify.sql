-- =============================================================================
-- Read-only counts for the sensitive raw cleanup. This file does not update,
-- delete, or copy any payload.
--
-- Run it before apply and save the result. Run it again after apply.
-- After a successful apply:
--   completed_checkout_unredacted_sensitive_keys = 0
--   subscription_unredacted_sensitive_keys = 0
--   completed_checkout_rows_redaction_would_change = 0
--   subscription_rows_redaction_would_change = 0
-- The last two counts are the rows a repeated mask would still change.
-- Total rows, status counts, and link counts should match the saved snapshot.
--
-- A count-only audit saw 6 completed checkout rows and 5 to 6 subscription
-- rows that still held sensitive raw keys. This query returns counts only.
-- =============================================================================

select metric, row_count
from private.sensitive_raw_cleanup_verification()
order by metric;

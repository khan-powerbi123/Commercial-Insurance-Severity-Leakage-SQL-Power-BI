--2.7 Quality checks
-- Counts
SELECT 'core_policies' t, COUNT(*) FROM core.core_policies
UNION ALL 
SELECT 'core_claims', COUNT(*) FROM core.core_claims
UNION ALL 
SELECT 'core_payments', COUNT(*) FROM core.core_payments
UNION ALL 
SELECT 'core_adjuster', COUNT(*) FROM core.core_adjuster
UNION ALL 
SELECT 'core_notes', COUNT(*) FROM core.core_notes;

-- NULL checks on critical FKs
SELECT 'claims_missing_policy' AS issue, COUNT(*) AS cnt
FROM core.core_claims WHERE policy_id IS NULL;

SELECT 'claims_missing_adjuster' AS issue, COUNT(*) AS cnt
FROM core.core_claims WHERE adjuster_id IS NULL;  -- may be acceptable

-- Money sanity
SELECT TOP 20 
	claim_number, incurred_total, paid_total, reserve_total
FROM core.core_claims
WHERE incurred_total IS NULL OR paid_total IS NULL;

--Showing all tables;
select TOP 50 *
from core.core_claims;

select TOP 50 *
from core.core_policies;

select TOP 50 *
from core.core_payments;
 
select TOP 50 *
from core.core_adjuster;

select TOP 100 *
from core.core_notes;
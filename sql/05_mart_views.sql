--4) Mart objects to package results (nice for exports later)
IF OBJECT_ID('mart.claim_risk_signals') IS NOT NULL DROP VIEW mart.claim_risk_signals;
GO
CREATE VIEW mart.claim_risk_signals AS
WITH dup AS (
  SELECT p.claim_id, COUNT(*) AS dup_hits
  FROM core.core_payments p
  GROUP BY p.claim_id, p.payment_date, p.cost_type, p.amount, p.check_number
  HAVING COUNT(*)>1
),
kpi AS (
  SELECT c.claim_id,
         DATEDIFF(day, c.loss_date, GETDATE()) AS age_days,
         c.paid_total, c.reserve_total
  FROM core.core_claims c
),
score AS (
  SELECT k.claim_id,
         COALESCE(d.dup_hits,0) AS dup_hits,
         CASE WHEN k.age_days>365 AND k.reserve_total > k.paid_total*3 THEN 1 ELSE 0 END AS reserve_flag
  FROM kpi k
  LEFT JOIN dup d ON d.claim_id = k.claim_id
)
SELECT c.claim_number, p.lob, c.loss_state,
       c.paid_total, c.reserve_total,
       s.dup_hits, s.reserve_flag,
       (COALESCE(s.dup_hits,0)*1.0 + CASE WHEN s.reserve_flag=1 THEN 1.0 ELSE 0.0 END) AS risk_score
FROM score s
JOIN core.core_claims c ON c.claim_id = s.claim_id
JOIN core.core_policies p ON p.policy_id = c.policy_id;
GO

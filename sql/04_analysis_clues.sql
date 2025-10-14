--3) Step 3 — Mystery case flow (clues unlocked by cleaned data)
-- Clue 1. Severity hotspots by LOB/state and quarter trend

-- use case: Which LOB + State combinations have seen the largest increases (or decreases) in average claim severity based on price from one quarter to the next in the last 2 years.
WITH base AS (
SELECT
c.claim_id,
p.lob,
c.loss_state,
c.reserve_total + c.paid_total as incurred,
c.loss_date
from core.core_claims c
join core.core_policies p
on c.policy_id = p.policy_id
where c.loss_date >= DATEADD(year, -2, GETDATE())
),

qtr AS (
SELECT
lob,
loss_state,
DATEFROMPARTS(
	year(loss_date),
	CASE DATEPART(quarter, loss_date)
		WHEN 1 THEN 1
		WHEN 2 THEN 4
		WHEN 3 THEN 7
		WHEN 4 THEN 10
	END, 1) AS qstart,
avg(incurred) AS avg_severity
from base
GROUP BY lob, loss_state, DATEFROMPARTS(year(loss_date),CASE DATEPART(quarter, loss_date) WHEN 1 THEN 1 WHEN 2 THEN 4 WHEN 3 THEN 7 WHEN 4 THEN 10 END, 1)
),

change AS (
Select *,
LAG(avg_severity) OVER (PARTITION BY lob, loss_state ORDER BY qstart) AS prev_q
FROM qtr
)

SELECT
	lob,
	loss_state,
	qstart,
	avg_severity,
	prev_q,
	cast((avg_severity - prev_q) / NULLIF(prev_q,0) AS decimal(10,4)) AS qoq_change
	from change
	ORDER BY qoq_change DESC;  --Interpretation Highlights where average incurred jumped most; these are your first “hot” leads.


    -- Clue 2. Reserve adequacy and late activity flags
	WITH KPI AS (
	SELECT
	c.claim_id,
	c.claim_number,
	c.loss_date,
	c.status,
	DATEDIFF(day, c.loss_date, GETDATE()) AS loss_age_days,
	c.paid_total,
	c.reserve_total,
	sum(CASE WHEN p.payment_date >= DATEADD(DAY, -90, GETDATE()) THEN p.amount ELSE 0 END) AS total_paid_90
	from core.core_claims c
	left join core.core_payments p
	on c.claim_id = p.claim_id
	GROUP BY c.claim_id, c.claim_number, c.loss_date, c.status, DATEDIFF(day, c.loss_date, GETDATE()), c.paid_total, c.reserve_total),

	score AS (
	select *,
		(CASE WHEN loss_age_days > 365 AND reserve_total > 3* paid_total THEN 1.0 ELSE 0.0 END) + 
		(CASE WHEN total_paid_90 = 0 AND reserve_total > 0 THEN 0.5 ELSE 0.00 END) AS leakage_score
		from KPI
	)

	select top 100 *
	from score
	ORDER BY leakage_score DESC, reserve_total DESC;

-- 📌 Interpretation:
--This is a reserve adequacy / leakage flagging tool.
--It highlights claims where:
--Reserves are high,
--Payments haven’t been made recently,
--Or the claim is old but still “open.”
 --Surfaced claims with heavy reserves but little recent payment activity 
-- mean reserve drift, stalled claim handling, or potential leakage (more money than necessary locked in reserves).

 --Clue 3. Duplicate or erroneous payments
 SELECT
	c.claim_number,
	p.payment_date,
	p.cost_type,
	p.amount,
	p.check_number,
	count(*) as dup_count
	FROM core.core_claims c
	join core.core_payments p
	on c.claim_id = p.claim_id
	GROUP BY c.claim_number, p.payment_date, p.cost_type, p.amount, p.check_number
	HAVING count(*) > 1 
	ORDER BY dup_count DESC, amount DESC;

	-- 📌 Interpretation -> Same claim/date/amount/check is strong duplicate signal. These are direct leakage candidates.
	--I tested for duplicate or erroneous payments by grouping claims on payment date, cost type, and amount. 
	--The query returned no results, which suggests the dataset is free of duplicate disbursements under those criteria. 
    --In other words, our payment data looks clean.

	--Clue 4. Vendor outliers using IQR with window functions
	WITH V as (
	SELECT
		vendor_id,
		amount
		FROM core.core_payments
		WHERE amount IS NOT NULL
	),
	stats AS (
	SELECT
		vendor_id,
		PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amount) OVER (PARTITION BY vendor_id) AS q1,
		PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amount) OVER (PARTITION BY vendor_id) AS q3,
		amount
		FROM V
	),
	flagged AS (
	SELECT
		vendor_id,
		amount,
		q1,
		q3,
		(q3 - q1) AS IQR
		FROM stats
	)
	SELECT 
		vendor_id,
		amount,
		q1,
		q3
		FROM flagged
		WHERE amount > q3 + 1.5*(IQR) OR amount < q1 - 1.5*(IQR)
		ORDER BY amount DESC;
--📌 Interpretation ->
-- Using the IQR method, I identified both unusually high and unusually low vendor payments.
-- High outliers (e.g., Vendor V1801 with $4,997 vs typical $2,600) may signal overpayments or fraudulent invoices.
-- Low outliers (e.g., Vendor V2299 with $12 vs typical $2,500) may represent test/erroneous transactions.
-- These findings provide a shortlist of vendors for audit review.

-- Clue 5. Recursive CTE: adjuster hierarchy and severity by tier
WITH Hierarchy AS (
SELECT
	adjuster_id,
	full_name,
	supervisor_id,
	cast(full_name AS NVARCHAR(MAX)) AS Path
FROM core.core_adjuster 
WHERE supervisor_id IS NULL

UNION ALL
SELECT
	a.adjuster_id,
	a.full_name,
	a.supervisor_id,
	h.Path + N'->' + a.full_name AS path
FROM core.core_adjuster a
JOIN Hierarchy h
on a.supervisor_id = h.adjuster_id
)
SELECT
	h.adjuster_id,
	h.full_name,
	h.supervisor_id,
	h.Path,
	count(c.claim_id) AS claim_count,
	COALESCE(AVG(c.paid_total + c.reserve_total),0) AS avg_severity
	FROM Hierarchy h
	LEFT JOIN core.core_claims c
	on c.adjuster_id = h.adjuster_id
	GROUP BY h.adjuster_id, h.full_name, h.supervisor_id, h.Path
	ORDER BY avg_severity DESC;
--📌 Interpretation ->	
--Which depth/tier has the highest average severity? Are certain teams driving leakage?
-- We built a recursive hierarchy query that rolls claims up to each adjuster. In this dataset, there are no supervisor links yet (all supervisor_id values are NULL), so the hierarchy is flat. 
--Each adjuster has an equal number of claims (40), but average severity differs. This kind of query would normally let us see severity and claim counts at every tier in the adjuster hierarchy (Supervisor → Adjuster → Junior Adjuster). 
--With real-world data, it highlights which teams or adjusters are handling the highest severity claims.

--Clue 6. Notes mining: missed subrogation, late FNOL, duplicate billing keywords
-- Simple keyword flags
	WITH flags AS (
	SELECT
		n.claim_id,
		MAX(CASE WHEN n.note_text LIKE '%subrogation%' AND n.note_text LIKE '%not pursued%' THEN 1 ELSE 0 END) AS missed_subrogation,
		MAX(CASE WHEN n.note_text LIKE '%LATE FNOL%' AND n.note_text LIKE '%Reported after%' THEN 1 ELSE 0 END) AS missed_FNOL,
		MAX(CASE WHEN n.note_text LIKE '%Duplicate billing%' THEN 1 ELSE 0 END) AS dup_billing
    FROM core.core_notes n
	GROUP BY n.claim_id
)

SELECT
	f.claim_id, 
	f.missed_subrogation,
	f.missed_FNOL, 
	f.dup_billing,
	c.paid_total + c.reserve_total AS incurred
	FROM flags f
	JOIN core.core_claims c 
	on c.claim_id = f.claim_id
	WHERE f.missed_subrogation =1 OR f.missed_FNOL = 1 OR f.dup_billing = 1
	ORDER BY incurred DESC;
--📌 Interpretation ->	
--I mined claim notes for key leakage indicators. For each claim, I flagged three common issues: missed subrogation, late reporting, and duplicate billing. 
--The results highlight only those claims with at least one red flag, ranked by incurred costs. For example, Claim 16932 shows both late reporting and duplicate billing with $25K exposure. 
--This lets me quickly prioritize the largest-dollar claims with potential leakage risk for deeper review.

-- Clue 7. Executive rollups (GROUPING SETS) to summarize findings.
SELECT
	coalesce(p.lob, 'ALL LOBs') AS lob,
	coalesce(c.loss_state, 'ALL States') AS loss_state,
	COALESCE(CONVERT(varchar(10), c.loss_date, 120), 'ALL DATES') AS loss_date,
	SUM(c.paid_total + c.reserve_total) AS incurred
	FROM core.core_policies p
	JOIN core.core_claims c
	on c.policy_id = p.policy_id
	GROUP BY GROUPING SETS (
	(p.lob, c.loss_state, c.loss_date), -- daily detail
	(p.lob, c.loss_state),              -- state totals
	(p.lob),                            -- lob totals
	()                                  -- grand total
	)
	ORDER BY p.lob, c.loss_state, c.loss_date;
--📌 Interpretation ->	
--Total incurred claims across all lines and states ≈ $270M.
--General Liability (GL) is the largest driver at $179M.
--Within GL, Illinois is the biggest hotspot (~$117M).
--Daily detail highlights spikes and anomalies for further investigation.


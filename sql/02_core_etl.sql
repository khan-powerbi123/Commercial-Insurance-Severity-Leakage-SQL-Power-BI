--2) Step 2 — ETL cleaning & conformance into core
-- ~ 2.1 Create typed core tables
-- DROP: children -> parents
IF OBJECT_ID('core.core_payments','U') IS NOT NULL DROP TABLE core.core_payments;
IF OBJECT_ID('core.core_notes','U')    IS NOT NULL DROP TABLE core.core_notes;
IF OBJECT_ID('core.core_claims','U')   IS NOT NULL DROP TABLE core.core_claims;
IF OBJECT_ID('core.core_adjuster','U') IS NOT NULL DROP TABLE core.core_adjuster;
IF OBJECT_ID('core.core_policies','U') IS NOT NULL DROP TABLE core.core_policies;

-- CREATE: parents -> children
CREATE TABLE core.core_policies (
  policy_id       int identity primary key,
  policy_number   varchar(30) unique,
  insured_name    nvarchar(200),
  lob             varchar(20),
  effective_date  date,
  expiration_date date,
  state           char(2),
  broker_code     varchar(20)
);

CREATE TABLE core.core_adjuster (
  adjuster_id     int identity primary key,
  adjuster_ext_id varchar(30) unique,
  full_name       nvarchar(120),
  hire_date       date,
  office          nvarchar(50),
  supervisor_id   int null references core.core_adjuster(adjuster_id) -- self-FK ok
);

CREATE TABLE core.core_claims(
  claim_id       int identity primary key,
  claim_number   varchar(30) unique,
  policy_id      int not null references core.core_policies(policy_id),
  loss_date      date,
  report_date    date,
  injury_cause   nvarchar(30),
  body_part      nvarchar(30),
  claimant_id    varchar(30),
  loss_state     char(2),
  incurred_total decimal(18,2),
  paid_total     decimal(18,2),
  reserve_total  decimal(18,2),
  status         varchar(20),
  adjuster_id    int null references core.core_adjuster(adjuster_id)
);

CREATE TABLE core.core_payments (
  payment_id     bigint identity primary key,
  claim_id       int not null references core.core_claims(claim_id),
  payment_date   date,
  payee_type     varchar(30),
  vendor_id      varchar(30),
  cost_type      varchar(30),
  cost_category  varchar(30),
  amount         decimal(18,2),
  check_number   varchar(30)
);

CREATE TABLE core.core_notes(
  note_id       bigint identity primary key,
  claim_id      int not null references core.core_claims(claim_id),
  note_time     datetime2,
  author        nvarchar(20),
  note_text     nvarchar(max)
);

-- 2.2 Clean policies to core_policies
-- Normalize strings, trim, upcase state/lob, parse dates safely
WITH base AS (
SELECT
	LTRIM(RTRIM(policy_number)) AS policy_number,
	NULLIF(LTRIM(RTRIM(insured_name)), '') AS insured_name,
	UPPER(LTRIM(RTRIM(lob))) AS lob_raw,
	LTRIM(RTRIM(effective_date)) AS eff_raw,
	LTRIM(RTRIM(expiration_date)) AS exp_raw,
	UPPER(LTRIM(RTRIM(state))) AS state_raw,
	NULLIF(LTRIM(RTRIM(broker_code)),'') AS broker_code 
FROM staged.staged_policies
),
typed AS (
SELECT
	policy_number,
	insured_name,
	CASE 
		WHEN lob_raw in ('WC', 'W C', 'wc') THEN 'WC'
		WHEN lob_raw in ('GL', 'gL', 'gl') THEN 'GL'
		ELSE Coalesce(NULLIF(lob_raw, ''), 'GL') END AS lob,
	TRY_CONVERT(date, NULLIF(eff_raw, '')) AS effective_date,
	TRY_CONVERT(date, NULLIF(exp_raw, '')) AS expiry_date,
	CASE 
		WHEN LEN(state_raw) = 2 THEN state_raw
		WHEN state_raw LIKE 'IL%' THEN 'IL'
		WHEN state_raw LIKE 'WI%' THEN 'WI'
	ELSE NULL END AS state,
	broker_code
	FROM base
	)
	INSERT core.core_policies(policy_number, insured_name, lob, effective_date, expiration_date, state, broker_code)
	SELECT policy_number, insured_name, lob, effective_date, expiry_date, state, broker_code
	FROM typed
	WHERE policy_number IS NOT NULL;

  --2.3 Clean adjusters to core_adjuster, then wire supervisor_id (two-pass)
  -- Pass 1: load adjusters without supervisor linkage
  INSERT INTO core.core_adjuster(adjuster_ext_id, full_name, hire_date, office, supervisor_id)
  SELECT
	LTRIM(RTRIM(adjuster_ext_id)),
	NULLIF(LTRIM(RTRIM(full_name)),''),
	TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(hire_date)), '')),
	NULLIF(LTRIM(RTRIM(office)),''),
	NULL
  FROM staged.staged_adjuster
  WHERE	adjuster_ext_id IS NOT NULL;

--Pass 2: resolve supervisor by matching ext ids already loaded 
 UPDATE a
SET supervisor_id = sup.adjuster_id -- 4) write the supervisor's PK onto the child row
FROM core.core_adjuster a           -- 1) alias the table being updated as c (the "child")
JOIN staged.staged_adjuster s       -- 2) bring in supervisor_ext_id from staging
    ON a.adjuster_ext_id = s.adjuster_ext_id 
JOIN core.core_adjuster sup          -- 3) self-join: find the supervisor row in the same core table
    ON sup.adjuster_ext_id = s.supervisor_ext_id;


-- 2.4 Clean claims to core_claims with deduping (ROW_NUMBER)
;with ranked AS (
SELECT 
	LTRIM(RTRIM(claim_number)) AS claim_number,
	LTRIM(RTRIM(policy_number)) AS policy_number,
	TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(loss_date)),'')) AS loss_date,
	TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(report_date)),'')) AS report_date,
	NULLIF(LTRIM(RTRIM(injury_cause)),'') AS injury_cause,
	NULLIF(ltrim(rtrim(body_part)),'') AS body_part,
	NULLIF(LTRIM(RTRIM(claimant_id)),'') AS claimant_id,
	UPPER(LTRIM(RTRIM(loss_state))) AS loss_state,
	TRY_CONVERT(money, NULLIF(LTRIM(RTRIM(incurred_total)),'NULL')) AS incurred_total,
	TRY_CONVERT(money, NULLIF(LTRIM(RTRIM(paid_total)),'NULL')) AS paid_total,
	TRY_CONVERT(money, NULLIF(LTRIM(RTRIM(reserve_total)),'NULL')) AS reserve_total,
	CASE
		WHEN LTRIM(RTRIM(status)) in ('Open', 'OPEN', 'open') THEN 'Open'
		WHEN LTRIM(RTRIM(status)) in ('Closed','closed', 'CLOSED') THEN 'Closed'
		ELSE 'Litigation'
		END AS status_norm,
	LTRIM(RTRIM(adjuster_ext_id)) AS adjuster_ext_id,
	ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(claim_number)) ORDER BY (SELECT NULL)) as rn
	FROM staged.staged_claims
	)
	INSERT INTO core.core_claims(claim_number, policy_id, loss_date, report_date, injury_cause, body_part, claimant_id, loss_state, incurred_total, paid_total, reserve_total, status, adjuster_id)

	SELECT
		r.claim_number,
		p.policy_id,
		r.loss_date,
		r.report_date,
		r.injury_cause,
		r.body_part,
		r.claimant_id,
		CASE
		    WHEN LEN(r.loss_state) = 2 THEN r.loss_state
			WHEN r.loss_state LIKE '%WI' THEN 'WI'
			WHEN r.loss_state LIKE '%IL' THEN 'IL'
			ELSE NULL 
		END AS loss_state,
		r.incurred_total,
		r.paid_total,
		r.reserve_total,
		r.status_norm,
		a.adjuster_id
		FROM ranked r
		JOIN core.core_policies p
		ON r.policy_number = p.policy_number 
		JOIN core.core_adjuster a
		on r.adjuster_ext_id = a.adjuster_ext_id
		WHERE r.rn = 1;

		--2.5 Clean payments to core_payments
		insert into core.core_payments (claim_id, payment_date, payee_type, vendor_id, cost_type, cost_category, amount, check_number)
		SELECT
			c.claim_id,
			TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(s.payment_date)),'')) AS payment_date,
			UPPER(NULLIF(LTRIM(RTRIM(s.payee_type)),'')) AS payee_type,
			NULLIF(LTRIM(RTRIM(vendor_id)),'') AS vendor_id,
			CASE 
			WHEN LTRIM(RTRIM(s.cost_type)) IN ('Indemnty', 'indemnty', 'INDEMNTY') THEN 'Indemnity'
			ELSE NULLIF(LTRIM(RTRIM(s.cost_type)), '') END AS cost_type,
			UPPER(NULLIF(LTRIM(RTRIM(s.cost_category)),'')) AS cost_category,
			TRY_CONVERT(money, NULLIF(LTRIM(RTRIM(s.amount)), 'NULL')) AS amount,
			nullif(ltrim(rtrim(s.check_number)),'') AS check_number 
			FROM staged.staged_payments s
			JOIN core.core_claims c
			on s.claim_number = c.claim_number
			WHERE TRY_CONVERT(money, NULLIF(LTRIM(RTRIM(s.amount)), 'NULL')) IS NOT NULL
			AND
			TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(s.payment_date)),'')) IS NOT NULL;
			
			--2.6 Clean notes to core_notes

			insert into core.core_notes(claim_id, note_time, author, note_text)
			SELECT
				c.claim_id,
				TRY_CONVERT(datetime2, NULLIF(LTRIM(RTRIM(s.note_time)), '')),
				NULLIF(LTRIM(RTRIM(s.author)),''),
				s.note_text
				FROM staged.staged_notes s
				JOIN core.core_claims c
				on s.claim_number = c.claim_number
				WHERE s.note_text IS NOT NULL;



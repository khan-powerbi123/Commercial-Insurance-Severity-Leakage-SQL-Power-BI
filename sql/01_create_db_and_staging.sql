-- setup database and schema
IF DB_ID('SeverityLeakageCase') IS NULL
	CREATE DATABASE SeverityLeakageCase;
GO
USE SeverityLeakageCase;
GO
-- Schema for pipeline ~ folders/namespaces inside the database to organize tables: pipeline
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'staged') EXEC('CREATE SCHEMA staged'); --messy/raw data.
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'core')   EXEC('CREATE SCHEMA core');   --cleaned/standardized data.
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'mart')   EXEC('CREATE SCHEMA mart');   --reporting/summary views.

--Volume parameters
DECLARE @policies INT = 5000;    -- ~ companies/policies
DECLARE @claims   INT = 20000;   -- ~ claims
DECLARE @payments INT = 100000;  -- ~ payment rows
DECLARE @adjuster INT = 500;     -- ~ adjusters
DECLARE @notes    INT = 200000;  -- ~ note lines 

-- 1) Step 1: Staging design (messy by design) + data generation
-- 1.1 Create messy staging tables
--  Dates and amounts deliberately as varchar; minimal constraints; duplicates allowed
IF OBJECT_ID('staged.staged_policies') IS NOT NULL DROP TABLE staged.staged_policies;
CREATE TABLE staged.staged_policies (
policy_number   varchar(30),
insured_name    varchar(200),
lob             varchar(20),    --e.g WC, GL, Auto, but messy casing/typos allowed 
effective_date  varchar(20),    -- many formats '2023-01-01', '01/01/2023', '01-jan-2023'
expiration_date varchar(20),
state           varchar(3),     -- may include space, lowercase
broker_code     varchar(20)
);

IF OBJECT_ID('staged.staged_claims') IS NOT NULL DROP TABLE staged.staged_claims;
CREATE TABLE staged.staged_claims (
claim_number    varchar(30),
policy_number   varchar(30),
loss_date       varchar(20),
report_date     varchar(20),
injury_cause    varchar(100),
body_part       varchar(100),
claimant_id     varchar(30),
loss_state      varchar(3),
incurred_total  varchar(30),    --numeric stored as string 
paid_total      varchar(30),
reserve_total   varchar(30),
status          varchar(30),    -- 'Open', 'Closed', 'Litigation', mixed case
adjuster_ext_id   varchar(30)
);

IF OBJECT_ID('staged.staged_payments') IS NOT NULL DROP TABLE staged.staged_payments;
CREATE TABLE staged.staged_payments (
payment_ext_id  varchar(40),
claim_number    varchar(30),
payment_date    varchar(20),
payee_type      varchar(30),     --Provider/Vendor/etc. With inconsistencies 
vendor_id       varchar(30),
cost_type       varchar(30),     -- Medical/Indemnity but typos like 'Indemnty'
cost_category   varchar(30),     --Treatment/Legal, Others ... 
amount          varchar(30),     --numeric as string or 'NULL'
check_number    varchar(30)
);

IF OBJECT_ID('staged.staged_adjuster') IS NOT NULL DROP TABLE staged.staged_adjuster;
CREATE TABLE staged.staged_adjuster (
adjuster_ext_id   varchar(30),
full_name         varchar(120),
hire_date         varchar(20),
office            varchar(50),
supervisor_ext_id varchar(30)
);

IF OBJECT_ID('staged.staged_notes') IS NOT NULL DROP TABLE staged.staged_notes;
CREATE TABLE staged.staged_notes (
claim_number      varchar(30),
note_time         varchar(25),
author            varchar(120),
note_text         varchar(max)
);

--1.2 Helper: big numbers source (tally) and utility functions
-- Tally source using system tables
WITH src AS (
  SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
SELECT TOP 1 1 AS ok INTO #warmup FROM src;  -- force compile
DROP TABLE #warmup;


-- 1.3 Populate staging with messy data
-- Policies
;WITH n AS (
  SELECT TOP (@policies)   --5000
  ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
  FROM sys.all_objects a 
  CROSS JOIN sys.all_objects b
)
INSERT staged.staged_policies(policy_number, insured_name, lob, effective_date, expiration_date, state, broker_code)
SELECT
  CONCAT('POL', RIGHT(CONCAT('000000', i), 6)),
  CONCAT('Acme Co ', i),
  CASE 
	WHEN i%7=0 
		THEN 'gl' 
	WHEN i%11=0 
		THEN 'Wc ' 
	ELSE (CASE WHEN i%3=0 THEN 'WC' ELSE 'GL' END) 
  END,
  CASE 
	WHEN i%5=0  
		THEN CONVERT(varchar(10), DATEADD(day, -i%1200, GETDATE()), 101)      -- mm/dd/yyyy
    WHEN i%9=0  
		THEN CONVERT(varchar(10), DATEADD(day, -i%1200, GETDATE()), 23)       -- yyyy-mm-dd
    ELSE FORMAT(DATEADD(day, -i%1200, GETDATE()), 'dd-MMM-yyyy') 
  END,
  CASE 
	WHEN i%8=0  
		THEN ''
    WHEN i%10=0 
		THEN 'NULL'
    ELSE CONVERT(varchar(10), DATEADD(day, 365, DATEADD(day, -i%1200, GETDATE())), 23) 
  END,
  CASE 
	WHEN i%6=0  
		THEN 'il ' 
	WHEN i%4=0 
		THEN 'wi' 
	ELSE 'IL' 
  END,
  CONCAT('BRK', (i%300)+1)
  from n;


-- Claims (with deliberate duplicates and null-ish strings)
  ;WITH n AS (
  SELECT TOP (@claims) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT staged.staged_claims
  (claim_number, policy_number, loss_date, report_date, injury_cause, body_part,
   claimant_id, loss_state, incurred_total, paid_total, reserve_total, status, adjuster_ext_id)
SELECT
  CONCAT('CLM', RIGHT(CONCAT('000000', i), 6)),
  CONCAT('POL', RIGHT(CONCAT('000000', (i%@policies)+1), 6)),
  CASE 
	WHEN i%5=0  
		THEN CONVERT(varchar(10), DATEADD(day, -(i%1500), GETDATE()), 101)
    WHEN i%7=0  
		THEN 'NULL'
    ELSE FORMAT(DATEADD(day, -(i%1500), GETDATE()), 'yyyy-MM-dd') 
  END,
  CASE 
	WHEN i%6=0  
		THEN '' 
    ELSE FORMAT(DATEADD(day, -(i%1490), GETDATE()), 'dd-MMM-yyyy') 
  END,
  CASE 
	WHEN i%9=0  
		THEN 'Slip/Trip' 
	WHEN i%13=0 
		THEN 'Overexertion' 
	ELSE 'Struck-By' 
  END,
  CASE 
	WHEN i%8=0  
		THEN 'Back' 
	WHEN i%10=0	
		THEN 'Shoulder' 
	ELSE 'Hand' 
  END,
  CONCAT('P', RIGHT(CONCAT('0000000', i), 7)),
  CASE 
	WHEN i%3=0  
		THEN 'wi' 
	ELSE 'IL' 
  END,
  CASE 
	WHEN i%11=0 
		THEN 'N/A' 
	ELSE CAST((ABS(CHECKSUM(NEWID()))%20000)/1.0 AS varchar(30)) 
  END,
  CASE 
	WHEN i%12=0 
		THEN '' 
	ELSE CAST((ABS(CHECKSUM(NEWID()))%12000)/1.0 AS varchar(30)) 
  END,
  CASE 
	WHEN i%14=0 
		THEN 'NULL' 
	ELSE CAST((ABS(CHECKSUM(NEWID()))%18000)/1.0 AS varchar(30)) 
  END,
  CASE 
	WHEN i%5=0  
		THEN 'open' 
	WHEN i%4=0 
		THEN 'Closed' 
	ELSE 'Litigation' 
  END,
  CONCAT('A', RIGHT(CONCAT('0000', (i%@adjuster)+1), 4))
  FROM n;

-- Introduce a wave of duplicated claims (same claim_number repeated)
INSERT staged.staged_claims
SELECT TOP (CAST(@claims*0.02 AS INT)) *  -- ~2% dupes
FROM staged.staged_claims
ORDER BY NEWID();

--Adjusters (with loose supervisor links)
;WITH n AS (
  SELECT TOP (@adjuster) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT staged.staged_adjuster(adjuster_ext_id, full_name, hire_date, office, supervisor_ext_id)
SELECT
  CONCAT('A', RIGHT(CONCAT('0000', i), 4)),
  CONCAT('Adjuster ', i),
  CASE 
	WHEN i%9=0 
		THEN '' ELSE CONVERT(varchar(10), DATEADD(day, - (i%3650), GETDATE()), 23) 
  END,
  CASE 
	WHEN i%3=0 
		THEN 'Milwaukee' 
	WHEN i%5=0 
		THEN 'Chicago' ELSE 'Madison' 
  END,
  CASE 
	WHEN i%10=0 
		THEN NULL 
	ELSE CONCAT('A', RIGHT(CONCAT('0000', NULLIF((i%50),0)), 4))   -- some missing/looping
  END
  from n;


-- Payments (typos, mixed formats, null-ish amounts, duplicate check rows) ~ 100k rows  
;WITH n AS (
  SELECT TOP (@payments) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
  FROM sys.all_objects a 
  CROSS JOIN sys.all_objects b
)
INSERT staged.staged_payments
  (payment_ext_id, claim_number, payment_date, payee_type, vendor_id, cost_type, cost_category, amount, check_number)
SELECT
  CONCAT('PMT', RIGHT(CONCAT('0000000', i), 7)),
  CONCAT('CLM', RIGHT(CONCAT('000000', (i%@claims)+1), 6)),
  CASE 
	WHEN i%5=0  
		THEN CONVERT(varchar(10), DATEADD(day, -i%850, GETDATE()), 101)
    WHEN i%7=0  THEN CONVERT(varchar(10), DATEADD(day, -i%850, GETDATE()), 23)
	ELSE FORMAT(DATEADD(day, -i%850, GETDATE()), 'dd-MMM-yyyy') 
  END,
  CASE 
	WHEN i%11=0 THEN 'Vendor' 
	ELSE 'Provider' 
  END,
  CONCAT('V', (i%3000)+1),
  CASE 
	WHEN i%13=0 THEN 'Indemnty' 
	ELSE 
		CASE 
			WHEN i%2=0 THEN 'Medical'
			ELSE 'Indemnity' 
	END 
  END,
  CASE 
	WHEN i%17=0 THEN 'Other' 
	ELSE 'Treatment' 
  END,
  CASE 
	WHEN i%19=0  THEN 'NULL' 
	ELSE CAST(ABS(CHECKSUM(NEWID()))%5000/1.0 AS varchar(30)) 
  END,
  CONCAT('CHK', (i%50000)+1)
  from n;

-- Duplicate payment rows (same date/amount/check) to simulate leakage risk
INSERT staged.staged_payments
SELECT TOP (CAST(@payments*0.01 AS INT)) *    -- ~1% intentional dupes
FROM staged.staged_payments
WHERE (ABS(CHECKSUM(NEWID()))%5)=0;


--Notes (free text with keywords for later clues)
;WITH n AS (
  SELECT TOP (@notes) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT staged.staged_notes(claim_number, note_time, author, note_text)
SELECT
  CONCAT('CLM', RIGHT(CONCAT('000000', (i%@claims)+1), 6)),
  CASE 
	WHEN i%6=0 
		THEN CONVERT(varchar(16), DATEADD(hour, -i%2000, GETDATE()), 120)  -- yyyy-mm-dd hh:mi
	ELSE CONVERT(varchar(10), DATEADD(day, -i%2000, GETDATE()), 23) 
  END,
  CONCAT('User', (i%300)+1),
  CASE
    WHEN i%40=0 
		THEN 'Potential subrogation opportunity not pursued.'
    WHEN i%33=0 
		THEN 'Late FNOL. Reported after 20 days.'
    WHEN i%27=0 
		THEN 'Duplicate billing suspected by vendor.'
    WHEN i%22=0 
		THEN 'Litigation hold. Reserve to be increased.'
    ELSE 'Routine update.'
  END
  from n;


--Quick counts
 SELECT 
	'policies' Src, 
	COUNT(*) AS 'Counts'
FROM staged.staged_policies
UNION ALL 
SELECT 
	'claims', 
	COUNT(*) 
FROM staged.staged_claims
UNION ALL 
SELECT 
	'payments', 
	COUNT(*) AS 'Counts'
FROM staged.staged_payments
UNION ALL 
SELECT 
	'adjuster', 
	COUNT(*) AS 'Counts'
FROM staged.staged_adjuster
UNION ALL 
SELECT 
	'notes', 
	COUNT(*) AS 'Counts'
FROM staged.staged_notes;

-- checking Notes table all columns & 50 Rows 
select TOP 50 *

from staged.staged_notes;




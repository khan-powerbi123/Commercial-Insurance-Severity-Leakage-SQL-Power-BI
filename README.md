Severity \& Leakage — SQL Case Study



goal

* simulate messy insurance claims data, clean it, and find risk signals:
* severity spikes by quarter (lob + state)
* reserve leakage flags
* duplicate payments 
* vendor outliers
* notes keywords (missed subrogation, late fnol, duplicate billing)
* a final risk view to rank claims



stack

sql server (t-sql). three schemas:



* staged = messy/raw
* core = cleaned/typed with keys
* mart = reporting views



data size

about 5k policies, 20k claims, 100k payments, 500 adjusters, 200k notes.



how to run



1. run sql/01\_create\_db\_and\_staging.sql
2. run sql/02\_core\_etl.sql
3. run sql/03\_quality\_checks.sql
4. run sql/04\_analysis\_clues.sql
5. run sql/05\_mart\_views.sql



sample results (csv in /results)



* clue1 severity hotspots: results/clue1\_severity\_hotspots\_top5.csv
* clue2 reserve flags: results/clue2\_reserve\_flags\_top100.csv
* clue3 duplicate payments: no rows in this dataset under same date + cost\_type + amount + check\_number
* clue4 vendor outliers (high): results/clue4\_vendor\_outliers\_high\_top50.csv
* clue6 notes flags: results/clue6\_notes\_flags\_top50.csv
* mart risk signals: results/claim\_risk\_signals\_top50.csv



screenshots (in /images)



* images/clue1\_hotspots.png
* images/clue2\_reserve\_flags.png
* images/risk\_signals\_top.png



what this shows (short)



* end-to-end pipeline: messy staging → clean core → analytics view
* real insurance ideas: reserve adequacy, duplicate spend, vendor outliers, missed subrogation, late reporting
* advanced sql: window functions, lag, recursive cte, percentile\_cont, grouping sets



folder map



* /sql → all scripts in run order
* /results → small csv samples (top rows only)
* /images → tiny screenshots (for quick viewing)
* README.md → this page

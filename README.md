# Credit and Lending Analytics

A SQL-based analysis of a consumer lending portfolio covering origination, credit risk, delinquency migration, and loss forecasting. The project is structured as five self-contained modules, each targeting a different layer of the credit lifecycle. All queries are written for PostgreSQL 14+.

---

## Dataset

The dataset spans 20,000 loan originations across 15,000 unique borrowers with full monthly payment histories from 2020 through 2024. It is split across five tables:

| Table | Rows | Description |
|---|---|---|
| `borrowers` | 15,000 | Credit profile, income, DTI, FICO range, employment, home ownership |
| `loans` | 20,000 | Origination details including grade, sub-grade, interest rate, term, purpose |
| `payments` | 567,853 | Monthly payment ledger with principal/interest split and days past due |
| `loan_performance` | 20,000 | Latest status snapshot per loan (Current, Fully Paid, Charged Off) |
| `credit_pulls` | 20,000 | Hard bureau inquiry at origination including inquiries in the past 6 months |

Loan grades run A through G with associated sub-grades (A1 to G5). Interest rates range from ~5% for Grade A to ~31% for Grade G. The portfolio contains a mix of 36 and 60 month terms across purposes including debt consolidation, credit card refinancing, home improvement, medical expenses, and small business.

---

## Schema

```
borrowers ──< loans ──< payments
                  |
                  +──< loan_performance
                  |
borrowers ──< credit_pulls
```

All foreign keys enforce referential integrity. Indexes are placed on the columns most frequently used in joins and filters: `loans.borrower_id`, `loans.issue_date`, `loans.grade`, `loan_performance(loan_id, snapshot_date)`, `payments(loan_id, payment_date)`, and `payments.days_past_due`.

To load the dataset:

```sql
psql lending_analytics -f schema.sql
psql lending_analytics -c "\copy borrowers        FROM 'data/borrowers.csv'        CSV HEADER"
psql lending_analytics -c "\copy loans            FROM 'data/loans.csv'            CSV HEADER"
psql lending_analytics -c "\copy loan_performance FROM 'data/loan_performance.csv' CSV HEADER"
psql lending_analytics -c "\copy payments         FROM 'data/payments.csv'         CSV HEADER"
psql lending_analytics -c "\copy credit_pulls     FROM 'data/credit_pulls.csv'     CSV HEADER"
```

---

## Modules

### 01 - Portfolio Overview and KPIs

Answers the first-pass questions about the book: how much has been originated, what is the weighted average coupon, what fraction has charged off, and how has volume trended over time.

- Single-row portfolio snapshot using `COUNT(*) FILTER`, weighted average rate, `PERCENTILE_CONT` for median loan size
- Grade-level risk-return table computing default rate, loss rate, realized yield, and net yield per grade
- Monthly origination trend with running cumulative totals using `SUM() OVER (ORDER BY ...)` and month-over-month growth via `LAG()`
- Loan purpose breakdown with dual `RANK()` window functions scoring each purpose simultaneously by volume and by safety

### 02 - Credit Risk Segmentation

Cuts the portfolio along borrower credit dimensions to identify which segments drive losses and how individual features relate to the default outcome.

- FICO band by DTI band default heatmap using nested `CASE WHEN` bucketing, with a z-score per cell computed via `STDDEV() OVER ()` to flag statistically elevated segments
- Points-based internal credit scorecard (0-100) assigning weighted scores across FICO, DTI, delinquency history, revolving utilization, and employment stability, then segmenting borrowers into Prime / Near-Prime / Sub-Prime / Deep Sub-Prime tiers
- Pearson correlation of six numeric features against the binary default flag using `CORR()`, with results ordered by absolute correlation strength
- State-level geographic concentration analysis with `RANK() OVER` to surface the highest-default-rate states

### 03 - Cohort and Vintage Analysis

Groups loans by origination quarter and tracks how each cohort ages. The goal is to separate underwriting quality from portfolio seasoning.

- Cumulative default curves by Months on Book (MOB), showing the marginal and running default rate for each quarterly vintage using `SUM() OVER (PARTITION BY cohort ORDER BY mob)`
- Kaplan-Meier-style survival probability by credit grade using `GENERATE_SERIES` to build a complete 1-60 month timeline, with cumulative survival computed via the log-sum identity `EXP(SUM(LN(...)))` since PostgreSQL has no native product aggregate
- Repeat borrower analysis using `ROW_NUMBER() OVER (PARTITION BY borrower_id ORDER BY issue_date)` to sequence each borrower's loans, then comparing default rates across loan sequence numbers with `LAG()`
- Cohort-level net return by origination quarter, rolling up interest income and net credit losses into a single return-on-book metric

### 04 - Roll-Rate and Delinquency Migration

Models how loans move between delinquency states from one payment period to the next. This is the standard framework for projecting near-term charge-off volumes from the current delinquency pipeline.

- A reusable view `v_payment_bucket` that classifies each payment into a DPD bucket (Current, Grace 1-15, Late 16-30, Late 31-60, Late 61-90, Late 90+) and assigns a sequential period number per loan
- Roll-rate transition matrix built by self-joining the view on `loan_id` and `period = period + 1`, counting every bucket-to-bucket transition and expressing it as a percentage of flows out of the source bucket
- Cure rate analysis using `MAX(CASE WHEN days_past_due BETWEEN ... THEN 1 END)` to flag whether each loan ever reached each DPD bucket, then joining to final status to compute cure vs. charge-off rates
- Prepayment analysis grouping fully paid loans by how early they paid off relative to their scheduled term, and calculating total foregone interest income by category
- Rolling 3-month delinquency trend using `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` to smooth the monthly 30+ DPD rate

### 05 - Loss Forecasting, Expected Credit Loss, and IRR

Applies the IFRS 9 and Basel III expected credit loss framework to the active book and approximates the internal rate of return on individual loans using Newton-Raphson iteration in chained CTEs.

- Point-in-time ECL = PD x LGD x EAD, where PD is the empirical charge-off rate by grade, LGD is the average loss net of recoveries and collection fees on charged-off loans, and EAD is the current outstanding principal on active loans
- Stress test expanding the base ECL to three macroeconomic scenarios (Base 1x, Adverse 1.5x, Severely Adverse 2.5x PD multipliers) via a `CROSS JOIN` against a scenarios CTE
- Loan-level IRR approximation using three Newton-Raphson iterations chained across CTE stages. Period 0 is the funded amount as a negative outflow; subsequent periods are actual payments received. The update rule `r_new = r - f(r) / f'(r)` is applied where `f(r)` is NPV and `f'(r)` is its first derivative with respect to the discount rate.
- Reserve adequacy analysis tracking whether a flat 5% reserve on new originations would have covered actual monthly net losses, with a cumulative running position via `SUM() OVER (ORDER BY month)`

---

## SQL Features Used

| Feature | Modules |
|---|---|
| `COUNT(*) FILTER (WHERE ...)` | 01, 02, 03, 04, 05 |
| `SUM / AVG / RANK / ROW_NUMBER OVER (...)` | 01, 02, 03, 04 |
| Running totals with `ROWS BETWEEN` | 01, 04 |
| `LAG()` for period-over-period deltas | 01, 03, 04 |
| Chained CTEs | 02, 03, 05 |
| `GENERATE_SERIES` for a complete time spine | 03 |
| `CORR()`, `STDDEV()`, `PERCENTILE_CONT()` | 01, 02 |
| Self-join for state-machine transitions | 04 |
| `CROSS JOIN` for scenario expansion | 05 |
| Newton-Raphson via chained CTEs | 05 |
| `CREATE OR REPLACE VIEW` | 04 |

---

## Requirements

- PostgreSQL 14 or later
- Any SQL client (psql, DBeaver, DataGrip, TablePlus)

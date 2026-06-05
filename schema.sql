-- Credit & Lending Analytics
-- PostgreSQL schema modeled after the Lending Club public loan dataset.
-- Run this file first, then seed_data.py to populate it.

DROP TABLE IF EXISTS payments          CASCADE;
DROP TABLE IF EXISTS loan_performance  CASCADE;
DROP TABLE IF EXISTS loans             CASCADE;
DROP TABLE IF EXISTS borrowers         CASCADE;
DROP TABLE IF EXISTS credit_pulls      CASCADE;

-- One row per borrower. Holds the credit profile that existed at the time
-- they applied. We store the FICO range (low/high) rather than a single
-- score because that is how the raw Lending Club data reports it.
CREATE TABLE borrowers (
    borrower_id         SERIAL PRIMARY KEY,
    state               CHAR(2)         NOT NULL,
    zip_code            CHAR(5)         NOT NULL,
    annual_income       NUMERIC(12,2)   NOT NULL,
    employment_length   SMALLINT,                  -- years; NULL means not reported
    home_ownership      VARCHAR(10)     NOT NULL,  -- RENT, OWN, or MORTGAGE
    fico_range_low      SMALLINT        NOT NULL,
    fico_range_high     SMALLINT        NOT NULL,
    open_accounts       SMALLINT        NOT NULL,
    total_accounts      SMALLINT        NOT NULL,
    delinq_2yrs         SMALLINT        NOT NULL DEFAULT 0,
    pub_rec             SMALLINT        NOT NULL DEFAULT 0,
    revol_util          NUMERIC(5,2),              -- revolving credit utilization as a percentage
    dti                 NUMERIC(6,2)    NOT NULL,  -- debt-to-income ratio
    member_since        DATE            NOT NULL
);

-- One row per loan origination. A borrower can have multiple loans over time,
-- which is why borrower_id is a foreign key rather than a unique key here.
-- loan_amount is the requested amount; funded_amount is what was actually disbursed
-- (usually slightly less due to investor funding mechanics on the platform).
CREATE TABLE loans (
    loan_id             SERIAL PRIMARY KEY,
    borrower_id         INT             NOT NULL REFERENCES borrowers(borrower_id),
    loan_amount         NUMERIC(10,2)   NOT NULL,
    funded_amount       NUMERIC(10,2)   NOT NULL,
    term_months         SMALLINT        NOT NULL,  -- either 36 or 60
    interest_rate       NUMERIC(5,2)    NOT NULL,  -- annualized percentage
    installment         NUMERIC(8,2)    NOT NULL,  -- fixed monthly payment
    grade               CHAR(1)         NOT NULL,  -- A through G, A being lowest risk
    sub_grade           VARCHAR(2)      NOT NULL,  -- finer breakdown, e.g. A1 through G5
    purpose             VARCHAR(30)     NOT NULL,
    issue_date          DATE            NOT NULL,
    initial_list_status VARCHAR(1)      NOT NULL DEFAULT 'w',  -- w = whole loan, f = fractional
    application_type    VARCHAR(15)     NOT NULL DEFAULT 'Individual'
);

-- One summary row per loan, updated as of the latest monthly snapshot.
-- Rather than storing a full time series here, the payments table holds the
-- granular history. This table is what most KPI queries hit first.
-- loan_status values: Current, Fully Paid, Charged Off, Late (31-120), Default, In Grace Period
CREATE TABLE loan_performance (
    perf_id             SERIAL PRIMARY KEY,
    loan_id             INT             NOT NULL REFERENCES loans(loan_id),
    snapshot_date       DATE            NOT NULL,
    loan_status         VARCHAR(25)     NOT NULL,
    out_prncp           NUMERIC(10,2)   NOT NULL,  -- remaining principal balance
    out_prncp_inv       NUMERIC(10,2)   NOT NULL,
    total_pymnt         NUMERIC(10,2)   NOT NULL DEFAULT 0,
    total_rec_prncp     NUMERIC(10,2)   NOT NULL DEFAULT 0,
    total_rec_int       NUMERIC(10,2)   NOT NULL DEFAULT 0,
    recoveries          NUMERIC(10,2)   NOT NULL DEFAULT 0,
    collection_fees     NUMERIC(10,2)   NOT NULL DEFAULT 0,
    last_payment_date   DATE,
    last_payment_amount NUMERIC(10,2),
    UNIQUE (loan_id, snapshot_date)
);

-- One row per monthly payment due date. This is the most granular table and
-- will be the largest (~600k rows for 20k loans). Queries in modules 4 and 5
-- rely on this table to reconstruct cash flows and delinquency trajectories.
-- payment_status values: On Time, Late 1-15, Late 16-30, Late 31-60, Late 61-90, Charged Off
CREATE TABLE payments (
    payment_id          SERIAL PRIMARY KEY,
    loan_id             INT             NOT NULL REFERENCES loans(loan_id),
    payment_date        DATE            NOT NULL,
    scheduled_amount    NUMERIC(8,2)    NOT NULL,
    paid_amount         NUMERIC(8,2)    NOT NULL DEFAULT 0,
    principal_portion   NUMERIC(8,2)    NOT NULL DEFAULT 0,
    interest_portion    NUMERIC(8,2)    NOT NULL DEFAULT 0,
    days_past_due       SMALLINT        NOT NULL DEFAULT 0,
    payment_status      VARCHAR(20)     NOT NULL
);

-- Captures the hard credit bureau inquiry that happens at origination.
-- Useful for studying whether the number of recent inquiries predicts default,
-- and for understanding which bureau the platform used by region.
CREATE TABLE credit_pulls (
    pull_id             SERIAL PRIMARY KEY,
    borrower_id         INT             NOT NULL REFERENCES borrowers(borrower_id),
    loan_id             INT             NOT NULL REFERENCES loans(loan_id),
    pull_date           DATE            NOT NULL,
    bureau              VARCHAR(15)     NOT NULL,  -- Equifax, TransUnion, or Experian
    fico_score          SMALLINT        NOT NULL,
    inquiries_6m        SMALLINT        NOT NULL DEFAULT 0,
    mths_since_last_delinq SMALLINT
);

-- These indexes target the join and filter patterns used most often in the
-- analysis modules. Without them, the cohort and roll-rate queries in
-- particular would do full table scans on the payments table.
CREATE INDEX idx_loans_borrower      ON loans(borrower_id);
CREATE INDEX idx_loans_issue_date    ON loans(issue_date);
CREATE INDEX idx_loans_grade         ON loans(grade);
CREATE INDEX idx_perf_loan_snapshot  ON loan_performance(loan_id, snapshot_date);
CREATE INDEX idx_perf_status         ON loan_performance(loan_status);
CREATE INDEX idx_payments_loan_date  ON payments(loan_id, payment_date);
CREATE INDEX idx_payments_dpd        ON payments(days_past_due);
CREATE INDEX idx_credit_pulls_borr   ON credit_pulls(borrower_id);

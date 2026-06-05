-- Module 3: Cohort and Vintage Analysis

-- 3.1 Vintage cohort default curve
-- For each quarterly cohort, shows the cumulative percentage of loans that
-- have charged off by each month on book (MOB). Plotting these curves side
-- by side lets us see whether recent cohorts are performing better or worse
-- than older ones at the same age. The running SUM window function is what
-- converts the per-month default count into a cumulative curve.

WITH cohort_loans AS (
    SELECT
        l.loan_id,
        l.funded_amount,
        DATE_TRUNC('quarter', l.issue_date)::DATE    AS cohort_qtr,
        lp.loan_status,
        lp.last_payment_date,
        l.issue_date,
        -- How many months did the loan perform before it defaulted?
        -- For non-defaulted loans this is NULL, which gets filtered out below.
        CASE
            WHEN lp.loan_status = 'Charged Off' AND lp.last_payment_date IS NOT NULL
            THEN (EXTRACT(YEAR  FROM AGE(lp.last_payment_date, l.issue_date)) * 12
                + EXTRACT(MONTH FROM AGE(lp.last_payment_date, l.issue_date)))::INT
        END AS months_to_default
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
),
cohort_sizes AS (
    SELECT cohort_qtr, COUNT(*) AS cohort_size, SUM(funded_amount) AS cohort_volume
    FROM cohort_loans
    GROUP BY cohort_qtr
),
default_by_month AS (
    SELECT
        cohort_qtr,
        months_to_default AS mob,
        COUNT(*) AS defaults_at_mob
    FROM cohort_loans
    WHERE loan_status = 'Charged Off' AND months_to_default IS NOT NULL
    GROUP BY cohort_qtr, months_to_default
)
SELECT
    d.cohort_qtr,
    cs.cohort_size,
    d.mob,
    d.defaults_at_mob,
    SUM(d.defaults_at_mob)
        OVER (PARTITION BY d.cohort_qtr ORDER BY d.mob)          AS cum_defaults,
    ROUND(
        SUM(d.defaults_at_mob)
            OVER (PARTITION BY d.cohort_qtr ORDER BY d.mob)::NUMERIC
        / cs.cohort_size * 100, 3
    )                                                             AS cum_default_rate_pct,
    -- Marginal rate: how many new defaults happened just this month?
    ROUND(d.defaults_at_mob::NUMERIC / cs.cohort_size * 100, 3)  AS marginal_default_rate_pct
FROM default_by_month d
JOIN cohort_sizes      cs ON cs.cohort_qtr = d.cohort_qtr
ORDER BY d.cohort_qtr, d.mob;


-- 3.2 Survival probability by grade
-- A Kaplan-Meier-style estimate of the probability that a loan survives
-- (does not default) to each month on book, broken down by credit grade.
-- KM survival is defined as the running product of (1 - hazard rate at each step).
-- PostgreSQL has no built-in product aggregate, so we use the log-sum trick:
-- PRODUCT(x) = EXP(SUM(LN(x))). The GREATEST(..., 0.0001) prevents LN(0).
-- GENERATE_SERIES creates a row for every month from 1 to 60 so we have a
-- complete timeline even for months with no events.

WITH loan_events AS (
    SELECT
        l.loan_id,
        l.grade,
        CASE WHEN lp.loan_status = 'Charged Off' THEN 1 ELSE 0 END AS defaulted,
        CASE
            WHEN lp.loan_status = 'Charged Off' AND lp.last_payment_date IS NOT NULL
            THEN (EXTRACT(YEAR  FROM AGE(lp.last_payment_date, l.issue_date)) * 12
                + EXTRACT(MONTH FROM AGE(lp.last_payment_date, l.issue_date)))::INT
            ELSE l.term_months
        END AS observed_months
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
),
mob_range AS (
    SELECT generate_series(1, 60) AS mob
),
at_risk AS (
    SELECT
        m.mob,
        le.grade,
        COUNT(*) FILTER (WHERE le.observed_months >= m.mob)           AS at_risk_count,
        COUNT(*) FILTER (WHERE le.observed_months = m.mob
                           AND le.defaulted = 1)                      AS events_this_mob
    FROM mob_range m
    CROSS JOIN loan_events le
    GROUP BY m.mob, le.grade
)
SELECT
    mob,
    grade,
    at_risk_count,
    events_this_mob,
    ROUND(1 - events_this_mob::NUMERIC / NULLIF(at_risk_count, 0), 6) AS survival_prob_this_mob,
    ROUND(
        EXP(SUM(LN(GREATEST(
            1 - events_this_mob::NUMERIC / NULLIF(at_risk_count, 0),
            0.0001
        ))) OVER (PARTITION BY grade ORDER BY mob)) , 4
    )                                                                  AS cum_survival_prob
FROM at_risk
WHERE at_risk_count > 10   -- drop months where only a handful of loans remain
ORDER BY grade, mob;


-- 3.3 Repeat borrower analysis
-- Do borrowers who come back for a second or third loan behave differently
-- than first-time borrowers? If repeat borrowers default less, it suggests
-- that the platform has learned something useful about them from their first loan.
-- ROW_NUMBER() assigns a sequence number to each loan per borrower sorted by date.
-- LAG() then computes how the default rate changes from one loan number to the next.

WITH loan_sequence AS (
    SELECT
        l.loan_id,
        l.borrower_id,
        l.issue_date,
        l.funded_amount,
        l.grade,
        lp.loan_status,
        ROW_NUMBER() OVER (PARTITION BY l.borrower_id ORDER BY l.issue_date) AS loan_seq,
        COUNT(*) OVER (PARTITION BY l.borrower_id)                           AS total_loans
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
)
SELECT
    loan_seq,
    COUNT(*)                                                          AS loan_count,
    COUNT(DISTINCT borrower_id)                                       AS unique_borrowers,
    ROUND(AVG(funded_amount), 0)                                      AS avg_loan_size,
    ROUND(
        COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) * 100, 2
    )                                                                 AS default_rate_pct,
    -- Positive delta means default rate went up on the nth loan vs. the (n-1)th
    ROUND(
        (COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC / COUNT(*)
         - LAG(COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC / COUNT(*))
             OVER (ORDER BY loan_seq)
        ) * 100, 2
    )                                                                 AS default_rate_delta_pct
FROM loan_sequence
WHERE loan_seq <= 5
GROUP BY loan_seq
ORDER BY loan_seq;


-- 3.4 Cohort-level net return by origination quarter
-- Rolls up interest income and credit losses by the quarter loans were issued.
-- This is useful for identifying whether the platform's underwriting improved
-- or deteriorated over time. A cohort with high interest income but also
-- high net credit losses may end up with a worse net return than a safer cohort
-- that had a lower coupon to begin with.

SELECT
    DATE_TRUNC('quarter', l.issue_date)::DATE                    AS issue_qtr,
    COUNT(*)                                                      AS loans,
    ROUND(SUM(l.funded_amount) / 1e6, 2)                         AS funded_M,
    ROUND(SUM(lp.total_rec_int) / 1e6, 2)                        AS interest_income_M,
    ROUND(
        SUM(l.funded_amount - lp.total_rec_prncp - lp.out_prncp
            + lp.recoveries - lp.collection_fees)
        FILTER (WHERE lp.loan_status = 'Charged Off') / 1e6, 2
    )                                                             AS net_credit_loss_M,
    ROUND(
        (SUM(lp.total_rec_int)
         + COALESCE(SUM(l.funded_amount - lp.total_rec_prncp - lp.out_prncp
             + lp.recoveries - lp.collection_fees)
             FILTER (WHERE lp.loan_status = 'Charged Off'), 0)
        ) / NULLIF(SUM(l.funded_amount), 0) * 100, 2
    )                                                             AS net_return_pct
FROM loans l
JOIN loan_performance lp ON lp.loan_id = l.loan_id
GROUP BY DATE_TRUNC('quarter', l.issue_date)
ORDER BY issue_qtr;

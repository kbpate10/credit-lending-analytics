-- Module 4: Roll-Rate and Delinquency Migration Analysis

-- 4.1 Payment bucket view
-- The period column is critical for the roll-rate matrix: it lets us join a row to the "next month" row by
-- incrementing period by 1.

CREATE OR REPLACE VIEW v_payment_bucket AS
SELECT
    p.payment_id,
    p.loan_id,
    p.payment_date,
    p.days_past_due,
    p.payment_status,
    p.paid_amount,
    p.scheduled_amount,
    CASE
        WHEN p.days_past_due =  0                THEN 'Current'
        WHEN p.days_past_due BETWEEN  1 AND 15   THEN 'Grace (1-15)'
        WHEN p.days_past_due BETWEEN 16 AND 30   THEN 'Late 16-30'
        WHEN p.days_past_due BETWEEN 31 AND 60   THEN 'Late 31-60'
        WHEN p.days_past_due BETWEEN 61 AND 90   THEN 'Late 61-90'
        ELSE                                          'Late 90+'
    END AS dpd_bucket,
    ROW_NUMBER() OVER (PARTITION BY p.loan_id ORDER BY p.payment_date) AS period
FROM payments p;


-- 4.2 Roll-rate transition matrix
-- For every loan, joins each payment period to the following one and counts
-- how often each bucket-to-bucket transition occurs. Reading across a row tells
-- you where loans in that bucket tend to go next: back to Current (cure) or
-- forward into deeper delinquency (roll). High roll rates from 60 DPD to
-- Charged Off are normal; high roll rates from Current to 30 DPD are a warning sign.
-- The self-join on (loan_id, period = period + 1) is what makes this work
-- without a correlated subquery.

WITH transitions AS (
    SELECT
        a.dpd_bucket  AS from_bucket,
        b.dpd_bucket  AS to_bucket,
        COUNT(*)      AS transitions
    FROM v_payment_bucket a
    JOIN v_payment_bucket b
      ON  b.loan_id = a.loan_id
      AND b.period  = a.period + 1
    GROUP BY a.dpd_bucket, b.dpd_bucket
),
from_totals AS (
    SELECT from_bucket, SUM(transitions) AS total_from
    FROM transitions
    GROUP BY from_bucket
)
SELECT
    t.from_bucket,
    t.to_bucket,
    t.transitions,
    ROUND(t.transitions::NUMERIC / ft.total_from * 100, 2) AS transition_rate_pct
FROM transitions    t
JOIN from_totals   ft ON ft.from_bucket = t.from_bucket
ORDER BY
    CASE t.from_bucket
        WHEN 'Current'     THEN 1 WHEN 'Grace (1-15)' THEN 2
        WHEN 'Late 16-30'  THEN 3 WHEN 'Late 31-60'   THEN 4
        WHEN 'Late 61-90'  THEN 5 ELSE 6 END,
    CASE t.to_bucket
        WHEN 'Current'     THEN 1 WHEN 'Grace (1-15)' THEN 2
        WHEN 'Late 16-30'  THEN 3 WHEN 'Late 31-60'   THEN 4
        WHEN 'Late 61-90'  THEN 5 ELSE 6 END;


-- 4.3 Cure rate by delinquency severity
-- Of all loans that ever touched each delinquency bucket, what fraction
-- eventually recovered versus charged off? This tells us how much credit
-- to give to borrowers who miss a payment but then catch up. A 30 DPD cure
-- rate above 70% is healthy; anything below 50% suggests the delinquency
-- pipeline is feeding a large charge-off wave. We use MAX(CASE...) to flag
-- whether a loan ever reached each bucket without creating multiple rows per loan.

WITH ever_delinquent AS (
    SELECT
        p.loan_id,
        MAX(p.days_past_due)                   AS max_dpd,
        MAX(CASE
            WHEN p.days_past_due BETWEEN  1 AND 30 THEN 1 ELSE 0 END) AS ever_30,
        MAX(CASE
            WHEN p.days_past_due BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS ever_60,
        MAX(CASE
            WHEN p.days_past_due BETWEEN 61 AND 90 THEN 1 ELSE 0 END) AS ever_90,
        MAX(CASE
            WHEN p.days_past_due > 90              THEN 1 ELSE 0 END) AS ever_90plus
    FROM payments p
    GROUP BY p.loan_id
)
SELECT
    bucket,
    loan_count,
    charged_off,
    loan_count - charged_off                                          AS cured,
    ROUND((loan_count - charged_off)::NUMERIC / loan_count * 100, 2) AS cure_rate_pct,
    ROUND(charged_off::NUMERIC / loan_count * 100, 2)                AS charge_off_rate_pct
FROM (
    SELECT '30 DPD' AS bucket, COUNT(*) AS loan_count,
           COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off') AS charged_off
    FROM ever_delinquent ed
    JOIN loan_performance lp ON lp.loan_id = ed.loan_id
    WHERE ed.ever_30 = 1

    UNION ALL

    SELECT '60 DPD', COUNT(*),
           COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')
    FROM ever_delinquent ed JOIN loan_performance lp ON lp.loan_id = ed.loan_id
    WHERE ed.ever_60 = 1

    UNION ALL

    SELECT '90 DPD', COUNT(*),
           COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')
    FROM ever_delinquent ed JOIN loan_performance lp ON lp.loan_id = ed.loan_id
    WHERE ed.ever_90 = 1

    UNION ALL

    SELECT '90+ DPD', COUNT(*),
           COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')
    FROM ever_delinquent ed JOIN loan_performance lp ON lp.loan_id = ed.loan_id
    WHERE ed.ever_90plus = 1
) x
ORDER BY bucket;


-- 4.4 Prepayment analysis
-- Loans that pay off before their scheduled end date are good for the borrower
-- but reduce interest income for the lender. This query groups fully paid loans
-- by how early they paid off and calculates how much interest income the portfolio
-- lost as a result. High prepayment rates on high-grade loans suggest borrowers
-- are refinancing elsewhere at lower rates, which is an adverse selection signal.

WITH loan_duration AS (
    SELECT
        l.loan_id,
        l.borrower_id,
        l.grade,
        l.term_months,
        l.funded_amount,
        l.interest_rate,
        lp.loan_status,
        lp.total_rec_int,
        -- Actual months active: how long did the loan actually run?
        COALESCE(
            (EXTRACT(YEAR  FROM AGE(lp.last_payment_date, l.issue_date)) * 12
           + EXTRACT(MONTH FROM AGE(lp.last_payment_date, l.issue_date)))::INT,
            l.term_months
        ) AS actual_months,
        -- Total installments minus principal approximates full-term interest
        l.installment * l.term_months - l.funded_amount AS expected_interest,
        lp.total_rec_int                                AS actual_interest
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
    WHERE lp.loan_status = 'Fully Paid'
)
SELECT
    CASE
        WHEN actual_months::NUMERIC / term_months < 0.5  THEN 'Very Early (<50% term)'
        WHEN actual_months::NUMERIC / term_months < 0.75 THEN 'Early (50-75%)'
        WHEN actual_months::NUMERIC / term_months < 0.90 THEN 'Near Full (75-90%)'
        ELSE                                                  'Full Term (90%+)'
    END                                                          AS payoff_category,
    COUNT(*)                                                     AS loans,
    ROUND(AVG(funded_amount), 0)                                 AS avg_loan_size,
    ROUND(AVG(interest_rate), 2)                                 AS avg_rate,
    ROUND(AVG(actual_months), 1)                                 AS avg_months_active,
    ROUND(AVG(actual_interest), 0)                               AS avg_interest_collected,
    ROUND(AVG(expected_interest), 0)                             AS avg_expected_interest,
    -- Total foregone interest across all loans in this category
    ROUND(SUM(expected_interest - actual_interest) / 1e6, 2)    AS foregone_interest_M
FROM loan_duration
GROUP BY payoff_category
ORDER BY avg_months_active;


-- 4.5 Rolling 3-month delinquency trend
-- Tracks the 30+ DPD rate across all payment periods month by month.
-- ROWS BETWEEN 2 PRECEDING AND CURRENT ROW tells the window function
-- to average only the current row and the two rows before it, giving a
-- 3-month rolling average. LAG gives the month-over-month change.

WITH monthly_payments AS (
    SELECT
        DATE_TRUNC('month', payment_date)::DATE                  AS pay_month,
        COUNT(*)                                                  AS total_pmts,
        COUNT(*) FILTER (WHERE days_past_due >= 30)               AS late_30plus
    FROM payments
    GROUP BY DATE_TRUNC('month', payment_date)
)
SELECT
    pay_month,
    total_pmts,
    late_30plus,
    ROUND(late_30plus::NUMERIC / total_pmts * 100, 2)            AS delinq_rate_pct,
    -- The rolling average smooths out month-to-month noise
    ROUND(
        AVG(late_30plus::NUMERIC / total_pmts * 100)
            OVER (ORDER BY pay_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2
    )                                                            AS rolling_3m_delinq_pct,
    ROUND(
        late_30plus::NUMERIC / total_pmts * 100
        - LAG(late_30plus::NUMERIC / total_pmts * 100)
              OVER (ORDER BY pay_month), 2
    )                                                            AS mom_change_pct
FROM monthly_payments
ORDER BY pay_month;

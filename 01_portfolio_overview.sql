-- Module 1: Portfolio Overview and KPIs
-- Start here to get a feel for the overall health of the book before
-- drilling into risk or performance. These queries answer the questions
-- a credit portfolio manager would ask on a Monday morning.


-- 1.1 Snapshot KPIs
-- A single-row summary of the entire portfolio as of the latest snapshot.
-- We weight the average interest rate by funded amount (not loan count)
-- because a $40k loan contributes more to portfolio yield than a $5k loan.
-- PERCENTILE_CONT gives the median loan size without needing a subquery.

SELECT
    COUNT(*)                                                AS total_loans,
    COUNT(*) FILTER (WHERE lp.loan_status = 'Current')     AS active_loans,
    COUNT(*) FILTER (WHERE lp.loan_status = 'Fully Paid')  AS paid_off,
    COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off') AS charged_off,

    ROUND(SUM(l.funded_amount) / 1e6, 2)                   AS total_funded_M,
    ROUND(SUM(lp.out_prncp)    / 1e6, 2)                   AS outstanding_balance_M,
    ROUND(SUM(lp.total_pymnt)  / 1e6, 2)                   AS total_collected_M,
    ROUND(SUM(lp.recoveries)   / 1e6, 2)                   AS recoveries_M,

    ROUND(
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) * 100, 2
    )                                                       AS charge_off_rate_pct,

    -- Weighted average coupon: larger loans should have more influence on this figure
    ROUND(
        SUM(l.interest_rate * l.funded_amount) / SUM(l.funded_amount), 2
    )                                                       AS wa_interest_rate,

    -- Portfolio yield: total interest actually collected divided by total funded.
    -- This will be lower than the contractual rate because of early payoffs and defaults.
    ROUND(
        SUM(lp.total_rec_int) / NULLIF(SUM(l.funded_amount), 0) * 100, 2
    )                                                       AS portfolio_yield_pct,

    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY l.loan_amount) AS median_loan_amount

FROM loans          l
JOIN loan_performance lp ON lp.loan_id = l.loan_id;


-- 1.2 Grade-level risk-return breakdown
-- The most important question in lending: are higher-grade borrowers actually
-- less risky, and does the higher interest rate on lower grades compensate for
-- those losses? Net yield = realized interest income minus credit losses.
-- We use a CTE here to compute expensive aggregates once and reuse them.

WITH grade_stats AS (
    SELECT
        l.grade,
        COUNT(*)                                                   AS loan_count,
        SUM(l.funded_amount)                                       AS funded,
        SUM(lp.total_rec_int)                                      AS int_received,
        SUM(lp.out_prncp)                                          AS outstanding,
        SUM(l.funded_amount - lp.total_rec_prncp - lp.out_prncp
            + lp.recoveries) FILTER (WHERE lp.loan_status = 'Charged Off')
                                                                   AS net_loss,
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')     AS defaults,
        AVG(l.interest_rate)                                       AS avg_rate,
        AVG(b.dti)                                                 AS avg_dti,
        AVG((b.fico_range_low + b.fico_range_high) / 2.0)         AS avg_fico
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id   = l.loan_id
    JOIN borrowers        b  ON b.borrower_id = l.borrower_id
    GROUP BY l.grade
)
SELECT
    grade,
    loan_count,
    ROUND(funded / 1e6, 2)                                AS funded_M,
    ROUND(avg_rate, 2)                                    AS avg_interest_rate,
    ROUND(avg_fico)                                       AS avg_fico,
    ROUND(avg_dti, 1)                                     AS avg_dti,
    ROUND(defaults::NUMERIC / loan_count * 100, 2)        AS default_rate_pct,
    ROUND(net_loss  / NULLIF(funded, 0) * 100, 2)         AS loss_rate_pct,
    ROUND(int_received / NULLIF(funded, 0) * 100, 2)      AS realized_yield_pct,
    -- Net yield: this is what the platform actually earns after losses.
    -- A negative number means the grade is losing money in aggregate.
    ROUND(
        int_received / NULLIF(funded, 0) * 100
        - net_loss   / NULLIF(funded, 0) * 100, 2
    )                                                     AS net_yield_pct
FROM grade_stats
ORDER BY grade;


-- 1.3 Monthly origination trend with running totals
-- Tracks portfolio growth over time. The window function SUM(...) OVER (ORDER BY ...)
-- computes a cumulative total without a self-join, which would be much slower.
-- LAG lets us compute the month-over-month growth rate by looking at the previous row.

SELECT
    DATE_TRUNC('month', l.issue_date)::DATE                AS month,
    COUNT(*)                                               AS loans_originated,
    ROUND(SUM(l.funded_amount) / 1e6, 2)                   AS volume_M,
    ROUND(AVG(l.interest_rate), 2)                         AS avg_rate,
    ROUND(AVG(l.loan_amount), 0)                           AS avg_loan_size,

    -- Running total: how large has the book grown in aggregate?
    SUM(COUNT(*))
        OVER (ORDER BY DATE_TRUNC('month', l.issue_date))  AS cumulative_loans,
    ROUND(
        SUM(SUM(l.funded_amount))
            OVER (ORDER BY DATE_TRUNC('month', l.issue_date)) / 1e6, 2
    )                                                      AS cumulative_volume_M,

    -- Month-over-month growth: positive means the platform is accelerating originations
    ROUND(
        (SUM(l.funded_amount)
         - LAG(SUM(l.funded_amount))
             OVER (ORDER BY DATE_TRUNC('month', l.issue_date)))
        / NULLIF(LAG(SUM(l.funded_amount))
             OVER (ORDER BY DATE_TRUNC('month', l.issue_date)), 0) * 100, 1
    )                                                      AS mom_volume_growth_pct

FROM loans l
GROUP BY DATE_TRUNC('month', l.issue_date)
ORDER BY month;


-- 1.4 Purpose-level profitability
-- Not all loan purposes carry the same risk. Debt consolidation is the most
-- common purpose but is it also the riskiest? We use two separate RANK()
-- window functions to score each purpose by volume and by safety independently,
-- so we can see where those two rankings diverge.

SELECT
    l.purpose,
    COUNT(*)                                               AS loan_count,
    ROUND(AVG(l.loan_amount), 0)                           AS avg_amount,
    ROUND(AVG(l.interest_rate), 2)                         AS avg_rate,
    ROUND(
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) * 100, 2
    )                                                      AS default_rate_pct,
    ROUND(AVG(b.dti), 1)                                   AS avg_dti,
    RANK() OVER (ORDER BY COUNT(*) DESC)                   AS volume_rank,
    -- Rank 1 here means the lowest default rate (safest purpose)
    RANK() OVER (ORDER BY
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) ASC
    )                                                      AS safest_rank
FROM loans l
JOIN loan_performance lp ON lp.loan_id   = l.loan_id
JOIN borrowers        b  ON b.borrower_id = l.borrower_id
GROUP BY l.purpose
ORDER BY loan_count DESC;

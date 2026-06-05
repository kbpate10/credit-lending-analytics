-- Module 5: Loss Forecasting, Expected Credit Loss, and IRR
-- These queries sit at the intersection of credit risk and finance.
-- ECL (query 5.1-5.2) is the regulatory framework banks use to set aside
-- reserves. IRR (query 5.3) answers the investor question: given the actual
-- cash flows that happened, what return did this loan actually deliver?


-- 5.1 Expected Credit Loss per grade (IFRS 9 / Basel III framework)
-- ECL = PD x LGD x EAD, where:
--   PD  = probability of default (estimated from historical charge-off rates)
--   LGD = loss given default = fraction of the balance not recovered after charge-off
--   EAD = exposure at default = outstanding principal on the current active book
-- This gives the amount the lender should hold in reserve against future losses.
-- We compute PD and LGD from historical data, then apply them to the live book.

WITH historical_pd AS (
    SELECT
        l.grade,
        COUNT(*)                                                   AS loan_count,
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')     AS defaults,
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
            / COUNT(*)                                             AS pd
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
    GROUP BY l.grade
),
historical_lgd AS (
    SELECT
        l.grade,
        -- LGD = 1 minus the net recovery rate.
        -- Net recoveries = gross recoveries minus collection agency fees.
        AVG(
            GREATEST(
                1 - (lp.recoveries - lp.collection_fees)
                    / NULLIF(lp.out_prncp + lp.total_rec_prncp - lp.recoveries, 0),
                0
            )
        )                                                          AS lgd
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
    WHERE lp.loan_status = 'Charged Off'
    GROUP BY l.grade
),
active_portfolio AS (
    SELECT
        l.loan_id,
        l.grade,
        lp.out_prncp                                               AS ead
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
    WHERE lp.loan_status = 'Current'
)
SELECT
    ap.grade,
    COUNT(ap.loan_id)                                              AS active_loans,
    ROUND(SUM(ap.ead) / 1e6, 2)                                   AS total_ead_M,
    ROUND(hp.pd * 100, 2)                                         AS pd_pct,
    ROUND(hl.lgd * 100, 2)                                        AS lgd_pct,
    ROUND(SUM(ap.ead) * hp.pd * hl.lgd / 1e6, 3)                  AS ecl_M,
    -- Coverage ratio: what fraction of the outstanding balance does the ECL represent?
    ROUND(hp.pd * hl.lgd * 100, 3)                                AS ecl_coverage_pct
FROM active_portfolio   ap
JOIN historical_pd      hp ON hp.grade = ap.grade
JOIN historical_lgd     hl ON hl.grade = ap.grade
GROUP BY ap.grade, hp.pd, hl.lgd
ORDER BY ap.grade;


-- 5.2 Stress test under three macroeconomic scenarios
-- Regulators require banks to show how their loss reserves would change under
-- adverse conditions. We model this by multiplying the base PD by a stress
-- multiplier: 1.5x for "Adverse" (mild recession) and 2.5x for "Severely Adverse"
-- (severe recession, similar to the 2008 financial crisis scenario).
-- CROSS JOIN expands each grade row into three scenario rows cleanly.

WITH base_ecl AS (
    SELECT
        l.grade,
        SUM(lp.out_prncp)                                          AS ead,
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
            / COUNT(*)                                             AS base_pd,
        AVG(GREATEST(
            1 - (lp.recoveries - lp.collection_fees)
                / NULLIF(lp.out_prncp + lp.total_rec_prncp - lp.recoveries, 0), 0
        )) FILTER (WHERE lp.loan_status = 'Charged Off')           AS lgd
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
    GROUP BY l.grade
),
scenarios AS (
    SELECT 'Base'            AS scenario, 1.0  AS pd_mult UNION ALL
    SELECT 'Adverse',                     1.5  UNION ALL
    SELECT 'Severely Adverse',            2.5
)
SELECT
    s.scenario,
    b.grade,
    ROUND(b.ead / 1e6, 2)                                         AS ead_M,
    ROUND(b.base_pd * s.pd_mult * 100, 2)                         AS stressed_pd_pct,
    ROUND(b.lgd * 100, 2)                                         AS lgd_pct,
    ROUND(b.ead * b.base_pd * s.pd_mult * b.lgd / 1e6, 3)        AS ecl_M
FROM base_ecl b
CROSS JOIN scenarios s
ORDER BY s.scenario, b.grade;


-- 5.3 Loan-level IRR approximation via Newton-Raphson
-- IRR is the discount rate that makes the net present value of all cash flows
-- equal to zero. For a loan, that means the rate at which the present value of
-- all actual payments received exactly offsets the initial principal disbursed.
-- When a loan defaults early, its IRR will be below the contractual rate.
-- When a loan prepays, its IRR may be close to or above the contractual rate.
--
-- We cannot use a recursive CTE with aggregates in PostgreSQL, so we implement
-- three Newton-Raphson iterations by chaining three sets of CTEs manually.
-- Newton's method updates the guess using: r_new = r - f(r) / f'(r), where
-- f(r) is the NPV at rate r and f'(r) is its derivative with respect to r.
-- Three iterations starting from the contractual rate as the initial guess
-- is usually enough to converge to within a few basis points.
-- Period 0 is the initial cash outflow (negative funded amount).

WITH loan_cf AS (
    SELECT
        p.loan_id,
        0                AS period,
        -l.funded_amount AS cash_flow
    FROM payments p
    JOIN loans    l ON l.loan_id = p.loan_id
    GROUP BY p.loan_id, l.funded_amount

    UNION ALL

    SELECT
        p.loan_id,
        ROW_NUMBER() OVER (PARTITION BY p.loan_id ORDER BY p.payment_date) AS period,
        p.paid_amount
    FROM payments p
),
irr_seed AS (
    SELECT
        l.loan_id,
        l.interest_rate / 100.0 / 12.0  AS r
    FROM loans l
    WHERE EXISTS (SELECT 1 FROM payments p WHERE p.loan_id = l.loan_id)
),
npv_at_r AS (
    SELECT
        cf.loan_id,
        s.r,
        SUM(cf.cash_flow / POWER(1 + s.r, cf.period))                    AS npv,
        SUM(-cf.period * cf.cash_flow / POWER(1 + s.r, cf.period + 1))   AS dnpv
    FROM loan_cf cf
    JOIN irr_seed s ON s.loan_id = cf.loan_id
    GROUP BY cf.loan_id, s.r
),
irr_step1 AS (
    SELECT loan_id, r - npv / NULLIF(dnpv, 0) AS r FROM npv_at_r
),
npv2 AS (
    SELECT cf.loan_id, s.r,
           SUM(cf.cash_flow / POWER(1+s.r, cf.period)) AS npv,
           SUM(-cf.period*cf.cash_flow / POWER(1+s.r, cf.period+1)) AS dnpv
    FROM loan_cf cf JOIN irr_step1 s ON s.loan_id=cf.loan_id
    GROUP BY cf.loan_id, s.r
),
irr_step2 AS (SELECT loan_id, r - npv/NULLIF(dnpv,0) AS r FROM npv2),
npv3 AS (
    SELECT cf.loan_id, s.r,
           SUM(cf.cash_flow / POWER(1+s.r, cf.period)) AS npv
    FROM loan_cf cf JOIN irr_step2 s ON s.loan_id=cf.loan_id
    GROUP BY cf.loan_id, s.r
)
SELECT
    npv3.loan_id,
    l.grade,
    l.funded_amount,
    l.interest_rate                                               AS contractual_rate_pct,
    ROUND(npv3.r * 12 * 100, 2)                                  AS irr_annual_pct,
    -- Positive spread means the loan delivered more than its contractual rate (rare).
    -- Negative spread means default or prepayment reduced the actual return.
    ROUND((npv3.r * 12 - l.interest_rate / 100.0) * 100, 2)     AS irr_spread_pct,
    lp.loan_status
FROM npv3
JOIN loans            l  ON l.loan_id  = npv3.loan_id
JOIN loan_performance lp ON lp.loan_id = npv3.loan_id
WHERE ABS(npv3.r) < 1   -- Newton can diverge if the cash flows are unusual; filter those out
LIMIT 500;


-- 5.4 Reserve adequacy: did we set aside enough?
-- Compares actual charge-off losses each month against a simple 5% reserve
-- set aside on new originations. The cumulative reserve buffer shows whether
-- the reserve methodology would have kept the platform solvent or run short.
-- A negative cumulative buffer at any point means historical reserves were
-- insufficient and the methodology would need to be revised upward.

WITH monthly_charge_offs AS (
    SELECT
        DATE_TRUNC('month', lp.last_payment_date)::DATE             AS co_month,
        SUM(l.funded_amount - lp.total_rec_prncp - lp.out_prncp
            + lp.recoveries - lp.collection_fees)                   AS net_loss
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id = l.loan_id
    WHERE lp.loan_status = 'Charged Off'
      AND lp.last_payment_date IS NOT NULL
    GROUP BY DATE_TRUNC('month', lp.last_payment_date)
),
monthly_originations AS (
    SELECT
        DATE_TRUNC('month', issue_date)::DATE                       AS orig_month,
        SUM(funded_amount)                                          AS volume
    FROM loans
    GROUP BY DATE_TRUNC('month', issue_date)
)
SELECT
    COALESCE(co.co_month, mo.orig_month)                           AS month,
    ROUND(mo.volume / 1e6, 2)                                      AS origination_M,
    ROUND(co.net_loss / 1e6, 2)                                    AS net_loss_M,
    ROUND(mo.volume * 0.05 / 1e6, 2)                               AS reserved_M,
    ROUND((mo.volume * 0.05 - co.net_loss) / 1e6, 2)              AS reserve_surplus_M,
    -- Running total shows the cumulative position over the life of the portfolio
    ROUND(
        SUM(mo.volume * 0.05 - COALESCE(co.net_loss, 0))
            OVER (ORDER BY COALESCE(co.co_month, mo.orig_month)) / 1e6, 2
    )                                                              AS cum_reserve_buffer_M
FROM monthly_originations mo
LEFT JOIN monthly_charge_offs co ON co.co_month = mo.orig_month
ORDER BY month;

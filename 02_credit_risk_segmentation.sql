-- Module 2: Credit Risk Segmentation
-- These queries cut the portfolio along credit dimensions to understand
-- which borrower profiles drive losses. The scorecard in query 2.2 is
-- a simplified version of what a real underwriting model produces.


-- 2.1 FICO band by DTI band default heatmap
-- Two of the strongest predictors of default are FICO score and debt-to-income
-- ratio. This query builds a grid showing the default rate at every intersection
-- of those two dimensions, which helps identify where the safe and risky pockets
-- of the portfolio sit. The z-score at the end standardizes each cell's default
-- rate relative to the overall average, so it is easy to spot outliers.

WITH scored AS (
    SELECT
        l.loan_id,
        lp.loan_status,
        CASE
            WHEN (b.fico_range_low + b.fico_range_high)/2 < 620  THEN '1_Below620'
            WHEN (b.fico_range_low + b.fico_range_high)/2 < 660  THEN '2_620-659'
            WHEN (b.fico_range_low + b.fico_range_high)/2 < 700  THEN '3_660-699'
            WHEN (b.fico_range_low + b.fico_range_high)/2 < 740  THEN '4_700-739'
            WHEN (b.fico_range_low + b.fico_range_high)/2 < 780  THEN '5_740-779'
            ELSE                                                       '6_780+'
        END AS fico_band,
        CASE
            WHEN b.dti < 10  THEN '1_Low(<10)'
            WHEN b.dti < 20  THEN '2_Mod(10-20)'
            WHEN b.dti < 30  THEN '3_High(20-30)'
            WHEN b.dti < 40  THEN '4_VHigh(30-40)'
            ELSE                  '5_Danger(40+)'
        END AS dti_band
    FROM loans l
    JOIN loan_performance lp ON lp.loan_id   = l.loan_id
    JOIN borrowers        b  ON b.borrower_id = l.borrower_id
)
SELECT
    fico_band,
    dti_band,
    COUNT(*)                                                   AS loan_count,
    ROUND(
        COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) * 100, 2
    )                                                          AS default_rate_pct,
    -- How many standard deviations above or below the mean is this cell?
    -- A z-score above 2 flags a segment that is meaningfully riskier than average.
    ROUND(
        (COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC / COUNT(*)
         - AVG(
               COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC / COUNT(*)
           ) OVER ()
        ) / NULLIF(
               STDDEV(
                   COUNT(*) FILTER (WHERE loan_status = 'Charged Off')::NUMERIC / COUNT(*)
               ) OVER (), 0), 2
    )                                                          AS default_z_score
FROM scored
GROUP BY fico_band, dti_band
ORDER BY fico_band, dti_band;


-- 2.2 Internal credit scorecard
-- A points-based model that converts five borrower attributes into a 0-100
-- score. This is how traditional lenders built underwriting criteria before
-- machine learning models. FICO gets the most weight (40 pts) because it is
-- the most predictive single variable. The tier cutoffs (Prime, Near-Prime,
-- Sub-Prime) match standard industry definitions.

WITH scorecard AS (
    SELECT
        b.borrower_id,
        b.fico_range_low,
        b.fico_range_high,
        b.dti,
        b.delinq_2yrs,
        b.revol_util,
        b.pub_rec,
        b.employment_length,
        b.open_accounts,

        -- FICO is the biggest driver: 40 points available
        CASE
            WHEN (b.fico_range_low + b.fico_range_high)/2 >= 780 THEN 40
            WHEN (b.fico_range_low + b.fico_range_high)/2 >= 740 THEN 35
            WHEN (b.fico_range_low + b.fico_range_high)/2 >= 700 THEN 28
            WHEN (b.fico_range_low + b.fico_range_high)/2 >= 660 THEN 20
            WHEN (b.fico_range_low + b.fico_range_high)/2 >= 620 THEN 12
            ELSE 5
        END AS fico_pts,

        -- Debt-to-income: 20 points. High DTI means the borrower is already
        -- stretched thin and has less room to absorb an income shock.
        CASE
            WHEN b.dti < 10 THEN 20
            WHEN b.dti < 20 THEN 16
            WHEN b.dti < 30 THEN 11
            WHEN b.dti < 40 THEN 6
            ELSE 2
        END AS dti_pts,

        -- Recent delinquencies: 15 points. Even one missed payment in the past
        -- two years is a strong signal of future default risk.
        CASE
            WHEN b.delinq_2yrs = 0 THEN 15
            WHEN b.delinq_2yrs = 1 THEN 8
            WHEN b.delinq_2yrs = 2 THEN 3
            ELSE 0
        END AS delinq_pts,

        -- Revolving utilization: 15 points. Borrowers maxing out their credit cards
        -- are seen as a higher risk regardless of their FICO score.
        CASE
            WHEN b.revol_util < 20 THEN 15
            WHEN b.revol_util < 40 THEN 11
            WHEN b.revol_util < 60 THEN 7
            WHEN b.revol_util < 80 THEN 3
            ELSE 0
        END AS revol_pts,

        -- Employment stability: 10 points. Longer tenure reduces income disruption risk.
        CASE
            WHEN b.employment_length >= 7 THEN 10
            WHEN b.employment_length >= 3 THEN 7
            WHEN b.employment_length >= 1 THEN 4
            ELSE 2
        END AS emp_pts
    FROM borrowers b
),
with_score AS (
    SELECT
        *,
        fico_pts + dti_pts + delinq_pts + revol_pts + emp_pts AS risk_score,
        CASE
            WHEN fico_pts + dti_pts + delinq_pts + revol_pts + emp_pts >= 85 THEN 'Prime'
            WHEN fico_pts + dti_pts + delinq_pts + revol_pts + emp_pts >= 65 THEN 'Near-Prime'
            WHEN fico_pts + dti_pts + delinq_pts + revol_pts + emp_pts >= 45 THEN 'Sub-Prime'
            ELSE 'Deep Sub-Prime'
        END AS risk_tier
    FROM scorecard
)
SELECT
    risk_tier,
    COUNT(*)                                 AS borrowers,
    ROUND(AVG(risk_score), 1)                AS avg_score,
    ROUND(AVG((fico_range_low + fico_range_high) / 2.0)) AS avg_fico,
    ROUND(AVG(dti), 1)                       AS avg_dti,
    ROUND(AVG(revol_util), 1)                AS avg_revol_util,
    ROUND(MIN(risk_score))                   AS min_score,
    ROUND(MAX(risk_score))                   AS max_score
FROM with_score
GROUP BY risk_tier
ORDER BY avg_score DESC;


-- 2.3 Pearson correlation of features with default
-- Before building a model, it is useful to know which individual variables
-- are most linearly correlated with the outcome you are trying to predict.
-- We cast the loan_status comparison to INT (1 = defaulted, 0 = not) so the
-- CORR() aggregate function can treat it as a numeric outcome variable.
-- A negative correlation with FICO is expected: higher score, lower default rate.

SELECT
    'FICO'              AS feature,
    ROUND(CORR(
        (b.fico_range_low + b.fico_range_high) / 2.0,
        (lp.loan_status = 'Charged Off')::INT
    )::NUMERIC, 4)      AS correlation_with_default
FROM loans l
JOIN loan_performance lp ON lp.loan_id   = l.loan_id
JOIN borrowers        b  ON b.borrower_id = l.borrower_id

UNION ALL SELECT 'DTI',
    ROUND(CORR(b.dti, (lp.loan_status = 'Charged Off')::INT)::NUMERIC, 4)
    FROM loans l JOIN loan_performance lp ON lp.loan_id=l.loan_id
                 JOIN borrowers b ON b.borrower_id=l.borrower_id

UNION ALL SELECT 'Revol_Util',
    ROUND(CORR(b.revol_util, (lp.loan_status = 'Charged Off')::INT)::NUMERIC, 4)
    FROM loans l JOIN loan_performance lp ON lp.loan_id=l.loan_id
                 JOIN borrowers b ON b.borrower_id=l.borrower_id

UNION ALL SELECT 'Delinq_2yrs',
    ROUND(CORR(b.delinq_2yrs, (lp.loan_status = 'Charged Off')::INT)::NUMERIC, 4)
    FROM loans l JOIN loan_performance lp ON lp.loan_id=l.loan_id
                 JOIN borrowers b ON b.borrower_id=l.borrower_id

UNION ALL SELECT 'Pub_Rec',
    ROUND(CORR(b.pub_rec, (lp.loan_status = 'Charged Off')::INT)::NUMERIC, 4)
    FROM loans l JOIN loan_performance lp ON lp.loan_id=l.loan_id
                 JOIN borrowers b ON b.borrower_id=l.borrower_id

UNION ALL SELECT 'Interest_Rate',
    ROUND(CORR(l.interest_rate, (lp.loan_status = 'Charged Off')::INT)::NUMERIC, 4)
    FROM loans l JOIN loan_performance lp ON lp.loan_id=l.loan_id
                 JOIN borrowers b ON b.borrower_id=l.borrower_id

ORDER BY ABS(correlation_with_default) DESC;


-- 2.4 State-level credit risk profile
-- Geographic concentration risk: does the default rate vary meaningfully
-- by state? This matters for portfolio stress testing because a regional
-- recession (e.g. a collapse in oil prices hitting Texas) would affect
-- a geographically concentrated book more than a diversified one.
-- RANK() OVER lets us order states by default rate without a subquery.

SELECT
    b.state,
    COUNT(DISTINCT b.borrower_id)                            AS unique_borrowers,
    COUNT(l.loan_id)                                         AS total_loans,
    ROUND(SUM(l.funded_amount) / 1e6, 2)                    AS volume_M,
    ROUND(AVG((b.fico_range_low + b.fico_range_high)/2.0))  AS avg_fico,
    ROUND(AVG(b.dti), 1)                                    AS avg_dti,
    ROUND(AVG(l.interest_rate), 2)                          AS avg_rate,
    ROUND(
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) * 100, 2
    )                                                       AS default_rate_pct,
    -- Rank 1 is the state with the highest default rate
    RANK() OVER (ORDER BY
        COUNT(*) FILTER (WHERE lp.loan_status = 'Charged Off')::NUMERIC
        / COUNT(*) DESC
    )                                                       AS default_rank
FROM borrowers        b
JOIN loans            l  ON l.borrower_id = b.borrower_id
JOIN loan_performance lp ON lp.loan_id    = l.loan_id
GROUP BY b.state
ORDER BY default_rate_pct DESC;

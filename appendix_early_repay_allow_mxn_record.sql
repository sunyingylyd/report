-- =============================================================================
-- 允许/不允许提前还款 × 到期月度/周度（周一～周日）
-- 墨西哥比索原币；盈利率：repayment_record_copy
-- 入催金额：overdue_days_period>0 的 SUM(apply_amt_period)（已改回，不用 expect_repay_amt_period）
-- 实时逾期金额：loan_status_code_period=8 的 SUM(apply_amt_period)
-- 到期：due_date ∈ [2026-01-01, 2026-09-20]
-- =============================================================================
SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;

DROP TABLE IF EXISTS tmp_due;
CREATE TEMP TABLE tmp_due AS
SELECT
    o.serial_id,
    o.loan_type,
    o.due_date,
    DATE_TRUNC('month', o.due_date)::date AS ym,
    DATE_TRUNC('week', o.due_date)::date AS wk,
    CASE
        WHEN o.loan_type = 'firstloan' AND RIGHT(o.user_id::text, 1) IN ('4','5','6','7','8','9') THEN 'allow'
        WHEN o.loan_type = 'reloan' AND RIGHT(o.user_id::text, 1) IN ('1','2','3','4','5','6','7','8','9') THEN 'allow'
        ELSE 'deny'
    END AS allow_flag,
    CASE WHEN o.repaid_date IS NOT NULL
              AND o.repaid_date > DATE '2000-01-01'
              AND o.repaid_date < o.due_date THEN 1 ELSE 0 END AS is_early,
    CASE WHEN COALESCE(o.overdue_days, 0) > 0 THEN 1 ELSE 0 END AS is_coll,
    CASE WHEN o.loan_status_code = 8 THEN 1 ELSE 0 END AS is_st8,
    COALESCE(o.apply_amt, 0) AS apply_amt
FROM wangchuanliang.order_loan_f_v2_copy o
WHERE o.is_remit = 1
  AND COALESCE(o.remit_amt, 0) > 0
  AND o.due_date >= DATE '2026-01-01'
  AND o.due_date <= DATE '2026-09-20'
  AND o.loan_type IN ('firstloan', 'reloan');

CREATE INDEX tmp_due_serial ON tmp_due (serial_id);

DROP TABLE IF EXISTS tmp_p;
CREATE TEMP TABLE tmp_p AS
SELECT
    p.serial_id,
    SUM(CASE WHEN COALESCE(p.overdue_days_period, 0) > 0
             THEN COALESCE(p.apply_amt_period, 0) ELSE 0 END) AS coll_amt,
    SUM(CASE WHEN p.loan_status_code_period = 8
             THEN COALESCE(p.apply_amt_period, 0) ELSE 0 END) AS st8_amt,
    SUM(COALESCE(p.repaid_amt_period, 0)) AS repaid_amt
FROM wangchuanliang.repayment_plan_v2_copy p
INNER JOIN tmp_due d ON d.serial_id = p.serial_id
WHERE p.is_remit = 1
GROUP BY p.serial_id;

DROP TABLE IF EXISTS tmp_f;
CREATE TEMP TABLE tmp_f AS
SELECT r.serial_id, SUM(r.amount) AS flow_amt
FROM wangchuanliang.repayment_record_copy r
INNER JOIN tmp_due d ON d.serial_id = r.serial_id
GROUP BY r.serial_id;

DROP TABLE IF EXISTS tmp_base;
CREATE TEMP TABLE tmp_base AS
SELECT
    d.serial_id,
    d.loan_type,
    d.due_date,
    d.ym,
    d.wk,
    d.allow_flag,
    d.is_early,
    d.is_coll,
    d.is_st8,
    d.apply_amt,
    COALESCE(p.coll_amt, 0) AS coll_amt,
    COALESCE(p.st8_amt, 0) AS st8_amt,
    COALESCE(p.repaid_amt, 0) AS repaid_amt,
    COALESCE(f.flow_amt, 0) AS flow_amt
FROM tmp_due d
LEFT JOIN tmp_p p ON p.serial_id = d.serial_id
LEFT JOIN tmp_f f ON f.serial_id = d.serial_id;

DROP TABLE IF EXISTS tmp_agg;
CREATE TEMP TABLE tmp_agg AS
SELECT 'all'::text AS scope, 'month'::text AS grain, ym AS period_d, allow_flag,
       COUNT(*) AS n_due, SUM(is_early) AS n_early, SUM(is_coll) AS n_coll, SUM(is_st8) AS n_st8,
       SUM(apply_amt) AS due_amt,
       SUM(CASE WHEN is_early = 1 THEN apply_amt ELSE 0 END) AS early_amt,
       SUM(coll_amt) AS coll_amt, SUM(st8_amt) AS st8_amt,
       SUM(flow_amt) AS flow_usd, SUM(repaid_amt) AS repaid_usd
FROM tmp_base GROUP BY ym, allow_flag
UNION ALL
SELECT 'all', 'week', wk, allow_flag,
       COUNT(*), SUM(is_early), SUM(is_coll), SUM(is_st8),
       SUM(apply_amt), SUM(CASE WHEN is_early = 1 THEN apply_amt ELSE 0 END),
       SUM(coll_amt), SUM(st8_amt), SUM(flow_amt), SUM(repaid_amt)
FROM tmp_base GROUP BY wk, allow_flag
UNION ALL
SELECT loan_type, 'month', ym, allow_flag,
       COUNT(*), SUM(is_early), SUM(is_coll), SUM(is_st8),
       SUM(apply_amt), SUM(CASE WHEN is_early = 1 THEN apply_amt ELSE 0 END),
       SUM(coll_amt), SUM(st8_amt), SUM(flow_amt), SUM(repaid_amt)
FROM tmp_base GROUP BY loan_type, ym, allow_flag
UNION ALL
SELECT loan_type, 'week', wk, allow_flag,
       COUNT(*), SUM(is_early), SUM(is_coll), SUM(is_st8),
       SUM(apply_amt), SUM(CASE WHEN is_early = 1 THEN apply_amt ELSE 0 END),
       SUM(coll_amt), SUM(st8_amt), SUM(flow_amt), SUM(repaid_amt)
FROM tmp_base GROUP BY loan_type, wk, allow_flag;

SELECT
    scope,
    grain,
    period_d,
    CASE WHEN allow_flag = 'allow' THEN '允许提前还款用户' ELSE '不允许提前还款用户' END AS grp,
    n_due,
    n_early,
    CASE WHEN n_due > 0 THEN 1.0 * n_early / n_due END AS early_n_rate,
    n_coll,
    CASE WHEN n_due > 0 THEN 1.0 * n_coll / n_due END AS coll_n_rate,
    n_st8,
    CASE WHEN n_due > 0 THEN 1.0 * n_st8 / n_due END AS st8_n_rate,
    due_amt,
    early_amt,
    CASE WHEN due_amt > 0 THEN 1.0 * early_amt / due_amt END AS early_amt_rate,
    coll_amt,
    CASE WHEN due_amt > 0 THEN 1.0 * coll_amt / due_amt END AS coll_amt_rate,
    st8_amt,
    CASE WHEN due_amt > 0 THEN 1.0 * st8_amt / due_amt END AS st8_amt_rate,
    CASE WHEN due_amt > 0 THEN 1.0 * flow_usd / due_amt - 1 END AS profit_flow,
    CASE WHEN due_amt > 0 THEN 1.0 * repaid_usd / due_amt - 1 END AS profit_plan
FROM tmp_agg
ORDER BY scope, grain, period_d, allow_flag;


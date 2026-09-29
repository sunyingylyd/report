-- =============================================================================
-- 允许/不允许提前还款 × 到期月度/周度（周一～周日）
-- 到期：due_date ∈ [2026-01-01, 2026-09-20]
-- 已放款：is_remit=1 AND remit_amt>0
-- 金额 MXN→USD：exchange_rate_copy country='MXN' local2usd
--   提单 apply_amt / apply_amt_period → remit_date
--   流水 repayment_plan_record_copy.amount → payin_date
--   盈利率1 repaid_amt_period → repaid_date_period>2000-01-01 否则 due_date_period
-- 分期 apply_amt 每期相同，禁止 SUM(apply_amt)
-- 允许：firstloan 末位 4-9；reloan 末位 1-9
-- =============================================================================
SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;

DROP TABLE IF EXISTS tmp_fx;
CREATE TEMP TABLE tmp_fx AS
SELECT d::date AS dt,
       (SELECT e.local2usd
          FROM wangchuanliang.exchange_rate_copy e
         WHERE e.country = 'MXN' AND e.snap_date <= d::date
         ORDER BY e.snap_date DESC
         LIMIT 1) AS local2usd
FROM generate_series(DATE '2025-11-01', DATE '2026-09-28', INTERVAL '1 day') d;

DROP TABLE IF EXISTS tmp_due;
CREATE TEMP TABLE tmp_due AS
SELECT
    o.serial_id,
    o.loan_type,
    o.due_date,
    o.remit_date,
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
    COALESCE(o.apply_amt, 0) * fx.local2usd AS apply_usd
FROM wangchuanliang.order_loan_f_v2_copy o
INNER JOIN tmp_fx fx ON fx.dt = o.remit_date
WHERE o.is_remit = 1
  AND COALESCE(o.remit_amt, 0) > 0
  AND o.due_date >= DATE '2026-01-01'
  AND o.due_date <= DATE '2026-09-20'
  AND o.loan_type IN ('firstloan', 'reloan');

CREATE INDEX tmp_due_serial ON tmp_due (serial_id);
CREATE INDEX tmp_fx_dt ON tmp_fx (dt);

DROP TABLE IF EXISTS tmp_p;
CREATE TEMP TABLE tmp_p AS
SELECT
    p.serial_id,
    SUM(CASE WHEN COALESCE(p.overdue_days_period, 0) > 0
             THEN COALESCE(p.apply_amt_period, 0) * fx_a.local2usd ELSE 0 END) AS coll_amt_usd,
    SUM(CASE WHEN p.loan_status_code_period = 8
             THEN COALESCE(p.apply_amt_period, 0) * fx_a.local2usd ELSE 0 END) AS st8_amt_usd,
    SUM(COALESCE(p.repaid_amt_period, 0) * COALESCE(fx_r.local2usd, 0)) AS repaid_usd
FROM wangchuanliang.repayment_plan_v2_copy p
INNER JOIN tmp_due d ON d.serial_id = p.serial_id
INNER JOIN tmp_fx fx_a ON fx_a.dt = d.remit_date
LEFT JOIN tmp_fx fx_r ON fx_r.dt = CASE
    WHEN p.repaid_date_period IS NOT NULL AND p.repaid_date_period > DATE '2000-01-01'
    THEN p.repaid_date_period ELSE p.due_date_period END
WHERE p.is_remit = 1
GROUP BY p.serial_id;

DROP TABLE IF EXISTS tmp_f;
CREATE TEMP TABLE tmp_f AS
SELECT r.serial_id, SUM(r.amount * fx.local2usd) AS flow_usd
FROM wangchuanliang.repayment_plan_record_copy r
INNER JOIN tmp_due d ON d.serial_id = r.serial_id
INNER JOIN tmp_fx fx ON fx.dt = r.payin_date
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
    d.apply_usd,
    COALESCE(p.coll_amt_usd, 0) AS coll_amt_usd,
    COALESCE(p.st8_amt_usd, 0) AS st8_amt_usd,
    COALESCE(p.repaid_usd, 0) AS repaid_usd,
    COALESCE(f.flow_usd, 0) AS flow_usd
FROM tmp_due d
LEFT JOIN tmp_p p ON p.serial_id = d.serial_id
LEFT JOIN tmp_f f ON f.serial_id = d.serial_id;

DROP TABLE IF EXISTS tmp_agg;
CREATE TEMP TABLE tmp_agg AS
SELECT 'all'::text AS scope, 'month'::text AS grain, ym AS period_d, allow_flag,
       COUNT(*) AS n_due, SUM(is_early) AS n_early, SUM(is_coll) AS n_coll, SUM(is_st8) AS n_st8,
       SUM(apply_usd) AS due_amt,
       SUM(CASE WHEN is_early = 1 THEN apply_usd ELSE 0 END) AS early_amt,
       SUM(coll_amt_usd) AS coll_amt, SUM(st8_amt_usd) AS st8_amt,
       SUM(flow_usd) AS flow_usd, SUM(repaid_usd) AS repaid_usd
FROM tmp_base GROUP BY ym, allow_flag
UNION ALL
SELECT 'all', 'week', wk, allow_flag,
       COUNT(*), SUM(is_early), SUM(is_coll), SUM(is_st8),
       SUM(apply_usd), SUM(CASE WHEN is_early = 1 THEN apply_usd ELSE 0 END),
       SUM(coll_amt_usd), SUM(st8_amt_usd), SUM(flow_usd), SUM(repaid_usd)
FROM tmp_base GROUP BY wk, allow_flag
UNION ALL
SELECT loan_type, 'month', ym, allow_flag,
       COUNT(*), SUM(is_early), SUM(is_coll), SUM(is_st8),
       SUM(apply_usd), SUM(CASE WHEN is_early = 1 THEN apply_usd ELSE 0 END),
       SUM(coll_amt_usd), SUM(st8_amt_usd), SUM(flow_usd), SUM(repaid_usd)
FROM tmp_base GROUP BY loan_type, ym, allow_flag
UNION ALL
SELECT loan_type, 'week', wk, allow_flag,
       COUNT(*), SUM(is_early), SUM(is_coll), SUM(is_st8),
       SUM(apply_usd), SUM(CASE WHEN is_early = 1 THEN apply_usd ELSE 0 END),
       SUM(coll_amt_usd), SUM(st8_amt_usd), SUM(flow_usd), SUM(repaid_usd)
FROM tmp_base GROUP BY loan_type, wk, allow_flag;


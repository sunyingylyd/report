-- =============================================================================
-- T0 结清0在贷 × 获额时点 KabyBXgboost407Apd7RePrime
-- 月度总体 + 三档：当天提单率 / 提单结构 / 加权息费 / 到期盈利 / 整笔逾期
-- 库：kaby_dw  GaussDB    SET search_path TO wangchuanliang, public;
-- 窗口：vir_date 2026-05-01（含）～ 2026-09-01（不含）；仅保留有 407 分的获额单（6 月无分单剔除，该月仅供参考）
--
-- 分：model_result_copy.serial_id = 获额订单号 credit_serial_id
--     kabybxgboost407apd7reprime；-9999999 或空 = 无分
--     分越高资质越好。三档阈值 = 全量 T0 有分样本 P30 / P60（脚本内计算）
-- 当天提单：获额后第一笔 apply_time>=vir_time 且 apply_date=vir_date（不卡放款）
-- 息费：当天提单订单，不卡 is_remit；Σ(pre_amt+post_amt)/Σ(remit_amt)
-- 盈利/逾期：当天提单且 is_remit=1 且 remit_amt>0 且 due_date < CURRENT_DATE
-- 盈利：Σ(repayment_record_copy.amount, payin_date<=due_date)/Σremit_amt - 1
-- 非逾期：repaid_date > 2000-01-01 AND repaid_date <= due_date
-- 逾期：其余到期放款单（含空值、1969-12-31、晚于到期日）
-- =============================================================================

-- [M0] 环境
SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;

-- [M1] T0 结清0在贷获额快照
DROP TABLE IF EXISTS tmp_m_origin;
CREATE TEMP TABLE tmp_m_origin AS
WITH params AS (
    SELECT DATE '2026-05-01' AS start_date, DATE '2026-09-01' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date, TO_TIMESTAMP(v.vir_unix) AS vir_time
    FROM order_vir_f_copy v
    INNER JOIN side_recycle_type_copy r ON r.serial_id = v.serial_id
    CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND r.recycle_type = 3
      AND v.vir_date >= p.start_date - 1 AND v.vir_date < p.end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
), lagged AS (
    SELECT r.*, LAG(r.vir_time) OVER (PARTITION BY r.user_id ORDER BY r.vir_time, r.serial_id) AS prev_vir_time
    FROM raw_offer r
), batched AS (
    SELECT l.*, SUM(CASE WHEN l.prev_vir_time IS NULL OR l.vir_time - l.prev_vir_time > INTERVAL '20 seconds' THEN 1 ELSE 0 END)
      OVER (PARTITION BY l.user_id ORDER BY l.vir_time, l.serial_id ROWS UNBOUNDED PRECEDING) AS batch_id
    FROM lagged l
), dedup_offer AS (
    SELECT user_id, serial_id, vir_date, vir_time
    FROM (
        SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.user_id, b.batch_id ORDER BY b.vir_time DESC, b.serial_id DESC) AS batch_rn
        FROM batched b
    ) x
    CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.start_date AND vir_date < p.end_date
), candidate_users AS (SELECT DISTINCT user_id FROM dedup_offer),
all_orders AS (
    SELECT o.user_id, o.serial_id, o.apply_time, o.repaid_time, o.repaid_date::date AS repaid_date,
           o.loan_status_code, o.is_remit, o.is_repaid
    FROM order_loan_f_v2_copy o
    INNER JOIN candidate_users u ON u.user_id = o.user_id
), clean_settlement AS (
    SELECT o.user_id, o.serial_id, o.repaid_time, o.repaid_date
    FROM all_orders o
    WHERE o.is_remit = 1 AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS (
          SELECT 1 FROM all_orders x
          WHERE x.user_id = o.user_id AND x.serial_id <> o.serial_id AND x.apply_time < o.repaid_time
            AND (x.loan_status_code IN (5, 8) OR (x.loan_status_code = 7 AND x.repaid_time > o.repaid_time))
      )
), paired AS (
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time,
           ROW_NUMBER() OVER (PARTITION BY e.user_id, e.vir_date ORDER BY e.vir_time ASC, e.serial_id DESC) AS day_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
)
SELECT user_id, credit_serial_id, vir_date, vir_time FROM paired WHERE day_rn = 1;

-- 只保留有有效 407 分的获额单（6 月无分单不进样本，该月带 * 仅供参考）
DELETE FROM tmp_m_origin t
WHERE NOT EXISTS (
    SELECT 1 FROM model_result_copy m
    WHERE m.serial_id = t.credit_serial_id
      AND m.kabybxgboost407apd7reprime IS NOT NULL
      AND m.kabybxgboost407apd7reprime <> -9999999
);

-- [M2] 全量 T0 获额分 P30 / P60
DROP TABLE IF EXISTS tmp_cuts;
CREATE TEMP TABLE tmp_cuts AS
SELECT
    PERCENTILE_CONT(0.30) WITHIN GROUP (ORDER BY m.kabybxgboost407apd7reprime) AS p30,
    PERCENTILE_CONT(0.60) WITHIN GROUP (ORDER BY m.kabybxgboost407apd7reprime) AS p60
FROM tmp_m_origin t
INNER JOIN model_result_copy m ON m.serial_id = t.credit_serial_id
WHERE m.kabybxgboost407apd7reprime IS NOT NULL
  AND m.kabybxgboost407apd7reprime <> -9999999;

-- [M3] 获额后首次提单
DROP TABLE IF EXISTS tmp_first_apply;
CREATE TEMP TABLE tmp_first_apply AS
SELECT user_id, vir_date, serial_id, apply_date, apply_time, due_date,
       is_remit, remit_amt, pre_amt, post_amt, repaid_date
FROM (
    SELECT t.user_id, t.vir_date, a.serial_id, a.apply_date, a.apply_time, a.due_date,
           a.is_remit, a.remit_amt, a.pre_amt, a.post_amt, a.repaid_date::date AS repaid_date,
           ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
    FROM tmp_m_origin t
    INNER JOIN order_loan_f_v2_copy a
      ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
) z WHERE rn = 1;

-- [M4] 获额分、三档、当天提单标记
DROP TABLE IF EXISTS tmp_base;
CREATE TEMP TABLE tmp_base AS
SELECT
    t.user_id,
    t.vir_date,
    DATE_TRUNC('month', t.vir_date)::date AS ym,
    t.credit_serial_id,
    CASE
      WHEN m.kabybxgboost407apd7reprime IS NULL THEN NULL
      WHEN m.kabybxgboost407apd7reprime = -9999999 THEN NULL
      ELSE m.kabybxgboost407apd7reprime
    END AS score,
    CASE
      WHEN m.kabybxgboost407apd7reprime IS NULL OR m.kabybxgboost407apd7reprime = -9999999 THEN '无分'
      WHEN m.kabybxgboost407apd7reprime <= (SELECT p30 FROM tmp_cuts) THEN '较差'
      WHEN m.kabybxgboost407apd7reprime <= (SELECT p60 FROM tmp_cuts) THEN '一般'
      ELSE '最好'
    END AS tier,
    CASE WHEN f.apply_date = t.vir_date THEN 1 ELSE 0 END AS is_same_day,
    f.serial_id AS apply_serial_id,
    f.is_remit,
    f.remit_amt,
    f.pre_amt,
    f.post_amt,
    f.due_date,
    f.repaid_date
FROM tmp_m_origin t
INNER JOIN model_result_copy m ON m.serial_id = t.credit_serial_id
LEFT JOIN tmp_first_apply f ON f.user_id = t.user_id AND f.vir_date = t.vir_date;

-- [M5] 到期日及之前还款
DROP TABLE IF EXISTS tmp_repay;
CREATE TEMP TABLE tmp_repay AS
SELECT b.apply_serial_id, SUM(r.amount) AS repay_amt
FROM tmp_base b
INNER JOIN repayment_record_copy r ON r.serial_id = b.apply_serial_id
WHERE b.is_same_day = 1
  AND b.is_remit = 1
  AND COALESCE(b.remit_amt, 0) > 0
  AND b.due_date < CURRENT_DATE
  AND r.payin_date <= b.due_date
GROUP BY b.apply_serial_id;

-- [M6] 结果：阈值
-- ---------------------------------------------------------------------------
-- 结果1：阈值
-- ---------------------------------------------------------------------------
SELECT p30, p60 FROM tmp_cuts;

-- [M7] 结果：月度总体
-- ---------------------------------------------------------------------------
-- 结果2：月度总体
-- ---------------------------------------------------------------------------
SELECT
    TO_CHAR(ym, 'YYYY-MM') AS ym,
    COUNT(*) AS n_t0,
    SUM(is_same_day) AS n_same_day,
    ROUND(100.0 * AVG(is_same_day::numeric), 2) AS apply_rate_pct,
    ROUND(AVG(score)::numeric, 2) AS mean_score_t0,
    ROUND(AVG(CASE WHEN is_same_day = 1 THEN score END)::numeric, 2) AS mean_score_apply,
    SUM(CASE WHEN tier = '较差' THEN 1 ELSE 0 END) AS n_t0_poor,
    SUM(CASE WHEN tier = '一般' THEN 1 ELSE 0 END) AS n_t0_mid,
    SUM(CASE WHEN tier = '最好' THEN 1 ELSE 0 END) AS n_t0_good,
    SUM(CASE WHEN tier = '无分' THEN 1 ELSE 0 END) AS n_t0_noscored,
    ROUND(100.0 * SUM(CASE WHEN tier = '较差' THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_t0_poor,
    ROUND(100.0 * SUM(CASE WHEN tier = '一般' THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_t0_mid,
    ROUND(100.0 * SUM(CASE WHEN tier = '最好' THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_t0_good,
    SUM(CASE WHEN is_same_day = 1 AND tier = '较差' THEN 1 ELSE 0 END) AS n_apply_poor,
    SUM(CASE WHEN is_same_day = 1 AND tier = '一般' THEN 1 ELSE 0 END) AS n_apply_mid,
    SUM(CASE WHEN is_same_day = 1 AND tier = '最好' THEN 1 ELSE 0 END) AS n_apply_good,
    ROUND(100.0 * SUM(CASE WHEN is_same_day = 1 AND tier = '较差' THEN 1 ELSE 0 END)
        / NULLIF(SUM(is_same_day), 0), 2) AS pct_apply_poor,
    ROUND(100.0 * SUM(CASE WHEN is_same_day = 1 AND tier = '一般' THEN 1 ELSE 0 END)
        / NULLIF(SUM(is_same_day), 0), 2) AS pct_apply_mid,
    ROUND(100.0 * SUM(CASE WHEN is_same_day = 1 AND tier = '最好' THEN 1 ELSE 0 END)
        / NULLIF(SUM(is_same_day), 0), 2) AS pct_apply_good,
    ROUND((
        SUM(CASE WHEN is_same_day = 1 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_same_day = 1 THEN COALESCE(remit_amt, 0) ELSE 0 END), 0)
    )::numeric, 4) AS fee_rate,
    SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
              AND due_date < CURRENT_DATE THEN 1 ELSE 0 END) AS n_due,
    ROUND((
        SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                  AND due_date < CURRENT_DATE THEN COALESCE(p.repay_amt, 0) ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                          AND due_date < CURRENT_DATE THEN remit_amt ELSE 0 END), 0)
        - 1
    )::numeric, 4) AS profit_rate,
    ROUND((
        100.0 * SUM(CASE
            WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
             AND due_date < CURRENT_DATE
             AND NOT (repaid_date > DATE '2000-01-01' AND repaid_date <= due_date)
            THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                          AND due_date < CURRENT_DATE THEN 1 ELSE 0 END), 0)
    )::numeric, 2) AS overdue_pct
FROM tmp_base b
LEFT JOIN tmp_repay p ON p.apply_serial_id = b.apply_serial_id
GROUP BY ym
ORDER BY ym;

-- [M8] 结果：月度 × 三档
-- ---------------------------------------------------------------------------
-- 结果3：月度 × 三档
-- ---------------------------------------------------------------------------
SELECT
    TO_CHAR(ym, 'YYYY-MM') AS ym,
    tier,
    COUNT(*) AS n_t0,
    SUM(is_same_day) AS n_same_day,
    ROUND(100.0 * AVG(is_same_day::numeric), 2) AS apply_rate_pct,
    ROUND(AVG(score)::numeric, 2) AS mean_score,
    ROUND((
        SUM(CASE WHEN is_same_day = 1 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_same_day = 1 THEN COALESCE(remit_amt, 0) ELSE 0 END), 0)
    )::numeric, 4) AS fee_rate,
    SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
              AND due_date < CURRENT_DATE THEN 1 ELSE 0 END) AS n_due,
    ROUND((
        SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                  AND due_date < CURRENT_DATE THEN COALESCE(p.repay_amt, 0) ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                          AND due_date < CURRENT_DATE THEN remit_amt ELSE 0 END), 0)
        - 1
    )::numeric, 4) AS profit_rate,
    ROUND((
        100.0 * SUM(CASE
            WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
             AND due_date < CURRENT_DATE
             AND NOT (repaid_date > DATE '2000-01-01' AND repaid_date <= due_date)
            THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_same_day = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                          AND due_date < CURRENT_DATE THEN 1 ELSE 0 END), 0)
    )::numeric, 2) AS overdue_pct
FROM tmp_base b
LEFT JOIN tmp_repay p ON p.apply_serial_id = b.apply_serial_id
GROUP BY ym, tier
ORDER BY ym, CASE tier WHEN '最好' THEN 1 WHEN '一般' THEN 2 WHEN '较差' THEN 3 ELSE 4 END;

-- =============================================================================
-- T0 结清0在贷获额：产品结构、加权期次、当日提单产品、息费与日息率
-- 库：kaby_dw（GaussDB）
-- 窗口：2026-01-01（含）～ 2026-09-01（不含）
-- 一次跑完可复现报告全部月表。GaussDB 不用 unnest 关联外表，产品槽用 split_part。
--
-- 口径
--   T0：is_pass1=1 AND loan_type_code=2 AND recycle_type=3；20 秒批次去重留最新 serial；
--       同日结清且 vir_time>=repaid_time；结清时无其他在途/在贷；用户×日最早一轮获额。
--   获额产品槽：order_vir_f_copy.risk_product 去空格后按逗号拆开，1 个或 2 个 product_no。
--   产品期次：order_loan_f_v2_copy 上 MAX(total_term)（T0 当日提单产品号均为一品一期）。
--   加权平均期次 = Σ(槽位期次) / Σ(槽位数)，双产品 2 期+4 期计 3 期，月度按槽加权。
--   当日提单：获额后首次提单且 apply_date = vir_date。
--   息费（已放款 remit_amt>0）= Σ(pre_amt+post_amt) / Σ(remit_amt)。
--   日息额 = Σ(pre_amt+post_amt) / Σ(loan_day)。
--   日息率 = Σ((pre_amt+post_amt)/remit_amt) / Σ(loan_day)。
-- =============================================================================

SET statement_timeout = 900000;

DROP TABLE IF EXISTS tmp_m_origin;
CREATE TEMP TABLE tmp_m_origin AS
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date, DATE '2026-09-01' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date, TO_TIMESTAMP(v.vir_unix) AS vir_time,
        v.risk_product
    FROM wangchuanliang.order_vir_f_copy v
    INNER JOIN wangchuanliang.side_recycle_type_copy r ON r.serial_id = v.serial_id
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
    SELECT user_id, serial_id, vir_date, vir_time, risk_product
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
    FROM wangchuanliang.order_loan_f_v2_copy o
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
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time, e.risk_product,
           ROW_NUMBER() OVER (PARTITION BY e.user_id, e.vir_date ORDER BY e.vir_time ASC, e.serial_id DESC) AS day_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
)
SELECT user_id, credit_serial_id, vir_date, vir_time, risk_product FROM paired WHERE day_rn = 1;

DROP TABLE IF EXISTS tmp_first;
CREATE TEMP TABLE tmp_first AS
SELECT t.user_id, t.vir_date, t.vir_time,
       o.serial_id, o.apply_date, o.product_no, o.total_term, o.loan_day,
       o.is_remit, o.remit_amt, o.pre_amt, o.post_amt,
       CASE
         WHEN o.serial_id IS NULL THEN 'never'
         WHEN o.apply_date = t.vir_date THEN '当日'
         WHEN o.apply_date >= t.vir_date + 1 AND o.apply_date <= t.vir_date + 3 THEN '1-3日'
         WHEN o.apply_date >= t.vir_date + 4 AND o.apply_date <= t.vir_date + 7 THEN '4-7日'
         ELSE '7日以后'
       END AS bucket
FROM tmp_m_origin t
LEFT JOIN (
    SELECT user_id, vir_date, serial_id, apply_date, product_no, total_term, loan_day,
           is_remit, remit_amt, pre_amt, post_amt
    FROM (
        SELECT t.user_id, t.vir_date, a.serial_id, a.apply_date, a.product_no, a.total_term,
               a.loan_day, a.is_remit, a.remit_amt, a.pre_amt, a.post_amt,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
    ) z WHERE rn = 1
) o ON o.user_id = t.user_id AND o.vir_date = t.vir_date;

DROP TABLE IF EXISTS tmp_prod_term;
CREATE TEMP TABLE tmp_prod_term AS
SELECT product_no::text AS product_no, MAX(total_term) AS term, MAX(loan_day) AS loan_day
FROM wangchuanliang.order_loan_f_v2_copy
WHERE product_no IS NOT NULL
GROUP BY 1;

-- 获额产品槽：最多 2 个号，用 generate_series + split_part，避免 unnest 关联外表
DROP TABLE IF EXISTS tmp_slots;
CREATE TEMP TABLE tmp_slots AS
SELECT
  t.user_id,
  t.vir_date,
  DATE_TRUNC('month', t.vir_date)::date AS ym,
  TRIM(split_part(regexp_replace(COALESCE(t.risk_product, ''), '\s', '', 'g'), ',', gs.n)) AS product_no,
  regexp_replace(COALESCE(t.risk_product, ''), '\s', '', 'g') AS combo
FROM tmp_m_origin t
CROSS JOIN generate_series(1, 2) AS gs(n)
WHERE NULLIF(TRIM(split_part(regexp_replace(COALESCE(t.risk_product, ''), '\s', '', 'g'), ',', gs.n)), '') IS NOT NULL;

-- -----------------------------------------------------------------------------
-- A 月度获额结构：产品个数、单/双产品、加权平均期次
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(m.ym, 'YYYY-MM'), '合计') AS ym,
  COUNT(*) AS t0,
  ROUND(AVG(m.n_prod)::numeric, 4) AS avg_n_prod,
  ROUND(100.0 * SUM(CASE WHEN m.n_prod = 1 THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_single,
  ROUND(100.0 * SUM(CASE WHEN m.n_prod = 2 THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_dual,
  ROUND(SUM(m.sum_term)::numeric / NULLIF(SUM(m.n_prod), 0), 4) AS avg_term_weighted
FROM (
    SELECT
      DATE_TRUNC('month', s.vir_date)::date AS ym,
      s.user_id,
      s.vir_date,
      COUNT(*) AS n_prod,
      SUM(p.term) AS sum_term
    FROM tmp_slots s
    LEFT JOIN tmp_prod_term p ON p.product_no = s.product_no
    GROUP BY 1, 2, 3
) m
GROUP BY ROLLUP (m.ym)
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- B 获额槽位期次构成
-- -----------------------------------------------------------------------------
SELECT
  TO_CHAR(s.ym, 'YYYY-MM') AS ym,
  p.term,
  COUNT(*) AS n_slots,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY s.ym), 2) AS slot_pct
FROM tmp_slots s
LEFT JOIN tmp_prod_term p ON p.product_no = s.product_no
GROUP BY s.ym, p.term
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- C 获额槽位产品号占比（按月）
-- -----------------------------------------------------------------------------
SELECT
  TO_CHAR(s.ym, 'YYYY-MM') AS ym,
  s.product_no,
  COUNT(*) AS n_slots,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY s.ym), 2) AS slot_pct
FROM tmp_slots s
GROUP BY s.ym, s.product_no
ORDER BY s.ym, n_slots DESC;

-- -----------------------------------------------------------------------------
-- D 获额组合 combo 占比（按月）
-- -----------------------------------------------------------------------------
SELECT
  TO_CHAR(DATE_TRUNC('month', t.vir_date), 'YYYY-MM') AS ym,
  regexp_replace(COALESCE(t.risk_product, ''), '\s', '', 'g') AS combo,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY DATE_TRUNC('month', t.vir_date)), 2) AS pct
FROM tmp_m_origin t
GROUP BY 1, 2
ORDER BY 1, n DESC;

-- -----------------------------------------------------------------------------
-- E 当日提单率、月度提单率、当日整笔息费、日息额、日息率
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(DATE_TRUNC('month', vir_date), 'YYYY-MM'), '合计') AS ym,
  COUNT(*) AS t0,
  SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) AS n_d0,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d0_apply_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_rate_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                         THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '当日' AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0
                                THEN remit_amt ELSE 0 END), 0), 2) AS d0_fee_pct,
  ROUND(SUM(CASE WHEN bucket = '当日' AND is_remit = 1 AND COALESCE(loan_day, 0) > 0
                 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
        / NULLIF(SUM(CASE WHEN bucket = '当日' AND is_remit = 1 AND COALESCE(loan_day, 0) > 0
                          THEN loan_day ELSE 0 END), 0), 4) AS d0_daily_amt,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' AND is_remit = 1 AND COALESCE(loan_day, 0) > 0 AND COALESCE(remit_amt, 0) > 0
                         THEN (COALESCE(pre_amt, 0) + COALESCE(post_amt, 0)) / remit_amt ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '当日' AND is_remit = 1 AND COALESCE(loan_day, 0) > 0 AND COALESCE(remit_amt, 0) > 0
                                THEN loan_day ELSE 0 END), 0), 4) AS d0_daily_rate_pct
FROM tmp_first
GROUP BY ROLLUP (DATE_TRUNC('month', vir_date))
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- F 当日提单产品号：笔数、期次、息费、日息额、日息率（合计）
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(f.product_no::text, '(空)') AS product_no,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
  MIN(f.total_term) AS term,
  MIN(f.loan_day) AS loan_day,
  SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.remit_amt, 0) > 0 THEN 1 ELSE 0 END) AS n_remit,
  ROUND(100.0 * SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.remit_amt, 0) > 0
                         THEN COALESCE(f.pre_amt, 0) + COALESCE(f.post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.remit_amt, 0) > 0
                                THEN f.remit_amt ELSE 0 END), 0), 2) AS fee_pct,
  ROUND(SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.loan_day, 0) > 0
                 THEN COALESCE(f.pre_amt, 0) + COALESCE(f.post_amt, 0) ELSE 0 END)
        / NULLIF(SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.loan_day, 0) > 0
                          THEN f.loan_day ELSE 0 END), 0), 4) AS daily_amt,
  ROUND(100.0 * SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.loan_day, 0) > 0 AND COALESCE(f.remit_amt, 0) > 0
                         THEN (COALESCE(f.pre_amt, 0) + COALESCE(f.post_amt, 0)) / f.remit_amt ELSE 0 END)
              / NULLIF(SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.loan_day, 0) > 0 AND COALESCE(f.remit_amt, 0) > 0
                                THEN f.loan_day ELSE 0 END), 0), 4) AS daily_rate_pct
FROM tmp_first f
WHERE f.bucket = '当日'
GROUP BY f.product_no
ORDER BY n DESC;

-- -----------------------------------------------------------------------------
-- G 当日提单产品号分月：占比、息费、日息率
-- -----------------------------------------------------------------------------
SELECT
  TO_CHAR(DATE_TRUNC('month', f.vir_date), 'YYYY-MM') AS ym,
  COALESCE(f.product_no::text, '(空)') AS product_no,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY DATE_TRUNC('month', f.vir_date)), 2) AS share_pct,
  ROUND(100.0 * SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.remit_amt, 0) > 0
                         THEN COALESCE(f.pre_amt, 0) + COALESCE(f.post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.remit_amt, 0) > 0
                                THEN f.remit_amt ELSE 0 END), 0), 2) AS fee_pct,
  ROUND(100.0 * SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.loan_day, 0) > 0 AND COALESCE(f.remit_amt, 0) > 0
                         THEN (COALESCE(f.pre_amt, 0) + COALESCE(f.post_amt, 0)) / f.remit_amt ELSE 0 END)
              / NULLIF(SUM(CASE WHEN f.is_remit = 1 AND COALESCE(f.loan_day, 0) > 0 AND COALESCE(f.remit_amt, 0) > 0
                                THEN f.loan_day ELSE 0 END), 0), 4) AS daily_rate_pct
FROM tmp_first f
WHERE f.bucket = '当日'
GROUP BY 1, 2
ORDER BY 1, n DESC;

-- =============================================================================
-- 结清未提单召回：7天/3天 30% 减息券实验（排除 0814）
-- 库：kaby_dw（GaussDB）  schema：wangchuanliang
-- 统计日：CURRENT_DATE；复现报告全部表与图中的人数、提单率、次数、盈利率、特征分箱
--
-- 口径
--   样本：no_apply_结清日_触达日_30pct，14 张表（不含 0814）
--   组：G1=0716-0719 实验7天30% / 对照不发
--       G2=0730-0802 实验7天30% / 对照3天30%
--       G3=0813,0815,0816,0821-0823 实验3天30% / 对照不发
--   用户：组内 DISTINCT ON (user_id)，按 reach_date, ab_group 取最早一条
--   召回后提单：order_loan_f_v2_copy.apply_date >= reach_date，不卡 is_due / is_remit
--   平均提单次数：召回后全部提单订单数 / 提单去重用户
--   平均放款次数：召回后 is_remit=1 订单数 / 放款去重用户
--   盈利率：仅 is_remit=1 AND is_due=1 AND remit_amt>0
--            (Σrepaid_amt - Σremit_amt) / Σremit_amt ，repaid_amt 空按 0
--   用券窗：召回当天发券；7天=reach..reach+6；3天=reach..reach+2
--            实验组用 t_days，对照用 c_days（0 表示不发券，订单全记非用券）
--   对齐窗（仅对照无券时用于比较）：G1 用 7 天，G3 用 3 天
-- =============================================================================

SET statement_timeout = 420000;

-- -----------------------------------------------------------------------------
-- 0) 召回名单 + 实验分组
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_na_raw;
CREATE TEMP TABLE tmp_na_raw AS
SELECT churn_user_id::bigint AS user_id, ab_group::text AS ab_group,
       churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text AS last_remit_interest_type,
       last_remit_total_term, last_remit_overdue_days, last_vir_amt,
       last_vir_risk_product::text AS last_vir_risk_product, last_vir_total_term,
       active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-07-21' AS reach_date, 'G1'::text AS exp_g, 7 AS t_days, 0 AS c_days
FROM wangchuanliang.no_apply_0716_0721_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-07-22', 'G1', 7, 0
FROM wangchuanliang.no_apply_0717_0722_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-07-23', 'G1', 7, 0
FROM wangchuanliang.no_apply_0718_0723_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-07-24', 'G1', 7, 0
FROM wangchuanliang.no_apply_0719_0724_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-04', 'G2', 7, 3
FROM wangchuanliang.no_apply_0730_0804_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-05', 'G2', 7, 3
FROM wangchuanliang.no_apply_0731_0805_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-06', 'G2', 7, 3
FROM wangchuanliang.no_apply_0801_0806_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-07', 'G2', 7, 3
FROM wangchuanliang.no_apply_0802_0807_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-18', 'G3', 3, 0
FROM wangchuanliang.no_apply_0813_0818_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-20', 'G3', 3, 0
FROM wangchuanliang.no_apply_0815_0820_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-21', 'G3', 3, 0
FROM wangchuanliang.no_apply_0816_0821_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-26', 'G3', 3, 0
FROM wangchuanliang.no_apply_0821_0826_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-27', 'G3', 3, 0
FROM wangchuanliang.no_apply_0822_0827_30pct WHERE churn_user_id IS NOT NULL
UNION ALL
SELECT churn_user_id::bigint, ab_group::text, churn_days, total_apply_rnb, total_remit_rnb, total_remit_amt, als,
       max_over_due, overdue_cnt, overdue_term_cnt, total_vir_amt, total_apply_amt,
       utilization_rate, last_remit_utilization_rate, high_interest_rate,
       last_remit_product_no, last_remit_interest_type::text, last_remit_total_term, last_remit_overdue_days,
       last_vir_amt, last_vir_risk_product::text, last_vir_total_term, active_days_cnt, days_since_last_active,
       newpage_cnt, newconfirm_cnt, amount_selection_cnt, term_selection_cnt,
       plan_newdetails_cnt, contract_newdetails_cnt, purpose_newdetails_cnt,
       coupons_page_cnt, coupons_confirm_cnt, send_coupon_d_cnt, send_coupon_r_cnt,
       DATE '2026-08-28', 'G3', 3, 0
FROM wangchuanliang.no_apply_0823_0828_30pct WHERE churn_user_id IS NOT NULL;

DROP TABLE IF EXISTS tmp_na_user;
CREATE TEMP TABLE tmp_na_user AS
SELECT DISTINCT ON (exp_g, user_id)
    *,
    CASE WHEN ab_group = 'treatment' THEN t_days
         WHEN ab_group = 'control' THEN c_days
         ELSE 0 END AS coupon_days,
    CASE WHEN exp_g = 'G3' THEN 3 ELSE 7 END AS align_days
FROM tmp_na_raw
ORDER BY exp_g, user_id, reach_date, ab_group;

-- -----------------------------------------------------------------------------
-- 1) 召回后订单（不卡到期）
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_na_ord;
CREATE TEMP TABLE tmp_na_ord AS
SELECT
    u.exp_g, u.user_id, u.ab_group, u.reach_date, u.coupon_days, u.align_days, u.t_days, u.c_days,
    u.last_vir_amt, u.als, u.max_over_due, u.overdue_cnt,
    u.utilization_rate, u.last_remit_utilization_rate, u.high_interest_rate,
    u.newpage_cnt, u.amount_selection_cnt, u.active_days_cnt, u.days_since_last_active,
    u.last_remit_interest_type,
    o.serial_id, o.apply_date, o.apply_time, o.is_remit, o.is_due,
    o.remit_amt, COALESCE(o.repaid_amt, 0) AS repaid_amt,
    COALESCE(o.pre_amt, 0) + COALESCE(o.post_amt, 0) AS fee_amt,
    CASE WHEN u.coupon_days > 0 AND o.apply_date <= u.reach_date + (u.coupon_days - 1)
         THEN 1 ELSE 0 END AS in_coupon_win,
    CASE WHEN o.apply_date <= u.reach_date + (u.align_days - 1)
         THEN 1 ELSE 0 END AS in_align_win
FROM tmp_na_user u
INNER JOIN wangchuanliang.order_loan_f_v2_copy o
  ON o.user_id = u.user_id
 AND o.apply_date >= u.reach_date;

-- -----------------------------------------------------------------------------
-- A) ITT：组 × 实验/对照  提单率、平均次数、到期盈利率
-- -----------------------------------------------------------------------------
SELECT
    u.exp_g,
    u.ab_group,
    COUNT(*) AS n_user,
    SUM(CASE WHEN a.n_apply > 0 THEN 1 ELSE 0 END) AS n_apply_user,
    ROUND(100.0 * SUM(CASE WHEN a.n_apply > 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_pct,
    SUM(COALESCE(a.n_apply, 0)) AS n_apply_ord,
    ROUND(1.0 * SUM(COALESCE(a.n_apply, 0))
        / NULLIF(SUM(CASE WHEN a.n_apply > 0 THEN 1 ELSE 0 END), 0), 3) AS avg_apply,
    SUM(CASE WHEN a.n_remit_user > 0 THEN 1 ELSE 0 END) AS n_remit_user,
    SUM(COALESCE(a.n_remit, 0)) AS n_remit_ord,
    ROUND(1.0 * SUM(COALESCE(a.n_remit, 0))
        / NULLIF(SUM(CASE WHEN a.n_remit_user > 0 THEN 1 ELSE 0 END), 0), 3) AS avg_remit,
    SUM(COALESCE(a.due_n, 0)) AS due_n,
    SUM(CASE WHEN a.due_n > 0 THEN 1 ELSE 0 END) AS due_user,
    SUM(COALESCE(a.due_repaid, 0)) AS due_repaid,
    SUM(COALESCE(a.due_remit, 0)) AS due_remit,
    ROUND(100.0 * (SUM(COALESCE(a.due_repaid, 0)) - SUM(COALESCE(a.due_remit, 0)))
        / NULLIF(SUM(COALESCE(a.due_remit, 0)), 0), 2) AS profit_pct
FROM tmp_na_user u
LEFT JOIN (
    SELECT exp_g, user_id,
           COUNT(*) AS n_apply,
           SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) AS n_remit,
           MAX(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) AS n_remit_user,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN 1 ELSE 0 END) AS due_n,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END) AS due_remit,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END) AS due_repaid
    FROM tmp_na_ord
    GROUP BY 1, 2
) a ON a.exp_g = u.exp_g AND a.user_id = u.user_id
GROUP BY u.exp_g, u.ab_group
ORDER BY 1, 2;

-- 组合计（实验+对照）
SELECT
    u.exp_g,
    COUNT(*) AS n_user,
    SUM(CASE WHEN a.n_apply > 0 THEN 1 ELSE 0 END) AS n_apply_user,
    ROUND(100.0 * SUM(CASE WHEN a.n_apply > 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_pct,
    ROUND(1.0 * SUM(COALESCE(a.n_apply, 0))
        / NULLIF(SUM(CASE WHEN a.n_apply > 0 THEN 1 ELSE 0 END), 0), 3) AS avg_apply,
    ROUND(1.0 * SUM(COALESCE(a.n_remit, 0))
        / NULLIF(SUM(CASE WHEN a.n_remit_user > 0 THEN 1 ELSE 0 END), 0), 3) AS avg_remit,
    SUM(COALESCE(a.due_n, 0)) AS due_n,
    ROUND(100.0 * (SUM(COALESCE(a.due_repaid, 0)) - SUM(COALESCE(a.due_remit, 0)))
        / NULLIF(SUM(COALESCE(a.due_remit, 0)), 0), 2) AS profit_pct
FROM tmp_na_user u
LEFT JOIN (
    SELECT exp_g, user_id,
           COUNT(*) AS n_apply,
           SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) AS n_remit,
           MAX(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) AS n_remit_user,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN 1 ELSE 0 END) AS due_n,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END) AS due_remit,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END) AS due_repaid
    FROM tmp_na_ord GROUP BY 1, 2
) a ON a.exp_g = u.exp_g AND a.user_id = u.user_id
GROUP BY u.exp_g
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- B) 用券窗 / 窗外  + 对照对齐窗
-- -----------------------------------------------------------------------------
SELECT
    exp_g, ab_group,
    CASE WHEN in_coupon_win = 1 THEN 'in_coupon' ELSE 'out_coupon' END AS win,
    COUNT(*) AS n_apply_ord,
    COUNT(DISTINCT user_id) AS n_apply_user,
    SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) AS n_remit_ord,
    COUNT(DISTINCT CASE WHEN is_remit = 1 THEN user_id END) AS n_remit_user,
    SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN 1 ELSE 0 END) AS due_n,
    COUNT(DISTINCT CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN user_id END) AS due_user,
    SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END) AS due_repaid,
    SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END) AS due_remit,
    ROUND(100.0 * (
        SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END)
      - SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END)
    ) / NULLIF(SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END), 0), 2) AS profit_pct,
    ROUND(AVG(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt END), 1) AS avg_due_remit,
    ROUND(SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN fee_amt ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END), 0), 4) AS fee_rate
FROM tmp_na_ord
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- 窗内提单率分母 = 组内该臂全部用户
SELECT
    u.exp_g, u.ab_group,
    COUNT(*) AS n_user,
    SUM(CASE WHEN i.n_in > 0 THEN 1 ELSE 0 END) AS n_in_apply_user,
    ROUND(100.0 * SUM(CASE WHEN i.n_in > 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS in_apply_pct,
    SUM(CASE WHEN i.n_out > 0 THEN 1 ELSE 0 END) AS n_out_apply_user,
    ROUND(100.0 * SUM(CASE WHEN i.n_out > 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS out_apply_pct
FROM tmp_na_user u
LEFT JOIN (
    SELECT exp_g, user_id,
           SUM(in_coupon_win) AS n_in,
           SUM(CASE WHEN in_coupon_win = 0 THEN 1 ELSE 0 END) AS n_out
    FROM tmp_na_ord GROUP BY 1, 2
) i ON i.exp_g = u.exp_g AND i.user_id = u.user_id
GROUP BY 1, 2
ORDER BY 1, 2;

-- 对照对齐窗（G1=7天、G3=3天，无券对照与实验同一观察窗）
SELECT
    u.exp_g, u.ab_group,
    COUNT(*) AS n_user,
    SUM(CASE WHEN i.n_in > 0 THEN 1 ELSE 0 END) AS n_align_apply_user,
    ROUND(100.0 * SUM(CASE WHEN i.n_in > 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS align_apply_pct
FROM tmp_na_user u
LEFT JOIN (
    SELECT exp_g, user_id, SUM(in_align_win) AS n_in
    FROM tmp_na_ord GROUP BY 1, 2
) i ON i.exp_g = u.exp_g AND i.user_id = u.user_id
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT
    exp_g, ab_group,
    CASE WHEN in_align_win = 1 THEN 'align_in' ELSE 'align_out' END AS win,
    COUNT(*) AS n_apply_ord,
    COUNT(DISTINCT user_id) AS n_apply_user,
    SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN 1 ELSE 0 END) AS due_n,
    SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END) AS due_repaid,
    SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END) AS due_remit,
    ROUND(100.0 * (
        SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END)
      - SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END)
    ) / NULLIF(SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END), 0), 2) AS profit_pct,
    ROUND(AVG(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt END), 1) AS avg_due_remit,
    ROUND(SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN fee_amt ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END), 0), 4) AS fee_rate
FROM tmp_na_ord
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- -----------------------------------------------------------------------------
-- C) 用券订单 vs 非用券订单（到期放款）：件均、费比、零还款金额占比
-- -----------------------------------------------------------------------------
SELECT
    exp_g, ab_group,
    CASE WHEN in_coupon_win = 1 THEN '用券订单' ELSE '非用券订单' END AS ord_type,
    COUNT(*) AS due_n,
    COUNT(DISTINCT user_id) AS due_user,
    ROUND(AVG(remit_amt), 1) AS avg_remit,
    ROUND(SUM(fee_amt) / SUM(remit_amt), 4) AS fee_rate,
    ROUND(100.0 * (SUM(repaid_amt) - SUM(remit_amt)) / SUM(remit_amt), 2) AS profit_pct,
    SUM(CASE WHEN repaid_amt <= 0 THEN 1 ELSE 0 END) AS unpaid_n,
    ROUND(SUM(CASE WHEN repaid_amt <= 0 THEN remit_amt ELSE 0 END) / SUM(remit_amt), 4) AS unpaid_remit_share
FROM tmp_na_ord
WHERE is_remit = 1 AND is_due = 1 AND remit_amt > 0
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- 用券到期单金额分桶
SELECT
    exp_g, ab_group,
    CASE WHEN in_coupon_win = 1 THEN '用券订单' ELSE '非用券订单' END AS ord_type,
    CASE WHEN remit_amt <= 1500 THEN '<=1.5k'
         WHEN remit_amt <= 3000 THEN '1.5-3k'
         WHEN remit_amt <= 5000 THEN '3-5k'
         WHEN remit_amt <= 10000 THEN '5-10k'
         ELSE '>10k' END AS amt_bin,
    COUNT(*) AS due_n,
    ROUND(AVG(remit_amt), 1) AS avg_remit,
    ROUND(100.0 * (SUM(repaid_amt) - SUM(remit_amt)) / SUM(remit_amt), 2) AS profit_pct,
    ROUND(SUM(CASE WHEN repaid_amt <= 0 THEN remit_amt ELSE 0 END) / SUM(remit_amt), 4) AS unpaid_remit_share
FROM tmp_na_ord
WHERE is_remit = 1 AND is_due = 1 AND remit_amt > 0
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;

-- -----------------------------------------------------------------------------
-- D) 实验组用户类型：窗内用过券 / 仅窗外提单 / 从未提单，其全部到期单
-- -----------------------------------------------------------------------------
SELECT
    u.exp_g,
    CASE WHEN COALESCE(i.n_in, 0) > 0 THEN '用券用户'
         WHEN COALESCE(i.n_apply, 0) > 0 THEN '未用券但后来提单'
         ELSE '从未提单' END AS utype,
    COUNT(*) AS n_user,
    SUM(COALESCE(i.due_n, 0)) AS due_n,
    COUNT(DISTINCT CASE WHEN i.due_n > 0 THEN u.user_id END) AS due_user,
    ROUND(100.0 * (SUM(COALESCE(i.due_repaid, 0)) - SUM(COALESCE(i.due_remit, 0)))
        / NULLIF(SUM(COALESCE(i.due_remit, 0)), 0), 2) AS profit_pct
FROM tmp_na_user u
LEFT JOIN (
    SELECT exp_g, user_id,
           COUNT(*) AS n_apply,
           SUM(in_coupon_win) AS n_in,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN 1 ELSE 0 END) AS due_n,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END) AS due_remit,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END) AS due_repaid
    FROM tmp_na_ord GROUP BY 1, 2
) i ON i.exp_g = u.exp_g AND i.user_id = u.user_id
WHERE u.ab_group = 'treatment'
GROUP BY 1, 2
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- E) 召回时特征分箱 × 实验/对照（ITT 提单率、到期盈利率）
--     分母=箱内该臂用户；盈利=箱内该臂到期放款单金额加权
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_na_feat;
CREATE TEMP TABLE tmp_na_feat AS
SELECT
    u.*,
    CASE WHEN COALESCE(a.n_apply, 0) > 0 THEN 1 ELSE 0 END AS applied,
    COALESCE(a.due_n, 0) AS due_n,
    COALESCE(a.due_remit, 0) AS due_remit,
    COALESCE(a.due_repaid, 0) AS due_repaid,
    CASE WHEN last_vir_amt <= 2000 THEN '<=2k'
         WHEN last_vir_amt <= 5000 THEN '2-5k'
         WHEN last_vir_amt <= 10000 THEN '5-10k'
         ELSE '>10k' END AS vir_bin,
    CASE WHEN last_vir_amt > 5000 THEN '>5k' ELSE '<=5k' END AS amt5,
    CASE WHEN COALESCE(newpage_cnt, 0) + COALESCE(amount_selection_cnt, 0) > 0
         THEN '有进件' ELSE '无进件' END AS intent,
    CASE WHEN COALESCE(max_over_due, 0) > 0 THEN '有逾期' ELSE '无逾期' END AS od_bin,
    CASE WHEN last_remit_utilization_rate <= 0.8 THEN '<=0.8'
         WHEN last_remit_utilization_rate <= 1.0 THEN '0.8-1'
         ELSE '>1' END AS util_bin,
    CASE WHEN COALESCE(newpage_cnt, 0) = 0 THEN '0'
         WHEN newpage_cnt = 1 THEN '1'
         WHEN newpage_cnt <= 3 THEN '2-3'
         ELSE '>3' END AS newpage_bin
FROM tmp_na_user u
LEFT JOIN (
    SELECT exp_g, user_id,
           COUNT(*) AS n_apply,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN 1 ELSE 0 END) AS due_n,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN remit_amt ELSE 0 END) AS due_remit,
           SUM(CASE WHEN is_remit = 1 AND is_due = 1 AND remit_amt > 0 THEN repaid_amt ELSE 0 END) AS due_repaid
    FROM tmp_na_ord GROUP BY 1, 2
) a ON a.exp_g = u.exp_g AND a.user_id = u.user_id;

-- E1 last_vir_amt
SELECT 'last_vir_amt' AS feat, vir_bin AS bin, ab_group,
       COUNT(*) AS n_user,
       SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 2, 3
ORDER BY 2, 3;

-- E2 进件意图
SELECT 'intent' AS feat, intent AS bin, ab_group,
       COUNT(*) AS n_user, SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 2, 3
ORDER BY 2, 3;

-- E3 上次用信
SELECT 'last_remit_utilization' AS feat, util_bin AS bin, ab_group,
       COUNT(*) AS n_user, SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 2, 3
ORDER BY 2, 3;

-- E4 进首页次数
SELECT 'newpage_cnt' AS feat, newpage_bin AS bin, ab_group,
       COUNT(*) AS n_user, SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 2, 3
ORDER BY 2, 3;

-- E5 额度 × 意图
SELECT amt5, intent, ab_group,
       COUNT(*) AS n_user, SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- E6 额度 × 逾期
SELECT amt5, od_bin, ab_group,
       COUNT(*) AS n_user, SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- E7 组内额度分箱（报告分组对照）
SELECT exp_g, vir_bin, ab_group,
       COUNT(*) AS n_user, SUM(applied) AS n_apply_user,
       ROUND(100.0 * SUM(applied) / COUNT(*), 2) AS apply_pct,
       SUM(due_n) AS due_n,
       ROUND(100.0 * (SUM(due_repaid) - SUM(due_remit)) / NULLIF(SUM(due_remit), 0), 2) AS profit_pct
FROM tmp_na_feat
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- E8 特征均值（报告描述用）
SELECT
    COUNT(*) AS n_user,
    ROUND(AVG(churn_days), 3) AS avg_churn_days,
    ROUND(AVG(last_vir_amt), 1) AS avg_last_vir_amt,
    ROUND(AVG(als), 1) AS avg_als,
    ROUND(AVG(utilization_rate), 3) AS avg_util,
    ROUND(AVG(newpage_cnt), 3) AS avg_newpage,
    ROUND(AVG(active_days_cnt), 3) AS avg_active_days,
    SUM(CASE WHEN coupons_page_cnt = 0 THEN 1 ELSE 0 END) AS n_coupon_page_zero
FROM tmp_na_user;

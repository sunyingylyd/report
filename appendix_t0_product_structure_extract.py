#!/usr/bin/env python3
"""Extract T0 offer slots + same-day first apply products for the product-structure report."""
import csv
import io
import json
from collections import Counter, defaultdict
from pathlib import Path

import psycopg2

OUT = Path("/Users/wangchuanliang/Documents/trae_projects/sunyingylyd-report/t0_product_structure.json")

T0_SQL = r"""
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
SELECT user_id, credit_serial_id, vir_date, vir_time, risk_product FROM paired WHERE day_rn = 1
"""

FIRST_SQL = r"""
DROP TABLE IF EXISTS tmp_first;
CREATE TEMP TABLE tmp_first AS
SELECT t.user_id, t.vir_date, t.vir_time,
       o.serial_id, o.apply_date, o.apply_time, o.product_no, o.total_term, o.loan_day,
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
    SELECT user_id, vir_date, serial_id, apply_date, apply_time, product_no, total_term, loan_day,
           is_remit, remit_amt, pre_amt, post_amt
    FROM (
        SELECT t.user_id, t.vir_date, a.serial_id, a.apply_date, a.apply_time, a.product_no, a.total_term,
               a.loan_day, a.is_remit, a.remit_amt, a.pre_amt, a.post_amt,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
    ) z WHERE rn = 1
) o ON o.user_id = t.user_id AND o.vir_date = t.vir_date
"""


def fnum(x):
    if x is None:
        return None
    if isinstance(x, float):
        return round(x, 6)
    return x


def main():
    conn = psycopg2.connect(
        host="47.89.225.85",
        port=8000,
        dbname="kaby_dw",
        user="wangchuanliang_readonly",
        password=__import__("os").environ["PGPASSWORD"],
        connect_timeout=30,
        options="-c statement_timeout=900000",
    )
    conn.autocommit = True
    cur = conn.cursor()
    print("timeout", flush=True)
    cur.execute("SET statement_timeout = 900000")
    print("t0", flush=True)
    cur.execute(T0_SQL)
    print("first", flush=True)
    cur.execute(FIRST_SQL)
    print("copy t0", flush=True)
    t0_buf = io.StringIO()
    cur.copy_expert("COPY (SELECT vir_date, risk_product FROM tmp_m_origin) TO STDOUT WITH CSV", t0_buf)
    print("copy first", flush=True)
    f_buf = io.StringIO()
    cur.copy_expert(
        """COPY (
            SELECT vir_date, bucket, product_no, total_term, loan_day, is_remit, remit_amt, pre_amt, post_amt
            FROM tmp_first
        ) TO STDOUT WITH CSV""",
        f_buf,
    )
    print("terms", flush=True)
    cur.execute(
        """
        SELECT product_no::text, MAX(total_term), MAX(loan_day)
        FROM wangchuanliang.order_loan_f_v2_copy
        WHERE product_no IS NOT NULL
        GROUP BY 1
        """
    )
    term_map = {str(k): {"term": int(v) if v is not None else None, "loan_day": int(d) if d is not None else None} for k, v, d in cur.fetchall()}
    conn.close()

    monthly = defaultdict(lambda: {
        "t0": 0, "n1": 0, "n2": 0, "slots": 0, "sum_term": 0,
        "term_hist": Counter(), "slot_prod": Counter(), "combo": Counter(),
        "n_d0": 0, "n_apply": 0,
        "d0_prod": Counter(),
        "fee_num": 0.0, "fee_den": 0.0,
        "dfee_num": 0.0, "dfee_den": 0.0,
        "rate_num": 0.0, "rate_den": 0.0,
        "prod_fee": defaultdict(lambda: [0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0]),
        # prod: fee_num, fee_den, n, dfee_num, dfee_den, rate_num, rate_den
    })

    t0_buf.seek(0)
    for vir_date, risk in csv.reader(t0_buf):
        ym = vir_date[:7]
        a = monthly[ym]
        a["t0"] += 1
        parts = [p.strip() for p in (risk or "").replace(" ", "").split(",") if p.strip()]
        combo = ",".join(parts) if parts else ""
        a["combo"][combo] += 1
        n = len(parts)
        if n == 1:
            a["n1"] += 1
        elif n == 2:
            a["n2"] += 1
        a["slots"] += n
        for p in parts:
            a["slot_prod"][p] += 1
            t = term_map.get(p, {}).get("term")
            if t:
                a["sum_term"] += t
                a["term_hist"][t] += 1

    f_buf.seek(0)
    for row in csv.reader(f_buf):
        vir_date, bucket, product_no, total_term, loan_day, is_remit, remit_amt, pre_amt, post_amt = row
        ym = vir_date[:7]
        a = monthly[ym]
        if bucket != "never":
            a["n_apply"] += 1
        if bucket != "当日":
            continue
        a["n_d0"] += 1
        p = (product_no or "").strip()
        a["d0_prod"][p] += 1
        remit = float(remit_amt) if remit_amt else 0.0
        pre = float(pre_amt) if pre_amt else 0.0
        post = float(post_amt) if post_amt else 0.0
        ld = float(loan_day) if loan_day else 0.0
        if is_remit == "1" and remit > 0:
            a["fee_num"] += pre + post
            a["fee_den"] += remit
            st = a["prod_fee"][p]
            st[0] += pre + post
            st[1] += remit
            st[2] += 1
            if ld > 0:
                a["dfee_num"] += pre + post
                a["dfee_den"] += ld
                a["rate_num"] += (pre + post) / remit
                a["rate_den"] += ld
                st[3] += pre + post
                st[4] += ld
                st[5] += (pre + post) / remit
                st[6] += ld

    yms = sorted(monthly)
    top_d0 = Counter()
    top_slot = Counter()
    for ym in yms:
        top_d0.update(monthly[ym]["d0_prod"])
        top_slot.update(monthly[ym]["slot_prod"])
    top_d0_list = [p for p, _ in top_d0.most_common(12)]
    top_slot_list = [p for p, _ in top_slot.most_common(12)]
    top_combo = Counter()
    for ym in yms:
        top_combo.update(monthly[ym]["combo"])
    top_combo_list = [c for c, _ in top_combo.most_common(10)]

    month_rows = []
    for ym in yms:
        a = monthly[ym]
        t0 = a["t0"]
        row = {
            "ym": ym,
            "t0": t0,
            "avg_n_prod": round(a["slots"] / t0, 4) if t0 else None,
            "pct_single": round(100 * a["n1"] / t0, 2) if t0 else None,
            "pct_dual": round(100 * a["n2"] / t0, 2) if t0 else None,
            "avg_term_w": round(a["sum_term"] / a["slots"], 4) if a["slots"] else None,
            "term_mix": {str(k): int(v) for k, v in sorted(a["term_hist"].items())},
            "n_d0": a["n_d0"],
            "d0_apply_pct": round(100 * a["n_d0"] / t0, 2) if t0 else None,
            "apply_rate_pct": round(100 * a["n_apply"] / t0, 2) if t0 else None,
            "d0_fee_pct": round(100 * a["fee_num"] / a["fee_den"], 2) if a["fee_den"] else None,
            "d0_daily_amt": round(a["dfee_num"] / a["dfee_den"], 4) if a["dfee_den"] else None,
            "d0_daily_rate_pct": round(100 * a["rate_num"] / a["rate_den"], 4) if a["rate_den"] else None,
            "d0_share": {p: round(100 * a["d0_prod"][p] / a["n_d0"], 2) if a["n_d0"] else 0 for p in top_d0_list},
            "slot_share": {p: round(100 * a["slot_prod"][p] / a["slots"], 2) if a["slots"] else 0 for p in top_slot_list},
            "combo_share": {c: round(100 * a["combo"][c] / t0, 2) if t0 else 0 for c in top_combo_list},
            "prod_metrics": {},
        }
        for p in top_d0_list:
            st = a["prod_fee"][p]
            n = a["d0_prod"][p]
            row["prod_metrics"][p] = {
                "n": n,
                "share": round(100 * n / a["n_d0"], 2) if a["n_d0"] else 0,
                "fee_pct": round(100 * st[0] / st[1], 2) if st[1] else None,
                "daily_amt": round(st[3] / st[4], 4) if st[4] else None,
                "daily_rate_pct": round(100 * st[5] / st[6], 4) if st[6] else None,
                "n_remit": st[2],
            }
        month_rows.append(row)

    # shift-share on d0 fee vs January
    jan = monthly["2026-01"]
    jan_share = {p: jan["d0_prod"][p] / jan["n_d0"] for p in jan["d0_prod"]}
    jan_fee = {}
    for p, st in jan["prod_fee"].items():
        if st[1]:
            jan_fee[p] = st[0] / st[1]
    fee_decomp = []
    for ym in yms:
        a = monthly[ym]
        actual = a["fee_num"] / a["fee_den"] if a["fee_den"] else None
        # Laspeyres price: jan mix * current fees
        price_hold = 0.0
        w = 0.0
        for p, s in jan_share.items():
            st = a["prod_fee"].get(p)
            if st and st[1]:
                price_hold += s * (st[0] / st[1])
                w += s
        price_hold = price_hold / w if w else None
        # current mix * jan fees
        mix_hold = 0.0
        w2 = 0.0
        for p, n in a["d0_prod"].items():
            if p in jan_fee:
                mix_hold += (n / a["n_d0"]) * jan_fee[p]
                w2 += n / a["n_d0"]
        mix_hold = mix_hold / w2 if w2 else None
        jan_actual = jan["fee_num"] / jan["fee_den"]
        fee_decomp.append({
            "ym": ym,
            "actual_fee_pct": round(100 * actual, 2) if actual is not None else None,
            "jan_mix_curr_price_pct": round(100 * price_hold, 2) if price_hold is not None else None,
            "curr_mix_jan_price_pct": round(100 * mix_hold, 2) if mix_hold is not None else None,
            "price_effect_pp": round(100 * (price_hold - jan_actual), 2) if price_hold is not None else None,
            "mix_effect_pp": round(100 * (mix_hold - jan_actual), 2) if mix_hold is not None else None,
        })

    d0_overall = []
    tot_n = sum(monthly[ym]["d0_prod"][p] for ym in yms for p in monthly[ym]["d0_prod"])
    overall_prod = Counter()
    overall_fee = defaultdict(lambda: [0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, 0])
    for ym in yms:
        a = monthly[ym]
        overall_prod.update(a["d0_prod"])
        for p, st in a["prod_fee"].items():
            o = overall_fee[p]
            for i in range(7):
                o[i] += st[i]
            o[7] += a["d0_prod"][p]
    for p, n in overall_prod.most_common():
        st = overall_fee[p]
        info = term_map.get(p, {})
        d0_overall.append({
            "product_no": p,
            "n": n,
            "share": round(100 * n / tot_n, 2) if tot_n else 0,
            "term": info.get("term"),
            "loan_day": info.get("loan_day"),
            "fee_pct": round(100 * st[0] / st[1], 2) if st[1] else None,
            "daily_amt": round(st[3] / st[4], 4) if st[4] else None,
            "daily_rate_pct": round(100 * st[5] / st[6], 4) if st[6] else None,
        })

    payload = {
        "as_of": "2026-09-17",
        "t0": sum(monthly[ym]["t0"] for ym in yms),
        "n_d0": sum(monthly[ym]["n_d0"] for ym in yms),
        "months": month_rows,
        "fee_decomp": fee_decomp,
        "d0_overall": d0_overall,
        "top_d0": top_d0_list,
        "top_slot": top_slot_list,
        "top_combo": top_combo_list,
        "term_map": {k: v["term"] for k, v in term_map.items() if k in set(top_d0_list + top_slot_list)},
    }
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print("wrote", OUT, "t0", payload["t0"], "d0", payload["n_d0"])
    for r in month_rows:
        print(r["ym"], "t0", r["t0"], "d0", r["d0_apply_pct"], "dual", r["pct_dual"], "term", r["avg_term_w"], "fee", r["d0_fee_pct"])


if __name__ == "__main__":
    main()

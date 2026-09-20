#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
T7+ 召回提单监测看板 · 后端
库：kaby_dw / GaussDB
名单：wangchuanliang.t7recalllist_0818_0819
触达日：recall_date = 2026-08-18
提单：order_loan_f_v2_copy.apply_date >= 触达日，用户去重，不卡到期/放款

用法：
  export PGPASSWORD='...'
  python3 appendix_t7_0818_dashboard.py
输出 t7_0818_dashboard_data.json ，把内容贴进看板页 const DATA。
"""
import json
import os
import psycopg2

HOST = os.environ.get("PGHOST", "47.89.225.85")
PORT = int(os.environ.get("PGPORT", "8000"))
DB = os.environ.get("PGDATABASE", "kaby_dw")
USER = os.environ.get("PGUSER", "wangchuanliang_readonly")
RECALL_DATE = "2026-08-18"
LIST_TABLE = "wangchuanliang.t7recalllist_0818_0819"

SQL_USERS = f"""
SELECT DISTINCT churn_user_id::bigint AS user_id,
       COALESCE(strat, 'NA') AS strat,
       churn_days
FROM {LIST_TABLE}
WHERE churn_user_id IS NOT NULL
  AND recall_date = DATE '{RECALL_DATE}'
"""

SQL_DAILY = f"""
WITH u AS ({SQL_USERS}),
fa AS (
  SELECT o.user_id, MIN(o.apply_date) AS first_apply
  FROM u
  INNER JOIN wangchuanliang.order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
  GROUP BY 1
)
SELECT first_apply, COUNT(*) AS n
FROM fa GROUP BY 1 ORDER BY 1
"""

SQL_STRAT = f"""
WITH u AS ({SQL_USERS})
SELECT u.strat, COUNT(*) AS n_user, COUNT(a.user_id) AS n_apply
FROM u
LEFT JOIN (
  SELECT DISTINCT o.user_id
  FROM u
  INNER JOIN wangchuanliang.order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
) a ON a.user_id = u.user_id
GROUP BY 1 ORDER BY n_user DESC
"""

SQL_CHURN = f"""
WITH u AS ({SQL_USERS})
SELECT
  CASE
    WHEN churn_days <= 15 THEN '7-15d'
    WHEN churn_days <= 30 THEN '16-30d'
    WHEN churn_days <= 60 THEN '31-60d'
    WHEN churn_days <= 90 THEN '61-90d'
    WHEN churn_days <= 180 THEN '91-180d'
    ELSE '180d+'
  END AS bin,
  COUNT(*) AS n_user,
  COUNT(a.user_id) AS n_apply
FROM u
LEFT JOIN (
  SELECT DISTINCT o.user_id
  FROM u
  INNER JOIN wangchuanliang.order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
) a ON a.user_id = u.user_id
GROUP BY 1
"""

CHURN_ORDER = ["7-15d", "16-30d", "31-60d", "61-90d", "91-180d", "180d+"]


def fetch():
    pwd = os.environ.get("PGPASSWORD")
    if not pwd:
        raise SystemExit("请先设置环境变量 PGPASSWORD")
    conn = psycopg2.connect(
        host=HOST, port=PORT, dbname=DB, user=USER, password=pwd,
        connect_timeout=30, options="-c statement_timeout=180000",
    )
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute(f"SELECT COUNT(*) FROM ({SQL_USERS}) t")
    n_user = int(cur.fetchone()[0])

    cur.execute(SQL_DAILY)
    daily = []
    cum = 0
    for d, n in cur.fetchall():
        n = int(n)
        cum += n
        daily.append({
            "d": str(d), "n": n, "cum": cum,
            "rate": round(100.0 * cum / n_user, 2),
        })

    cur.execute(SQL_STRAT)
    strat = []
    for s, nu, na in cur.fetchall():
        nu, na = int(nu), int(na)
        strat.append({
            "strat": s, "n_user": nu, "n_apply": na,
            "pct": round(100.0 * na / nu, 2) if nu else 0,
        })

    cur.execute(SQL_CHURN)
    raw = {
        r[0]: {"bin": r[0], "n_user": int(r[1]), "n_apply": int(r[2]),
               "pct": round(100.0 * float(r[2]) / float(r[1]), 2) if r[1] else 0}
        for r in cur.fetchall()
    }
    churn = [raw[k] for k in CHURN_ORDER if k in raw]
    conn.close()

    n_apply = daily[-1]["cum"] if daily else 0
    return {
        "kpi": {
            "n_user": n_user,
            "n_apply": n_apply,
            "rate": round(100.0 * n_apply / n_user, 2) if n_user else 0,
            "recall_date": RECALL_DATE,
            "as_of": daily[-1]["d"] if daily else None,
        },
        "daily": daily,
        "strat": strat,
        "churn": churn,
    }


if __name__ == "__main__":
    data = fetch()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t7_0818_dashboard_data.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("wrote", out)
    print("kpi", data["kpi"])

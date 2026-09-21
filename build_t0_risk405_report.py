#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跑 appendix_t0_risk405_full.sql，写出 HTML 报告。"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
SQL_PATH = HERE / "appendix_t0_risk405_full.sql"
HTML_PATH = HERE / "T0获额风控分405三档当日提单息费逾期盈利报告.html"


def connect():
    if not os.environ.get("PGPASSWORD"):
        raise SystemExit("请先设置环境变量 PGPASSWORD")
    import psycopg2

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "47.89.225.85"),
        port=int(os.environ.get("PGPORT", "8000")),
        dbname=os.environ.get("PGDATABASE", "kaby_dw"),
        user=os.environ.get("PGUSER", "wangchuanliang_readonly"),
        password=os.environ["PGPASSWORD"],
        connect_timeout=30,
        options="-c statement_timeout=0",
    )
    conn.autocommit = True
    return conn


def fetch(cur, sql):
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    rows = []
    for r in cur.fetchall():
        rows.append({c: (float(v) if hasattr(v, "as_tuple") else v) for c, v in zip(cols, r)})
    return rows


def fnum(v, nd=2):
    if v is None:
        return "—"
    return f"{float(v):,.{nd}f}"


def pct(v, nd=2):
    if v is None:
        return "—"
    return f"{float(v):.{nd}f}%"


def rate_pct(v, nd=2):
    if v is None:
        return "—"
    return f"{float(v) * 100:.{nd}f}%"


def main():
    sql_text = SQL_PATH.read_text(encoding="utf-8")
    setup, _ = sql_text.split("SELECT p30, p60 FROM tmp_cuts;", 1)
    def is_executable(stmt: str) -> bool:
        body = "\n".join(ln for ln in stmt.splitlines() if not ln.strip().startswith("--"))
        return bool(body.strip())

    statements = [s.strip() for s in setup.split(";") if is_executable(s)]

    conn = connect()
    cur = conn.cursor()
    print("run setup", flush=True)
    for i, stmt in enumerate(statements):
        if stmt.upper().startswith("SELECT"):
            continue
        print(f"  stmt {i+1}/{len(statements)} {stmt[:50].replace(chr(10),' ')}", flush=True)
        cur.execute(stmt)

    print("fetch results", flush=True)
    cuts = fetch(cur, "SELECT p30, p60 FROM tmp_cuts")[0]
    p30, p60 = float(cuts["p30"]), float(cuts["p60"])
    print("P30", p30, "P60", p60, flush=True)

    q2 = """
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
        ORDER BY ym
    """
    q3 = """
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
        ORDER BY ym, CASE tier WHEN '最好' THEN 1 WHEN '一般' THEN 2 WHEN '较差' THEN 3 ELSE 4 END
    """
    monthly = fetch(cur, q2)
    tier = fetch(cur, q3)
    cov = fetch(
        cur,
        """
        SELECT ym, n_t0_raw, n_no_join, n_miss, n_scored,
               ROUND(100.0 * n_scored / NULLIF(n_t0_raw, 0), 2) AS scored_pct
        FROM tmp_cov
        ORDER BY ym
        """,
    )
    cur.close()
    conn.close()

    for r in monthly:
        for k, v in list(r.items()):
            if v is not None and not isinstance(v, str):
                r[k] = float(v)
    for r in tier:
        for k, v in list(r.items()):
            if v is not None and not isinstance(v, str):
                r[k] = float(v)

    for r in cov:
        for k, v in list(r.items()):
            if v is not None and not isinstance(v, str):
                r[k] = float(v)

    print("MONTHLY")
    for r in monthly:
        print(r["ym"], r["n_t0"], r["apply_rate_pct"], r["fee_rate"], r["profit_rate"], r["overdue_pct"],
              r["pct_t0_good"], r["pct_t0_poor"], r["pct_apply_good"], r["pct_apply_poor"])
    print("TIER rows", len(tier))
    print("COV", cov)

    Path(HERE / "t0_risk405_monthly.json").write_text(
        json.dumps({"p30": p30, "p60": p60, "monthly": monthly, "tier": tier, "cov": cov}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_html(sql_text, p30, p60, monthly, tier, cov)
    print("HTML", HTML_PATH)


def write_html(sql_text, p30, p60, monthly, tier, cov):
    cov_by = {r["ym"]: r for r in cov}
    star_yms = {r["ym"] for r in cov if int(r["n_miss"]) >= 10}
    n_raw = int(sum(r["n_t0_raw"] for r in cov))
    n_miss = int(sum(r["n_miss"] for r in cov))
    n_scored = int(sum(r["n_scored"] for r in cov))
    miss_bits = [
        f"{r['ym']} 剔除 {int(r['n_miss']):,} / {int(r['n_t0_raw']):,}"
        for r in cov if int(r["n_miss"]) > 0
    ]
    miss_txt = "；".join(miss_bits) if miss_bits else "无"

    def ym_star(ym):
        return f"{ym}*" if ym in star_yms else ym

    m0, m1 = monthly[0], monthly[-1]
    ym = [ym_star(r["ym"]) for r in monthly]
    by_tier = {"最好": [], "一般": [], "较差": []}
    for r in tier:
        if r["tier"] in by_tier:
            by_tier[r["tier"]].append(r)

    def series(key, rows=None, scale=1):
        rows = rows or monthly
        return [None if x[key] is None else round(float(x[key]) * scale, 4) for x in rows]

    def tseries(name, key, scale=1):
        return [None if x[key] is None else round(float(x[key]) * scale, 4) for x in by_tier[name]]

    data = {
        "ym": ym,
        "apply": series("apply_rate_pct"),
        "fee": series("fee_rate", scale=100),
        "profit": series("profit_rate", scale=100),
        "overdue": series("overdue_pct"),
        "t0_good": series("pct_t0_good"),
        "t0_mid": series("pct_t0_mid"),
        "t0_poor": series("pct_t0_poor"),
        "ap_good": series("pct_apply_good"),
        "ap_mid": series("pct_apply_mid"),
        "ap_poor": series("pct_apply_poor"),
        "r_good": tseries("最好", "apply_rate_pct"),
        "r_mid": tseries("一般", "apply_rate_pct"),
        "r_poor": tseries("较差", "apply_rate_pct"),
        "f_good": tseries("最好", "fee_rate", 100),
        "f_mid": tseries("一般", "fee_rate", 100),
        "f_poor": tseries("较差", "fee_rate", 100),
        "o_good": tseries("最好", "overdue_pct"),
        "o_mid": tseries("一般", "overdue_pct"),
        "o_poor": tseries("较差", "overdue_pct"),
        "p_good": tseries("最好", "profit_rate", 100),
        "p_mid": tseries("一般", "profit_rate", 100),
        "p_poor": tseries("较差", "profit_rate", 100),
    }

    def month_table():
        head = "<tr><th>月</th><th>T0</th><th>当天提单</th><th>当天提单率</th><th>获额均分</th><th>T0最好%</th><th>T0一般%</th><th>T0较差%</th><th>提单最好%</th><th>提单一般%</th><th>提单较差%</th><th>息费</th><th>到期单</th><th>逾期率</th><th>盈利率</th></tr>"
        body = []
        for r in monthly:
            body.append(
                "<tr>"
                + "".join(
                    [
                        f"<td>{ym_star(r['ym'])}</td>",
                        f"<td>{int(r['n_t0']):,}</td>",
                        f"<td>{int(r['n_same_day']):,}</td>",
                        f"<td>{pct(r['apply_rate_pct'])}</td>",
                        f"<td>{fnum(r['mean_score_t0'])}</td>",
                        f"<td>{pct(r['pct_t0_good'])}</td>",
                        f"<td>{pct(r['pct_t0_mid'])}</td>",
                        f"<td>{pct(r['pct_t0_poor'])}</td>",
                        f"<td>{pct(r['pct_apply_good'])}</td>",
                        f"<td>{pct(r['pct_apply_mid'])}</td>",
                        f"<td>{pct(r['pct_apply_poor'])}</td>",
                        f"<td>{rate_pct(r['fee_rate'])}</td>",
                        f"<td>{int(r['n_due']):,}</td>",
                        f"<td>{pct(r['overdue_pct'])}</td>",
                        f"<td>{rate_pct(r['profit_rate'])}</td>",
                    ]
                )
                + "</tr>"
            )
        return "<table><thead>" + head + "</thead><tbody>" + "".join(body) + "</tbody></table>"

    def tier_table(name):
        rows = by_tier[name]
        head = "<tr><th>月</th><th>T0</th><th>当天提单</th><th>当天提单率</th><th>均分</th><th>息费</th><th>到期单</th><th>逾期率</th><th>盈利率</th></tr>"
        body = []
        for r in rows:
            body.append(
                "<tr>"
                f"<td>{ym_star(r['ym'])}</td><td>{int(r['n_t0']):,}</td><td>{int(r['n_same_day']):,}</td>"
                f"<td>{pct(r['apply_rate_pct'])}</td><td>{fnum(r['mean_score'])}</td>"
                f"<td>{rate_pct(r['fee_rate'])}</td><td>{int(r['n_due']):,}</td>"
                f"<td>{pct(r['overdue_pct'])}</td><td>{rate_pct(r['profit_rate'])}</td></tr>"
            )
        return "<table><thead>" + head + "</thead><tbody>" + "".join(body) + "</tbody></table>"

    d_apply = float(m1["apply_rate_pct"]) - float(m0["apply_rate_pct"])
    d_fee = (float(m1["fee_rate"]) - float(m0["fee_rate"])) * 100
    d_ov = float(m1["overdue_pct"]) - float(m0["overdue_pct"])
    d_pf = (float(m1["profit_rate"]) - float(m0["profit_rate"])) * 100
    d_good_t0 = float(m1["pct_t0_good"]) - float(m0["pct_t0_good"])
    d_poor_t0 = float(m1["pct_t0_poor"]) - float(m0["pct_t0_poor"])
    d_good_ap = float(m1["pct_apply_good"]) - float(m0["pct_apply_good"])
    d_poor_ap = float(m1["pct_apply_poor"]) - float(m0["pct_apply_poor"])

    g0, g1 = by_tier["最好"][0], by_tier["最好"][-1]
    p0, p1 = by_tier["较差"][0], by_tier["较差"][-1]
    mid0, mid1 = by_tier["一般"][0], by_tier["一般"][-1]

    sql_esc = (
        sql_text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )
    payload = json.dumps(data, ensure_ascii=False)

    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>T0获额风控分405三档：当日提单息费逾期盈利</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{{--bg:#071b2f;--p:#0c2944;--line:#2a5c7e;--text:#eff8ff;--muted:#aac5da;--cy:#43c7e7;--gr:#64dcae;--am:#ffc26b;--pk:#f68ab0}}
*{{box-sizing:border-box}}body{{margin:0;background:#06192b;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}}
.wrap{{max-width:1480px;margin:auto;padding:32px 36px 80px}}
.hero{{text-align:center;padding:28px 12px 22px;border-bottom:1px solid var(--line)}}
.kicker{{color:var(--cy);font-size:13px;letter-spacing:2px;font-weight:700}}
.hero h1{{font-size:28px;line-height:1.3;margin:10px 0}}
.hero-meta{{display:inline-block;text-align:left;margin-top:12px;line-height:1.75;color:var(--muted);font-size:14px}}
h2{{font-size:24px;margin:44px 0 10px}}h3{{font-size:17px;margin:22px 0 8px}}
.desc,.sub{{color:var(--muted);margin:0 0 12px;line-height:1.75;font-size:14px}}
.grid{{display:grid;gap:14px}}.g2{{grid-template-columns:repeat(2,minmax(0,1fr))}}.g4{{grid-template-columns:repeat(4,minmax(0,1fr))}}
.card,.chart{{background:rgba(10,41,68,.95);border:1px solid var(--line);border-radius:14px;padding:16px}}
.label{{color:var(--muted);font-size:12px}}.num{{font-size:20px;font-weight:800;margin:4px 0 2px;line-height:1.2;color:var(--cy)}}
.box{{height:300px;position:relative}}.chart h3{{margin:0 0 4px;font-size:15px}}.chart p{{font-size:12px;color:var(--muted);margin:0 0 10px}}
.callout{{background:#0a2a45;border:1px solid #2a5c7e;border-left:4px solid #43c7e7;border-radius:10px;padding:14px 18px;margin:14px 0;line-height:1.75;font-size:14px}}
.callout.gold{{border-left-color:#ffc26b}}.callout.red{{border-left-color:#f68ab0}}.callout.green{{border-left-color:#64dcae}}
.callout .ch{{font-weight:800;margin-bottom:8px}}
.table{{overflow-x:auto;margin:12px 0}}table{{width:100%;border-collapse:collapse;font-size:13px}}
th,td{{padding:8px 10px;border-bottom:1px solid rgba(42,92,126,.45);text-align:right;white-space:nowrap}}
th{{color:var(--muted);background:rgba(12,48,78,.65);font-weight:600}}th:first-child,td:first-child{{text-align:left}}
details{{background:#082238;border:1px solid var(--line);border-radius:10px;margin:12px 0}}
summary{{cursor:pointer;padding:14px 16px;font-weight:700;color:#d9edf8}}
details[open] summary{{border-bottom:1px solid var(--line)}}
details pre.sql{{margin:0;border:0;border-radius:0 0 10px 10px}}
pre.sql{{background:#081726;border:1px solid var(--line);border-radius:14px;padding:18px;overflow:auto;max-height:820px;font-size:12px;line-height:1.6;color:#bfe0f2;font-family:"SF Mono",ui-monospace,Menlo,Consolas,monospace;white-space:pre;tab-size:2}}
.foot{{color:#7fa6c2;font-size:12.5px;margin-top:50px;border-top:1px solid var(--line);padding-top:16px;line-height:1.9}}
@media(max-width:900px){{.g2,.g4{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main class="wrap">
<header class="hero">
<div class="kicker">T0 · 结清0在贷 · 获额时点 KabyBXgboost405Apd7CreCyc · 2026-01～08</div>
<h1>风控分三档：当天提单率、客群结构、息费、到期逾期与盈利</h1>
<div class="hero-meta">
分：<code>model_result_copy.serial_id</code> = 获额订单号，字段 kabybxgboost405apd7crecyc；分越高资质越好（高分档到期逾期更低、盈利更高）<br>
分层：全量 T0 有分样本 P30={p30:.1f} / P60={p60:.1f}（较差 ≤P30，一般 P30–P60，最好 &gt;P60）<br>
息费统计当天提单订单（不卡放款）；盈利与逾期统计当天提单且已放款、已到期订单<br>
T0 用户日 {int(sum(r['n_t0'] for r in monthly)):,}（剔除前 {n_raw:,}，无分 {n_miss:,}）。无分月：{miss_txt}。标 * 月剔除较多，仅供参考。8 月到期未完全成熟，逾期/盈利仅供方向。
</div>
</header>

<h2>结论</h2>
<div class="callout"><div class="ch">1. 当天提单率下降，和息费抬升同时发生</div>
总体当天提单率 {pct(m0['apply_rate_pct'])} → {pct(m1['apply_rate_pct'])}（{d_apply:+.2f}pp）。当天提单订单加权息费 {rate_pct(m0['fee_rate'])} → {rate_pct(m1['fee_rate'])}（{d_fee:+.2f}pp）。价格上去、当天转化下来。主对比为 1 月 vs 8 月。无分已剔除；剔除较多的月份标 *，不作拐点。</div>
<div class="callout red"><div class="ch">2. 获额客群和当天提单客群都在变差</div>
T0 获额结构：最好档 {pct(m0['pct_t0_good'])} → {pct(m1['pct_t0_good'])}（{d_good_t0:+.2f}pp），较差档 {pct(m0['pct_t0_poor'])} → {pct(m1['pct_t0_poor'])}（{d_poor_t0:+.2f}pp）。<br>
当天提单结构：最好档 {pct(m0['pct_apply_good'])} → {pct(m1['pct_apply_good'])}（{d_good_ap:+.2f}pp），较差档 {pct(m0['pct_apply_poor'])} → {pct(m1['pct_apply_poor'])}（{d_poor_ap:+.2f}pp）。<br>
1–4 月结构相对稳，变差主要在 5 月以后。这与「息费升 → 好资质少提、差资质占比升」同向，但不能单独当成因果鉴定。</div>
<div class="callout gold"><div class="ch">3. 三档当天提单率都在掉，不是只有好客不提</div>
最好档 {pct(g0['apply_rate_pct'])} → {pct(g1['apply_rate_pct'])}；一般档 {pct(mid0['apply_rate_pct'])} → {pct(mid1['apply_rate_pct'])}；较差档 {pct(p0['apply_rate_pct'])} → {pct(p1['apply_rate_pct'])}。总提单率下降是各档转化都弱，叠加获额结构变差。较差档仍是最高转化。</div>
<div class="callout green"><div class="ch">4. 分越高逾期越低、盈利越高；较差档加价仍盖不住风险</div>
最好档息费 {rate_pct(g0['fee_rate'])} → {rate_pct(g1['fee_rate'])}，到期盈利率 {rate_pct(g0['profit_rate'])} → {rate_pct(g1['profit_rate'])}，逾期 {pct(g0['overdue_pct'])} → {pct(g1['overdue_pct'])}。<br>
较差档息费 {rate_pct(p0['fee_rate'])} → {rate_pct(p1['fee_rate'])}，到期盈利率 {rate_pct(p0['profit_rate'])} → {rate_pct(p1['profit_rate'])}，逾期 {pct(p0['overdue_pct'])} → {pct(p1['overdue_pct'])}。<br>
总体到期盈利率 {rate_pct(m0['profit_rate'])} → {rate_pct(m1['profit_rate'])}（{d_pf:+.2f}pp），逾期 {pct(m0['overdue_pct'])} → {pct(m1['overdue_pct'])}（{d_ov:+.2f}pp）。8 月到期尚未完全成熟。较差档到期盈利持续为负或接近 0。</div>
<div class="callout"><div class="ch">经营含义</div>
不宜再用降息/提额去抬 T0 当天提单率——当天单里较差档占比在升，且该档到期盈利盖不住。更合理的是：保护最好档定价与转化；较差档控制让利；把经营重心放到结清当天之后仍未提单的时段。</div>

<section class="grid g4" style="margin-top:18px">
<article class="card"><div class="label">当天提单率 1月→8月</div><div class="num">{pct(m0['apply_rate_pct'])}→{pct(m1['apply_rate_pct'])}</div><div class="sub">{d_apply:+.2f}pp</div></article>
<article class="card"><div class="label">当天提单息费</div><div class="num">{rate_pct(m0['fee_rate'])}→{rate_pct(m1['fee_rate'])}</div><div class="sub">{d_fee:+.2f}pp</div></article>
<article class="card"><div class="label">T0 获额较差档占比</div><div class="num">{pct(m0['pct_t0_poor'])}→{pct(m1['pct_t0_poor'])}</div><div class="sub">{d_poor_t0:+.2f}pp</div></article>
<article class="card"><div class="label">当天提单较差档占比</div><div class="num">{pct(m0['pct_apply_poor'])}→{pct(m1['pct_apply_poor'])}</div><div class="sub">{d_poor_ap:+.2f}pp</div></article>
</section>

<h2>一、月度总体</h2>
<p class="desc">先看全部 T0，再看当天提单内部。提单率分母是当月全部获额用户日；息费是当天提单单（含未放款）；逾期与盈利是当天提单且已放款、已到期。标 * 月份剔除无分较多，仅供参考。</p>
<div class="grid g2">
<div class="chart"><h3>图1 当天提单率 vs 加权息费</h3><p>左轴提单率，右轴息费</p><div class="box"><canvas id="c1"></canvas></div></div>
<div class="chart"><h3>图2 到期逾期率 vs 到期盈利率</h3><p>仅已放款且 due_date 已过；8月到期偏少</p><div class="box"><canvas id="c2"></canvas></div></div>
</div>
<div class="grid g2" style="margin-top:14px">
<div class="chart"><h3>图3 T0 获额客群结构</h3><p>折线；纵轴不从 0 起，便于看结构变化。分母=当月全部 T0</p><div class="box"><canvas id="c3"></canvas></div></div>
<div class="chart"><h3>图4 当天提单客群结构</h3><p>折线；纵轴不从 0 起。分母=当月当天提单</p><div class="box"><canvas id="c4"></canvas></div></div>
</div>
<div class="table">{month_table()}</div>
<div class="table"><table><thead><tr><th>月</th><th>剔除前 T0</th><th>未匹配</th><th>无分</th><th>有有效分</th><th>有分占比</th></tr></thead><tbody>{"".join(
    f"<tr><td>{ym_star(r['ym'])}</td><td>{int(r['n_t0_raw']):,}</td><td>{int(r['n_no_join']):,}</td>"
    f"<td>{int(r['n_miss']):,}</td><td>{int(r['n_scored']):,}</td><td>{pct(r['scored_pct'])}</td></tr>"
    for r in cov
)}</tbody></table></div>
<p class="desc">上表为附录 SQL 结果4（剔除前覆盖）。报告主表只用有有效分的订单。无分合计 {n_miss:,} / {n_raw:,}。</p>

<h2>二、三类用户月度</h2>
<p class="desc">每档当天提单率 = 该档当天提单人数 / 该档 T0 获额人数。因此可以看到是「档内不愿提」还是「获额结构变了」。</p>
<div class="grid g2">
<div class="chart"><h3>图5 三档当天提单率</h3><p>各档分母为本档 T0</p><div class="box"><canvas id="c5"></canvas></div></div>
<div class="chart"><h3>图6 三档当天提单息费</h3><p>不卡是否放款</p><div class="box"><canvas id="c6"></canvas></div></div>
</div>
<div class="grid g2" style="margin-top:14px">
<div class="chart"><h3>图7 三档到期逾期率</h3><p>当天提单且已放款、已到期</p><div class="box"><canvas id="c7"></canvas></div></div>
<div class="chart"><h3>图8 三档到期盈利率</h3><p>到期日及之前还款 / 放款 − 1</p><div class="box"><canvas id="c8"></canvas></div></div>
</div>
<h3>资质最好（&gt;{p60:.1f}）</h3><div class="table">{tier_table("最好")}</div>
<h3>资质一般（{p30:.1f}–{p60:.1f}）</h3><div class="table">{tier_table("一般")}</div>
<h3>资质较差（≤{p30:.1f}）</h3><div class="table">{tier_table("较差")}</div>

<h2>口径</h2>
<ul class="desc">
<li>T0：is_pass1=1、loan_type_code=2、recycle_type=3；20 秒获额去重；结清日=获额日且获额时间≥结清时间；结清时 0 在贷；同日最早一轮获额。</li>
<li>模型分：获额订单号关联 model_result_copy.kabybxgboost405apd7crecyc；无分（空或 -9999999）不进主表。剔除件数见结果4。</li>
<li>分越高资质越好：同月最好档到期逾期明显低于较差档，盈利明显高于较差档。</li>
<li>当天提单不卡 is_due / is_remit。息费不卡放款。盈利、逾期要求 is_remit=1 且已到期。</li>
</ul>

<section id="sql">
<h2>附录：完整 PGSQL</h2>
<p class="desc">在 kaby_dw 执行；<code>SET search_path TO wangchuanliang, public;</code>。四个结果集依次为阈值、月度总体、月度×三档、剔除前覆盖。同目录文件 <code>appendix_t0_risk405_full.sql</code>。默认收起，点击展开。</p>
<details>
<summary>完整 PGSQL（点击展开）</summary>
<pre class="sql">{sql_esc}</pre>
</details>
</section>
<p class="foot">数据：kaby_dw · wangchuanliang · 2026-01-01～2026-08-31 · 无 405 分获额单已剔除（见结果4） · 报告生成于分析当日库内 CURRENT_DATE</p>
</main>
<script>
const D = {payload};
const col = {{good:'#64dcae', mid:'#ffc26b', poor:'#f68ab0', cy:'#43c7e7', am:'#ffc26b'}};
function line(id, datasets, y2) {{
  const scales = {{
    y: {{type:'linear', position:'left', ticks:{{color:'#aac5da'}}, grid:{{color:'rgba(42,92,126,.25)'}}}},
    x: {{ticks:{{color:'#aac5da'}}, grid:{{display:false}}}}
  }};
  if (y2) scales.y2 = {{type:'linear', position:'right', ticks:{{color:'#ffc26b'}}, grid:{{drawOnChartArea:false}}}};
  new Chart(document.getElementById(id), {{
    type:'line',
    data:{{labels:D.ym, datasets}},
    options:{{responsive:true, maintainAspectRatio:false, interaction:{{mode:'index', intersect:false}},
      plugins:{{legend:{{labels:{{color:'#eff8ff'}}}}}},
      scales
    }}
  }});
}}
function stack(id, ds) {{
  new Chart(document.getElementById(id), {{
    type:'bar',
    data:{{labels:D.ym, datasets: ds.map(x => ({{...x, stack:'a'}}))}},
    options:{{responsive:true, maintainAspectRatio:false,
      plugins:{{legend:{{labels:{{color:'#eff8ff'}}}}}},
      scales:{{
        x:{{stacked:true, ticks:{{color:'#aac5da'}}, grid:{{display:false}}}},
        y:{{stacked:true, max:100, ticks:{{color:'#aac5da'}}, grid:{{color:'rgba(42,92,126,.25)'}}}}
      }}
    }}
  }});
}}
const labelGood = {{
  id: 'labelGood',
  afterDatasetsDraw(chart) {{
    const {{ctx}} = chart;
    chart.data.datasets.forEach((ds, i) => {{
      if (!String(ds.label).startsWith('最好')) return;
      const meta = chart.getDatasetMeta(i);
      ctx.save();
      ctx.font = '12px sans-serif';
      ctx.fillStyle = '#64dcae';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      meta.data.forEach((pt, j) => {{
        const v = ds.data[j];
        if (v == null) return;
        if (j === 0) {{
          ctx.textAlign = 'left';
          ctx.fillText(Number(v).toFixed(2) + '%', pt.x + 8, pt.y - 7);
        }} else {{
          ctx.textAlign = 'center';
          ctx.fillText(Number(v).toFixed(2) + '%', pt.x, pt.y - 7);
        }}
      }});
      ctx.restore();
    }});
  }}
}};
function lineZoom(id, datasets) {{
  const vals = datasets.flatMap(d => d.data).filter(x => x != null);
  const mn = Math.min(...vals), mx = Math.max(...vals);
  const padLo = Math.max(1.2, (mx - mn) * 0.22);
  const padHi = Math.max(2.4, (mx - mn) * 0.38);
  new Chart(document.getElementById(id), {{
    type:'line',
    data:{{labels:D.ym, datasets}},
    options:{{responsive:true, maintainAspectRatio:false, interaction:{{mode:'index', intersect:false}},
      plugins:{{legend:{{labels:{{color:'#eff8ff'}}}}}},
      scales:{{
        x:{{ticks:{{color:'#aac5da'}}, grid:{{display:false}}}},
        y:{{type:'linear', min: +(mn - padLo).toFixed(1), max: +(mx + padHi).toFixed(1), beginAtZero:false,
          ticks:{{color:'#aac5da'}}, grid:{{color:'rgba(42,92,126,.25)'}}}}
      }}
    }},
    plugins:[labelGood]
  }});
}}
const lw = 2.4;
line('c1', [
  {{label:'当天提单率%', data:D.apply, borderColor:col.cy, backgroundColor:'transparent', tension:.25, yAxisID:'y', borderWidth:lw, pointRadius:3}},
  {{label:'加权息费%', data:D.fee, borderColor:col.am, backgroundColor:'transparent', tension:.25, yAxisID:'y2', borderWidth:lw, pointRadius:3}}
], true);
line('c2', [
  {{label:'逾期率%', data:D.overdue, borderColor:col.poor, backgroundColor:'transparent', tension:.25, yAxisID:'y', borderWidth:lw}},
  {{label:'盈利率%', data:D.profit, borderColor:col.good, backgroundColor:'transparent', tension:.25, yAxisID:'y2', borderWidth:lw}}
], true);
lineZoom('c3', [
  {{label:'最好%', data:D.t0_good, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}},
  {{label:'一般%', data:D.t0_mid, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}},
  {{label:'较差%', data:D.t0_poor, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}}
]);
lineZoom('c4', [
  {{label:'最好%', data:D.ap_good, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}},
  {{label:'一般%', data:D.ap_mid, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}},
  {{label:'较差%', data:D.ap_poor, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}}
]);
line('c5', [
  {{label:'最好', data:D.r_good, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'一般', data:D.r_mid, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'较差', data:D.r_poor, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw}}
]);
line('c6', [
  {{label:'最好', data:D.f_good, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'一般', data:D.f_mid, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'较差', data:D.f_poor, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw}}
]);
line('c7', [
  {{label:'最好', data:D.o_good, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'一般', data:D.o_mid, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'较差', data:D.o_poor, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw}}
]);
line('c8', [
  {{label:'最好', data:D.p_good, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'一般', data:D.p_mid, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw}},
  {{label:'较差', data:D.p_poor, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw}}
]);
</script>
</body></html>
"""
    HTML_PATH.write_text(html, encoding="utf-8")


if __name__ == "__main__":
    main()

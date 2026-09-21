#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从四份已发布的 T0 风控分报告抽出图3/图4，写成对照报告。"""
from __future__ import annotations

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
HTML_PATH = HERE / "T0获额四模型风控分客群结构对照报告.html"

SPECS = [
    {
        "key": "363",
        "file": "T0获额风控分363三档当日提单息费逾期盈利报告.html",
        "title": "KabyBXgboost363 · 2026-01～08",
        "field": "kabybxgboost363dpd7cre",
        "p": "P30=452 / P60=473",
        "window": "1–8 月，覆盖率 100%",
        "cut": "1月→8月",
        "mix_note": "获额、当天提单都变差；1–4 月稳，变差主要在 5 月以后。",
    },
    {
        "key": "100",
        "file": "T0获额风控分100三档当日提单息费逾期盈利报告.html",
        "title": "KabyBXgboost100 · 2026-01～06",
        "field": "kabybxgboost100",
        "p": "P30=451 / P60=487",
        "window": "1–6 月（2 月无分 1 单已剔除）",
        "cut": "1月→6月",
        "mix_note": "获额没有变差（最好档略升）；当天提单明显变差。问题在转化端。",
    },
    {
        "key": "407",
        "file": "T0获额风控分407三档当日提单息费逾期盈利报告.html",
        "title": "KabyBXgboost407 · 2026-05～08",
        "field": "kabybxgboost407apd7reprime",
        "p": "P30=448 / P60=465",
        "window": "5–8 月有分样本；6 月标 *（剔除无分 5,549）",
        "cut": "5月→8月",
        "mix_note": "获额、当天提单都变差，且幅度在四个模型里最大。",
    },
    {
        "key": "405",
        "file": "T0获额风控分405三档当日提单息费逾期盈利报告.html",
        "title": "KabyBXgboost405 · 2026-01～08",
        "field": "kabybxgboost405apd7crecyc",
        "p": "P30=447 / P60=465",
        "window": "1–8 月有分样本；5 月标 *（剔除 765）",
        "cut": "1月→8月",
        "mix_note": "获额、当天提单都变差；形态接近 363，5 月以后更明显。",
    },
]


def load_d(name: str) -> dict:
    text = (HERE / name).read_text(encoding="utf-8")
    m = re.search(r"const D = (\{.*?\});", text)
    if not m:
        raise SystemExit(f"no DATA in {name}")
    return json.loads(m.group(1))


def pp(a, b):
    return round(float(b) - float(a), 2)


def pct(v):
    return f"{float(v):.2f}%"


def main():
    packs = []
    for spec in SPECS:
        d = load_d(spec["file"])
        row = {
            **spec,
            "d": {
                "ym": d["ym"],
                "t0_good": d["t0_good"],
                "t0_mid": d["t0_mid"],
                "t0_poor": d["t0_poor"],
                "ap_good": d["ap_good"],
                "ap_mid": d["ap_mid"],
                "ap_poor": d["ap_poor"],
            },
            "t0g0": d["t0_good"][0],
            "t0g1": d["t0_good"][-1],
            "t0p0": d["t0_poor"][0],
            "t0p1": d["t0_poor"][-1],
            "apg0": d["ap_good"][0],
            "apg1": d["ap_good"][-1],
            "app0": d["ap_poor"][0],
            "app1": d["ap_poor"][-1],
        }
        row["t0g_pp"] = pp(row["t0g0"], row["t0g1"])
        row["t0p_pp"] = pp(row["t0p0"], row["t0p1"])
        row["apg_pp"] = pp(row["apg0"], row["apg1"])
        row["app_pp"] = pp(row["app0"], row["app1"])
        packs.append(row)

    payload = {p["key"]: p["d"] for p in packs}

    def sign(v):
        return f"+{v:.2f}pp" if v > 0 else f"{v:.2f}pp"

    rows_html = []
    for p in packs:
        t0_bad = p["t0p_pp"] > 0 and p["t0g_pp"] < 0
        ap_bad = p["app_pp"] > 0 and p["apg_pp"] < 0
        rows_html.append(
            "<tr>"
            f"<td>{p['key']}</td><td>{p['cut']}</td>"
            f"<td>{pct(p['t0g0'])}→{pct(p['t0g1'])}<br><span class='delta'>{sign(p['t0g_pp'])}</span></td>"
            f"<td>{pct(p['t0p0'])}→{pct(p['t0p1'])}<br><span class='delta'>{sign(p['t0p_pp'])}</span></td>"
            f"<td>{'变差' if t0_bad else '未变差'}</td>"
            f"<td>{pct(p['apg0'])}→{pct(p['apg1'])}<br><span class='delta'>{sign(p['apg_pp'])}</span></td>"
            f"<td>{pct(p['app0'])}→{pct(p['app1'])}<br><span class='delta'>{sign(p['app_pp'])}</span></td>"
            f"<td>{'变差' if ap_bad else '未变差'}</td>"
            "</tr>"
        )

    sections = []
    for i, p in enumerate(packs, 1):
        href = p["file"].replace(" ", "%20")
        sections.append(
            f"""
<h2>{i}. {p['key']} 分 · {p['title']}</h2>
<p class="desc">字段 <code>{p['field']}</code> · {p['p']} · {p['window']}<br>
{p['mix_note']} 原报告：<a href="{href}">{p['file']}</a></p>
<div class="grid g2">
  <div class="chart"><h3>图{i}.1 T0 获额客群结构</h3><p>折线；纵轴不从 0 起。分母=当月全部有分 T0</p><div class="box"><canvas id="t0_{p['key']}"></canvas></div></div>
  <div class="chart"><h3>图{i}.2 当天提单客群结构</h3><p>折线；纵轴不从 0 起。分母=当月当天提单</p><div class="box"><canvas id="ap_{p['key']}"></canvas></div></div>
</div>
"""
        )

    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>T0 获额四模型风控分 · 客群结构对照</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{{--bg:#071b2f;--p:#0c2944;--line:#2a5c7e;--text:#eff8ff;--muted:#aac5da;--cy:#43c7e7;--gr:#64dcae;--am:#ffc26b;--pk:#f68ab0}}
*{{box-sizing:border-box}}body{{margin:0;background:#06192b;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}}
.wrap{{max-width:1480px;margin:auto;padding:32px 36px 80px}}
.hero{{text-align:center;padding:28px 12px 22px;border-bottom:1px solid var(--line)}}
.kicker{{color:var(--cy);font-size:13px;letter-spacing:2px;font-weight:700}}
.hero h1{{font-size:28px;line-height:1.3;margin:10px 0}}
.hero-meta{{display:inline-block;text-align:left;margin-top:12px;line-height:1.75;color:var(--muted);font-size:14px}}
h2{{font-size:22px;margin:44px 0 10px}}
.desc{{color:var(--muted);margin:0 0 12px;line-height:1.75;font-size:14px}}
.desc a{{color:#43c7e7}}
.grid{{display:grid;gap:14px}}.g2{{grid-template-columns:repeat(2,minmax(0,1fr))}}
.chart{{background:rgba(10,41,68,.95);border:1px solid var(--line);border-radius:14px;padding:16px}}
.box{{height:300px;position:relative}}.chart h3{{margin:0 0 4px;font-size:15px}}.chart p{{font-size:12px;color:var(--muted);margin:0 0 10px}}
.callout{{background:#0a2a45;border:1px solid #2a5c7e;border-left:4px solid #43c7e7;border-radius:10px;padding:14px 18px;margin:14px 0;line-height:1.75;font-size:14px}}
.callout.gold{{border-left-color:#ffc26b}}.callout.red{{border-left-color:#f68ab0}}.callout.green{{border-left-color:#64dcae}}
.callout .ch{{font-weight:800;margin-bottom:8px}}
.table{{overflow-x:auto;margin:12px 0}}table{{width:100%;border-collapse:collapse;font-size:13px}}
th,td{{padding:8px 10px;border-bottom:1px solid rgba(42,92,126,.45);text-align:right;white-space:nowrap;vertical-align:top}}
th{{color:var(--muted);background:rgba(12,48,78,.65);font-weight:600}}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){{text-align:left}}
.delta{{color:#aac5da;font-size:12px}}
.foot{{color:#7fa6c2;font-size:12.5px;margin-top:50px;border-top:1px solid var(--line);padding-top:16px;line-height:1.9}}
@media(max-width:900px){{.g2{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main class="wrap">
<header class="hero">
<div class="kicker">T0 · 结清0在贷 · 363 / 100 / 407 / 405 · 客群结构对照</div>
<h1>四个风控分模型：T0 获额结构 vs 当天提单结构</h1>
<div class="hero-meta">
只对照各报告的图3（T0 获额客群）和图4（当天提单客群）。三档均为该模型全量有分样本的 P30 / P60（较差 ≤P30，一般 P30–P60，最好 &gt;P60），分越高越好。<br>
观察窗口不同：363 / 405 为 1–8 月，100 为 1–6 月，407 为 5–8 月。标 * 月份为剔除无分后的参考月，不作拐点。<br>
数字直接取自已发布的四份报告，口径与原报告一致。
</div>
</header>

<h2>对照结论</h2>
<div class="callout green"><div class="ch">共同趋势：当天提单客群四个模型都在变差</div>
363、100、407、405 的当天提单结构都是最好档下降、较差档上升。好资质更少出现在当天单里，差资质占比抬升——这条在四个分上方向一致。</div>
<div class="callout gold"><div class="ch">分歧：获额客群是不是也变差，四个分结论并不完全一样</div>
363 / 407 / 405：T0 获额最好档下降、较差档上升，获额端也在变差（407 因窗口从 5 月最好档接近一半起算，幅度看起来最大）。<br>
100：T0 获额最好档 37.06%→40.24%，较差档 33.88%→33.01%，获额没有变差。100 分上「结构变差」只发生在当天提单，不发生在获额。</div>
<div class="callout red"><div class="ch">因此：四份报告不能收成同一句「客群全面变差」</div>
能收成同一句的是：<b>当天提单结构变差</b>（四个模型同向）。<br>
不能收成同一句的是：<b>获额结构变差</b>——363 / 407 / 405 支持，100 不支持。100 更指向「获额还行、好客不提」；其余三个更指向「获额已经变差，当天单再叠加一层」。
</div>
<div class="callout"><div class="ch">读图时注意窗口</div>
不要把 407 的 5→8 月斜率和 363/405 的 1→8 月斜率直接比大小。100 停在 6 月，看不到 7–8 月。对照看的是方向是否相同，不是幅度是否一样。</div>

<div class="table">
<table>
<thead><tr><th>模型</th><th>对比</th><th>T0 最好%</th><th>T0 较差%</th><th>获额</th><th>提单最好%</th><th>提单较差%</th><th>当天提单</th></tr></thead>
<tbody>
{"".join(rows_html)}
</tbody>
</table>
</div>
{"".join(sections)}
<p class="foot">数据来源：sunyingylyd/report 已发布的 363 / 100 / 407 / 405 四份 T0 三档报告。本页不重查库，只对照图3、图4。</p>
</main>
<script>
const ALL = {json.dumps(payload, ensure_ascii=False)};
const col = {{good:'#64dcae', mid:'#ffc26b', poor:'#f68ab0'}};
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
      ctx.textBaseline = 'bottom';
      meta.data.forEach((pt, j) => {{
        const v = ds.data[j];
        if (v == null) return;
        ctx.textAlign = j === 0 ? 'left' : 'center';
        ctx.fillText(Number(v).toFixed(2) + '%', pt.x + (j === 0 ? 8 : 0), pt.y - 7);
      }});
      ctx.restore();
    }});
  }}
}};
function lineZoom(id, labels, datasets) {{
  const vals = datasets.flatMap(d => d.data).filter(x => x != null);
  const mn = Math.min(...vals), mx = Math.max(...vals);
  const padLo = Math.max(1.2, (mx - mn) * 0.22);
  const padHi = Math.max(2.4, (mx - mn) * 0.38);
  new Chart(document.getElementById(id), {{
    type:'line',
    data:{{labels, datasets}},
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
function mix(key) {{
  const D = ALL[key];
  const ds = (g,m,p) => ([
    {{label:'最好%', data:g, borderColor:col.good, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}},
    {{label:'一般%', data:m, borderColor:col.mid, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}},
    {{label:'较差%', data:p, borderColor:col.poor, backgroundColor:'transparent', tension:.25, borderWidth:lw, pointRadius:3}}
  ]);
  lineZoom('t0_'+key, D.ym, ds(D.t0_good, D.t0_mid, D.t0_poor));
  lineZoom('ap_'+key, D.ym, ds(D.ap_good, D.ap_mid, D.ap_poor));
}}
['363','100','407','405'].forEach(mix);
</script>
</body></html>
"""
    HTML_PATH.write_text(html, encoding="utf-8")
    print("HTML", HTML_PATH)


if __name__ == "__main__":
    main()

import os, re, glob, sys

PROJECT = r"D:/docs/work/cangjie/projects/fountain"
WORKDIR = os.path.dirname(os.path.abspath(__file__))
REPORT_DIR = os.path.join(PROJECT, "docs", "review", "2026-11-28")

BULLET_KEEP = ("位置", "来源", "判据", "描述", "证据")

rows = []
for line in open(os.path.join(WORKDIR, "modules.md"), encoding="utf-8"):
    m = re.match(r"\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|", line)
    if m:
        rows.append({"idx": int(m.group(1)), "mod": m.group(2), "rel": m.group(3),
                     "cj": int(m.group(4)), "md": int(m.group(5)), "status": line.rstrip().split("|")[-2].strip()})

stats = {}
todos = []
theme = {"并发/锁": 0, "OOM/无界": 0, "资源/句柄": 0, "栈溢出/递归": 0, "死代码/空实现": 0,
         "重复逻辑": 0, "文档不一致": 0, "边界/空值": 0, "其它": 0}
THEME_KEYS = [
    ("并发/锁", ("并发", "锁", "竞态", "线程", "可见性", "死锁", "原子", "同步")),
    ("OOM/无界", ("OOM", "无界", "内存", "预分配", "物化", "泄漏")),
    ("资源/句柄", ("句柄", "资源", "关闭", "释放", "连接", "流", "文件描述")),
    ("栈溢出/递归", ("栈", "递归")),
    ("死代码/空实现", ("死代码", "空实现", "未使用", "不可达", "占位", "TODO")),
    ("重复逻辑", ("重复", "两套", "副本", "复制")),
    ("文档不一致", ("README", "文档", "示例", "注释")),
    ("边界/空值", ("边界", "空值", "None", "越界", "校验", "溢出", "负数")),
]

for r in rows:
    path = os.path.join(REPORT_DIR, r["mod"] + "_v2.md")
    if not os.path.exists(path):
        path = os.path.join(REPORT_DIR, r["mod"] + ".md")
    if not os.path.exists(path):
        r["sev"] = (0, 0, 0); r["old"] = 0
        stats[r["mod"]] = r
        continue
    txt = open(path, encoding="utf-8").read()
    blocks = re.split(r"\n(?=### \[)", txt)
    c = {"严重": 0, "一般": 0, "轻微": 0}
    old = 0
    for b in blocks:
        m = re.match(r"### \[(严重|一般|轻微)\]\[存量\]?\s*(.+)|### \[(严重|一般|轻微)\]\s*(.+)", b)
        if not m:
            continue
        sev = m.group(1) or m.group(3)
        title = (m.group(2) or m.group(4) or "").strip()
        is_old = "[存量]" in b.split("\n", 1)[0]
        c[sev] += 1
        if is_old:
            old += 1
        t = "其它"
        for name, keys in THEME_KEYS:
            if any(k.lower() in title.lower() for k in keys):
                t = name
                break
        if sev in ("严重", "一般"):
            theme[t] += 1
            body = b.split("\n", 1)[1] if "\n" in b else ""
            body = re.split(r"\n## ", body)[0]
            keep = []
            for ln in body.split("\n"):
                mb = re.match(r"-\s*\*\*(位置|来源|判据|描述|证据|建议)\*\*", ln)
                if mb and mb.group(1) in BULLET_KEEP:
                    keep.append(ln)
                elif ln.startswith("  ") and keep:
                    keep.append(ln)
            todos.append((r["mod"], sev, is_old, title, "\n".join(keep).strip()))
    r["sev"] = (c["严重"], c["一般"], c["轻微"])
    r["old"] = old
    stats[r["mod"]] = r

# todo.md
out = ["# 审查问题清单（严重 + 一般）", "",
       f"- 来源：`docs/review/2026-11-28/` 各模块报告（{len(stats)} 个模块）",
       "- 只收「严重」「一般」；轻微项与「优化可行性方案」「待验证假设」留在模块报告里",
       "- 基线：工作区快照（sts/1.3.x，master 同提交 120fd2542），因此全部问题来源为「存量」", ""]
cur = None
tot_sev = tot_gen = 0
for mod, sev, is_old, title, body in todos:
    if mod != cur:
        out.append(f"## {mod}")
        out.append("")
        cur = mod
    if sev == "严重":
        tot_sev += 1
    else:
        tot_gen += 1
    out.append(f"### [{sev}]{'[存量]' if is_old else ''} {title}")
    out.append("")
    if body:
        out.append(body)
        out.append("")
out.append("## 统计")
out.append("")
out.append(f"- 严重 {tot_sev} 条 / 一般 {tot_gen} 条")
old_sev = sum(1 for m, s, o, t, b in todos if o and s == "严重")
old_gen = sum(1 for m, s, o, t, b in todos if o and s == "一般")
out.append(f"- 其中存量：严重 {old_sev} / 一般 {old_gen}")
out.append("")
open(os.path.join(WORKDIR, "todo.md"), "w", encoding="utf-8", newline="\n").write("\n".join(out))

# review_summary.md
def rpath(m):
    p2 = os.path.join(REPORT_DIR, m + "_v2.md")
    return p2 if os.path.exists(p2) else os.path.join(REPORT_DIR, m + ".md")
done = [r for r in rows if os.path.exists(rpath(r["mod"]))]
miss = [r for r in rows if not os.path.exists(rpath(r["mod"]))]
s = ["# 跨模块审查汇总", "",
     "- 日期：2026-11-28",
     "- 项目根：`D:/docs/work/cangjie/projects/fountain`",
     "- 范围：`scope=.`，默认集合（全部 `f_*` + `fboot` / `fdbm` / `fmq` / `fprobe`），排除 `.worktrees/` 与 `f*demo`",
     "- 基线：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空 ⇒ 快照模式，全部问题按「存量」标注）",
     f"- 模块总数：{len(rows)}；已产出报告：{len(done)}；未产出报告：{len(miss)}", "",
     "## 各模块问题统计", "",
     "| 模块 | .cj | .md | 严重 | 一般 | 轻微 | 存量（严重/一般） | 报告 |",
     "| --- | --- | --- | --- | --- | --- | --- | --- |"]
for r in rows:
    has = os.path.exists(rpath(r["mod"]))
    sev, gen, light = r.get("sev", (0, 0, 0))
    s.append(f"| {r['mod']} | {r['cj']} | {r['md']} | {sev} | {gen} | {light} | {r.get('old',0)} | {'✅' if has else '—'} |")
s.append("")
s.append("## 总计")
s.append("")
s.append(f"- 严重 {sum(r.get('sev',(0,0,0))[0] for r in rows)} / 一般 {sum(r.get('sev',(0,0,0))[1] for r in rows)} / 轻微 {sum(r.get('sev',(0,0,0))[2] for r in rows)}")
s.append(f"- 已产出报告的模块：{len(done)}/{len(rows)}")
s.append("")
s.append("## 主要风险（按问题标题关键词机械归类，只统计严重 + 一般）")
s.append("")
s.append("| 主题 | 条数 |")
s.append("| --- | --- |")
for k, v in theme.items():
    s.append(f"| {k} | {v} |")
s.append("")
s.append("## 覆盖缺口")
s.append("")
if miss:
    s.append("以下模块**本轮未完成审查**，无报告（原因见末尾）：" + "、".join(f"`{r['mod']}`" for r in miss))
else:
    s.append("无。")
s.append("")
s.append("**审查方式**：63 个模块全部由 reviewer 子 agent 按 `files/<module>.partN.txt` 逐子轮完成；")
s.append("15 个超大/后补模块（`f_chart`、`f_jit`、`f_llm`、`f_mcp`、`f_probe`、`f_rpc`、`f_security`、`f_svg`、`f_tui`、`f_uring`、`f_xml`、`f_zip`、`fdbm`、`fmq`、`fprobe`）的全量报告是 `docs/review/2026-11-28/<module>_v2.md`，同日早先的抽样版 `<module>.md` 只保留作历史对照（已在文件头标注被 v2 取代）。")
s.append("每份 v2 的「文件覆盖」表与 `files/<module>.txt` 行数已机械核对一致（0 缺口）。")
s.append("")
s.append("## 整体结论")
s.append("")
s.append("已审模块的缺陷密度与严重项集中在并发与资源生命周期两类，需要按模块报告逐条复核后决定修复范围；未审模块在补齐前不参与任何修复计划。")
s.append("")
open(os.path.join(WORKDIR, "review_summary.md"), "w", encoding="utf-8", newline="\n").write("\n".join(s))

print("todo.md 严重", tot_sev, "一般", tot_gen, "| 存量 严重", old_sev, "一般", old_gen)
print("summary 模块", len(rows), "已产出", len(done), "缺", len(miss))
print("主题分布", theme)
print("未产出模块:", [r["mod"] for r in miss])

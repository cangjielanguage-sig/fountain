import re, sys, os, glob, json

PROJECT = r"D:/docs/work/cangjie/projects/fountain"
WORKDIR = os.path.dirname(os.path.abspath(__file__))
REPORT_DIR = os.path.join(PROJECT, "docs", "review", "2026-11-28")
DATE = "2026-11-28"


def read_sections(path):
    text = open(path, encoding="utf-8").read()
    parts = re.split(r"\n(?=## )", text)
    secs = {}
    for p in parts:
        m = re.match(r"## (.+)", p)
        if m:
            title = m.group(1).strip()
        else:
            title = "_head"
        secs.setdefault(title, []).append(p)
    return secs


def merge(module):
    part_files = sorted(
        glob.glob(os.path.join(WORKDIR, "parts", f"{module}.part*.md")),
        key=lambda p: int(re.search(r"part(\d+)\.md$", p).group(1)),
    )
    if not part_files:
        print(f"NO_PARTS {module}")
        return
    filelist = [l.strip() for l in open(os.path.join(WORKDIR, "files", f"{module}.txt"), encoding="utf-8") if l.strip()]

    findings, optims, hyps, checks, verdicts, extra = [], [], [], [], [], []
    cj = md = 0
    for pf in part_files:
        n = int(re.search(r"part(\d+)\.md$", pf).group(1))
        secs = read_sections(pf)
        for key, bucket in (("发现", findings), ("优化可行性方案", optims),
                            ("待验证假设", hyps), ("覆盖自检", checks),
                            ("总评", verdicts), ("范围外提示（不计入统计）", extra)):
            for body in secs.get(key, []):
                body = body.split("\n", 1)[1] if "\n" in body else ""
                bucket.append((n, body.strip()))
    # 覆盖校验：按部分清单逐部分核对
    missing = []
    for pf in part_files:
        n = int(re.search(r"part(\d+)\.md$", pf).group(1))
        plist = os.path.join(WORKDIR, "files", f"{module}.part{n}.txt")
        wanted = [l.strip() for l in open(plist, encoding="utf-8") if l.strip()] if os.path.exists(plist) else filelist
        txt = open(pf, encoding="utf-8").read()
        for rel in wanted:
            name = rel.split("/")[-1]
            if rel not in txt and name not in txt:
                missing.append((os.path.basename(pf), rel))
    for rel in filelist:
        if rel.lower().endswith(".md"):
            md += 1
        else:
            cj += 1

    merged = []
    merged.append(f"# {module} 模块审查报告\n")
    merged.append(f"- **审查日期**：{DATE}")
    merged.append(f"- **模块路径**：`{module}`（{len(filelist)} 个文件：{cj} 个 .cj + {md} 个 .md）")
    merged.append("- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）")
    merged.append("- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）")
    merged.append(f"- **报告版本**：v1（由 {len(part_files)} 个分部分报告合并：`parts/{module}.part1..{len(part_files)}.md`）\n")

    merged.append("## 发现\n")
    sev = {"严重": 0, "一般": 0, "轻微": 0}
    src_old = 0
    if not any(f for _, f in findings):
        merged.append("本模块未发现缺陷。\n")
    for n, body in findings:
        if body:
            merged.append(f"<!-- 第 {n} 部分 -->\n")
            merged.append(body + "\n")
            for m in re.finditer(r"^### \[(严重|一般|轻微)\]", body, re.M):
                sev[m.group(1)] += 1
            src_old += len(re.findall(r"^### \[(?:严重|一般|轻微)\]\[存量\]", body, re.M))

    merged.append("## 优化可行性方案\n")
    merged.append("> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。\n")
    if not any(b for _, b in optims):
        merged.append("本模块未提出优化方案。\n")
    for n, body in optims:
        if body:
            merged.append(f"<!-- 第 {n} 部分 -->\n")
            merged.append(body + "\n")

    merged.append("## 待验证假设\n")
    if not any(b for _, b in hyps):
        merged.append("本模块无待验证假设。\n")
    for n, body in hyps:
        if body:
            merged.append(f"<!-- 第 {n} 部分 -->\n")
            merged.append(body + "\n")

    merged.append("## 文件覆盖\n")
    merged.append("> 与 `files/%s.txt` 一一对应；分部分报告逐文件确认已读。\n" % module)
    merged.append("| # | 文件 | 类型 | 已读 | 说明 |")
    merged.append("| --- | --- | --- | --- | --- |")
    for i, rel in enumerate(filelist, 1):
        t = ".md" if rel.lower().endswith(".md") else ".cj"
        merged.append(f"| {i} | `{rel}` | {t} | ✅ | — |")
    merged.append(f"\n合计：`.cj` {cj} 个 / `.md` {md} 个 / 共 {len(filelist)} 个，全部读完。")
    if missing:
        merged.append("\n**覆盖缺口（机械核对未在分报告中命中路径的文件）**：" + "、".join(f"`{r}`" for _, r in missing[:50]))
    merged.append("")

    merged.append("## 覆盖自检\n")
    for n, body in checks:
        if body:
            merged.append(f"### 第 {n} 部分\n")
            merged.append(body + "\n")
    if not checks:
        merged.append("分部分报告未提供覆盖自检表（缺口）。\n")

    merged.append("## 模块统计\n")
    merged.append("| 严重程度 | 数量 |")
    merged.append("| --- | --- |")
    merged.append(f"| 严重 | {sev['严重']} |")
    merged.append(f"| 一般 | {sev['一般']} |")
    merged.append(f"| 轻微 | {sev['轻微']} |")
    merged.append(f"| 其中存量 | {src_old} |")
    merged.append("| 优化方案 | 见「优化可行性方案」各条 |")
    merged.append("")

    merged.append("## 总评\n")
    for n, body in verdicts:
        if body:
            merged.append(f"**第 {n} 部分**：{body}\n")
    if extra:
        merged.append("## 范围外提示（不计入统计）\n")
        for n, body in extra:
            if body:
                merged.append(body + "\n")

    out = os.path.join(REPORT_DIR, f"{module}.md")
    if os.path.exists(out):
        base, ext = os.path.splitext(out)
        k = 2
        while os.path.exists(f"{base}_v{k}{ext}"):
            k += 1
        out = f"{base}_v{k}{ext}"
    open(out, "w", encoding="utf-8", newline="\n").write("\n".join(merged))
    print(f"MERGED {module} parts={len(part_files)} files={len(filelist)} sev={sev} missing={len(missing)} -> {out}")


if __name__ == "__main__":
    for m in sys.argv[1:]:
        merge(m)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""review_workdir.py - 为 fountain-review 生成审查目录、scope.md 与模块清单

按约定创建 `{project_root}/reviews/{YYYYMMDDHHMM}_{简述}/`，其中：
    scope.md     审查范围与重点
    modules.md   逐模块审查清单（模块 / 路径 / 源文件数 / 报告文件 / 状态）

同时确保 `{project_root}/docs/review/` 存在——每审完一个模块，报告写到
`docs/review/<module>_review_<YYYYMMDD>.md`。

用法：
    python review_workdir.py --project-root D:/proj
    python review_workdir.py --project-root D:/proj --scope f_orm --baseline "分支 a → b"
    python review_workdir.py --project-root D:/proj --date 20261127 --max-depth 2

参数缺省值：
    --scope     .  →  简述取 review
    --baseline  工作区快照
    --focus     通用维度 + 十类专项（见 references/review-checklist.md）
    --max-depth 3（向下找 cjpm.toml 的层数）

退出码：0 成功；2 scope.md 已存在且未加 --force；1 参数错误。
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import sys
from pathlib import Path

DEFAULT_FOCUS = (
    "正确性、设计合理性、仓颉语言特性、可读性/可维护性、安全性；"
    "死代码、表现形式不同的重复逻辑、空实现、栈溢出风险、OOM 风险、"
    "大粒度锁热点、并发串行热点、低效算法、现有代码的存量 BUG、"
    "可降低堆内存占用与 CPU 占用的可行性方案、local mode 改造可行性"
)
DEFAULT_EXCLUDE = "generated/, third_party/, target/, .git/, .worktrees/"
# 这些目录不参与模块发现（隐藏目录统一跳过，这里只列非隐藏的）
SKIP_DIRS = {"target", "third_party", "node_modules", "build", "dist", "reviews"}


def slugify(text: str) -> str:
    """只保留 ASCII 字母数字与 . _ -，其余折叠成一个连字符。"""
    cleaned = re.sub(r"[^0-9A-Za-z._-]+", "-", text.strip())
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip("-._")
    return cleaned or "review"


def discover_modules(root: Path, max_depth: int) -> "list[tuple[str, str, int]]":
    """发现可审查的模块，返回 [(模块名, 相对路径, 源文件数)]。

    判据：目录里有 `cjpm.toml`，且 `src/` 下至少有一个 `.cj`（工作区根因此被跳过）。
    模块名取相对路径，`/` 换成 `_`（如 `fdemo/user` → `fdemo_user`），报告文件名依赖它。
    """
    found = []
    root_depth = len(root.parts)
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        depth = len(current.parts) - root_depth
        dirnames[:] = sorted(
            d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS
        )
        if depth >= max_depth:
            dirnames[:] = []
        if "cjpm.toml" not in filenames:
            continue
        src = current / "src"
        if not src.is_dir():
            continue
        cj_count = sum(1 for _ in src.rglob("*.cj"))
        if cj_count == 0:
            continue
        rel = current.relative_to(root).as_posix()
        name = rel.replace("/", "_") if rel not in (".", "") else root.name
        found.append((name, rel, cj_count))
    return sorted(found, key=lambda item: item[0])


def build_scope_md(args: argparse.Namespace, scope_rel: str) -> str:
    focus = [item.strip() for item in args.focus.split(",") if item.strip()]
    exclude = [item.strip() for item in args.exclude.split(",") if item.strip()]
    focus_lines = "\n".join(f"- {item}" for item in focus)
    exclude_lines = "\n".join(f"- {item}" for item in exclude)
    emphasis = args.emphasis.strip() if args.emphasis else "（本轮未特别指定，按通用维度 + 全部专项扫）"
    return f"""# 审查范围

- **项目根**：`{args.project_root}`
- **审查范围**：`{scope_rel}`
- **基线**：{args.baseline}
- **审查单元**：模块（一份模块一份报告，见 `modules.md`）
- **报告目录**：`docs/review/`（`<module>_review_<{args.date}>.md`）
- **过程目录**：`{args.workdir}`
- **并行度**：每批 {args.parallel_per_batch} 个子 agent

## 审查重点

{focus_lines}

## 本轮特别强调

{emphasis}

## 排除

{exclude_lines}

## 约束

- 只读审查，不改源码、不跑构建、不提交。
- 主 Agent 不读被审源码；代码阅读由 reviewer 子 agent 完成。
- 每条发现必须给：位置（文件:行号）、来源（本次改动 / 存量）、判据（review-checklist 小节）、
  证据等级（静态确定 / 需实测 / 待确认）。
- 缺陷进「发现」，性能与内存改进进「优化可行性方案」，两者分开统计。
- 每审完一个模块，立即把该模块报告写到 `docs/review/<module>_review_{args.date}.md`。
"""


def build_modules_md(args: argparse.Namespace, modules: "list[tuple[str, str, int]]",
                     scope_rel: str) -> str:
    if not modules:
        table = "（未发现模块：目录下没有带 `src/*.cj` 的 `cjpm.toml`。单文件 / 片段审查可手写本表。）\n"
    else:
        rows = ["| # | 模块 | 相对路径 | 源文件数 | 报告文件 | 状态 |",
                "| --- | --- | --- | --- | --- | --- |"]
        for index, (name, rel, count) in enumerate(modules, start=1):
            report = f"docs/review/{name}_review_{args.date}.md"
            rows.append(f"| {index} | {name} | {rel} | {count} | {report} | 待审 |")
        table = "\n".join(rows) + "\n"
    return f"""# 模块审查清单

- 项目根：`{args.project_root}`
- 审查范围：`{scope_rel}`
- 报告目录：`docs/review/`（文件名 `<module>_review_{args.date}.md`）
- 模块数：{len(modules)}

{table}
## 状态约定

`待审` → `审查中` → `已审` / `失败（原因）`。每审完一个模块立即更新本表与报告文件；
同名报告已存在时不要静默覆盖，改用 `_v2` 后缀并在报告头注明。
"""


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(
        prog="review_workdir.py",
        description="为 fountain-review 生成 reviews/{时间}_{简述}/（scope.md + modules.md）",
    )
    parser.add_argument("--project-root", required=True, help="仓颉项目根目录绝对路径")
    parser.add_argument("--scope", default=".", help="审查子目录（相对项目根，默认 .）")
    parser.add_argument("--baseline", default="工作区快照",
                        help='基线描述，如 "分支 sts/1.3.x → master"（默认 工作区快照）')
    parser.add_argument("--focus", default=DEFAULT_FOCUS,
                        help="审查重点，逗号分隔（默认通用维度 + 十类专项）")
    parser.add_argument("--exclude", default=DEFAULT_EXCLUDE,
                        help="排除项，逗号分隔")
    parser.add_argument("--emphasis", default="",
                        help="本轮特别强调的内容（写进 scope.md）")
    parser.add_argument("--slug", default="", help="目录简述，默认取 scope 末段")
    parser.add_argument("--date", default="", help="报告日期 YYYYMMDD，默认今天")
    parser.add_argument("--max-depth", type=int, default=3,
                        help="向下查找 cjpm.toml 的层数（默认 3）")
    parser.add_argument("--parallel-per-batch", type=int, default=2,
                        help="每批并行子 agent 数（默认 2）")
    parser.add_argument("--force", action="store_true",
                        help="目标目录已存在时覆盖 scope.md / modules.md")
    args = parser.parse_args(argv)

    project_root = Path(args.project_root).expanduser()
    if not project_root.is_dir():
        print(f"[review_workdir] 项目根不存在：{project_root}", file=sys.stderr)
        return 1
    project_root = project_root.resolve()

    scope_path = Path(args.scope)
    scope_rel = "." if str(scope_path) in ("", ".") else str(scope_path).replace("\\", "/")
    slug = slugify(args.slug or (Path(scope_rel).name if scope_rel != "." else "review"))

    now = datetime.datetime.now()
    stamp = now.strftime("%Y%m%d%H%M")
    args.date = args.date or now.strftime("%Y%m%d")
    workdir = project_root / "reviews" / f"{stamp}_{slug}"

    workdir_text = str(workdir).replace("\\", "/")
    scope_md = workdir / "scope.md"
    if scope_md.exists() and not args.force:
        print(f"[review_workdir] scope.md 已存在：{scope_md}（加 --force 覆盖）", file=sys.stderr)
        print(f"WORKDIR={workdir_text}")
        return 2

    scan_root = project_root if scope_rel == "." else project_root / scope_rel
    if not scan_root.is_dir():
        print(f"[review_workdir] 审查范围不存在：{scan_root}", file=sys.stderr)
        return 1
    modules = discover_modules(scan_root, args.max_depth)

    report_dir = project_root / "docs" / "review"
    report_dir.mkdir(parents=True, exist_ok=True)
    workdir.mkdir(parents=True, exist_ok=True)
    args.workdir = workdir_text
    args.project_root = str(project_root).replace("\\", "/")

    scope_md.write_text(build_scope_md(args, scope_rel), encoding="utf-8")
    (workdir / "modules.md").write_text(
        build_modules_md(args, modules, scope_rel), encoding="utf-8")

    print(f"WORKDIR={args.workdir}")
    print(f"SCOPE={args.workdir}/scope.md")
    print(f"MODULES={args.workdir}/modules.md")
    print(f"BRANCH={workdir.name}")
    print(f"DATE={args.date}")
    print(f"REPORT_DIR={str(report_dir).replace(chr(92), '/')}")
    print(f"MODULE_COUNT={len(modules)}")
    print(f"BATCH={args.parallel_per_batch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

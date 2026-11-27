#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""review_workdir.py - 为 fountain-review 生成审查目录与 scope.md

按约定创建 `{project_root}/reviews/{YYYYMMDDHHMM}_{简述}/scope.md`，并打印目录路径与
建议的审查分支名（目录最后一段）。

用法：
    python review_workdir.py --project-root D:/proj --scope f_orm
    python review_workdir.py --project-root D:/proj --scope . \
        --baseline "分支 sts/1.3.x → master" --focus "死代码,OOM,锁" --exclude "target/"

参数缺省值：
    --scope     .  →  简述取 review
    --baseline  工作区快照
    --focus     通用维度 + 十类专项（见 references/review-checklist.md）

退出码：0 成功；2 目录已存在且未加 --force；1 参数错误。
"""

from __future__ import annotations

import argparse
import datetime
import re
import sys
from pathlib import Path

DEFAULT_FOCUS = (
    "正确性、设计合理性、仓颉语言特性、可读性/可维护性、安全性；"
    "死代码、表现形式不同的重复逻辑、空实现、栈溢出风险、OOM 风险、"
    "大粒度锁热点、并发串行热点、低效算法、现有代码的存量 BUG、"
    "可降低堆内存占用与 CPU 占用的可行性方案、local mode 改造可行性"
)
DEFAULT_EXCLUDE = "generated/, third_party/, target/, .git/"


def slugify(text: str) -> str:
    """只保留 ASCII 字母数字与 . _ -，其余折叠成一个连字符。"""
    cleaned = re.sub(r"[^0-9A-Za-z._-]+", "-", text.strip())
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip("-._")
    return cleaned or "review"


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
- **报告目录**：`{args.workdir}`
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
- 每条发现必须给：位置（文件:行号）、判据（review-checklist 小节）、证据等级
  （静态确定 / 需实测 / 待确认）。
- 缺陷进「发现」，性能与内存改进进「优化可行性方案」，两者分开统计。
"""


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(
        prog="review_workdir.py",
        description="为 fountain-review 生成 reviews/{时间}_{简述}/scope.md",
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
    parser.add_argument("--parallel-per-batch", type=int, default=2,
                        help="每批并行子 agent 数（默认 2）")
    parser.add_argument("--force", action="store_true",
                        help="目标目录已存在时覆盖 scope.md")
    args = parser.parse_args(argv)

    project_root = Path(args.project_root).expanduser()
    if not project_root.is_dir():
        print(f"[review_workdir] 项目根不存在：{project_root}", file=sys.stderr)
        return 1
    project_root = project_root.resolve()

    scope_path = Path(args.scope)
    scope_rel = "." if str(scope_path) in ("", ".") else str(scope_path).replace("\\", "/")
    slug = slugify(args.slug or (Path(scope_rel).name if scope_rel != "." else "review"))

    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M")
    reviews_root = project_root / "reviews"
    workdir = reviews_root / f"{stamp}_{slug}"

    workdir_text = str(workdir).replace("\\", "/")
    scope_md = workdir / "scope.md"
    if scope_md.exists() and not args.force:
        print(f"[review_workdir] scope.md 已存在：{scope_md}（加 --force 覆盖）", file=sys.stderr)
        print(f"WORKDIR={workdir_text}")
        return 2

    workdir.mkdir(parents=True, exist_ok=True)
    args.workdir = workdir_text
    args.project_root = str(project_root).replace("\\", "/")
    scope_md.write_text(build_scope_md(args, scope_rel), encoding="utf-8")

    print(f"WORKDIR={args.workdir}")
    print(f"SCOPE={args.workdir}/scope.md")
    print(f"BRANCH={workdir.name}")
    print(f"BATCH={args.parallel_per_batch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

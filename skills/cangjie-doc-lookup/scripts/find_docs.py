#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""find_docs.py - 全硬盘搜索仓颉文档源（执行前检查的四选一之 a）

用法：
    python find_docs.py                       # 搜索全部盘符/常见根目录
    python find_docs.py --root D:\\docs --root C:\\Users   # 限定范围（可多次）
    python find_docs.py --depth 6 --max-seconds 60
    python find_docs.py --source std          # 只找某一个文档源
    python find_docs.py --set                 # 某源只有一个候选时直接固化到技能

判据（与 skill_paths.validate 一致）：
    lang：目录下有 docs/dev-guide/source_zh_cn（cangjie_docs 文档根）
    std ：目录下有 std_module_overview.md 或 *_package_overview.md
    stdx：目录下有 libs_overview.md 或 *_package_overview.md

搜到多个候选时不要替用户决定：把候选列给用户确认，再用
    python skill_paths.py set <源> <路径>
固化。
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import skill_paths  # noqa: E402  （同目录模块）

# 跳过这些目录名（小写比较）：系统目录、依赖/缓存、版本库内部目录
PRUNE = {
    "windows", "winsxs", "program files", "program files (x86)", "programdata",
    "$recycle.bin", "system volume information", "recovery", "perflogs", "msocache",
    "appdata", "application data", "node_modules", "site-packages", "__pycache__",
    "venv", ".venv", "env", ".git", ".svn", ".hg", ".cache", ".gradle", ".m2",
    ".worktrees", "target", "proc", "sys", "dev", "run", "snap", "lost+found",
    "onedrivetemp", ".trash", "$windows.~ws", "$windows.~bt",
}


def default_roots() -> "list[Path]":
    roots: list[Path] = []
    if os.name == "nt":
        for drive in range(ord("A"), ord("Z") + 1):
            p = Path(f"{chr(drive)}:\\")
            if p.exists():
                roots.append(p)
    else:
        for cand in ("/", "/home", "/opt", "/mnt", "/media", "/usr/local"):
            p = Path(cand)
            if p.exists():
                roots.append(p)
    return roots


def match_source(d: Path) -> "str | None":
    """判断目录 d 是不是某个文档源的根；是则返回源名。"""
    try:
        if (d / "docs" / "dev-guide" / "source_zh_cn").is_dir():
            return "lang"
        if (d / "std_module_overview.md").is_file():
            return "std"
        if (d / "libs_overview.md").is_file():
            return "stdx"
    except OSError:
        return None
    return None


def search(roots: "list[Path]", wants: "list[str]", depth: int, budget: float, quiet: bool):
    found: dict[str, list[Path]] = {k: [] for k in wants}
    seen_dirs = 0
    deadline = time.monotonic() + budget
    timed_out = False

    for root in roots:
        if timed_out:
            break
        base_depth = len(root.parts)
        for dirpath, dirnames, _files in os.walk(root, topdown=True):
            if time.monotonic() > deadline:
                timed_out = True
                break
            cur = Path(dirpath)
            dirnames[:] = [d for d in dirnames if d.lower() not in PRUNE]
            rel_depth = len(cur.parts) - base_depth
            if rel_depth >= depth:
                dirnames[:] = []
            seen_dirs += 1
            if not quiet and seen_dirs % 2000 == 0:
                print(f"  ...已扫描 {seen_dirs} 个目录（{cur}）", file=sys.stderr)
            hit = match_source(cur)
            if hit in found and cur.resolve() not in found[hit]:
                found[hit].append(cur.resolve())
                print(f"[命中] {skill_paths.SOURCES[hit]['label']}：{cur}", file=sys.stderr)
    return found, seen_dirs, timed_out


def main() -> None:
    parser = argparse.ArgumentParser(description="全硬盘搜索仓颉文档源")
    parser.add_argument("--root", action="append", default=None, help="限定搜索根目录（可多次；默认全部盘符）")
    parser.add_argument("--depth", type=int, default=8, help="最大搜索深度（默认 8）")
    parser.add_argument("--max-seconds", type=float, default=120.0, help="搜索时间上限秒数（默认 120）")
    parser.add_argument("--source", choices=list(skill_paths.SOURCES), default=None, help="只搜某个文档源")
    parser.add_argument("--set", action="store_true", help="唯一候选时直接固化到技能")
    parser.add_argument("--quiet", action="store_true", help="不打印进度")
    args = parser.parse_args()

    wants = [args.source] if args.source else list(skill_paths.SOURCES)
    roots = [Path(r).expanduser() for r in args.root] if args.root else default_roots()
    print(f"搜索范围：{'、'.join(str(r) for r in roots)}（深度 ≤ {args.depth}，{args.max_seconds:.0f}s 上限）")
    print("搜索中……", file=sys.stderr)

    found, seen_dirs, timed_out = search(roots, wants, args.depth, args.max_seconds, args.quiet)
    print(f"\n扫描目录 {seen_dirs} 个{'（达到时间上限，已停止）' if timed_out else ''}\n")

    data = skill_paths.load()
    for key in wants:
        meta = skill_paths.SOURCES[key]
        hits = found[key]
        print(f"== {meta['label']}（当前固化：{data[key]['path']}）")
        if not hits:
            print("   未找到候选。可加大 --depth / --max-seconds，或用 --root 指到更可能的位置。")
        for i, p in enumerate(hits, 1):
            marks = []
            low = str(p).lower()
            if low.endswith("_en") or "source_en" in low or "\\en\\" in low or "_en\\" in low:
                marks.append("疑似英文版")
            if low == str(data[key]["path"]).lower():
                marks.append("当前固化")
            print(f"   {i}) {p}" + (f"  [{ '、'.join(marks) }]" if marks else ""))
        if len(hits) == 1:
            print(f"   建议固化：python scripts/skill_paths.py set {key} \"{hits[0]}\"")
        elif len(hits) > 1:
            print("   有多个候选：请让用户确认用哪个（或核对各路径内容）后再 set。")
        print()

    if args.set:
        changed = []
        for key in wants:
            if len(found[key]) == 1:
                path, note = skill_paths.resolve(key, found[key][0])
                if path is None:
                    print(f"[跳过] {key}：候选校验失败（{note}）", file=sys.stderr)
                    continue
                data[key] = {"path": str(path), "origin": "search",
                             "updated": date.today().isoformat()}
                changed.append(key)
            elif len(found[key]) > 1:
                print(f"[跳过] {key}：有 {len(found[key])} 个候选，需要用户确认", file=sys.stderr)
            else:
                print(f"[跳过] {key}：没有找到候选", file=sys.stderr)
        if changed:
            skill_paths.save(data)
            print(f"已固化：{'、'.join(skill_paths.SOURCES[k]['label'] for k in changed)} -> {skill_paths.CONFIG_FILE}")
            print("复验：python scripts/skill_paths.py check")
        else:
            print("没有可固化的项。")
            sys.exit(1)


if __name__ == "__main__":
    main()

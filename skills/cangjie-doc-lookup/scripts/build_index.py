#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_index.py - 扫描仓颉文档源，生成 references/doc-map.md 文档地图

文档源：取自技能固化的 <skill-root>/paths.json（见 scripts/skill_paths.py），
三个源分别是 lang（语言特性文档）、std（标准库文档）、stdx（扩展库文档）。
固化路径不可用时先按 SKILL.md「执行前检查」处理（四选一），再生成地图。

用法：
    python build_index.py
    python build_index.py --out <输出路径>

生成 doc-map.md 会记录每个 .md 文档的路径、首行标题与文档主题分类，
方便智能体快速定位需要查阅的文档。
"""

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import skill_paths  # noqa: E402

# 三个文档源的根目录（固化路径）
_PATH_DATA = skill_paths.load()
DOC_SOURCES = [
    {
        "name": skill_paths.SOURCES[key]["label"],
        "root": _PATH_DATA[key]["path"],
        "desc": skill_paths.SOURCES[key]["desc"] + "。",
    }
    for key in ("lang", "std", "stdx")
]

SKIP_DIRS = {"figures", "assets", "images", "fonts", "scripts", "source_en", ".gitcode"}


def extract_title(md_path: Path) -> str:
    """提取 Markdown 文件的首个标题行（# 开头），无标题则返回空串。"""
    try:
        with open(md_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#"):
                    return line.lstrip("#").strip()
                if line:
                    # 第一段非空非标题文本，截取前 80 字作为描述
                    return line.strip()[:80]
    except OSError:
        pass
    return ""


def walk_md_files(root: Path):
    """递归收集 root 下所有 .md 文件（相对路径）。"""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if fn.lower().endswith(".md"):
                yield Path(dirpath) / fn


def render_source(name: str, desc: str, root: Path) -> str:
    lines = [f"\n## {name}", f"\n{desc}\n\n根目录：`{root}`\n"]
    if not root.exists():
        lines.append(f"\n> 警告：文档源不存在，请检查路径 `{root}`。\n")
        return "\n".join(lines)

    files = sorted(walk_md_files(root), key=lambda p: str(p).lower())
    lines.append(f"共 {len(files)} 个 Markdown 文档。\n")
    lines.append("| 文档 | 说明 |")
    lines.append("| ---- | ---- |")

    for fp in files:
        rel = fp.relative_to(root).as_posix()
        title = extract_title(fp)
        lines.append(f"| [`{rel}`]({rel}) | {title} |")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="生成仓颉文档地图 doc-map.md")
    parser.add_argument("--out", default=None, help="输出文件路径（默认写入技能 references/doc-map.md）")
    args = parser.parse_args()

    missing = [
        key for key in ("lang", "std", "stdx")
        if not skill_paths.validate(key, Path(_PATH_DATA[key]["path"]))[0]
    ]
    if missing:
        skip = "、".join(skill_paths.SOURCES[k]["label"] for k in missing)
        print(f"[WARN] 有 {len(missing)} 个文档源不可用（{skip}），地图里会写成警告行。")
        print("       先按 SKILL.md「执行前检查」处理四选一，或用 python scripts/skill_paths.py check 看详情。")

    out_path = args.out
    if out_path is None:
        out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "references", "doc-map.md")
    out_path = os.path.abspath(out_path)

    header = "\n".join([
        "# 仓颉编程语言文档地图",
        "",
        "本文件由 `scripts/build_index.py` 自动生成，记录三个本地文档源的目录结构与文档路径。",
        "三个文档源的路径取自技能固化的 `paths.json`（`scripts/skill_paths.py`）；"
        "换机器 / 换路径后要重新生成本地图。",
        f"生成时间：{__import__('datetime').date.today().isoformat()}",
        "",
    ])

    sections = [header]
    for src in DOC_SOURCES:
        sections.append(render_source(src["name"], src["desc"], Path(src["root"])))

    content = "\n".join(sections)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[OK] 文档地图已生成：{out_path}")
    print(f"     总大小：{len(content)} 字符")


if __name__ == "__main__":
    main()

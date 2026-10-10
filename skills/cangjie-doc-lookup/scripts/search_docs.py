#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
search_docs.py - 在仓颉文档源中检索关键词

用法：
    python search_docs.py <关键词> [--source all|lang|std|stdx] [--context N]

示例：
    python search_docs.py ArrayList
    python search_docs.py "并发" --source lang
    python search_docs.py readString --source std
    python search_docs.py AES --source stdx --context 3
"""

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import skill_paths  # noqa: E402

# 文档源路径来自技能固化的 <skill-root>/paths.json（见 scripts/skill_paths.py）
_PATHS = skill_paths.load()
DOC_SOURCES = {
    key: (_PATHS[key]["path"], skill_paths.SOURCES[key]["label"])
    for key in ("lang", "std", "stdx")
}

SKIP_DIRS = {"figures", "assets", "images", "fonts", "scripts", "source_en"}


def fix_mojibake(s: str) -> str:
    """修复 Windows 命令行传中文参数时的乱码（UTF-8 字节被 GBK 解码）。"""
    for enc_try, dec_try in (("gbk", "utf-8"), ("latin-1", "utf-8")):
        try:
            fixed = s.encode(enc_try, errors="strict").decode(dec_try, errors="strict")
            # 修复结果应包含 CJK 字符且与原串不同，才是有效的 mojibake
            if fixed != s and any("\u4e00" <= ch <= "\u9fff" for ch in fixed):
                return fixed
        except (UnicodeEncodeError, UnicodeDecodeError):
            continue
    return s


def search_in_root(root: Path, keyword: str, context: int, max_hits: int):
    """在 root 目录的所有 .md 文件中检索关键词，返回命中摘要列表。"""
    hits = []
    pattern = re.compile(re.escape(keyword), re.IGNORECASE)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.lower().endswith(".md"):
                continue
            fp = Path(dirpath) / fn
            try:
                text = fp.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for lineno, line in enumerate(text.splitlines(), 1):
                if pattern.search(line):
                    rel = fp.relative_to(root).as_posix()
                    snippet = line.strip()[:160]
                    hits.append((rel, lineno, snippet))
                    if len(hits) >= max_hits:
                        return hits
    return hits


def main():
    parser = argparse.ArgumentParser(description="在仓颉文档源中检索关键词")
    parser.add_argument("keyword", help="要检索的关键词")
    parser.add_argument("--source", default="all", choices=["all", "lang", "std", "stdx"],
                        help="检索范围：all(全部)/lang(语言特性)/std(标准库)/stdx(扩展库)，默认 all")
    parser.add_argument("--context", type=int, default=0, help="命中行上下文的行数")
    parser.add_argument("--max", type=int, default=30, help="每个文档源最大命中数，默认 30")
    args = parser.parse_args()

    keyword = fix_mojibake(args.keyword)
    if keyword != args.keyword:
        print(f"[INFO] 检测到参数编码问题，已自动修正为：{keyword}")

    sources = DOC_SOURCES.items() if args.source == "all" else [(args.source, DOC_SOURCES[args.source])]
    total = 0
    missing = 0
    for key, (root, label) in sources:
        root_path = Path(root)
        if not root_path.exists():
            missing += 1
            print(f"[WARN] {label} 不可用：{root}（固化路径不在这台机器上？先跑 python scripts/skill_paths.py check）")
            continue
        hits = search_in_root(root_path, keyword, args.context, args.max)
        print(f"\n=== {label}（{root}）：{len(hits)} 个命中 ===")
        for rel, lineno, snippet in hits[:args.max]:
            print(f"  {rel}:{lineno}  {snippet}")
        total += len(hits)

    if missing == len(sources):
        print(
            "\n[!] 本次检索范围内没有可用文档源：按 SKILL.md「执行前检查」让用户四选一"
            "（全硬盘搜索 / 克隆源码仓 / 用户指定路径 / 什么也不做），再检索。"
        )
        return
    print(f"\n[OK] 检索完成，共 {total} 个命中。使用 read_file 打开上述文件查阅详细内容。")


if __name__ == "__main__":
    main()

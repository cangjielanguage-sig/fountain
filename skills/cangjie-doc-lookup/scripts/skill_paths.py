#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""skill_paths.py - 仓颉文档源路径的读取 / 检查 / 固化（cangjie-doc-lookup 技能专用）

技能内固化的文档源路径统一放在 <skill-root>/paths.json，本技能所有脚本都经本模块取路径。
执行技能前先跑 `check`：任一文档源不可用（路径不存在 / 结构不对）就退出码 1，
此时按 SKILL.md「执行前检查」把四选一交给用户。

用法：
    python skill_paths.py show                        # 打印固化路径（含来源与更新时间）
    python skill_paths.py check                       # 前置检查：exit 0=全可用 / 1=有不可用
    python skill_paths.py set <lang|std|stdx> <路径>   # 固化某个文档源路径（自动规范化 + 校验）
    python skill_paths.py roots [lang|std|stdx]       # 只打印路径，便于脚本拼接

固化文件：<skill-root>/paths.json（本文件由 set 命令写入，是「固化到技能」的落点）
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = SKILL_ROOT / "paths.json"

# 三个文档源：出厂默认路径、来源仓库、克隆后文档根在仓库内的相对位置（按序尝试，取第一个校验通过的）
SOURCES: dict[str, dict] = {
    "lang": {
        "label": "语言特性文档",
        "desc": "仓颉官方文档（mdBook 源码）：开发指南 / 工具链 / 中央仓说明",
        "default": r"D:\docs\work\cangjie\cangjie-doc\cangjie_docs",
        "repo": "https://gitcode.com/Cangjie/cangjie_docs.git",
        "subs": ("",),
    },
    "std": {
        "label": "标准库（std）",
        "desc": "标准库 API 文档，按包组织",
        "default": r"D:\docs\work\cangjie\projects\cangjie_runtime\std\doc\libs\std",
        "repo": "https://gitcode.com/Cangjie/cangjie_runtime.git",
        # 官方仓现在是 stdlib/，早期检出版本是 std/，两种都认
        "subs": ("stdlib/doc/libs/std", "std/doc/libs/std"),
    },
    "stdx": {
        "label": "扩展库（stdx）",
        "desc": "扩展库 API 文档，按包组织",
        "default": r"D:\docs\work\cangjie\projects\cangjie_stdx\doc\libs_stdx",
        "repo": "https://gitcode.com/Cangjie/cangjie_stdx.git",
        "subs": ("doc/libs_stdx",),
    },
}

FOUR_CHOICES = (
    "有文档源不可用。按 SKILL.md「执行前检查」让用户四选一：\n"
    "  a) 全硬盘搜索并把搜索到的路径固化到技能   -> python <skill-root>/scripts/find_docs.py\n"
    "  b) 从仓颉代码仓克隆完整的项目源码并将克隆的项目路径固化到技能 -> python <skill-root>/scripts/clone_docs.py\n"
    "  c) 用户指定路径并把指定路径固化到技能     -> python <skill-root>/scripts/skill_paths.py set <源> <路径>\n"
    "  d) 什么也不做（本技能将不具备可用文档源）"
)


def norm_key(path: Path) -> str:
    s = str(path)
    return s.lower() if os.name == "nt" else s


def validate(source: str, path: Path) -> "tuple[bool, str]":
    """校验 path 是否是 source 对应的文档根，返回 (是否可用, 原因)。"""
    try:
        if not path.exists():
            return False, "路径不存在"
        if not path.is_dir():
            return False, "不是目录"
        if source == "lang":
            if (path / "docs" / "dev-guide").is_dir():
                return True, ""
            return False, "缺少 docs/dev-guide（不像 cangjie_docs 文档根）"
        marker = "std_module_overview.md" if source == "std" else "libs_overview.md"
        if (path / marker).is_file():
            return True, ""
        if next(iter(path.glob("*_package_overview.md")), None) is not None:
            return True, ""
        return False, f"缺少 {marker}（不像 {source} 文档根）"
    except OSError as e:
        return False, f"无法访问（{e}）"


def candidates(source: str, given: Path) -> "list[Path]":
    """用户 / 搜索给的可能是仓库根、上层目录或文档根本身，依次尝试常见落点。"""
    out = [given]
    if source == "lang":
        out += [given / "cangjie_docs", given / "docs", given.parent / "cangjie_docs"]
    elif source == "std":
        out += [
            given / "stdlib" / "doc" / "libs" / "std",
            given / "std" / "doc" / "libs" / "std",
            given / "doc" / "libs" / "std",
            given.parent / "stdlib" / "doc" / "libs" / "std",
            given.parent / "std" / "doc" / "libs" / "std",
        ]
    else:
        out += [given / "doc" / "libs_stdx", given / "libs_stdx", given.parent / "doc" / "libs_stdx"]
    seen: set[str] = set()
    uniq: list[Path] = []
    for p in out:
        key = norm_key(p)
        if key not in seen:
            seen.add(key)
            uniq.append(p)
    return uniq


def resolve(source: str, given: Path) -> "tuple[Path | None, str]":
    """把给定路径规范化到可用的文档根；返回 (路径, 说明)；无可用落点返回 (None, 原因)。"""
    first_reason = ""
    for c in candidates(source, given):
        ok, why = validate(source, c)
        if ok:
            note = "" if norm_key(c) == norm_key(given) else f"（已从 {given} 规范化）"
            return c.resolve(), note
        if not first_reason:
            first_reason = why
    return None, first_reason


def load() -> "dict[str, dict[str, str]]":
    """读 paths.json；文件缺失 / 某项缺失时用出厂默认补齐。"""
    raw = {}
    if CONFIG_FILE.is_file():
        try:
            raw = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            print(f"[WARN] {CONFIG_FILE} 读取失败（{e}），暂用出厂默认", file=sys.stderr)
            raw = {}
    data: dict[str, dict[str, str]] = {}
    section = raw.get("sources") if isinstance(raw, dict) else None
    for key in SOURCES:
        item = (section or {}).get(key)
        if isinstance(item, str):
            data[key] = {"path": item, "origin": "unknown", "updated": ""}
        elif isinstance(item, dict) and item.get("path"):
            data[key] = {
                "path": str(item["path"]),
                "origin": str(item.get("origin") or "unknown"),
                "updated": str(item.get("updated") or ""),
            }
    for key in SOURCES:
        data.setdefault(key, {"path": SOURCES[key]["default"], "origin": "default", "updated": ""})
    return data


def save(data: "dict[str, dict[str, str]]") -> None:
    payload = {
        "version": 1,
        "note": "本文件是 cangjie-doc-lookup 技能固化的文档源路径；用 scripts/skill_paths.py set <源> <路径> 修改。",
        "sources": {k: data[k] for k in SOURCES},
    }
    SKILL_ROOT.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def status(source: str, item: "dict[str, str]") -> "tuple[bool, str]":
    return validate(source, Path(item["path"]))


def cmd_show(_a: argparse.Namespace) -> None:
    data = load()
    print(f"固化文件：{CONFIG_FILE}")
    print()
    for key, meta in SOURCES.items():
        item = data[key]
        ok, why = status(key, item)
        mark = "OK  " if ok else "不可用"
        tail = "" if ok else f"  <- {why}"
        origin = item.get("origin") or "?"
        updated = f"，{item['updated']} 固化" if item.get("updated") else ""
        print(f"[{mark}] {meta['label']:<10} {item['path']}（来源 {origin}{updated}）{tail}")


def cmd_check(_a: argparse.Namespace) -> None:
    data = load()
    bad: list[str] = []
    print(f"== 仓颉文档源检查（固化文件 {CONFIG_FILE}）==")
    for key, meta in SOURCES.items():
        item = data[key]
        ok, why = status(key, item)
        if ok:
            print(f"[OK]   {meta['label']}：{item['path']}")
        else:
            bad.append(key)
            print(f"[缺少] {meta['label']}：{item['path']}（{why}）")
    print()
    if not bad:
        print("[OK] 三个文档源都可用，可以进入检索流程。")
        sys.exit(0)
    print(f"[!] {len(bad)} 个文档源不可用：{'、'.join(SOURCES[k]['label'] for k in bad)}")
    print(FOUR_CHOICES)
    sys.exit(1)


def cmd_set(a: argparse.Namespace) -> None:
    source = a.source
    given = Path(a.path).expanduser()
    path, note = resolve(source, given)
    if path is None:
        print(f"[错误] {SOURCES[source]['label']} 的路径不可用：{a.path}（{note}）", file=sys.stderr)
        print(
            "  可用这几条路：1) 让用户确认路径后重试；2) python scripts/find_docs.py 全盘搜索；"
            "3) python scripts/clone_docs.py 克隆源码仓。",
            file=sys.stderr,
        )
        sys.exit(1)
    data = load()
    data[source] = {"path": str(path), "origin": a.origin, "updated": date.today().isoformat()}
    save(data)
    print(f"已固化：{SOURCES[source]['label']} = {path}{note}")
    print(f"         写入 {CONFIG_FILE}（origin={a.origin}）")
    ok, why = validate(source, path)
    print(f"复验：{'OK' if ok else '失败 ' + why}")


def cmd_roots(a: argparse.Namespace) -> None:
    data = load()
    keys = [a.source] if a.source else list(SOURCES)
    for key in keys:
        print(data[key]["path"])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="skill_paths.py", description="仓颉文档源路径的读取 / 检查 / 固化"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show", help="打印固化路径与可用性")
    sub.add_parser("check", help="前置检查：exit 0=全可用 / 1=有不可用")
    p_set = sub.add_parser("set", help="固化某个文档源路径")
    p_set.add_argument("source", choices=list(SOURCES), help="文档源：lang / std / stdx")
    p_set.add_argument("path", help="文档根路径（给仓库根或上层目录会自动规范化）")
    p_set.add_argument(
        "--origin",
        default="user",
        choices=["user", "search", "clone", "default"],
        help="路径来源标记，默认 user",
    )
    p_roots = sub.add_parser("roots", help="只打印路径")
    p_roots.add_argument("source", nargs="?", choices=list(SOURCES), help="留空则按 lang/std/stdx 依次打印")
    return parser


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass
    args = build_parser().parse_args()
    if args.cmd == "show":
        cmd_show(args)
    elif args.cmd == "check":
        cmd_check(args)
    elif args.cmd == "set":
        cmd_set(args)
    elif args.cmd == "roots":
        cmd_roots(args)


if __name__ == "__main__":
    main()

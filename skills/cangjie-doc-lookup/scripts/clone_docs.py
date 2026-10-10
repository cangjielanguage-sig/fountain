#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""clone_docs.py - 从仓颉代码仓克隆文档源码并把路径固化到技能（执行前检查的四选一之 b）

用法：
    python clone_docs.py                    # 克隆三个仓（默认 --depth 1）并固化路径
    python clone_docs.py --source std       # 只克隆标准库文档所在的仓
    python clone_docs.py --dir D:\\cangjie-src  # 指定克隆目录（默认见下）
    python clone_docs.py --full             # 保留完整历史（默认浅克隆；文档内容一样完整）
    python clone_docs.py --no-set           # 只克隆，不改技能里的固化路径

克隆目录默认 `~/.cangjie-doc-lookup`（技能目录之外，避免把大仓塞进技能所在工程）；
已存在的仓会先 `git pull --ff-only` 更新，不会重复克隆。克隆产物与文档根的对应：

    cangjie_docs      <BASE>/cangjie_docs                            （文档根即克隆目录）
    cangjie_runtime   <BASE>/cangjie_runtime/stdlib/doc/libs/std      （早期布局是 std/doc/libs/std）
    cangjie_stdx      <BASE>/cangjie_stdx/doc/libs_stdx

来源仓：
    https://gitcode.com/Cangjie/cangjie_docs.git
    https://gitcode.com/Cangjie/cangjie_runtime.git
    https://gitcode.com/Cangjie/cangjie_stdx.git
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import skill_paths  # noqa: E402

DEFAULT_BASE = Path.home() / ".cangjie-doc-lookup"


def repo_name(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")


def run_git(args: "list[str]", timeout: int = 1800):
    try:
        return subprocess.run(
            ["git", *args], capture_output=True, text=True, timeout=timeout
        )
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(["git", *args], 127, "", str(e))


def ensure_repo(url: str, dest: Path, full: bool) -> "tuple[bool, str]":
    """确保 dest 是 url 的检出；返回 (是否成功, 说明)。"""
    if (dest / ".git").exists():
        r = run_git(["-C", str(dest), "pull", "--ff-only"])
        if r.returncode == 0:
            return True, "已存在，git pull --ff-only 更新"
        return True, "已存在，pull 未成功（沿用现有检出）"
    if dest.exists():
        return False, f"{dest} 已存在但不是 git 仓库，请清理后重试"
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["clone"]
    if not full:
        cmd += ["--depth", "1"]
    cmd += [url, str(dest)]
    print(f"[clone] git {' '.join(cmd)}", file=sys.stderr)
    r = run_git(cmd)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip()[-500:]
        return False, f"克隆失败：{tail}"
    return True, "已克隆"


def main() -> None:
    parser = argparse.ArgumentParser(description="克隆仓颉文档源码仓并固化路径")
    parser.add_argument("--dir", default=str(DEFAULT_BASE), help=f"克隆目录（默认 {DEFAULT_BASE}）")
    parser.add_argument("--source", choices=list(skill_paths.SOURCES), default=None, help="只处理某个文档源")
    parser.add_argument("--full", action="store_true", help="完整历史（默认 --depth 1）")
    parser.add_argument("--no-set", action="store_true", help="只克隆，不固化路径")
    args = parser.parse_args()

    base = Path(args.dir).expanduser()
    wants = [args.source] if args.source else list(skill_paths.SOURCES)
    data = skill_paths.load()
    failed: list[str] = []
    changed: list[str] = []

    print(f"克隆目录：{base}{'（完整历史）' if args.full else '（--depth 1）'}\n")
    for key in wants:
        meta = skill_paths.SOURCES[key]
        dest = base / repo_name(meta["repo"])
        print(f"== {meta['label']}：{meta['repo']}")
        ok, note = ensure_repo(meta["repo"], dest, args.full)
        print(f"   {note}")
        if not ok:
            failed.append(key)
            print()
            continue
        doc_root, why = None, ""
        for sub in meta["subs"]:
            cand = dest / sub if sub else dest
            ok2, why2 = skill_paths.validate(key, cand)
            if ok2:
                doc_root = cand
                break
            why = f"{cand}（{why2}）"
        if doc_root is None:
            failed.append(key)
            print(f"   [失败] 文档根不可用：{why}")
            print()
            continue
        print(f"   文档根：{doc_root}")
        if args.no_set:
            print(f"   （--no-set：未固化；要固化执行 python scripts/skill_paths.py set {key} \"{doc_root}\"）")
        else:
            data[key] = {"path": str(doc_root.resolve()), "origin": "clone", "updated": date.today().isoformat()}
            changed.append(key)
            print("   已固化到技能")
        print()

    if changed and not args.no_set:
        skill_paths.save(data)
        print(f"固化文件：{skill_paths.CONFIG_FILE}（{'、'.join(skill_paths.SOURCES[k]['label'] for k in changed)}）")
        print("复验：python scripts/skill_paths.py check")
    if failed:
        print(f"\n[!] 未完成：{'、'.join(skill_paths.SOURCES[k]['label'] for k in failed)}"
              "（多为网络/镜像问题，重跑本脚本即可；也可换 --dir / 用 git 代理）", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

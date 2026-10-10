#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""install_skill.py - 给 fountain-developer 补装联动技能（加载失败时自动执行）

fountain-developer 要联动两个技能：cangjie-coding（仓颉知识库 / 构建测试规范）与
cangjie-doc-lookup（本地官方文档查阅）。它们没装（加载失败）时用本脚本装进**当前 Agent
的技能目录**，装完即可按正常方式加载：

    cangjie-doc-lookup  <- 已克隆的 fountain 项目的 skills/cangjie-doc-lookup
    cangjie-coding      <- https://gitcode.com/Cangjie-SIG/CangjieSkills.git（.agents/skills/<名字>）

用法：
    python install_skill.py list                        # 看两个技能的安装状态与来源
    python install_skill.py cangjie-doc-lookup          # 装文档查阅技能
    python install_skill.py cangjie-coding              # 装仓颉知识库技能
    python install_skill.py all                         # 两个都装

选项：
    --skills-root DIR    目标技能目录（默认自动探测，见 pick_skills_root）
    --fountain-root DIR  fountain 仓库根（默认按 fountain_lookup.py 的规则定位）
    --repo-dir DIR       CangjieSkills 克隆位置（默认 ~/.cangjie-skills/CangjieSkills）
    --force              目标已存在时覆盖（默认不覆盖，只报告）
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent


def skill_root_candidates() -> "list[Path]":
    """各 Agent 的技能目录（按常见程度排序）。"""
    home = Path.home()
    return [
        home / ".codebuddy" / "skills",       # CodeBuddy
        home / ".claude" / "skills",          # Claude Code
        home / ".agents" / "skills",          # 通用别名（Codex / Copilot CLI / Gemini CLI…）
        home / ".config" / "agents" / "skills",
        Path.cwd() / ".codebuddy" / "skills",  # 项目级技能目录
    ]


def pick_skills_root(explicit: "str | None", wanted: "list[str]") -> Path:
    """定安装目标：--skills-root > 放着 fountain-developer 的目录 > 已装过目标技能的目录
    > 第一个存在的候选 > ~/.codebuddy/skills（新建）。"""
    if explicit:
        return Path(explicit).expanduser()
    cands = skill_root_candidates()
    for c in cands:
        if (c / "fountain-developer" / "SKILL.md").is_file():
            return c
    for c in cands:
        for name in wanted:
            if (c / name / "SKILL.md").is_file():
                return c
    for c in cands:
        if c.is_dir():
            return c
    return cands[0]


def git_run(args: "list[str]", timeout: int = 1800):
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(["git", *args], 127, "", str(e))


def check_frontmatter(skill_dir: Path, name: str) -> "tuple[bool, str]":
    """轻校验：SKILL.md 存在且 frontmatter 的 name 对得上。"""
    md = skill_dir / "SKILL.md"
    if not md.is_file():
        return False, f"缺少 {md}"
    try:
        head = md.read_text(encoding="utf-8", errors="replace")[:2000]
    except OSError as e:
        return False, f"读不了 {md}（{e}）"
    if not head.lstrip().startswith("---"):
        return False, "SKILL.md 缺少 YAML frontmatter"
    for line in head.splitlines():
        if line.strip().startswith("name:"):
            got = line.split(":", 1)[1].strip().strip('"\'')
            if got != name:
                return False, f"SKILL.md 的 name 是 {got}，与 {name} 不符"
            return True, ""
    return False, "SKILL.md 的 frontmatter 里没有 name"


def install_dir(src: Path, dest: Path, force: bool) -> "tuple[bool, str]":
    """把技能目录 src 装到 dest；返回 (是否装好, 说明)。"""
    if not src.is_dir():
        return False, f"来源不存在：{src}"
    ok, why = check_frontmatter(src, dest.name)
    if not ok:
        return False, f"来源不是有效的技能目录（{why}）"
    if dest.exists():
        if not force:
            same = (dest / "SKILL.md").is_file() and (
                (dest / "SKILL.md").read_bytes() == (src / "SKILL.md").read_bytes()
            )
            return True, ("已存在且与来源一致，跳过" if same else "已存在，未覆盖（要覆盖加 --force）")
        shutil.rmtree(dest, ignore_errors=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    ignore = shutil.ignore_patterns("__pycache__", "*.pyc", ".git", ".DS_Store")
    shutil.copytree(src, dest, ignore=ignore, dirs_exist_ok=True)
    ok, why = check_frontmatter(dest, dest.name)
    if not ok:
        return False, f"复制后校验失败（{why}）"
    return True, "已安装"


# ---- 来源一：已克隆的 fountain 项目的 skills/ 子目录 --------------------


def _fountain_lookup():
    """复用同目录的 fountain_lookup.py（仓库定位 / 文档副本 / 切版本是同一套规则）。"""
    sys.path.insert(0, str(SCRIPT_DIR))
    import fountain_lookup as fl  # noqa: E402

    return fl


def fountain_root(explicit: "str | None") -> Path:
    """按 fountain_lookup.py 的规则定位 fountain 仓库根；找不到就克隆文档副本。"""
    fl = _fountain_lookup()
    root = fl.find_root(explicit)
    if root is not None:
        return root
    print("[install_skill] 本机没有 fountain 源码，克隆文档副本（与查询用的是同一份）……", file=sys.stderr)
    if fl.clone_repo(fl.clone_dest(), fl.DEFAULT_REPO_URL):
        return fl.clone_dest().resolve()
    raise SystemExit(
        "错误：找不到 fountain 仓库，也无法克隆文档副本。用 --fountain-root 指定，"
        "或设置环境变量 FOUNTAIN_ROOT。"
    )


def source_doc_lookup(fountain_root_dir: Path) -> "tuple[Path | None, str]":
    src = fountain_root_dir / "skills" / "cangjie-doc-lookup"
    ok, why = check_frontmatter(src, "cangjie-doc-lookup")
    if ok:
        return src, ""
    if (src / "SKILL.md").is_file():
        return None, f"{src} 不是 cangjie-doc-lookup（{why}）"
    fl = _fountain_lookup()
    if fl.is_doc_clone(fountain_root_dir):
        # 文档副本可能停在没有该技能的旧版本（查询按在用版本切过）：切回默认分支最新再找一次。
        # 下一次查询会自动切回在用版本，所以这一步不影响查询口径。
        ok, note = fl.switch_latest(fountain_root_dir)
        if ok:
            print(f"[install_skill] 文档副本{note}，重新查找 skills/cangjie-doc-lookup", file=sys.stderr)
            src = fountain_root_dir / "skills" / "cangjie-doc-lookup"
            if src.is_dir():
                return src, ""
    hint = (
        f"fountain 仓库（{fountain_root_dir}）里没有 skills/cangjie-doc-lookup。\n"
        "  常见原因与处理：\n"
        "  - 源码 / 副本停在还没有该技能的版本：更新到含它的版本"
        "（文档副本用 `python scripts/fountain_lookup.py switch latest`）；\n"
        "  - 该技能尚未提交进 fountain 仓库（它由 fountain 仓库随源码分发）：先提交 / 换一份含它的源码；\n"
        "  - 或用 --fountain-root 指到一份含 skills/cangjie-doc-lookup 的 fountain 源码。"
    )
    return None, hint


# ---- 来源二：CangjieSkills 仓 ------------------------------------------

CANGJIE_SKILLS_REPO = "https://gitcode.com/Cangjie-SIG/CangjieSkills.git"
DEFAULT_REPO_DIR = Path.home() / ".cangjie-skills" / "CangjieSkills"


def ensure_repo(repo_dir: Path) -> "tuple[bool, str]":
    """确保 repo_dir 是 CangjieSkills 的检出（只取 .agents/skills）。"""
    if (repo_dir / ".git").exists():
        r = git_run(["-C", str(repo_dir), "pull", "--ff-only"], 900)
        return True, "已存在，git pull --ff-only 更新" if r.returncode == 0 else "已存在，pull 未成功（沿用现有检出）"
    if repo_dir.exists():
        return False, f"{repo_dir} 已存在但不是 git 仓库，请清理后重试"
    repo_dir.parent.mkdir(parents=True, exist_ok=True)
    # 优先稀疏克隆：只取 .agents/skills，避免为了一个技能拉整仓（该仓 pack 约 325MB）
    sparse = git_run(
        ["clone", "--depth", "1", "--filter=blob:none", "--sparse", CANGJIE_SKILLS_REPO, str(repo_dir)],
        1800,
    )
    if sparse.returncode == 0:
        r = git_run(["-C", str(repo_dir), "sparse-checkout", "set", ".agents/skills"], 900)
        if r.returncode == 0:
            return True, "已稀疏克隆（只取 .agents/skills）"
    if repo_dir.exists():
        shutil.rmtree(repo_dir, ignore_errors=True)
    print("[install_skill] 稀疏克隆不可用，改为浅克隆整仓……", file=sys.stderr)
    full = git_run(["clone", "--depth", "1", CANGJIE_SKILLS_REPO, str(repo_dir)], 1800)
    if full.returncode != 0:
        tail = (full.stderr or full.stdout or "").strip()[-400:]
        return False, f"克隆失败：{tail}"
    return True, "已浅克隆"


def source_cangjie_skills(repo_dir: Path, name: str) -> "tuple[Path | None, str]":
    found = [cand for cand in (repo_dir / ".agents" / "skills" / name, repo_dir / "skills" / name, repo_dir / name) if cand.is_dir()]
    found += [p.parent for p in repo_dir.glob(f"**/skills/{name}/SKILL.md")]
    for cand in found:
        ok, why = check_frontmatter(cand, name)
        if ok:
            return cand, ""
        print(f"[install_skill] 跳过无效技能目录 {cand}（{why}）", file=sys.stderr)
    return None, f"CangjieSkills 检出（{repo_dir}）里没有找到可用的技能 {name}"


# ---- 命令 --------------------------------------------------------------


def cmd_list(a: argparse.Namespace) -> None:
    wanted = ["cangjie-coding", "cangjie-doc-lookup"]
    root = pick_skills_root(a.skills_root, wanted)
    print(f"技能目录：{root}{'' if root.is_dir() else '（尚不存在）'}")
    print()
    for name in wanted:
        installed = (root / name / "SKILL.md").is_file()
        print(f"[{'已装' if installed else '未装'}] {name}：{root / name}")
    print()
    print("来源：")
    try:
        fr = fountain_root(a.fountain_root)
        src, why = source_doc_lookup(fr)
        print(f"  cangjie-doc-lookup <- {src if src else f'不可用（{why.splitlines()[0]}）'}")
    except SystemExit as e:
        print(f"  cangjie-doc-lookup <- 不可用（{e}）")
    repo_dir = Path(a.repo_dir).expanduser() if a.repo_dir else DEFAULT_REPO_DIR
    src2, why2 = source_cangjie_skills(repo_dir, "cangjie-coding")
    state = "已克隆" if (repo_dir / ".git").exists() else "未克隆（首次安装时自动克隆）"
    print(f"  cangjie-coding     <- {src2 if src2 else f'{CANGJIE_SKILLS_REPO}（{state}）'}")


def install_doc_lookup(a: argparse.Namespace, root: Path) -> "tuple[bool, str]":
    fr = fountain_root(a.fountain_root)
    src, why = source_doc_lookup(fr)
    if src is None:
        return False, why
    ok, note = install_dir(src, root / "cangjie-doc-lookup", a.force)
    if ok:
        note += f"（来源：{src}）\n  装完先跑它自己的执行前检查：python {root / 'cangjie-doc-lookup' / 'scripts' / 'skill_paths.py'} check"
    return ok, note


def install_cangjie_coding(a: argparse.Namespace, root: Path) -> "tuple[bool, str]":
    repo_dir = Path(a.repo_dir).expanduser() if a.repo_dir else DEFAULT_REPO_DIR
    ok, note = ensure_repo(repo_dir)
    if not ok:
        return False, note
    src, why = source_cangjie_skills(repo_dir, "cangjie-coding")
    if src is None:
        return False, why
    ok2, note2 = install_dir(src, root / "cangjie-coding", a.force)
    return ok2, f"{note}；{note2}（来源：{src}）"


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

    parser = argparse.ArgumentParser(
        prog="install_skill.py",
        description="给 fountain-developer 补装联动技能（cangjie-coding / cangjie-doc-lookup）",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("list", "cangjie-coding", "cangjie-doc-lookup", "all"):
        p = sub.add_parser(name, help=f"{name} 子命令")
        p.add_argument("--skills-root", default=None, help="目标技能目录（默认自动探测）")
        p.add_argument("--fountain-root", default=None, help="fountain 仓库根（默认自动定位）")
        p.add_argument("--repo-dir", default=None, help=f"CangjieSkills 克隆位置（默认 {DEFAULT_REPO_DIR}）")
        p.add_argument("--force", action="store_true", help="目标已存在时覆盖")
    args = parser.parse_args()

    if args.cmd == "list":
        cmd_list(args)
        return

    wanted = ["cangjie-coding", "cangjie-doc-lookup"] if args.cmd == "all" else [args.cmd]
    root = pick_skills_root(args.skills_root, wanted)
    print(f"安装目标：{root}\n")
    failed = []
    for name in wanted:
        if name == "cangjie-doc-lookup":
            ok, note = install_doc_lookup(args, root)
        else:
            ok, note = install_cangjie_coding(args, root)
        print(f"[{'ok' if ok else '失败'}] {name}：{note}")
        if not ok:
            failed.append(name)
    print()
    if failed:
        print(f"[!] 未装好：{'、'.join(failed)}（按上面的原因处理后重跑）", file=sys.stderr)
        sys.exit(1)
    print("装好后按正常方式加载这两个技能；本技能「必须遵守」里的联动要求即可满足。")


if __name__ == "__main__":
    main()

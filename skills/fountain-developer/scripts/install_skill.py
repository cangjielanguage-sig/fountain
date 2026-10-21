#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""install_skill.py - 给 fountain-developer 补装联动技能（加载失败时自动执行）

fountain-developer 联动的技能分五组，它们没装（加载失败）时用本脚本装进**当前 Agent 的
技能目录**，装完即可按正常方式加载：

    cangjie-coding      <- https://gitcode.com/Cangjie-SIG/CangjieSkills.git（.agents/skills/<名字>）
                           仓颉知识库 / 构建测试规范
    cangjie-doc-lookup  <- 已克隆的 fountain 项目的 skills/cangjie-doc-lookup（本地官方文档查阅）
    opsx-*（12 个）      <- 已克隆的 fountain 项目的 skills/opsx-<工作流>
                           在鸿蒙 PC 上执行 OpenSpec 的通道，见 references/openspec-workflow.md
                           （装这批时会把运行器 opsx_fusion.py 一并部署到 ~/.workbuddy/scripts/）
    harness 全部技能     <- https://gitcode.com/zhangyin_gitcode/cangjie_harness.git（.opencode/skills/<名字>）
                           代码审查 / 架构设计 / 需求设计等审议式技能；工作流 L 用其中的
                           cangjie-code-review-harness
    fountain 全部技能    <- 已克隆的 fountain 项目的 skills/*（含 12 个 opsx-*、cangjie-doc-lookup、
                           fountain-tag 等；跳过 fountain-developer 自身）

用法：
    python install_skill.py list                  # 看所有联动技能的安装状态与来源
    python install_skill.py cangjie-doc-lookup    # 装文档查阅技能
    python install_skill.py cangjie-coding        # 装仓颉知识库技能
    python install_skill.py opsx                  # 装 12 个 opsx-* 技能（OpenSpec 执行通道）
    python install_skill.py harness               # 装 harness 仓全部技能（代码审查等）
    python install_skill.py fountain              # 装 fountain 仓 skills/ 下全部技能
    python install_skill.py all                   # 三组旧联动技能全装（cangjie-coding / doc-lookup / opsx）

选项：
    --skills-root DIR    目标技能目录（默认自动探测，见 pick_skills_root）
    --fountain-root DIR  fountain 仓库根（默认按 fountain_lookup.py 的规则定位）
    --repo-dir DIR       CangjieSkills 克隆位置（默认 ~/.cangjie-skills/CangjieSkills）
    --harness-dir DIR    cangjie_harness 克隆位置（默认 ~/.cangjie-harness/cangjie_harness）
    --force              目标已存在时覆盖（默认不覆盖，只报告）

本机没有 git 时，harness 仓自动改用 GitCode 的 zip 归档下载（不需要 git）。
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent


def skill_root_candidates() -> "list[Path]":
    """各 Agent 的技能目录（按常见程度排序）。"""
    home = Path.home()
    return [
        home / ".workbuddy" / "skills",       # WorkBuddy 桌面版（鸿蒙 PC 上就是它）
        home / ".codebuddy" / "skills",       # CodeBuddy
        home / ".claude" / "skills",          # Claude Code
        home / ".agents" / "skills",          # 通用别名（Codex / Copilot CLI / Gemini CLI…）
        home / ".config" / "agents" / "skills",
        Path.cwd() / ".codebuddy" / "skills",  # 项目级技能目录
    ]


def cwd_safe() -> "Path | None":
    try:
        return Path.cwd()
    except OSError:
        return None


def is_openspec_generated(d: Path) -> bool:
    """d 是不是被 openspec 托管（`openspec init/update` 生成的技能目录）。

    判据：它直接装着 `openspec-*` 技能。这类目录**不能当安装目标**——下一次
    `openspec update` 会把其中内容整片重刷，装进去的技能会静默消失。"""
    if not d.is_dir():
        return False
    try:
        return any((c / "SKILL.md").is_file() for c in d.glob("openspec-*"))
    except OSError:
        return False


def usable_candidates() -> "list[Path]":
    """候选目录，剔除被 openspec 托管的项目内 `.codebuddy/skills`。"""
    out = []
    for c in skill_root_candidates():
        if is_openspec_generated(c):
            print(f"[install_skill] 跳过 {c}：这是 openspec 生成并托管的目录，"
                  f"下一次 `openspec update` 会重刷它", file=sys.stderr)
            continue
        out.append(c)
    return out


def pick_skills_root(explicit: "str | None", wanted: "list[str]") -> Path:
    """定安装目标：--skills-root > 放着 fountain-developer 的目录 > 已装过目标技能的目录
    > 第一个存在的候选 > ~/.workbuddy/skills（新建）。"""
    if explicit:
        return Path(explicit).expanduser()
    cands = usable_candidates()
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


def fountain_root_readonly(explicit: "str | None") -> "Path | None":
    """只定位、不克隆。给 `list` 这类「看一眼状态」的场景用——
    为了显示状态去拉一份 30~45MB 的文档副本是没人想要的副作用。"""
    return _fountain_lookup().find_root(explicit)


def source_from_fountain(fountain_root_dir: Path, name: str) -> "tuple[Path | None, str]":
    """从 fountain 仓库的 skills/<name> 取技能源。找不到时带可操作的处理提示。"""
    src = fountain_root_dir / "skills" / name
    ok, why = check_frontmatter(src, name)
    if ok:
        return src, ""
    if (src / "SKILL.md").is_file():
        return None, f"{src} 不是 {name}（{why}）"
    fl = _fountain_lookup()
    if fl.is_doc_clone(fountain_root_dir):
        # 文档副本可能停在没有该技能的旧版本（查询按在用版本切过）：切回默认分支最新再找一次。
        # 下一次查询会自动切回在用版本，所以这一步不影响查询口径。
        ok, note = fl.switch_latest(fountain_root_dir)
        if ok:
            print(f"[install_skill] 文档副本{note}，重新查找 skills/{name}", file=sys.stderr)
            src = fountain_root_dir / "skills" / name
            if src.is_dir():
                return src, ""
    hint = (
        f"fountain 仓库（{fountain_root_dir}）里没有 skills/{name}。\n"
        "  常见原因与处理：\n"
        "  - 检出的分支 / 标签还没有这批技能：切到含它的分支"
        "（如 `git -C <fountain> switch sts/1.3.x`）；\n"
        "  - 源码 / 副本停在没有该技能的旧版本：更新到含它的版本"
        "（文档副本用 `python scripts/fountain_lookup.py switch latest`）；\n"
        "  - 该技能尚未提交进 fountain 仓库（它由 fountain 仓库随源码分发）：先提交 / 换一份含它的源码；\n"
        "  - 或用 --fountain-root 指到一份含 skills/<技能> 的 fountain 源码。"
    )
    return None, hint


def source_doc_lookup(fountain_root_dir: Path) -> "tuple[Path | None, str]":
    return source_from_fountain(fountain_root_dir, "cangjie-doc-lookup")


# ---- 来源三：opsx-* 技能族（12 个，鸿蒙 PC 上执行 OpenSpec 的通道）----------

OPSX_SKILLS = [
    "opsx-propose", "opsx-explore", "opsx-new", "opsx-continue",
    "opsx-apply", "opsx-update", "opsx-ff", "opsx-sync",
    "opsx-archive", "opsx-bulk-archive", "opsx-verify", "opsx-onboard",
]


def install_one_from_fountain(fr: Path, root: Path, name: str, force: bool) -> "tuple[bool, str]":
    src, why = source_from_fountain(fr, name)
    if src is None:
        return False, why
    ok, note = install_dir(src, root / name, force)
    return ok, f"{note}（来源：{src}）"


def deploy_opsx_runner(fr: Path, force: bool) -> "tuple[bool, str]":
    """把运行器 opsx_fusion.py 部署到 ~/.workbuddy/scripts/。

    12 个 opsx-* 技能的命令都引用这个脚本（ssh 探测 / 连接信息固化 / 生成执行命令），
    技能装好但运行器缺失时，技能第一步就失败。源在 fountain 仓库的
    skills/fountain-developer/scripts/opsx_fusion.py。
    """
    src = fr / "skills" / "fountain-developer" / "scripts" / "opsx_fusion.py"
    if not src.is_file():
        return False, f"运行器源不存在：{src}（该检出还没合入运行器，切到含它的分支再试）"
    dest_dir = Path.home() / ".workbuddy" / "scripts"
    dest = dest_dir / "opsx_fusion.py"
    if dest.is_file():
        if dest.read_bytes() == src.read_bytes():
            return True, f"已部署且与来源一致（{dest}）"
        if not force:
            return True, f"已存在，未覆盖（要覆盖加 --force）：{dest}"
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return True, f"已部署到 {dest}"


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


# ---- 来源四：cangjie_harness 仓（代码审查 / 架构设计等审议式技能）--------

HARNESS_REPO = "https://gitcode.com/zhangyin_gitcode/cangjie_harness.git"
DEFAULT_HARNESS_DIR = Path.home() / ".cangjie-harness" / "cangjie_harness"


def _download_file(url: str, dest: Path) -> bool:
    """优先 urllib，失败再用 curl；都不可用返回 False。"""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "fountain-developer-install-skill"})
        with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
        return dest.is_file() and dest.stat().st_size > 0
    except Exception:
        curl = shutil.which("curl")
        if not curl:
            return False
        r = subprocess.run([curl, "-L", "--fail", "--max-time", "300", "-o", str(dest), url],
                           capture_output=True, text=True)
        return r.returncode == 0 and dest.is_file() and dest.stat().st_size > 0


def _safe_extract(zpath: Path, dest: Path) -> bool:
    """解压 zip，拒绝越出 dest 的路径（防 zip-slip）。"""
    try:
        with zipfile.ZipFile(zpath) as z:
            root = dest.resolve()
            for member in z.infolist():
                target = (dest / member.filename).resolve()
                if target != root and root not in target.parents:
                    return False
            z.extractall(dest)
        return True
    except (OSError, zipfile.BadZipFile):
        return False


def download_repo_archive(base_url: str, repo_dir: Path,
                          branches: "tuple[str, ...]" = ("main", "master")) -> "tuple[bool, str]":
    """git 不可用时的兜底：下载 GitCode 仓库 zip 归档并解压到 repo_dir。"""
    tmp = Path(tempfile.mkdtemp(prefix="skill-archive-"))
    try:
        for branch in branches:
            for url in (f"{base_url}/archive/refs/heads/{branch}.zip",
                        f"{base_url}/archive/{branch}.zip"):
                zpath = tmp / "repo.zip"
                if not _download_file(url, zpath) or not zipfile.is_zipfile(zpath):
                    continue
                unpack = tmp / "unpack"
                shutil.rmtree(unpack, ignore_errors=True)
                unpack.mkdir()
                if not _safe_extract(zpath, unpack):
                    continue
                tops = [p for p in unpack.iterdir() if p.is_dir()]
                if len(tops) != 1:
                    continue
                if repo_dir.exists():
                    shutil.rmtree(repo_dir, ignore_errors=True)
                shutil.copytree(tops[0], repo_dir)
                return True, f"已用归档下载（{branch}）"
        return False, "git 不可用且归档下载失败（检查网络或仓库地址）"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def clone_via_fusion(repo_dir: Path, base_url: str) -> "tuple[bool, str]":
    """本机没有 git 时，借融合开发引擎的 git 克隆到共享目录。

    `repo_dir` 必须在本机家目录下（融合侧看到的是 `<sharePrefix>/<家目录>/...`），
    克隆完成后本机通过共享挂载直接可见。没有配置 fusion.ssh 时返回失败，由调用方
    继续尝试归档下载。
    """
    try:
        sys.path.insert(0, str(SCRIPT_DIR))
        import opsx_fusion as fx  # noqa: E402
    except Exception as exc:  # noqa: BLE001
        return False, f"无法加载 opsx_fusion：{exc}"
    cfg = fx.load_config(Path.home())
    ssh = fx.ssh_config(cfg)
    if not ssh["host"] or not ssh["user"]:
        return False, "fusion.ssh 未配置（先跑 opsx_fusion.py ssh-check）"
    home = str(Path.home())
    if not str(repo_dir).startswith(home + os.sep):
        return False, f"缓存目录不在本机家目录下，无法映射到融合侧：{repo_dir}"
    remote = fx.share_prefix(cfg).rstrip("/") + str(repo_dir)
    script = (
        "set -e\n"
        f"mkdir -p {shlex.quote(str(Path(remote).parent))}\n"
        f"if [ -d {shlex.quote(remote)} ]; then rmdir {shlex.quote(remote)} 2>/dev/null || true; fi\n"
        f"git clone --depth 1 {shlex.quote(base_url)} {shlex.quote(remote)}\n"
    )
    code, out = fx.run(["ssh", *fx.ssh_opts(ssh), fx.ssh_target(ssh), "bash -s"],
                       cwd=Path.home(), input_text=script, timeout=1800)
    if code != 0:
        return False, f"融合侧克隆失败：{out[-300:]}"
    if not repo_dir.is_dir():
        return False, f"融合侧克隆完成但本机看不到 {repo_dir}（共享挂载不可用？）"
    return True, f"已通过融合侧 git 克隆（{fx.ssh_target(ssh)}:{remote}）"


def ensure_harness_repo(repo_dir: Path) -> "tuple[bool, str]":
    """确保 repo_dir 是 cangjie_harness 的检出；本机无 git 时借融合侧或归档。"""
    if repo_dir.is_dir() and any(repo_dir.rglob("SKILL.md")):
        if (repo_dir / ".git").exists():
            r = git_run(["-C", str(repo_dir), "pull", "--ff-only"], 900)
            return True, "已存在，git pull --ff-only 更新" if r.returncode == 0 else "已存在，pull 未成功（沿用现有检出）"
        return True, "沿用现有检出（非 git 目录）"
    if repo_dir.exists():
        return False, f"{repo_dir} 已存在但不是技能仓，请清理后重试"
    repo_dir.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("git"):
        r = git_run(["clone", "--depth", "1", HARNESS_REPO, str(repo_dir)], 1800)
        if r.returncode == 0:
            return True, "已浅克隆"
        print(f"[install_skill] git clone 失败，改用其它通道：{(r.stderr or '').strip()[-200:]}",
              file=sys.stderr)
    ok, note = clone_via_fusion(repo_dir, HARNESS_REPO)
    if ok:
        return True, note
    print(f"[install_skill] 融合侧克隆不可用（{note}），尝试归档下载……", file=sys.stderr)
    return download_repo_archive(HARNESS_REPO, repo_dir)


def discover_skill_dirs(repo_dir: Path) -> "dict[str, Path]":
    """找 repo_dir 下所有有效技能目录（SKILL.md 的 name 与目录名一致）。"""
    found: "dict[str, Path]" = {}
    for md in sorted(repo_dir.rglob("SKILL.md")):
        if ".git" in md.parts or "__pycache__" in md.parts:
            continue
        d = md.parent
        ok, why = check_frontmatter(d, d.name)
        if ok and d.name not in found:
            found[d.name] = d
        elif not ok:
            print(f"[install_skill] 跳过无效技能目录 {d}（{why}）", file=sys.stderr)
    return found


def install_harness_all(a: argparse.Namespace, root: Path) -> "tuple[bool, str]":
    repo_dir = Path(a.harness_dir).expanduser() if a.harness_dir else DEFAULT_HARNESS_DIR
    ok, note = ensure_harness_repo(repo_dir)
    if not ok:
        return False, note
    skills = discover_skill_dirs(repo_dir)
    if not skills:
        return False, f"仓库里没找到有效技能：{repo_dir}"
    if "cangjie-code-review-harness" not in skills:
        return False, f"harness 仓里没有 cangjie-code-review-harness（仓库结构可能已变）：{repo_dir}"
    failed = []
    for name, src in sorted(skills.items()):
        ok2, note2 = install_dir(src, root / name, a.force)
        print(f"[{'ok' if ok2 else '失败'}] {name}：{note2}")
        if not ok2:
            failed.append(name)
    summary = f"{len(skills) - len(failed)}/{len(skills)} 个技能（来源：{repo_dir}；{note}）"
    if failed:
        summary += f"；未装好：{'、'.join(failed)}"
    return not failed, summary


# ---- 来源五：fountain 仓库 skills/ 下全部技能 ----------------------------


def install_fountain_all(a: argparse.Namespace, root: Path) -> "tuple[bool, str]":
    fr = fountain_root(a.fountain_root)
    skills_dir = fr / "skills"
    if not skills_dir.is_dir():
        return False, f"{fr} 里没有 skills/ 目录（该检出可能太旧）"
    names = sorted(p.name for p in skills_dir.iterdir()
                   if (p / "SKILL.md").is_file() and p.name != "fountain-developer")
    if not names:
        return False, f"{skills_dir} 下没有可安装的技能"
    required = ["cangjie-doc-lookup"] + OPSX_SKILLS
    missing = [n for n in required if not (skills_dir / n / "SKILL.md").is_file()]
    if missing:
        return False, (f"{skills_dir} 缺工作流 L 依赖：{'、'.join(missing)}；"
                       f"切到含这些技能的 fountain 检出（如 git -C {fr} switch sts/1.3.x）后重试")
    failed = []
    for name in names:
        src = skills_dir / name
        ok2, note2 = install_dir(src, root / name, a.force)
        print(f"[{'ok' if ok2 else '失败'}] {name}：{note2}")
        if not ok2:
            failed.append(name)
    if any(n in OPSX_SKILLS for n in names):
        ok3, note3 = deploy_opsx_runner(fr, a.force)
        print(f"[{'ok' if ok3 else '失败'}] opsx_fusion.py（运行器）：{note3}")
        if not ok3:
            failed.append("opsx_fusion.py")
    summary = (f"{len(names) - len(failed)}/{len(names)} 个技能（来源：{skills_dir}；"
               f"跳过 fountain-developer 自身）")
    if failed:
        summary += f"；未装好：{'、'.join(failed)}"
    return not failed, summary


# ---- 命令 --------------------------------------------------------------


def cmd_list(a: argparse.Namespace) -> None:
    root = pick_skills_root(a.skills_root, ["cangjie-coding", "cangjie-doc-lookup"] + OPSX_SKILLS)
    print(f"技能目录：{root}{'' if root.is_dir() else '（尚不存在）'}")
    print()
    for label, names in (
        ("cangjie-coding / cangjie-doc-lookup（仓颉知识库与文档）", ["cangjie-coding", "cangjie-doc-lookup"]),
        ("opsx-*（鸿蒙 PC 上执行 OpenSpec 的通道）", OPSX_SKILLS),
    ):
        done = sum(1 for n in names if (root / n / "SKILL.md").is_file())
        print(f"{label}：{done}/{len(names)} 已装")
        for name in names:
            installed = (root / name / "SKILL.md").is_file()
            print(f"  [{'已装' if installed else '未装'}] {name}")
    print()
    print("来源：")
    fr = fountain_root_readonly(a.fountain_root)
    if fr is None:
        print("  cangjie-doc-lookup  <- 未找到本机 fountain 源码（list 只为看状态，不会为此克隆）")
        print("  opsx-*（12 个）      <- 同上；用 --fountain-root 指定，或按 references/environment.md"
              " 先让 fountain_lookup.py 克隆一份文档副本")
    else:
        src, why = source_from_fountain(fr, "cangjie-doc-lookup")
        print(f"  cangjie-doc-lookup  <- {src if src else f'不可用（{why.splitlines()[0]}）'}")
        have = [n for n in OPSX_SKILLS if (fr / "skills" / n).is_dir()]
        if len(have) == len(OPSX_SKILLS):
            print(f"  opsx-*（12 个）      <- {fr / 'skills'}（全部可用）")
        else:
            miss = [n for n in OPSX_SKILLS if n not in have]
            print(f"  opsx-*（12 个）      <- {fr / 'skills'} 只有 {len(have)}/12"
                  f"（缺：{', '.join(miss[:3])}{' 等' if len(miss) > 3 else ''}）")
            print(f"     该检出还没这批技能：切到含它的分支再试"
                  f"（git -C {fr} switch sts/1.3.x），或 --fountain-root 指到含 skills/opsx-* 的源码")
    repo_dir = Path(a.repo_dir).expanduser() if a.repo_dir else DEFAULT_REPO_DIR
    src2, why2 = source_cangjie_skills(repo_dir, "cangjie-coding")
    state = "已克隆" if (repo_dir / ".git").exists() else "未克隆（首次安装时自动克隆）"
    print(f"  cangjie-coding      <- {src2 if src2 else f'{CANGJIE_SKILLS_REPO}（{state}）'}")
    harness_ok = (root / "cangjie-code-review-harness" / "SKILL.md").is_file()
    print(f"  cangjie-code-review-harness <- "
          f"{'已装' if harness_ok else '未装（工作流 L：install_skill.py harness）'}")
    if fr is not None:
        all_names = sorted(p.name for p in (fr / "skills").iterdir()
                           if (p / "SKILL.md").is_file() and p.name != "fountain-developer")
        all_done = sum(1 for n in all_names if (root / n / "SKILL.md").is_file())
        print(f"  fountain 全部技能    <- {fr / 'skills'}（已装 {all_done}/{len(all_names)}，不含自身）")
    runner = Path.home() / ".workbuddy" / "scripts" / "opsx_fusion.py"
    print(f"  opsx_fusion.py（运行器）<- {runner}（{'已部署' if runner.is_file() else '未部署：装 opsx 时自动部署'}）")


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
        description="给 fountain-developer 补装联动技能（cangjie-coding / doc-lookup / opsx-* / harness / fountain 全部）",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("list", "cangjie-coding", "cangjie-doc-lookup", "opsx", "all", "harness", "fountain"):
        p = sub.add_parser(name, help=f"{name} 子命令")
        p.add_argument("--skills-root", default=None, help="目标技能目录（默认自动探测）")
        p.add_argument("--fountain-root", default=None, help="fountain 仓库根（默认自动定位）")
        p.add_argument("--repo-dir", default=None, help=f"CangjieSkills 克隆位置（默认 {DEFAULT_REPO_DIR}）")
        p.add_argument("--harness-dir", default=None, help=f"cangjie_harness 克隆位置（默认 {DEFAULT_HARNESS_DIR}）")
        p.add_argument("--force", action="store_true", help="目标已存在时覆盖")
    args = parser.parse_args()

    if args.cmd == "list":
        cmd_list(args)
        return

    if args.cmd == "harness":
        root = pick_skills_root(args.skills_root, ["cangjie-code-review-harness"])
        print(f"安装目标：{root}\n")
        ok, note = install_harness_all(args, root)
        print(f"\n[{'ok' if ok else '失败'}] harness：{note}")
        sys.exit(0 if ok else 1)

    if args.cmd == "fountain":
        root = pick_skills_root(args.skills_root, ["cangjie-doc-lookup"] + OPSX_SKILLS)
        print(f"安装目标：{root}\n")
        ok, note = install_fountain_all(args, root)
        print(f"\n[{'ok' if ok else '失败'}] fountain：{note}")
        sys.exit(0 if ok else 1)

    if args.cmd == "all":
        wanted = ["cangjie-coding", "cangjie-doc-lookup"] + OPSX_SKILLS
    elif args.cmd == "opsx":
        wanted = list(OPSX_SKILLS)
    else:
        wanted = [args.cmd]
    root = pick_skills_root(args.skills_root, wanted)
    print(f"安装目标：{root}\n")
    failed = []
    fr = None
    fr_err = None
    for name in wanted:
        if name in OPSX_SKILLS:
            if fr is None and fr_err is None:
                try:
                    fr = fountain_root(args.fountain_root)
                except SystemExit as e:
                    fr_err = str(e)
            ok, note = (False, fr_err) if fr_err else install_one_from_fountain(fr, root, name, args.force)
        elif name == "cangjie-doc-lookup":
            ok, note = install_doc_lookup(args, root)
        else:
            ok, note = install_cangjie_coding(args, root)
        print(f"[{'ok' if ok else '失败'}] {name}：{note}")
        if not ok:
            failed.append(name)
    if any(n in OPSX_SKILLS for n in wanted):
        if fr_err:
            print(f"[失败] opsx_fusion.py（运行器）：{fr_err}")
            failed.append("opsx_fusion.py")
        else:
            ok, note = deploy_opsx_runner(fr, args.force)
            print(f"[{'ok' if ok else '失败'}] opsx_fusion.py（运行器）：{note}")
            if not ok:
                failed.append("opsx_fusion.py")
    print()
    if failed:
        print(f"[!] 未装好：{'、'.join(failed)}（按上面的原因处理后重跑）", file=sys.stderr)
        sys.exit(1)
    print("装好后按正常方式加载这些技能；本技能「必须遵守」里的联动要求即可满足。")


if __name__ == "__main__":
    main()

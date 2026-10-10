#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fountain 仓库检索工具（供 fountain-developer 技能使用）。

只读工具：按「在用版本」定位 fountain 仓库根、列出模块、按关键词检索 README 与源码声明。
仅依赖 Python 3 标准库，Windows / WSL / Linux 通用。

用法：
  python fountain_lookup.py root [--no-clone]
  python fountain_lookup.py modules [--all]
  python fountain_lookup.py search <关键词> [--in readme|code|docs|all] [--module NAME] [--max N]
  python fountain_lookup.py api <模块名> [--max N]
  python fountain_lookup.py version                      # 打印查询版本与文档副本状态
  python fountain_lookup.py switch <版本号|tag|latest>    # 把文档副本切到指定版本

全局选项（子命令前、后均可）：--version X.Y.Z、--root DIR、--no-clone、--repo-url URL

查询版本（决定 README / 源码取自哪个版本）：
  --version X.Y.Z  >  $FOUNTAIN_VERSION  >  当前项目 cjpm.toml 的 "fountain::f_*" 依赖版本
  （从当前目录向上找最近的、声明了 fountain 版本依赖的 cjpm.toml；都没定就不切版本）

定位仓库根的优先级：
  1. --root 参数
  2. 环境变量 FOUNTAIN_ROOT
  3. 从当前目录向上查找
  4. 从本脚本位置向上查找（技能源码放在 fountain 仓库内时的 skills/fountain-developer/ 上溯）
  5. 技能目录下的克隆副本 <skill-root>/fountain

  （判据：存在 f_version/src/FountainVersion.cj）

以上都找不到时，自动执行：
  git clone --depth 1 https://gitcode.com/Cangjie-SIG/fountain.git <skill-root>/fountain
该克隆副本**仅用于查询文档**（README / 源码 API 参考），不要用于构建或安装
（构建/安装用用户自己的 fountain 源码，或中心仓；--no-clone 可禁用自动克隆，
--repo-url 可换镜像地址）。

**按版本切副本**：定了查询版本而副本不在该版本上时，脚本先 `git fetch --depth 1 origin tag <tag>`
再 `checkout --detach <tag>`（只取该版本快照，不拉整仓历史）。tag 按**tag 名里的数字版本号**定位：
cjpm 只接受 a.b.c 形式的数字版本号，而数字版本号在 tag 名里唯一，所以 `release-1.3.14.alpha` /
`release-1.0.13` / `release-1.0.13.1` / `v1.3.9` 这类形态都能对上，不必猜后缀（也支持直接给 tag 名）。
切版本只作用于技能目录下的文档副本：`--root` / `$FOUNTAIN_ROOT` 指定的源码目录只读不改（版本不符时输出警告），
自动发现的源码目录版本不符时改用文档副本。
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

MARKER = Path("f_version") / "src" / "FountainVersion.cj"
DEFAULT_REPO_URL = "https://gitcode.com/Cangjie-SIG/fountain.git"
CLONE_DIR_NAME = "fountain"
SKIP_PARTS = {"target", ".build-logs", ".git", "node_modules", ".assets", ".cache"}
TOOL_MODULES = {"fboot": "工具", "fcoder": "工具"}
SAMPLE_MODULES = {"fdemo": "示例应用", "frpcdemo": "示例应用"}
SERVICE_MODULES = {"fleet": "服务"}
CLONE_HINT = "（自动克隆的文档副本，仅用于查询文档；构建/安装请用用户自己的 fountain 源码或中心仓）"

VERSION_MARKER_RE = re.compile(r'public\s+const\s+Version\s*(?::\s*String\s*)?=\s*"([^"]+)"')
TAG_VERSION_RE = re.compile(r"\d+(?:\.\d+)+")
DEP_VERSION_RE = re.compile(
    r'^\s*"fountain::([A-Za-z0-9_]+)"\s*=\s*(?:"([^"]+)"|\{[^}]*?version\s*=\s*"([^"]+)")',
    re.M,
)
DEFAULT_BRANCH = "master"
CTX: dict[str, str] = {}  # 本次运行：目标版本 / 来源 / 警告（供输出标注）


def script_hint() -> str:
    """输出里给出的本脚本调用示例（绝对路径，可直接复制执行）。"""
    return f'python "{Path(__file__).resolve()}"'


def die(msg: str) -> "None":
    print(msg, file=sys.stderr)
    sys.exit(1)


def skill_root() -> Path:
    """技能根目录（本脚本位于 <skill-root>/scripts/ 下）。"""
    return Path(__file__).resolve().parent.parent


def clone_dest() -> Path:
    return skill_root() / CLONE_DIR_NAME


def is_doc_clone(root: Path) -> bool:
    try:
        return os.path.normcase(str(root.resolve())) == os.path.normcase(
            str(clone_dest().resolve())
        )
    except OSError:
        return False


def rel_of(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


# ---- 版本：目标版本解析 + 文档副本按版本切换 --------------------------


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def source_version(root: Path) -> "str | None":
    """仓库根（或副本）当前源码版本：f_version/src/FountainVersion.cj 的 Version。"""
    m = VERSION_MARKER_RE.search(read_text(root / MARKER))
    return m.group(1) if m else None


def git_run(args: list[str], cwd: Path | None = None, timeout: int = 600):
    try:
        return subprocess.run(
            ["git", *args],
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(["git", *args], 127, "", str(e))


def git_tag_at_head(repo: Path) -> "str | None":
    r = git_run(["describe", "--tags", "--exact-match", "HEAD"], repo, 60)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def git_branch(repo: Path) -> "str | None":
    r = git_run(["symbolic-ref", "--short", "-q", "HEAD"], repo, 60)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def describe_root(root: Path) -> str:
    """一句话描述仓库根/副本的版本状态（用于输出标注）。"""
    parts = []
    ver = source_version(root)
    if ver:
        parts.append(f"版本 {ver}")
    if (root / ".git").exists():
        tag = git_tag_at_head(root)
        if tag:
            parts.append(f"tag {tag}")
        else:
            br = git_branch(root)
            parts.append(f"分支 {br}" if br else "detached")
    return "，".join(parts) or "版本未知"


def project_version(start: Path) -> "tuple[str, Path, str] | None":
    """从 start 向上找最近的、声明了 fountain 版本依赖的 cjpm.toml（= 当前项目在用版本）。"""
    for d in [start, *start.parents]:
        f = d / "cjpm.toml"
        if not f.is_file():
            continue
        deps: dict[str, str] = {}
        for m in DEP_VERSION_RE.finditer(read_text(f)):
            deps.setdefault(m.group(1), m.group(2) or m.group(3))
        if not deps:
            continue
        name = next((n for n in ("f_version", "f_base") if n in deps), next(iter(deps)))
        note = ""
        if len(set(deps.values())) > 1:
            note = "（依赖里版本不一致：" + "、".join(
                f"{k}={v}" for k, v in sorted(deps.items())
            ) + "）"
        return deps[name], f, note
    return None


def target_version(a: argparse.Namespace) -> "tuple[str | None, str]":
    """定查询版本：--version > $FOUNTAIN_VERSION > 当前项目 cjpm.toml 的 fountain 依赖版本。"""
    v = getattr(a, "version", None)
    if v:
        return v, "--version 指定"
    v = os.environ.get("FOUNTAIN_VERSION")
    if v:
        return v, "$FOUNTAIN_VERSION 指定"
    hit = project_version(Path.cwd().resolve())
    if hit:
        ver, f, note = hit
        return ver, f"当前项目依赖 {f}{note}"
    return None, "未定（可用 --version 指定；不切副本）"


def tag_version(tag: str) -> "str | None":
    """tag 名里的数字版本号：release-1.3.14.alpha → 1.3.14，release-1.0.13.1 → 1.0.13.1。"""
    m = TAG_VERSION_RE.search(tag)
    return m.group(0) if m else None


def tag_candidates(version: str) -> list[str]:
    """取不到 tag 名单（离线 / 镜像不支持）时直接试取的常见形态。"""
    if not re.match(r"^[0-9]", version):
        return [version]  # 用户直接给了 tag 名
    return [f"release-{version}", f"release-{version}.alpha", f"v{version}", version]


def pick_tag(available, version: str) -> "tuple[str | None, str]":
    """按版本号挑 tag，返回 (tag, 附注)。

    两种输入：**数字版本号**（cjpm.toml 只接受 a.b.c 形式，用户给的通常就是它）按 tag 名里的数字
    版本号精确匹配——数字版本号在各 tag 名里唯一（实测本仓 76 个 tag 无重复），所以不必猜后缀形态：
    release-1.3.14.alpha / release-1.0.13.1 / release-1.1.2.BETA / v2.0.0 都能对上；
    **其它输入**只按 tag 名精确匹配，不做数字兜底（`release-1.3.9.alpha` 就是它本身）。
    """
    if version in available:
        return version, ""
    if not re.fullmatch(r"\d+(?:\.\d+)+", version):
        return None, ""
    hits = sorted(t for t in available if tag_version(t) == version)
    if not hits:
        return None, ""
    if len(hits) == 1:
        return hits[0], ""
    plain = f"release-{version}"
    pick = plain if plain in hits else hits[0]
    return pick, f"该版本号对应多个 tag（{'、'.join(hits)}），取 {pick}"


def local_tags(repo: Path) -> set:
    r = git_run(["tag", "--list"], repo, 60)
    return set(r.stdout.split()) if r.returncode == 0 else set()


def remote_tags(repo: Path) -> set:
    """origin 上的 tag 名单；取不到（离线 / 不支持）时返回空集合。"""
    r = git_run(["ls-remote", "--tags", "--refs", "origin"], repo, 180)
    if r.returncode != 0:
        return set()
    return {
        ln.split("refs/tags/", 1)[1].strip()
        for ln in r.stdout.splitlines()
        if "refs/tags/" in ln
    }


def fetch_tag(repo: Path, tag: str, timeout: int = 900) -> bool:
    """浅取单个 tag（只取该版本的快照，不拉整仓历史）。"""
    print(f"[fountain_lookup] 取 {tag}（git fetch --depth 1 origin tag）", file=sys.stderr)
    r = git_run(["fetch", "--depth", "1", "origin", "tag", tag], repo, timeout)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip()[-500:]
        print(f"[fountain_lookup] 取 tag {tag} 失败：\n{tail}", file=sys.stderr)
        return False
    return True


def switch_clone(
    repo: Path, version: str, allow_net: bool = True, timeout: int = 900
) -> "tuple[bool, str]":
    """把文档副本切到 version（版本号或 tag 名）对应的 tag。"""
    cur = git_tag_at_head(repo)
    if cur and pick_tag({cur}, version)[0] == cur:
        return True, f"已在 {cur}"
    known = local_tags(repo)
    tag, note = pick_tag(known, version)
    if tag is None:
        if not allow_net:
            return False, f"副本里没有 {version} 对应的 tag（--no-clone：不做网络操作，取不到新版）"
        avail = remote_tags(repo)
        if avail:
            tag, note = pick_tag(avail, version)
        else:
            for c in tag_candidates(version):
                if fetch_tag(repo, c, timeout):
                    tag, known = c, known | {c}
                    break
        if tag is None:
            tried = "、".join(tag_candidates(version))
            why = (
                f"origin 的 tag 里没有版本号为 {version} 的 tag（试过 {tried}）"
                if avail
                else f"读不到 origin 的 tag 列表，直接试取也没成功（试过 {tried}）"
            )
            return False, why
    if tag not in known and not fetch_tag(repo, tag, timeout):
        return False, f"取 tag {tag} 失败"
    r = git_run(["checkout", "-q", "--detach", tag], repo, 300)
    if r.returncode != 0:
        r = git_run(["checkout", "-q", "-f", "--detach", tag], repo, 300)
        if r.returncode != 0:
            return False, f"checkout {tag} 失败：" + (r.stderr or r.stdout or "").strip()[-300:]
    return True, f"已切到 {tag}" + (f"（{note}）" if note else "")


def switch_latest(repo: Path, allow_net: bool = True, timeout: int = 900) -> "tuple[bool, str]":
    """把文档副本切回默认分支最新（不再停在某个 tag）。"""
    if not (repo / ".git").exists():
        return False, "文档副本还没有创建"
    if not allow_net:
        return False, "--no-clone：不做网络操作，不能切回默认分支最新"
    br = DEFAULT_BRANCH
    r = git_run(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], repo, 60)
    if r.returncode == 0 and r.stdout.strip().startswith("origin/"):
        br = r.stdout.strip().split("/", 1)[1]
    git_run(["fetch", "--depth", "1", "origin", br], repo, timeout)
    for args in (["checkout", "-q", "-B", br, f"origin/{br}"], ["checkout", "-q", "-f", br]):
        r = git_run(args, repo, 300)
        if r.returncode == 0:
            return True, f"已回到 {br}（默认分支）"
    return False, f"切回 {br} 失败：" + (r.stderr or r.stdout or "").strip()[-300:]


def ensure_clone(
    dest: Path,
    url: str,
    version: "str | None",
    allow_net: bool = True,
    timeout: int = 900,
) -> "tuple[bool, str]":
    """确保文档副本存在并按需切到 version；返回 (是否可用, 说明)。"""
    if not dest.exists():
        if not allow_net:
            return False, f"文档副本不存在：{dest}（--no-clone：不做网络操作，不能克隆）"
        if not clone_repo(dest, url, timeout):
            return False, "克隆失败"
    if not (dest / ".git").exists():
        return False, f"{dest} 已存在但不是 git 仓库（删掉该目录重试，或用 --root 指定现有源码）"
    if version:
        return switch_clone(dest, version, allow_net, timeout)
    if allow_net and git_branch(dest):
        r = git_run(["pull", "--ff-only"], dest, timeout)
        if r.returncode != 0:
            print("[fountain_lookup] 副本更新未成功，沿用现有副本", file=sys.stderr)
    return True, "沿用副本现状态（未指定版本）"


def find_root(explicit: str | None) -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    env = os.environ.get("FOUNTAIN_ROOT")
    if env:
        candidates.append(Path(env))
    cwd = Path.cwd().resolve()
    candidates.extend([cwd, *cwd.parents])
    sk = skill_root()
    candidates.extend([sk, *sk.parents])
    candidates.append(clone_dest())
    seen = set()
    for c in candidates:
        key = str(c)
        if key in seen:
            continue
        seen.add(key)
        try:
            if (c / MARKER).is_file():
                return c.resolve()
        except OSError:
            continue
    return None


def clone_repo(dest: Path, url: str, timeout: int = 900) -> bool:
    """克隆 fountain 仓库到 dest（已存在则直接用，更新/切版本由 ensure_clone 负责）。"""
    dest = dest.resolve()
    if dest.exists():
        if (dest / ".git").exists():
            return True
        print(
            f"[fountain_lookup] {dest} 已存在但不是 git 仓库；请删除后重试，"
            "或改用 --root / FOUNTAIN_ROOT 指定现有 fountain 源码。",
            file=sys.stderr,
        )
        return False

    print(
        "[fountain_lookup] 未找到本机 fountain 源码，正在克隆文档副本（--depth 1，约 30MB，视网络 10 秒~1 分钟）:\n"
        f"  {url}\n  -> {dest}",
        file=sys.stderr,
    )
    try:
        r = subprocess.run(
            ["git", "clone", "--depth", "1", url, str(dest)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as e:
        print(f"[fountain_lookup] git clone 失败: {e}", file=sys.stderr)
        return False
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip()
        print(
            f"[fountain_lookup] git clone 失败（exit {r.returncode}）:\n{tail[-800:]}",
            file=sys.stderr,
        )
        return False
    if not (dest / MARKER).is_file():
        print(
            f"[fountain_lookup] 克隆完成但缺少 {MARKER}，URL 可能不是 fountain 仓库: {url}",
            file=sys.stderr,
        )
        return False
    print(f"[fountain_lookup] 已克隆到 {dest}（仅用于查询文档）", file=sys.stderr)
    return True


def prepare_root(a: argparse.Namespace) -> Path:
    """解析目标版本与仓库根：文档副本先切到目标版本，再交给各查询命令使用。"""
    global CTX
    url = getattr(a, "repo_url", None) or DEFAULT_REPO_URL
    target, source = target_version(a)
    explicit = bool(getattr(a, "root", None)) or bool(os.environ.get("FOUNTAIN_ROOT"))
    allow_net = not getattr(a, "no_clone", False)
    root = find_root(getattr(a, "root", None))
    warn = ""

    def use_clone(reason: str):
        """把文档副本切到目标版本并改用它；失败返回 None 并留下警告。"""
        nonlocal warn
        ok, why = ensure_clone(clone_dest(), url, target, allow_net)
        if not ok:
            warn = f"⚠ {reason}，且文档副本不可用（{why}）"
            return None
        print(f"[fountain_lookup] {reason}，改用文档副本（{why}）", file=sys.stderr)
        got = source_version(clone_dest())
        if target and got and got != target:
            warn = f"⚠ 文档副本切到 {got}，与目标版本 {target} 不一致（{why}）"
        return clone_dest().resolve()

    if root is None:
        if getattr(a, "no_clone", False):
            die(
                "未找到 fountain 仓库根（已禁用自动克隆）：用 --root 指定，或设置环境变量 FOUNTAIN_ROOT，"
                "或在 fountain 仓库内执行本脚本。"
            )
        ok, note = ensure_clone(clone_dest(), url, target, allow_net)
        if not ok:
            die(
                f"未找到 fountain 仓库，且文档副本不可用：{note}\n"
                f"手动方式：git clone {url} <路径>，然后用 --root <路径> 或环境变量 FOUNTAIN_ROOT 指定。"
            )
        root = clone_dest().resolve()
        if target:
            print(f"[fountain_lookup] 文档副本：{note}", file=sys.stderr)
    elif is_doc_clone(root):
        ok, note = ensure_clone(root, url, target, allow_net)
        if not ok:
            warn = (
                f"⚠ 切版本失败：{note}；副本当前 {describe_root(root)}，"
                f"与目标版本 {target} 不一致 —— 下面结果可能对不上"
            )
        elif target:
            print(f"[fountain_lookup] 文档副本：{note}", file=sys.stderr)
    elif target:
        have = source_version(root)
        if have and have != target:
            if explicit:
                warn = (
                    f"⚠ 目标版本 {target} 与指定目录的源码版本 {have} 不一致；"
                    f"--root / $FOUNTAIN_ROOT 指定的目录不会被改动。"
                    f"要按 {target} 查请用文档副本：{script_hint()} switch {target}"
                )
            else:
                alt = use_clone(f"自动找到的源码是 {have}，与目标版本 {target} 不一致")
                if alt is not None:
                    root = alt

    CTX = {"target": target or "", "target_src": source, "warn": warn}
    return root


def root_label(root: Path) -> str:
    lines = [f"fountain 仓库: {root}（{describe_root(root)}）"]
    if is_doc_clone(root):
        lines.append(CLONE_HINT)
    if CTX.get("warn"):
        lines.append(CTX["warn"])
    return "\n".join(lines)


def module_names(root: Path) -> list[str]:
    names = []
    for p in sorted(root.iterdir()):
        if not p.is_dir() or p.name.startswith(".") or p.name in SKIP_PARTS:
            continue
        if (p / "cjpm.toml").is_file():
            names.append(p.name)
    return names


def module_kind(name: str) -> str:
    return (
        TOOL_MODULES.get(name)
        or SAMPLE_MODULES.get(name)
        or SERVICE_MODULES.get(name)
        or "库"
    )


def root_readme_desc(root: Path) -> dict[str, str]:
    p = root / "README.md"
    if not p.is_file():
        return {}
    text = p.read_text(encoding="utf-8", errors="replace")
    desc: dict[str, str] = {}
    for m in re.finditer(r"^### `fountain::([^`]+)`\s*$", text, re.M):
        name = m.group(1)
        seg = text[m.end():]
        nxt = re.search(r"^### ", seg, re.M)
        if nxt:
            seg = seg[: nxt.start()]
        for line in seg.splitlines():
            line = line.strip()
            if not line or line.startswith("也可以使用") or line.startswith("**详情请见"):
                continue
            desc[name] = line
            break
    return desc


def module_desc(root: Path, name: str, root_desc: dict[str, str]) -> str:
    if name in root_desc:
        return root_desc[name]
    p = root / name / "README.md"
    if p.is_file():
        text = p.read_text(encoding="utf-8", errors="replace")
        in_code = False
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("```"):
                in_code = not in_code
                continue
            if in_code or not s or s.startswith("#"):
                continue
            if s.startswith("**详情请见") or s.startswith("也可以使用"):
                continue
            return s
    return "(无描述)"


def scan_file(path: Path, pat: re.Pattern[str], limit: int) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    if not path.is_file():
        return rows
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                if pat.search(line):
                    rows.append((i, line.rstrip()))
                    if len(rows) >= limit:
                        break
    except OSError:
        pass
    return rows


def iter_code_files(root: Path, name: str):
    src = root / name / "src"
    if not src.is_dir():
        return
    for p in sorted(src.rglob("*.cj")):
        if any(part in SKIP_PARTS for part in p.parts):
            continue
        if p.name.endswith("_test.cj"):
            continue
        yield p


def cmd_root(a: argparse.Namespace) -> None:
    root = prepare_root(a)
    print(root)
    print(f"# {describe_root(root)}")
    if is_doc_clone(root):
        print(f"# {CLONE_HINT}")
    if CTX.get("warn"):
        print(f"# {CTX['warn']}")


def cmd_modules(a: argparse.Namespace) -> None:
    root = prepare_root(a)
    names = module_names(root)
    root_desc = root_readme_desc(root)
    print(root_label(root))
    print(f"共 {len(names)} 个模块（含工具与示例应用）")
    print()
    limit = 400 if a.all else 120
    for name in names:
        desc = module_desc(root, name, root_desc)
        if len(desc) > limit:
            desc = desc[: limit - 1] + "…"
        print(f"{name}\t{module_kind(name)}\t{desc}\t{name}/README.md")


def cmd_search(a: argparse.Namespace) -> None:
    root = prepare_root(a)
    names = module_names(root)
    if a.module and a.module not in names:
        die(f"未知模块: {a.module}\n可用模块: {', '.join(names)}")
    pat = re.compile(re.escape(a.keyword), re.I)

    groups: dict[str, list[tuple[str, int, str]]] = {}
    order: list[str] = []

    def add(key: str, path: Path) -> None:
        rows = scan_file(path, pat, a.per_file)
        if not rows:
            return
        if key not in groups:
            groups[key] = []
            order.append(key)
        for ln, txt in rows:
            groups[key].append((rel_of(path, root), ln, txt.strip()[:200]))

    if a.domain in ("all", "readme"):
        if a.module:
            add(a.module, root / a.module / "README.md")
        else:
            add("根 README", root / "README.md")
            if (root / "README_en.md").is_file():
                add("根 README", root / "README_en.md")
            for n in names:
                add(n, root / n / "README.md")
    if a.domain in ("all", "code"):
        for n in ([a.module] if a.module else names):
            for f in iter_code_files(root, n):
                add(n, f)
    if a.domain in ("all", "docs") and not a.module:
        docs = root / "docs"
        if docs.is_dir():
            for f in sorted(docs.rglob("*.md")):
                add("docs", f)

    total = sum(len(v) for v in groups.values())
    print(root_label(root))
    print(f'检索 "{a.keyword}"（{a.domain}），命中 {total} 处，最多显示 {a.max} 处')
    print()
    shown = 0
    for key in order:
        if shown >= a.max:
            break
        print(f"## {key}")
        for path_str, ln, txt in groups[key]:
            if shown >= a.max:
                print("…（其余省略；调大 --max 或加 --module/--in 缩小范围）")
                break
            print(f"  {path_str}:{ln}: {txt}")
            shown += 1
        print()
    if total == 0:
        print("无命中。可以换关键词、用 `--in code` 只搜源码，或用 `modules` 子命令看模块清单。")


def cmd_api(a: argparse.Namespace) -> None:
    root = prepare_root(a)
    names = module_names(root)
    if a.module not in names:
        die(f"未知模块: {a.module}\n可用模块: {', '.join(names)}")
    files = list(iter_code_files(root, a.module))
    print(f"# {a.module}（{module_kind(a.module)}）顶层声明，共 {len(files)} 个源文件")
    for line in root_label(root).splitlines():
        print(f"# {line}")
    print("# 判据：行首 `public` 或 `extend`（不含缩进成员）；完整签名请 read_file 对应行")
    print()
    for f in files:
        rows: list[tuple[int, str]] = []
        try:
            with f.open("r", encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    s = line.rstrip()
                    if s.startswith("public") or s.startswith("extend"):
                        rows.append((i, s))
        except OSError:
            continue
        if not rows:
            continue
        print(f"## {rel_of(f, root)}")
        for ln, s in rows[: a.max]:
            print(f"  {ln}: {s}")
        if len(rows) > a.max:
            print(f"  … 其余 {len(rows) - a.max} 条省略（--max 可调）")
        print()


def cmd_version(a: argparse.Namespace) -> None:
    """打印本次查询会用的版本与文档副本状态（不做切换）。"""
    target, source = target_version(a)
    clone = clone_dest()
    print("== 查询版本 ==")
    print(f"目标版本: {target or '（未指定）'}")
    print(f"          来源：{source}")
    print()
    print(f"文档副本: {clone}")
    if (clone / ".git").exists():
        print(f"          当前：{describe_root(clone)}")
    else:
        print("          尚未克隆（首次查询时自动创建）")
    print()
    root = find_root(getattr(a, "root", None))
    if root is None:
        print("仓库根: 本机没有找到 fountain 源码；查询时用文档副本")
    elif is_doc_clone(root):
        print(f"仓库根: {root}（文档副本；查询前会先切到目标版本）")
    else:
        print(f"仓库根: {root}（{describe_root(root)}；--root / $FOUNTAIN_ROOT 指定的目录只读不改）")
    print()
    print(f"切副本版本: {script_hint()} switch <版本号|tag|latest>")


def cmd_switch(a: argparse.Namespace) -> None:
    """把技能目录下的文档副本切到指定版本（只动副本，不动任何项目）。"""
    target = a.target
    clone = clone_dest()
    allow_net = not getattr(a, "no_clone", False)
    if target in ("latest", "master", "default"):
        if not (clone / ".git").exists():
            die(
                f"文档副本尚未创建：{clone}\n"
                f"先跑一次查询（如 modules），或 {script_hint()} switch <版本号> 之后再切 latest。"
            )
        ok, note = switch_latest(clone, allow_net)
    else:
        url = getattr(a, "repo_url", None) or DEFAULT_REPO_URL
        ok, note = ensure_clone(clone, url, target, allow_net)
        if ok and re.match(r"^[0-9]", target):
            got = source_version(clone)
            if got and got != target:
                ok = False
                note = f"切到了 {got}（tag {git_tag_at_head(clone) or '?'}），与目标版本 {target} 不一致"
    print(f"文档副本: {clone}")
    print(("ok: " if ok else "失败: ") + note)
    print(f"当前：{describe_root(clone)}")
    if not ok:
        sys.exit(1)


def main() -> None:
    # stdout / stderr 都固定 UTF-8：Windows 下重定向时默认按本地编码（GBK）写，中文会乱码，
    # 且 "⚠" 之类的字符会直接抛 UnicodeEncodeError。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

    # 全局选项（--version / --root / --no-clone / --repo-url）写在子命令前、后都支持：
    # 子命令侧用 SUPPRESS 默认值，避免覆盖主 parser 已解析到的值。
    common_main = argparse.ArgumentParser(add_help=False)
    common_main.add_argument(
        "--version",
        default=None,
        help="查询版本（版本号如 1.3.14，或 tag 名；默认取当前项目 cjpm.toml 的 fountain 依赖版本）",
    )
    common_main.add_argument("--root", default=None, help="fountain 仓库根（默认自动定位）")
    common_main.add_argument(
        "--no-clone",
        action="store_true",
        default=False,
        help="禁用自动克隆（找不到仓库时直接报错）",
    )
    common_main.add_argument(
        "--repo-url",
        default=None,
        help=f"克隆用的仓库地址（默认 {DEFAULT_REPO_URL}）",
    )
    common_sub = argparse.ArgumentParser(add_help=False)
    common_sub.add_argument("--version", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    common_sub.add_argument("--root", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    common_sub.add_argument(
        "--no-clone",
        action="store_true",
        default=argparse.SUPPRESS,
        help=argparse.SUPPRESS,
    )
    common_sub.add_argument("--repo-url", default=argparse.SUPPRESS, help=argparse.SUPPRESS)

    parser = argparse.ArgumentParser(
        prog="fountain_lookup.py",
        description="fountain 仓库检索工具：定位仓库根、模块清单、README 与源码检索。",
        parents=[common_main],
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("root", parents=[common_sub], help="打印 fountain 仓库根")
    p_mod = sub.add_parser("modules", parents=[common_sub], help="列出全部模块与描述")
    p_mod.add_argument("--all", action="store_true", help="不截断描述")

    p_search = sub.add_parser(
        "search", parents=[common_sub], help="按关键词检索 README / 源码 / docs"
    )
    p_search.add_argument("keyword", help="关键词（大小写不敏感，支持中文）")
    p_search.add_argument(
        "--in",
        dest="domain",
        choices=["readme", "code", "docs", "all"],
        default="all",
        help="检索范围（默认 all=readme+code+docs）",
    )
    p_search.add_argument("--module", help="只检索指定模块")
    p_search.add_argument("--max", type=int, default=60, help="最多显示条数（默认 60）")
    p_search.add_argument(
        "--per-file", type=int, default=20, help="每个文件最多条数（默认 20）"
    )

    p_api = sub.add_parser("api", parents=[common_sub], help="列出模块的顶层公开声明")
    p_api.add_argument("module", help="模块名，如 f_mvc")
    p_api.add_argument("--max", type=int, default=30, help="每个文件最多条数（默认 30）")

    sub.add_parser(
        "version", parents=[common_sub], help="打印查询版本与文档副本状态（不切换）"
    )
    p_sw = sub.add_parser(
        "switch",
        parents=[common_sub],
        help="把文档副本切到指定版本或 tag（latest = 回到默认分支最新）",
    )
    p_sw.add_argument("target", help="版本号（如 1.3.14）、tag 名（release-1.3.14.alpha）或 latest")

    args = parser.parse_args()
    if args.cmd == "root":
        cmd_root(args)
    elif args.cmd == "modules":
        cmd_modules(args)
    elif args.cmd == "search":
        cmd_search(args)
    elif args.cmd == "api":
        cmd_api(args)
    elif args.cmd == "version":
        cmd_version(args)
    elif args.cmd == "switch":
        cmd_switch(args)


if __name__ == "__main__":
    main()

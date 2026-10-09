#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fountain 仓库检索工具（供 fountain-developer 技能使用）。

只读工具：定位 fountain 仓库根、列出模块、按关键词检索 README 与源码声明。
仅依赖 Python 3 标准库，Windows / WSL / Linux 通用。

用法：
  python fountain_lookup.py root [--no-clone]
  python fountain_lookup.py modules [--all]
  python fountain_lookup.py search <关键词> [--in readme|code|docs|all] [--module NAME] [--max N]
  python fountain_lookup.py api <模块名> [--max N]

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
    """克隆（或更新）fountain 仓库到 dest；成功返回 True。所有进度写 stderr。"""
    dest = dest.resolve()
    if dest.exists():
        if (dest / ".git").exists():
            print(f"[fountain_lookup] 已存在克隆副本，尝试更新: {dest}", file=sys.stderr)
            try:
                r = subprocess.run(
                    ["git", "-C", str(dest), "pull", "--ff-only"],
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
            except (OSError, subprocess.SubprocessError) as e:
                print(f"[fountain_lookup] 更新失败: {e}", file=sys.stderr)
                r = None
            if r is not None and r.returncode == 0 and (dest / MARKER).is_file():
                print(f"[fountain_lookup] 更新完成: {dest}", file=sys.stderr)
                return True
            if (dest / MARKER).is_file():
                print(
                    f"[fountain_lookup] 更新未成功，沿用现有副本: {dest}", file=sys.stderr
                )
                return True
            print(
                f"[fountain_lookup] {dest} 已存在但内容不完整；请删除该目录后重试。",
                file=sys.stderr,
            )
            return False
        print(
            f"[fountain_lookup] {dest} 已存在但不是 git 仓库；请删除后重试，"
            "或改用 --root / FOUNTAIN_ROOT 指定现有 fountain 源码。",
            file=sys.stderr,
        )
        return False

    print(
        "[fountain_lookup] 未找到本机 fountain 源码，正在克隆文档副本（--depth 1，可能需要 1~2 分钟）:\n"
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


def resolve_root(a: argparse.Namespace) -> Path:
    root = find_root(getattr(a, "root", None))
    if root is not None:
        return root
    if getattr(a, "no_clone", False):
        die(
            "未找到 fountain 仓库根（已禁用自动克隆）：用 --root 指定，或设置环境变量 FOUNTAIN_ROOT，"
            "或在 fountain 仓库内执行本脚本。"
        )
    url = getattr(a, "repo_url", None) or DEFAULT_REPO_URL
    if clone_repo(clone_dest(), url):
        return clone_dest().resolve()
    die(
        "未找到 fountain 仓库，且自动克隆未能完成。\n"
        f"手动方式：git clone {url} <路径>，然后用 --root <路径> 或环境变量 FOUNTAIN_ROOT 指定。"
    )


def root_label(root: Path) -> str:
    return f"fountain 仓库: {root}" + (CLONE_HINT if is_doc_clone(root) else "")


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
    root = resolve_root(a)
    print(root)
    if is_doc_clone(root):
        print(CLONE_HINT)


def cmd_modules(a: argparse.Namespace) -> None:
    root = resolve_root(a)
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
    root = resolve_root(a)
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
    root = resolve_root(a)
    names = module_names(root)
    if a.module not in names:
        die(f"未知模块: {a.module}\n可用模块: {', '.join(names)}")
    files = list(iter_code_files(root, a.module))
    print(f"# {a.module}（{module_kind(a.module)}）顶层声明，共 {len(files)} 个源文件")
    if is_doc_clone(root):
        print(f"# {CLONE_HINT}")
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


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    # 全局选项（--root / --no-clone / --repo-url）写在子命令前、后都支持：
    # 子命令侧用 SUPPRESS 默认值，避免覆盖主 parser 已解析到的值。
    common_main = argparse.ArgumentParser(add_help=False)
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

    args = parser.parse_args()
    if args.cmd == "root":
        cmd_root(args)
    elif args.cmd == "modules":
        cmd_modules(args)
    elif args.cmd == "search":
        cmd_search(args)
    elif args.cmd == "api":
        cmd_api(args)


if __name__ == "__main__":
    main()
